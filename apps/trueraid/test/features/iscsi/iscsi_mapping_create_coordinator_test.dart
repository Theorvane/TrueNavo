import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/iscsi/iscsi_mapping_create_coordinator.dart';
import 'package:trueraid/features/iscsi/iscsi_mapping_create_editor.dart';
import 'package:trueraid/features/iscsi/iscsi_overview.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

Map<String, Object?> _method({bool create = false}) => {
  'accepts': create
      ? [
          {
            '_name_': 'data',
            '_required_': true,
            'type': 'object',
            'properties': {
              'target': {'type': 'integer'},
              'extent': {'type': 'integer'},
              'lunid': {'type': 'integer'},
            },
          },
        ]
      : <Object?>[],
  'returns': [
    {'type': 'object', 'properties': <String, Object?>{}},
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
        'iscsi.targetextent.create': _method(create: true),
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
      'locked': false,
    },
  ];
  final mappings = <Map<String, Object?>>[];
  final calls = <AdminRequest>[];
  bool sessions = false;
  bool unknown = false;
  bool mutateTarget = false;
  String state = 'STOPPED';

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
      case 'iscsi.targetextent.create':
        if (unknown) return AdminOutcomeUnknown(request);
        final payload = request.arguments.single as Map;
        final row = <String, Object?>{
          'id': 7,
          'target': payload['target'],
          'extent': payload['extent'],
          'lunid': payload['lunid'],
        };
        mappings.add(row);
        if (mutateTarget) targets.single['name'] = 'unexpected';
        return AdminCompleted(request, value: Map<String, Object?>.from(row));
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
    coordinator = IscsiMappingCreateCoordinator(
      session: session,
      api: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final _Fake api;
  late final AuthenticatedSession session;
  late final IscsiMappingCreateCoordinator coordinator;
  DateTime clock = DateTime.utc(2026);
  bool current = true;
  int get writes => api.calls
      .where((call) => call.method.name == 'iscsi.targetextent.create')
      .length;
}

