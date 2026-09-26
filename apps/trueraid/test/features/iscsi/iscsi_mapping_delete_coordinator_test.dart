import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/iscsi/iscsi_mapping_delete_coordinator.dart';
import 'package:trueraid/features/iscsi/iscsi_mapping_delete_editor.dart';
import 'package:trueraid/features/iscsi/iscsi_overview.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

Map<String, Object?> _method({bool delete = false}) => {
  'accepts': delete
      ? [
          {'_name_': 'id', '_required_': true, 'type': 'integer'},
          {'_name_': 'force', '_required_': false, 'type': 'boolean'},
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
        'iscsi.target.query': _method(),
        'iscsi.extent.query': _method(),
        'iscsi.targetextent.query': _method(),
        'iscsi.targetextent.delete': _method(delete: true),
        'service.query': _method(),
        'iscsi.global.sessions': _method(),
      },
    );
  }
  @override
  late final AdminCatalog adminCatalog;
  final targets = <Map<String, Object?>>[
    {
      'id': 3,
      'name': 'target-a',
      'mode': 'ISCSI',
      'groups': <Object?>[],
      'auth_networks': <Object?>[],
    },
  ];
  final extents = <Map<String, Object?>>[
    {
      'id': 5,
      'name': 'disk-a',
      'type': 'DISK',
      'path': 'zvol/tank/private',
      'enabled': true,
    },
    {
      'id': 6,
      'name': 'disk-b',
      'type': 'DISK',
      'path': 'zvol/tank/other',
      'enabled': true,
    },
  ];
  final mappings = <Map<String, Object?>>[
    {'id': 7, 'target': 3, 'extent': 5, 'lunid': 0},
    {'id': 8, 'target': 3, 'extent': 6, 'lunid': 1},
  ];
  final calls = <AdminRequest>[];
  String state = 'STOPPED';
  bool sessions = false;
  bool unknown = false;
  bool mutateTarget = false;

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
      case 'iscsi.target.query':
        return AdminCompleted(
          request,
          value: [for (final row in targets) Map<String, Object?>.from(row)],
        );
      case 'iscsi.extent.query':
        return AdminCompleted(
          request,
          value: [for (final row in extents) Map<String, Object?>.from(row)],
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
      case 'iscsi.targetextent.delete':
        if (unknown) return AdminOutcomeUnknown(request);
        mappings.removeWhere((row) => row['id'] == request.arguments.first);
        if (mutateTarget) targets.single['name'] = 'unexpected';
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
    coordinator = IscsiMappingDeleteCoordinator(
      session: session,
      api: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final _Fake api;
  late final AuthenticatedSession session;
  late final IscsiMappingDeleteCoordinator coordinator;
  DateTime clock = DateTime.utc(2026);
  bool current = true;
  int get writes => api.calls
      .where((call) => call.method.name == 'iscsi.targetextent.delete')
      .length;
}

void main() {
  test(
    'deletes one exact LUN mapping with force false and independent readback',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(7);
      expect(h.writes, 0);
      expect(
        [review.targetName, review.extentName, review.lun],
        ['target-a', 'disk-a', 0],
      );
      expect(review.proof, isNot(contains('zvol/tank/private')));
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, IscsiMappingDeleteOutcome.completed);
      expect(
        h.api.calls
            .singleWhere(
              (call) => call.method.name == 'iscsi.targetextent.delete',
            )
            .arguments,
        [7, false],
      );
      expect(h.api.mappings.map((row) => row['id']), [8]);
      expect(h.api.extents.length, 2);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiMappingDeleteOutcome.rejected,
      );
    },
  );

  test('service, sessions, FC mode and orphan mapping block review', () async {
    final h = _Harness();
    h.api.state = 'RUNNING';
    await expectLater(h.coordinator.prepare(7), throwsStateError);
    h.api.state = 'STOPPED';
    h.api.sessions = true;
    await expectLater(h.coordinator.prepare(7), throwsStateError);
    h.api.sessions = false;
    h.api.targets.single['mode'] = 'FC';
    await expectLater(h.coordinator.prepare(7), throwsStateError);
    h.api.targets.single['mode'] = 'ISCSI';
    h.api.extents.removeAt(0);
    await expectLater(h.coordinator.prepare(7), throwsStateError);
    expect(h.writes, 0);
  });

  test('wrong phrase, drift, expiry and session switch never write', () async {
    final h = _Harness();
    var review = await h.coordinator.prepare(7);
    expect(
      (await h.coordinator.execute(review, 'wrong')).outcome,
      IscsiMappingDeleteOutcome.rejected,
    );
    review = await h.coordinator.prepare(7);
    h.api.mappings.first['lunid'] = 4;
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiMappingDeleteOutcome.rejected,
    );
    h.api.mappings.first['lunid'] = 0;
    review = await h.coordinator.prepare(7);
    h.api.extents.first['path'] = 'zvol/tank/changed';
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiMappingDeleteOutcome.rejected,
    );
    h.api.extents.first['path'] = 'zvol/tank/private';
    review = await h.coordinator.prepare(7);
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiMappingDeleteOutcome.rejected,
    );
    review = await h.coordinator.prepare(7);
    h.current = false;
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiMappingDeleteOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test(
    'unknown result and unexpected post-write drift fence the session',
    () async {
      final h = _Harness();
      var review = await h.coordinator.prepare(7);
      h.api.unknown = true;
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiMappingDeleteOutcome.unknown,
      );
      expect(h.coordinator.locked, isTrue);

      final second = _Harness();
      review = await second.coordinator.prepare(7);
      second.api.mutateTarget = true;
      expect(
        (await second.coordinator.execute(review, review.confirmation)).outcome,
        IscsiMappingDeleteOutcome.unknown,
      );
      expect(second.coordinator.locked, isTrue);
    },
  );

  testWidgets('editor requires review and exact confirmation', (tester) async {
    final h = _Harness();
    final overview = IscsiOverview.parse(
      portals: [],
      initiators: [],
      targets: h.api.targets,
      extents: h.api.extents,
      mappings: h.api.mappings,
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
              child: IscsiMappingDeleteEditor(overview: overview),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-mapping-delete-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.textContaining('#7 target-a').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-mapping-delete-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    await tester.enterText(
      find.byKey(const Key('iscsi-mapping-delete-confirmation')),
      'UNMAP ISCSI LUN #7 TARGET #3 EXTENT #5',
    );
    await tester.ensureVisible(
      find.byKey(const Key('iscsi-mapping-delete-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-mapping-delete-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
  });
}
