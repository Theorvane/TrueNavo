import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/iscsi/iscsi_overview.dart';
import 'package:truenavo/features/iscsi/iscsi_target_delete_coordinator.dart';
import 'package:truenavo/features/iscsi/iscsi_target_delete_editor.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

Map<String, Object?> _method({bool delete = false}) => {
  'accepts': delete
      ? [
          {'_name_': 'id', '_required_': true, 'type': 'integer'},
          {'_name_': 'force', '_required_': false, 'type': 'boolean'},
          {'_name_': 'delete_extents', '_required_': false, 'type': 'boolean'},
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
        'iscsi.target.query': _method(),
        'iscsi.targetextent.query': _method(),
        if (advertiseDelete) 'iscsi.target.delete': _method(delete: true),
        'service.query': _method(),
        'iscsi.global.sessions': _method(),
      },
    );
  }
  final bool advertiseDelete;
  @override
  late final AdminCatalog adminCatalog;
  final targets = <Map<String, Object?>>[
    {
      'id': 3,
      'name': 'unbound',
      'mode': 'ISCSI',
      'groups': [],
      'auth_networks': [],
    },
  ];
  final mappings = <Map<String, Object?>>[];
  final calls = <AdminRequest>[];
  String state = 'STOPPED';
  bool sessions = false;
  bool unknownDelete = false;
  bool leaveTarget = false;

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
      case 'iscsi.target.query':
        return AdminCompleted(
          request,
          value: [for (final row in targets) Map<String, Object?>.from(row)],
        );
      case 'iscsi.targetextent.query':
        return AdminCompleted(
          request,
          value: [for (final row in mappings) Map<String, Object?>.from(row)],
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
      case 'iscsi.target.delete':
        if (unknownDelete) return AdminOutcomeUnknown(request);
        if (!leaveTarget) {
          targets.removeWhere((row) => row['id'] == request.arguments.first);
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
    coordinator = IscsiTargetDeleteCoordinator(
      session: session,
      api: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final _Fake api;
  late final AuthenticatedSession session;
  late final IscsiTargetDeleteCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes => api.calls
      .where((call) => call.method.name == 'iscsi.target.delete')
      .length;
}

void main() {
  test(
    'deletes one unbound target with both optional destructive flags false',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(3);
      expect(h.writes, 0);
      expect(review.confirmation, 'DELETE ISCSI TARGET #3 unbound');
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, IscsiTargetDeleteOutcome.completed);
      expect(h.writes, 1);
      expect(
        h.api.calls
            .singleWhere((call) => call.method.name == 'iscsi.target.delete')
            .arguments,
        [3, false, false],
      );
      expect(h.api.targets, isEmpty);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiTargetDeleteOutcome.rejected,
      );
    },
  );

  test(
    'groups, networks, mappings, running service and sessions block preflight',
    () async {
      final h = _Harness();
      h.api.targets.single['groups'] = [
        {'portal': 1},
      ];
      await expectLater(h.coordinator.prepare(3), throwsStateError);
      h.api.targets.single['groups'] = [];
      h.api.targets.single['auth_networks'] = ['192.0.2.0/24'];
      await expectLater(h.coordinator.prepare(3), throwsStateError);
      h.api.targets.single['auth_networks'] = [];
      h.api.mappings.add({'id': 8, 'target': 3, 'extent': 2, 'lunid': 0});
      await expectLater(h.coordinator.prepare(3), throwsStateError);
      h.api.mappings.clear();
      h.api.state = 'RUNNING';
      await expectLater(h.coordinator.prepare(3), throwsStateError);
      h.api.state = 'STOPPED';
      h.api.sessions = true;
      await expectLater(h.coordinator.prepare(3), throwsStateError);
      expect(h.writes, 0);
    },
  );

  test('inventory boundary and missing capability fail closed', () async {
    final h = _Harness();
    for (var id = 10; id < 109; id++) {
      h.api.targets.add({
        'id': id,
        'name': 'target-$id',
        'mode': 'ISCSI',
        'groups': [],
        'auth_networks': [],
      });
    }
    await expectLater(h.coordinator.prepare(3), throwsStateError);
    expect(h.writes, 0);
    expect(_Harness(advertiseDelete: false).coordinator.available, isFalse);
  });

  test(
    'drift, expiry, wrong phrase and session switch reject without write',
    () async {
      final h = _Harness();
      final first = await h.coordinator.prepare(3);
      h.api.mappings.add({'id': 8, 'target': 3, 'extent': 2, 'lunid': 0});
      expect(
        (await h.coordinator.execute(first, first.confirmation)).outcome,
        IscsiTargetDeleteOutcome.rejected,
      );
      h.api.mappings.clear();
      final second = await h.coordinator.prepare(3);
      h.clock = h.clock.add(const Duration(minutes: 5));
      expect(
        (await h.coordinator.execute(second, second.confirmation)).outcome,
        IscsiTargetDeleteOutcome.rejected,
      );
      final third = await h.coordinator.prepare(3);
      expect(
        (await h.coordinator.execute(third, 'wrong')).outcome,
        IscsiTargetDeleteOutcome.rejected,
      );
      final fourth = await h.coordinator.prepare(3);
      h.current = false;
      expect(
        (await h.coordinator.execute(fourth, fourth.confirmation)).outcome,
        IscsiTargetDeleteOutcome.rejected,
      );
      expect(h.writes, 0);
    },
  );

  test('unknown outcome or failed readback fences iSCSI writes', () async {
    final h = _Harness();
    h.api.unknownDelete = true;
    final review = await h.coordinator.prepare(3);
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiTargetDeleteOutcome.unknown,
    );
    expect(h.coordinator.locked, isTrue);
    await expectLater(h.coordinator.prepare(3), throwsStateError);

    final other = _Harness();
    other.api.leaveTarget = true;
    final otherReview = await other.coordinator.prepare(3);
    expect(
      (await other.coordinator.execute(
        otherReview,
        otherReview.confirmation,
      )).outcome,
      IscsiTargetDeleteOutcome.unknown,
    );
    expect(other.coordinator.locked, isTrue);
  });

  testWidgets('editor requires review and exact confirmation', (tester) async {
    final h = _Harness();
    final overview = IscsiOverview.parse(
      portals: [],
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
              child: IscsiTargetDeleteEditor(overview: overview),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-target-delete-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#3 unbound').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-target-delete-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    await tester.enterText(
      find.byKey(const Key('iscsi-target-delete-confirmation')),
      'DELETE ISCSI TARGET #3 unbound',
    );
    await tester.tap(find.byKey(const Key('iscsi-target-delete-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
  });
}