void main() {
  test(
    'adds a second explicit LUN without changing the existing mapping',
    () async {
      final h = _Harness();
      h.api.extents.add({
        'id': 6,
        'name': 'disk-b',
        'type': 'DISK',
        'path': 'zvol/tank/second',
        'enabled': true,
        'locked': false,
      });
      h.api.mappings.add({'id': 8, 'target': 3, 'extent': 5, 'lunid': 0});
      final review = await h.coordinator.prepare(3, 6, lun: 1);
      expect(review.confirmation, 'MAP ISCSI TARGET #3 EXTENT #6 LUN 1');
      expect(h.writes, 0);
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, IscsiMappingCreateOutcome.completed);
      expect(
        h.api.calls
            .singleWhere(
              (call) => call.method.name == 'iscsi.targetextent.create',
            )
            .arguments,
        [
          {'target': 3, 'extent': 6, 'lunid': 1},
        ],
      );
      expect(h.api.mappings, [
        {'id': 8, 'target': 3, 'extent': 5, 'lunid': 0},
        {'id': 7, 'target': 3, 'extent': 6, 'lunid': 1},
      ]);
    },
  );

  test('duplicate or missing LUN zero, used extent and out-of-range LUN block review', () async {
    final h = _Harness();
    h.api.extents.add({
      'id': 6,
      'name': 'disk-b',
      'type': 'DISK',
      'path': 'zvol/tank/second',
      'enabled': true,
      'locked': false,
    });
    h.api.mappings.add({'id': 8, 'target': 3, 'extent': 5, 'lunid': 0});
    await expectLater(h.coordinator.prepare(3, 6, lun: 0), throwsStateError);
    await expectLater(h.coordinator.prepare(3, 5, lun: 1), throwsStateError);
    await expectLater(h.coordinator.prepare(3, 6, lun: 32), throwsStateError);
    h.api.mappings.single['lunid'] = 1;
    await expectLater(h.coordinator.prepare(3, 6, lun: 2), throwsStateError);
    h.api.mappings.clear();
    await expectLater(h.coordinator.prepare(3, 6, lun: 1), throwsStateError);
    expect(h.writes, 0);
  });

  test(
    'creates only initial LUN 0 mapping with exact payload and readback',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(3, 5);
      expect(h.writes, 0);
      expect(review.proof, isNot(contains('zvol/tank/private')));
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, IscsiMappingCreateOutcome.completed);
      expect(
        h.api.calls
            .singleWhere(
              (call) => call.method.name == 'iscsi.targetextent.create',
            )
            .arguments,
        [
          {'target': 3, 'extent': 5, 'lunid': 0},
        ],
      );
      expect(h.api.mappings.single['id'], 7);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiMappingCreateOutcome.rejected,
      );
    },
  );

  test(
    'bound target, used extent, locked backing, service and sessions block',
    () async {
      final h = _Harness();
      h.api.targets.single['groups'] = [
        {'portal': 2, 'initiator': null, 'authmethod': 'NONE', 'auth': null},
      ];
      await expectLater(h.coordinator.prepare(3, 5), throwsStateError);
      h.api.targets.single['groups'] = <Object?>[];
      h.api.mappings.add({'id': 8, 'target': 3, 'extent': 5, 'lunid': 0});
      await expectLater(h.coordinator.prepare(3, 5), throwsStateError);
      h.api.mappings.clear();
      h.api.extents.single['locked'] = true;
      await expectLater(h.coordinator.prepare(3, 5), throwsStateError);
      h.api.extents.single['locked'] = false;
      h.api.state = 'RUNNING';
      await expectLater(h.coordinator.prepare(3, 5), throwsStateError);
      h.api.state = 'STOPPED';
      h.api.sessions = true;
      await expectLater(h.coordinator.prepare(3, 5), throwsStateError);
      expect(h.writes, 0);
    },
  );

  test(
    'phrase, inventory drift, expiry and connection switch reject',
    () async {
      final h = _Harness();
      var review = await h.coordinator.prepare(3, 5);
      expect(
        (await h.coordinator.execute(review, 'wrong')).outcome,
        IscsiMappingCreateOutcome.rejected,
      );
      review = await h.coordinator.prepare(3, 5);
      h.api.extents.single['path'] = 'zvol/tank/changed';
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiMappingCreateOutcome.rejected,
      );
      h.api.extents.single['path'] = 'zvol/tank/private';
      review = await h.coordinator.prepare(3, 5);
      h.clock = h.clock.add(const Duration(minutes: 5));
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiMappingCreateOutcome.rejected,
      );
      review = await h.coordinator.prepare(3, 5);
      h.current = false;
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiMappingCreateOutcome.rejected,
      );
      expect(h.writes, 0);
    },
  );

  test(
    'unknown result and unexpected post-write drift fence session',
    () async {
      final h = _Harness();
      var review = await h.coordinator.prepare(3, 5);
      h.api.unknown = true;
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiMappingCreateOutcome.unknown,
      );
      expect(h.coordinator.locked, isTrue);
      final second = _Harness();
      review = await second.coordinator.prepare(3, 5);
      second.api.mutateTarget = true;
      expect(
        (await second.coordinator.execute(review, review.confirmation)).outcome,
        IscsiMappingCreateOutcome.unknown,
      );
      expect(second.coordinator.locked, isTrue);
    },
  );

  testWidgets('editor reviews target, extent and LUN before sending', (
    tester,
  ) async {
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
              child: IscsiMappingCreateEditor(overview: overview),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-mapping-create-target')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#3 target-a').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-mapping-create-extent')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#5 disk-a').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-mapping-create-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    await tester.enterText(
      find.byKey(const Key('iscsi-mapping-create-confirmation')),
      'MAP ISCSI TARGET #3 EXTENT #5 LUN 0',
    );
    await tester.ensureVisible(
      find.byKey(const Key('iscsi-mapping-create-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-mapping-create-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
  });

  testWidgets('editor selects a free LUN on an already mapped target', (
    tester,
  ) async {
    final h = _Harness();
    h.api.extents.add({
      'id': 6,
      'name': 'disk-b',
      'type': 'DISK',
      'path': 'zvol/tank/second',
      'enabled': true,
      'locked': false,
    });
    h.api.mappings.add({'id': 8, 'target': 3, 'extent': 5, 'lunid': 0});
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
              child: IscsiMappingCreateEditor(overview: overview),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-mapping-create-target')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#3 target-a').last);
    await tester.pumpAndSettle();
    expect(find.text('LUN 1'), findsOneWidget);
    await tester.tap(find.byKey(const Key('iscsi-mapping-create-lun')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('LUN 2').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-mapping-create-extent')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#6 disk-b').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-mapping-create-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    await tester.enterText(
      find.byKey(const Key('iscsi-mapping-create-confirmation')),
      'MAP ISCSI TARGET #3 EXTENT #6 LUN 2',
    );
    await tester.ensureVisible(
      find.byKey(const Key('iscsi-mapping-create-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-mapping-create-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
    expect(h.api.mappings.last['lunid'], 2);
  });
}
