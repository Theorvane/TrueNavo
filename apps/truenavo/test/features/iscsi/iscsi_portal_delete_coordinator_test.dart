import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/iscsi/iscsi_overview.dart';
import 'package:truenavo/features/iscsi/iscsi_portal_delete_coordinator.dart';
import 'package:truenavo/features/iscsi/iscsi_portal_delete_editor.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

Map<String, Object?> _method({bool delete = false}) => {
  'accepts': delete
      ? [
          {'_name_': 'id', '_required_': true, 'type': 'integer'},
        ]
      : <Object?>[],
  'returns': [
    {'type': delete ? 'boolean' : 'object', 'properties': <String, Object?>{}},
  ],
  'job': false,
  'filterable': false,
  'no_auth_required': false,
  'uploadable': false,
  'downloadable': false,
  'roles': ['FULL_ADMIN'],
};

class _Fake implements SessionRepository, AuthenticatedAdminSession {
  _Fake() {
    adminCatalog = AdminCatalog.fromMetadata(
      version: '25.10.1',
      metadata: {
        'iscsi.portal.query': _method(),
        'iscsi.portal.delete': _method(delete: true),
        'iscsi.target.query': _method(),
        'service.query': _method(),
        'iscsi.global.sessions': _method(),
      },
    );
  }
  @override
  late final AdminCatalog adminCatalog;
  final portals = <Map<String, Object?>>[
    {
      'id': 3,
      'tag': 5,
      'listen': [
        {'ip': '192.0.2.10', 'port': 3260},
      ],
      'comment': 'unused',
    },
  ];
  final targets = <Map<String, Object?>>[
    {
      'id': 4,
      'name': 'target',
      'mode': 'ISCSI',
      'groups': <Object?>[],
      'auth_networks': <Object?>[],
    },
  ];
  final calls = <AdminRequest>[];
  String state = 'STOPPED';
  bool sessions = false;
  bool unknown = false;
  bool leavePortal = false;

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
      case 'iscsi.portal.query':
        return AdminCompleted(
          request,
          value: [for (final row in portals) Map<String, Object?>.from(row)],
        );
      case 'iscsi.target.query':
        return AdminCompleted(
          request,
          value: [for (final row in targets) Map<String, Object?>.from(row)],
        );
      case 'service.query':
        return AdminCompleted(
          request,
          value: [
            {'service': 'iscsitarget', 'enable': false, 'state': state},
          ],
        );
      case 'iscsi.global.sessions':
        return AdminCompleted(
          request,
          value: sessions ? [<String, Object?>{}] : [],
        );
      case 'iscsi.portal.delete':
        if (unknown) return AdminOutcomeUnknown(request);
        if (!leavePortal) {
          portals.removeWhere((row) => row['id'] == request.arguments.first);
        }
        return AdminCompleted(request, value: true);
      default:
        throw StateError('Unexpected fake call');
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness() : api = _Fake() {
    session = AuthenticatedSession(
      profileId: 'fixture',
      repository: api,
      availableMethodNames: const {},
      endpoint: 'wss://fixture.example/api/current',
    );
    coordinator = IscsiPortalDeleteCoordinator(
      session: session,
      api: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final _Fake api;
  late final AuthenticatedSession session;
  late final IscsiPortalDeleteCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes => api.calls
      .where((call) => call.method.name == 'iscsi.portal.delete')
      .length;
}

void main() {
  test(
    'deletes only unreferenced portal after exact review and readback',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(3);
      expect(review.tag, 5);
      expect(review.listeners, ['192.0.2.10:3260']);
      expect(h.writes, 0);
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, IscsiPortalDeleteOutcome.completed);
      expect(h.writes, 1);
      expect(
        h.api.calls
            .singleWhere((call) => call.method.name == 'iscsi.portal.delete')
            .arguments,
        [3],
      );
      expect(h.api.portals, isEmpty);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiPortalDeleteOutcome.rejected,
      );
    },
  );

  test(
    'target reference, running service and active session block review',
    () async {
      final h = _Harness();
      h.api.targets.single['groups'] = [
        {'portal': 3, 'initiator': null, 'authmethod': 'NONE', 'auth': null},
      ];
      await expectLater(h.coordinator.prepare(3), throwsStateError);
      h.api.targets.single['groups'] = <Object?>[];
      h.api.state = 'RUNNING';
      await expectLater(h.coordinator.prepare(3), throwsStateError);
      h.api.state = 'STOPPED';
      h.api.sessions = true;
      await expectLater(h.coordinator.prepare(3), throwsStateError);
      expect(h.writes, 0);
    },
  );

  test(
    'review drift, wrong phrase and expiration reject without write',
    () async {
      final h = _Harness();
      var review = await h.coordinator.prepare(3);
      expect(
        (await h.coordinator.execute(review, 'wrong')).outcome,
        IscsiPortalDeleteOutcome.rejected,
      );
      review = await h.coordinator.prepare(3);
      h.api.targets.single['name'] = 'changed';
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiPortalDeleteOutcome.rejected,
      );
      h.api.targets.single['name'] = 'target';
      review = await h.coordinator.prepare(3);
      h.clock = h.clock.add(const Duration(minutes: 5));
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiPortalDeleteOutcome.rejected,
      );
      expect(h.writes, 0);
    },
  );

  test('session switch and ambiguous outcome fence further writes', () async {
    final h = _Harness();
    var review = await h.coordinator.prepare(3);
    h.current = false;
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiPortalDeleteOutcome.rejected,
    );
    h.current = true;
    review = await h.coordinator.prepare(3);
    h.api.unknown = true;
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiPortalDeleteOutcome.unknown,
    );
    expect(h.coordinator.locked, isTrue);
    await expectLater(h.coordinator.prepare(3), throwsStateError);
  });

  test('missing post-write deletion is unknown', () async {
    final h = _Harness();
    h.api.leavePortal = true;
    final review = await h.coordinator.prepare(3);
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiPortalDeleteOutcome.unknown,
    );
    expect(h.coordinator.locked, isTrue);
  });

  testWidgets('editor requires review and exact confirmation', (tester) async {
    final h = _Harness();
    final overview = IscsiOverview.parse(
      portals: h.api.portals,
      initiators: [],
      targets: h.api.targets,
      extents: [],
      mappings: [],
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
        ],
        child: MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: IscsiPortalDeleteEditor(overview: overview),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-portal-delete-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Portal #3').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-portal-delete-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    await tester.enterText(
      find.byKey(const Key('iscsi-portal-delete-confirmation')),
      'DELETE ISCSI PORTAL #3 TAG 5',
    );
    await tester.ensureVisible(
      find.byKey(const Key('iscsi-portal-delete-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-portal-delete-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
  });
}
