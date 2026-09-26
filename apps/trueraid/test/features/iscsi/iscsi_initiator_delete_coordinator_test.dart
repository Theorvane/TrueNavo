import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/iscsi/iscsi_initiator_delete_coordinator.dart';
import 'package:trueraid/features/iscsi/iscsi_initiator_delete_editor.dart';
import 'package:trueraid/features/iscsi/iscsi_overview.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
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
  _Fake({this.advertiseDelete = true}) {
    adminCatalog = AdminCatalog.fromMetadata(
      version: '25.10.1',
      metadata: {
        'iscsi.initiator.query': _method(),
        if (advertiseDelete) 'iscsi.initiator.delete': _method(delete: true),
        'iscsi.target.query': _method(),
        'service.query': _method(),
        'iscsi.global.sessions': _method(),
      },
    );
  }
  final bool advertiseDelete;
  @override
  late final AdminCatalog adminCatalog;
  final groups = <Map<String, Object?>>[
    {
      'id': 3,
      'initiators': ['iqn.2026-01.example.com:host'],
      'comment': 'host',
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
  bool unknownDelete = false;
  bool leaveGroup = false;

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
      case 'iscsi.initiator.query':
        return AdminCompleted(
          request,
          value: [for (final row in groups) Map<String, Object?>.from(row)],
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
      case 'iscsi.initiator.delete':
        if (unknownDelete) return AdminOutcomeUnknown(request);
        if (!leaveGroup) {
          groups.removeWhere((row) => row['id'] == request.arguments.first);
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
  _Harness({bool advertiseDelete = true})
    : api = _Fake(advertiseDelete: advertiseDelete) {
    session = AuthenticatedSession(
      profileId: 'fixture',
      repository: api,
      availableMethodNames: const {},
      endpoint: 'wss://fixture.example/api/current',
    );
    coordinator = IscsiInitiatorDeleteCoordinator(
      session: session,
      api: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final _Fake api;
  late final AuthenticatedSession session;
  late final IscsiInitiatorDeleteCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes => api.calls
      .where((call) => call.method.name == 'iscsi.initiator.delete')
      .length;
}

void main() {
  test(
    'deletes only unreferenced group after exact review and readback',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(3);
      expect(h.writes, 0);
      expect(review.names, ['iqn.2026-01.example.com:host']);
      expect(review.confirmation, 'DELETE ISCSI INITIATOR #3');
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, IscsiInitiatorDeleteOutcome.completed);
      expect(h.writes, 1);
      expect(
        h.api.calls
            .singleWhere((call) => call.method.name == 'iscsi.initiator.delete')
            .arguments,
        [3],
      );
      expect(h.api.groups, isEmpty);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiInitiatorDeleteOutcome.rejected,
      );
    },
  );

  test(
    'target reference, running service, session or too many names block review',
    () async {
      final h = _Harness();
      h.api.targets.single['groups'] = [
        {'portal': 1, 'initiator': 3, 'authmethod': 'NONE', 'auth': null},
      ];
      await expectLater(h.coordinator.prepare(3), throwsStateError);
      h.api.targets.single['groups'] = [];
      h.api.state = 'RUNNING';
      await expectLater(h.coordinator.prepare(3), throwsStateError);
      h.api.state = 'STOPPED';
      h.api.sessions = true;
      await expectLater(h.coordinator.prepare(3), throwsStateError);
      h.api.sessions = false;
      h.api.groups.single['initiators'] = [
        for (var i = 0; i < 11; i++) 'iqn.2026-01.example.com:n$i',
      ];
      await expectLater(h.coordinator.prepare(3), throwsStateError);
      expect(h.writes, 0);
      expect(_Harness(advertiseDelete: false).coordinator.available, isFalse);
    },
  );

  test('inventory boundary and malformed access fail closed', () async {
    final h = _Harness();
    for (var id = 10; id < 109; id++) {
      h.api.groups.add({'id': id, 'initiators': [], 'comment': ''});
    }
    await expectLater(h.coordinator.prepare(3), throwsStateError);
    h.api.groups.removeRange(1, h.api.groups.length);
    h.api.targets.single['groups'] = [
      {'portal': 1, 'initiator': 'bad'},
    ];
    await expectLater(h.coordinator.prepare(3), throwsStateError);
    expect(h.writes, 0);
  });

  test(
    'drift, expiry, wrong phrase and session switch reject before write',
    () async {
      final h = _Harness();
      final first = await h.coordinator.prepare(3);
      h.api.targets.single['auth_networks'] = ['192.0.2.0/24'];
      expect(
        (await h.coordinator.execute(first, first.confirmation)).outcome,
        IscsiInitiatorDeleteOutcome.rejected,
      );
      h.api.targets.single['auth_networks'] = [];
      final second = await h.coordinator.prepare(3);
      h.clock = h.clock.add(const Duration(minutes: 5));
      expect(
        (await h.coordinator.execute(second, second.confirmation)).outcome,
        IscsiInitiatorDeleteOutcome.rejected,
      );
      final third = await h.coordinator.prepare(3);
      expect(
        (await h.coordinator.execute(third, 'wrong')).outcome,
        IscsiInitiatorDeleteOutcome.rejected,
      );
      final fourth = await h.coordinator.prepare(3);
      h.current = false;
      expect(
        (await h.coordinator.execute(fourth, fourth.confirmation)).outcome,
        IscsiInitiatorDeleteOutcome.rejected,
      );
      expect(h.writes, 0);
    },
  );

  test(
    'unknown result or failed readback fences further iSCSI writes',
    () async {
      final h = _Harness();
      h.api.unknownDelete = true;
      final review = await h.coordinator.prepare(3);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiInitiatorDeleteOutcome.unknown,
      );
      expect(h.coordinator.locked, isTrue);
      await expectLater(h.coordinator.prepare(3), throwsStateError);

      final other = _Harness();
      other.api.leaveGroup = true;
      final otherReview = await other.coordinator.prepare(3);
      expect(
        (await other.coordinator.execute(
          otherReview,
          otherReview.confirmation,
        )).outcome,
        IscsiInitiatorDeleteOutcome.unknown,
      );
      expect(other.coordinator.locked, isTrue);
    },
  );

  testWidgets('editor requires review and exact confirmation', (tester) async {
    final h = _Harness();
    final overview = IscsiOverview.parse(
      portals: [],
      initiators: h.api.groups,
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
          theme: TrueRAIDTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: IscsiInitiatorDeleteEditor(overview: overview),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-initiator-delete-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#3 iqn.2026-01.example.com:host').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-initiator-delete-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    await tester.enterText(
      find.byKey(const Key('iscsi-initiator-delete-confirmation')),
      'DELETE ISCSI INITIATOR #3',
    );
    await tester.ensureVisible(
      find.byKey(const Key('iscsi-initiator-delete-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-initiator-delete-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
  });
}
