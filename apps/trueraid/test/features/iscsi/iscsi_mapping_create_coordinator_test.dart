import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/iscsi/iscsi_mapping_create_coordinator.dart';
import 'package:trueraid/features/iscsi/iscsi_mapping_create_editor.dart';
import 'package:trueraid/features/iscsi/iscsi_mapping_renumber_editor.dart';
import 'package:trueraid/features/iscsi/iscsi_overview.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

Map<String, Object?> _method({bool create = false, bool update = false}) => {
  'accepts': update
      ? [
          {'_name_': 'id', '_required_': true, 'type': 'integer'},
          {
            '_name_': 'data',
            '_required_': true,
            'type': 'object',
            'properties': {
              'lunid': {'type': 'integer'},
            },
          },
        ]
      : create
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
        'iscsi.targetextent.update': _method(update: true),
        'iscsi.portal.query': _method(),
        'iscsi.initiator.query': _method(),
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
  final portals = <Map<String, Object?>>[
    {
      'id': 2,
      'tag': 1,
      'comment': '',
      'listen': [
        {'ip': '192.0.2.10', 'port': 3260},
      ],
    },
  ];
  final initiators = <Map<String, Object?>>[
    {
      'id': 4,
      'comment': '',
      'initiators': ['iqn.2026-09.example:client'],
    },
  ];
  final mappings = <Map<String, Object?>>[];
  final calls = <AdminRequest>[];
  bool sessions = false;
  bool unknown = false;
  bool mutateTarget = false;
  bool mutatePortal = false;
  bool mutateLastPortal = false;
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
      case 'iscsi.portal.query':
        return AdminCompleted(
          request,
          value: [for (final row in portals) Map<String, Object?>.from(row)],
        );
      case 'iscsi.initiator.query':
        return AdminCompleted(
          request,
          value: [for (final row in initiators) Map<String, Object?>.from(row)],
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
        if (mutatePortal) portals.single['comment'] = 'unexpected';
        if (mutateLastPortal) portals.last['comment'] = 'unexpected';
        return AdminCompleted(request, value: Map<String, Object?>.from(row));
      case 'iscsi.targetextent.update':
        if (unknown) return AdminOutcomeUnknown(request);
        final row = mappings.singleWhere(
          (item) => item['id'] == request.arguments.first,
        );
        row['lunid'] = (request.arguments[1] as Map)['lunid'];
        if (mutateTarget) targets.single['name'] = 'unexpected';
        if (mutatePortal) portals.single['comment'] = 'unexpected';
        if (mutateLastPortal) portals.last['comment'] = 'unexpected';
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
  int get updates => api.calls
      .where((call) => call.method.name == 'iscsi.targetextent.update')
      .length;
}

void _bindTarget(_Harness h) {
  h.api.targets.single['groups'] = [
    {'portal': 2, 'initiator': 4, 'authmethod': 'NONE', 'auth': null},
  ];
}

void _bindMultiTarget(_Harness h) {
  h.api.portals.add({
    'id': 3,
    'tag': 2,
    'comment': '',
    'listen': [
      {'ip': '192.0.2.11', 'port': 3260},
    ],
  });
  h.api.initiators.add({
    'id': 5,
    'comment': '',
    'initiators': ['iqn.2026-09.example:second'],
  });
  h.api.targets.single['groups'] = [
    {'portal': 2, 'initiator': 4, 'authmethod': 'NONE', 'auth': null},
    {'portal': 3, 'initiator': 5, 'authmethod': 'NONE', 'auth': null},
  ];
}

void main() {
  test('maps initial LUN on target with two no-CHAP groups', () async {
    final h = _Harness();
    _bindMultiTarget(h);
    final review = await h.coordinator.prepareBound(3, 5);
    expect(review.accessGroups, [
      (portalId: 2, initiatorId: 4),
      (portalId: 3, initiatorId: 5),
    ]);
    expect(
      review.confirmation,
      'MAP ISCSI TARGET #3 GROUPS PORTAL #2 INITIATOR #4 ; PORTAL #3 INITIATOR #5 EXTENT #5 LUN 0',
    );
    expect(h.writes, 0);
    expect(
      (await h.coordinator.executeBound(review, review.confirmation)).outcome,
      IscsiMappingCreateOutcome.completed,
    );
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
  });

  test('maps additional LUN on target with two no-CHAP groups', () async {
    final h = _Harness();
    _bindMultiTarget(h);
    h.api.extents.add({
      'id': 6,
      'name': 'disk-b',
      'type': 'DISK',
      'path': 'zvol/tank/second',
      'enabled': true,
      'locked': false,
    });
    h.api.mappings.add({'id': 8, 'target': 3, 'extent': 5, 'lunid': 0});
    final review = await h.coordinator.prepareBound(3, 6, lun: 2);
    expect(
      (await h.coordinator.executeBound(review, review.confirmation)).outcome,
      IscsiMappingCreateOutcome.completed,
    );
    expect(h.api.mappings, [
      {'id': 8, 'target': 3, 'extent': 5, 'lunid': 0},
      {'id': 7, 'target': 3, 'extent': 6, 'lunid': 2},
    ]);
  });

  test('multi-group mapping blocks duplicate pair and mixed CHAP', () async {
    final h = _Harness();
    _bindMultiTarget(h);
    (h.api.targets.single['groups'] as List)[1] = {
      'portal': 2,
      'initiator': 4,
      'authmethod': 'NONE',
      'auth': null,
    };
    await expectLater(h.coordinator.prepareBound(3, 5), throwsStateError);
    (h.api.targets.single['groups'] as List)[1] = {
      'portal': 3,
      'initiator': 5,
      'authmethod': 'CHAP',
      'auth': 1,
    };
    await expectLater(h.coordinator.prepareBound(3, 5), throwsStateError);
    h.api.targets.single['groups'] = [
      for (var i = 0; i < 9; i++)
        {'portal': 2, 'initiator': 4, 'authmethod': 'NONE', 'auth': null},
    ];
    await expectLater(h.coordinator.prepareBound(3, 5), throwsStateError);
    expect(h.writes, 0);
  });

  test('second portal postread drift fences multi-group mapping', () async {
    final h = _Harness();
    _bindMultiTarget(h);
    final review = await h.coordinator.prepareBound(3, 5);
    h.api.mutateLastPortal = true;
    expect(
      (await h.coordinator.executeBound(review, review.confirmation)).outcome,
      IscsiMappingCreateOutcome.unknown,
    );
    expect(h.coordinator.locked, isTrue);
  });

  testWidgets('multi-group mapping editor reviews every pair', (tester) async {
    final h = _Harness();
    _bindMultiTarget(h);
    final overview = IscsiOverview.parse(
      portals: h.api.portals,
      initiators: h.api.initiators,
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
              child: IscsiMappingCreateEditor(overview: overview, bound: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-mapping-bound-create-target')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('#3 target-a').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-mapping-bound-create-extent')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('#5 disk-a').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-mapping-bound-create-review')),
    );
    await tester.pumpAndSettle();
    expect(
      find.text('Access group 1: portal #2 · initiator #4 · no CHAP'),
      findsOneWidget,
    );
    expect(
      find.text('Access group 2: portal #3 · initiator #5 · no CHAP'),
      findsOneWidget,
    );
    expect(h.writes, 0);
  });

  test('maps a free additional LUN on the access-bound target', () async {
    final h = _Harness();
    _bindTarget(h);
    h.api.extents.add({
      'id': 6,
      'name': 'disk-b',
      'type': 'DISK',
      'path': 'zvol/tank/second',
      'enabled': true,
      'locked': false,
    });
    h.api.mappings.add({'id': 8, 'target': 3, 'extent': 5, 'lunid': 0});
    final review = await h.coordinator.prepareBound(3, 6, lun: 2);
    expect(
      review.confirmation,
      'MAP ISCSI TARGET #3 PORTAL #2 INITIATOR #4 EXTENT #6 LUN 2',
    );
    expect(h.writes, 0);
    final result = await h.coordinator.executeBound(
      review,
      review.confirmation,
    );
    expect(result.outcome, IscsiMappingCreateOutcome.completed);
    expect(
      h.api.calls
          .singleWhere(
            (call) => call.method.name == 'iscsi.targetextent.create',
          )
          .arguments,
      [
        {'target': 3, 'extent': 6, 'lunid': 2},
      ],
    );
    expect(h.api.mappings, [
      {'id': 8, 'target': 3, 'extent': 5, 'lunid': 0},
      {'id': 7, 'target': 3, 'extent': 6, 'lunid': 2},
    ]);
  });

  test('maps initial LUN 0 on one explicit access-bound target', () async {
    final h = _Harness();
    _bindTarget(h);
    final review = await h.coordinator.prepareBound(3, 5);
    expect(
      review.confirmation,
      'MAP ISCSI TARGET #3 PORTAL #2 INITIATOR #4 EXTENT #5 LUN 0',
    );
    expect(h.writes, 0);
    final result = await h.coordinator.executeBound(
      review,
      review.confirmation,
    );
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
    expect(h.api.mappings.single['lunid'], 0);
    expect(h.api.targets.single['groups'], [
      {'portal': 2, 'initiator': 4, 'authmethod': 'NONE', 'auth': null},
    ]);
    expect(
      (await h.coordinator.executeBound(review, review.confirmation)).outcome,
      IscsiMappingCreateOutcome.rejected,
    );
  });

  test(
    'bound mapping rejects CHAP, wildcard and invalid additional LUNs',
    () async {
      final h = _Harness();
      _bindTarget(h);
      h.api.targets.single['groups'] = [
        {'portal': 2, 'initiator': 4, 'authmethod': 'CHAP', 'auth': 7},
      ];
      await expectLater(h.coordinator.prepareBound(3, 5), throwsStateError);
      _bindTarget(h);
      h.api.initiators.single['initiators'] = ['ALL'];
      await expectLater(h.coordinator.prepareBound(3, 5), throwsStateError);
      h.api.initiators.single['initiators'] = ['iqn.2026-09.example:client'];
      (h.api.portals.single['listen'] as List).single['ip'] = '0.0.0.0';
      await expectLater(h.coordinator.prepareBound(3, 5), throwsStateError);
      (h.api.portals.single['listen'] as List).single['ip'] = '192.0.2.10';
      h.api.mappings.add({'id': 8, 'target': 3, 'extent': 5, 'lunid': 0});
      await expectLater(h.coordinator.prepareBound(3, 5), throwsStateError);
      h.api.extents.add({
        'id': 6,
        'name': 'disk-b',
        'type': 'DISK',
        'path': 'zvol/tank/second',
        'enabled': true,
        'locked': false,
      });
      await expectLater(h.coordinator.prepareBound(3, 6), throwsStateError);
      await expectLater(
        h.coordinator.prepareBound(3, 6, lun: 32),
        throwsStateError,
      );
      h.api.mappings.single['lunid'] = 1;
      await expectLater(
        h.coordinator.prepareBound(3, 6, lun: 2),
        throwsStateError,
      );
      expect(h.writes, 0);
    },
  );

  test(
    'bound dependency drift rejects before write and unknown fences',
    () async {
      final h = _Harness();
      _bindTarget(h);
      var review = await h.coordinator.prepareBound(3, 5);
      h.api.portals.single['comment'] = 'changed';
      expect(
        (await h.coordinator.executeBound(review, review.confirmation)).outcome,
        IscsiMappingCreateOutcome.rejected,
      );
      expect(h.writes, 0);
      h.api.portals.single['comment'] = '';
      review = await h.coordinator.prepareBound(3, 5);
      h.api.unknown = true;
      expect(
        (await h.coordinator.executeBound(review, review.confirmation)).outcome,
        IscsiMappingCreateOutcome.unknown,
      );
      expect(h.coordinator.locked, isTrue);
    },
  );

  test('bound mapping fences a changed portal after submission', () async {
    final h = _Harness();
    _bindTarget(h);
    final review = await h.coordinator.prepareBound(3, 5);
    h.api.mutatePortal = true;
    expect(
      (await h.coordinator.executeBound(review, review.confirmation)).outcome,
      IscsiMappingCreateOutcome.unknown,
    );
    expect(h.coordinator.locked, isTrue);
  });

  testWidgets('bound mapping editor reviews the access group before submit', (
    tester,
  ) async {
    final h = _Harness();
    _bindTarget(h);
    final overview = IscsiOverview.parse(
      portals: h.api.portals,
      initiators: h.api.initiators,
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
              child: IscsiMappingCreateEditor(overview: overview, bound: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-mapping-bound-create-target')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('#3 target-a').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-mapping-bound-create-extent')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('#5 disk-a').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-mapping-bound-create-review')),
    );
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    await tester.enterText(
      find.byKey(const Key('iscsi-mapping-bound-create-confirmation')),
      'MAP ISCSI TARGET #3 PORTAL #2 INITIATOR #4 EXTENT #5 LUN 0',
    );
    await tester.ensureVisible(
      find.byKey(const Key('iscsi-mapping-bound-create-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-mapping-bound-create-submit')),
    );
    await tester.pumpAndSettle();
    expect(h.writes, 1);
  });

  testWidgets('bound mapping editor selects a free additional LUN', (
    tester,
  ) async {
    final h = _Harness();
    _bindTarget(h);
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
      portals: h.api.portals,
      initiators: h.api.initiators,
      targets: h.api.targets,
      extents: h.api.extents,
      mappings: h.api.mappings,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
          iscsiMappingCreateCoordinatorProvider.overrideWithValue(h.coordinator),
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: IscsiMappingCreateEditor(overview: overview, bound: true),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-mapping-bound-create-target')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('#3 target-a').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-mapping-bound-create-lun')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('LUN 2').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-mapping-bound-create-extent')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('#6 disk-b').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-mapping-bound-create-review')),
    );
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    await tester.enterText(
      find.byKey(const Key('iscsi-mapping-bound-create-confirmation')),
      'MAP ISCSI TARGET #3 PORTAL #2 INITIATOR #4 EXTENT #6 LUN 2',
    );
    await tester.ensureVisible(
      find.byKey(const Key('iscsi-mapping-bound-create-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-mapping-bound-create-submit')),
    );
    await tester.pumpAndSettle();
    expect(h.writes, 1);
  });

  testWidgets(
    'renumber editor reviews and sends only after exact confirmation',
    (tester) async {
      final h = _Harness();
      h.api.extents.add({
        'id': 6,
        'name': 'disk-b',
        'type': 'DISK',
        'path': 'zvol/tank/second',
        'enabled': true,
        'locked': false,
      });
      h.api.mappings.addAll([
        {'id': 8, 'target': 3, 'extent': 5, 'lunid': 0},
        {'id': 9, 'target': 3, 'extent': 6, 'lunid': 1},
      ]);
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
                child: IscsiMappingRenumberEditor(overview: overview),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('iscsi-mapping-renumber-select')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('#9 target-a · LUN 1').last);
      await tester.pumpAndSettle();
      expect(find.text('LUN 2'), findsOneWidget);
      await tester.tap(find.byKey(const Key('iscsi-mapping-renumber-review')));
      await tester.pumpAndSettle();
      expect(h.updates, 0);
      await tester.enterText(
        find.byKey(const Key('iscsi-mapping-renumber-confirmation')),
        'MOVE ISCSI LUN #9 1 TO 2',
      );
      await tester.ensureVisible(
        find.byKey(const Key('iscsi-mapping-renumber-submit')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('iscsi-mapping-renumber-submit')));
      await tester.pumpAndSettle();
      expect(h.updates, 1);
    },
  );

  test(
    'renumbers one additional LUN with lunid-only payload and readback',
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
      h.api.mappings.addAll([
        {'id': 8, 'target': 3, 'extent': 5, 'lunid': 0},
        {'id': 9, 'target': 3, 'extent': 6, 'lunid': 1},
      ]);
      final review = await h.coordinator.prepareRenumber(9, 2);
      expect(review.confirmation, 'MOVE ISCSI LUN #9 1 TO 2');
      expect(h.updates, 0);
      final result = await h.coordinator.executeRenumber(
        review,
        review.confirmation,
      );
      expect(result.outcome, IscsiMappingCreateOutcome.completed);
      expect(
        h.api.calls
            .singleWhere(
              (call) => call.method.name == 'iscsi.targetextent.update',
            )
            .arguments,
        [
          9,
          {'lunid': 2},
        ],
      );
      expect(h.api.mappings, [
        {'id': 8, 'target': 3, 'extent': 5, 'lunid': 0},
        {'id': 9, 'target': 3, 'extent': 6, 'lunid': 2},
      ]);
      expect(
        (await h.coordinator.executeRenumber(
          review,
          review.confirmation,
        )).outcome,
        IscsiMappingCreateOutcome.rejected,
      );
    },
  );

  test(
    'renumber blocks LUN zero, occupied destination and target drift',
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
      h.api.mappings.addAll([
        {'id': 8, 'target': 3, 'extent': 5, 'lunid': 0},
        {'id': 9, 'target': 3, 'extent': 6, 'lunid': 1},
      ]);
      await expectLater(h.coordinator.prepareRenumber(8, 2), throwsStateError);
      await expectLater(h.coordinator.prepareRenumber(9, 0), throwsStateError);
      await expectLater(h.coordinator.prepareRenumber(9, 1), throwsStateError);
      await expectLater(h.coordinator.prepareRenumber(9, 32), throwsStateError);
      var review = await h.coordinator.prepareRenumber(9, 2);
      h.api.targets.single['groups'] = [
        {'portal': 1, 'initiator': null, 'authmethod': 'NONE', 'auth': null},
      ];
      expect(
        (await h.coordinator.executeRenumber(
          review,
          review.confirmation,
        )).outcome,
        IscsiMappingCreateOutcome.rejected,
      );
      h.api.targets.single['groups'] = <Object?>[];
      review = await h.coordinator.prepareRenumber(9, 2);
      h.clock = h.clock.add(const Duration(minutes: 5));
      expect(
        (await h.coordinator.executeRenumber(
          review,
          review.confirmation,
        )).outcome,
        IscsiMappingCreateOutcome.rejected,
      );
      expect(h.updates, 0);
    },
  );

  test('renumber unknown result fences the session', () async {
    final h = _Harness();
    h.api.extents.add({
      'id': 6,
      'name': 'disk-b',
      'type': 'DISK',
      'path': 'zvol/tank/second',
      'enabled': true,
      'locked': false,
    });
    h.api.mappings.addAll([
      {'id': 8, 'target': 3, 'extent': 5, 'lunid': 0},
      {'id': 9, 'target': 3, 'extent': 6, 'lunid': 1},
    ]);
    final review = await h.coordinator.prepareRenumber(9, 2);
    h.api.unknown = true;
    expect(
      (await h.coordinator.executeRenumber(
        review,
        review.confirmation,
      )).outcome,
      IscsiMappingCreateOutcome.unknown,
    );
    expect(h.coordinator.locked, isTrue);
  });

  test('renumbers one bound additional LUN and preserves access', () async {
    final h = _Harness();
    _bindTarget(h);
    h.api.extents.add({
      'id': 6,
      'name': 'disk-b',
      'type': 'DISK',
      'path': 'zvol/tank/second',
      'enabled': true,
      'locked': false,
    });
    h.api.mappings.addAll([
      {'id': 8, 'target': 3, 'extent': 5, 'lunid': 0},
      {'id': 9, 'target': 3, 'extent': 6, 'lunid': 1},
    ]);
    expect(h.coordinator.boundRenumberAvailable, isTrue);
    await expectLater(h.coordinator.prepareRenumber(9, 2), throwsStateError);
    final review = await h.coordinator.prepareBoundRenumber(9, 2);
    expect(
      review.confirmation,
      'MOVE ISCSI LUN #9 1 TO 2 PORTAL #2 INITIATOR #4',
    );
    expect(h.updates, 0);
    final result = await h.coordinator.executeBoundRenumber(
      review,
      review.confirmation,
    );
    expect(result.outcome, IscsiMappingCreateOutcome.completed);
    expect(
      h.api.calls
          .singleWhere(
            (call) => call.method.name == 'iscsi.targetextent.update',
          )
          .arguments,
      [
        9,
        {'lunid': 2},
      ],
    );
    expect(h.api.mappings, [
      {'id': 8, 'target': 3, 'extent': 5, 'lunid': 0},
      {'id': 9, 'target': 3, 'extent': 6, 'lunid': 2},
    ]);
  });

  test('bound renumber rejects CHAP, occupied LUN and access drift', () async {
    final h = _Harness();
    _bindTarget(h);
    h.api.extents.add({
      'id': 6,
      'name': 'disk-b',
      'type': 'DISK',
      'path': 'zvol/tank/second',
      'enabled': true,
      'locked': false,
    });
    h.api.mappings.addAll([
      {'id': 8, 'target': 3, 'extent': 5, 'lunid': 0},
      {'id': 9, 'target': 3, 'extent': 6, 'lunid': 1},
    ]);
    await expectLater(
      h.coordinator.prepareBoundRenumber(8, 2),
      throwsStateError,
    );
    await expectLater(
      h.coordinator.prepareBoundRenumber(9, 0),
      throwsStateError,
    );
    await expectLater(
      h.coordinator.prepareBoundRenumber(9, 1),
      throwsStateError,
    );
    h.api.targets.single['groups'] = [
      {'portal': 2, 'initiator': 4, 'authmethod': 'CHAP', 'auth': 1},
    ];
    await expectLater(
      h.coordinator.prepareBoundRenumber(9, 2),
      throwsStateError,
    );
    _bindTarget(h);
    final review = await h.coordinator.prepareBoundRenumber(9, 2);
    h.api.portals.single['comment'] = 'changed';
    expect(
      (await h.coordinator.executeBoundRenumber(
        review,
        review.confirmation,
      )).outcome,
      IscsiMappingCreateOutcome.rejected,
    );
    expect(h.updates, 0);
  });

  test('bound renumber postread access drift fences session', () async {
    final h = _Harness();
    _bindTarget(h);
    h.api.extents.add({
      'id': 6,
      'name': 'disk-b',
      'type': 'DISK',
      'path': 'zvol/tank/second',
      'enabled': true,
      'locked': false,
    });
    h.api.mappings.addAll([
      {'id': 8, 'target': 3, 'extent': 5, 'lunid': 0},
      {'id': 9, 'target': 3, 'extent': 6, 'lunid': 1},
    ]);
    final review = await h.coordinator.prepareBoundRenumber(9, 2);
    h.api.mutatePortal = true;
    expect(
      (await h.coordinator.executeBoundRenumber(
        review,
        review.confirmation,
      )).outcome,
      IscsiMappingCreateOutcome.unknown,
    );
    expect(h.coordinator.locked, isTrue);
  });

  test('renumbers additional LUN on multi-group no-CHAP target', () async {
    final h = _Harness();
    _bindMultiTarget(h);
    h.api.extents.add({
      'id': 6,
      'name': 'disk-b',
      'type': 'DISK',
      'path': 'zvol/tank/second',
      'enabled': true,
      'locked': false,
    });
    h.api.mappings.addAll([
      {'id': 8, 'target': 3, 'extent': 5, 'lunid': 0},
      {'id': 9, 'target': 3, 'extent': 6, 'lunid': 1},
    ]);
    final review = await h.coordinator.prepareBoundRenumber(9, 2);
    expect(review.accessGroups, [
      (portalId: 2, initiatorId: 4),
      (portalId: 3, initiatorId: 5),
    ]);
    expect(
      review.confirmation,
      'MOVE ISCSI LUN #9 1 TO 2 GROUPS PORTAL #2 INITIATOR #4 ; PORTAL #3 INITIATOR #5',
    );
    expect(
      (await h.coordinator.executeBoundRenumber(
        review,
        review.confirmation,
      )).outcome,
      IscsiMappingCreateOutcome.completed,
    );
    expect(
      h.api.calls
          .singleWhere(
            (call) => call.method.name == 'iscsi.targetextent.update',
          )
          .arguments,
      [
        9,
        {'lunid': 2},
      ],
    );
  });

  test(
    'multi-group renumber rejects second portal drift before write',
    () async {
      final h = _Harness();
      _bindMultiTarget(h);
      h.api.extents.add({
        'id': 6,
        'name': 'disk-b',
        'type': 'DISK',
        'path': 'zvol/tank/second',
        'enabled': true,
        'locked': false,
      });
      h.api.mappings.addAll([
        {'id': 8, 'target': 3, 'extent': 5, 'lunid': 0},
        {'id': 9, 'target': 3, 'extent': 6, 'lunid': 1},
      ]);
      final review = await h.coordinator.prepareBoundRenumber(9, 2);
      h.api.portals.last['comment'] = 'changed';
      expect(
        (await h.coordinator.executeBoundRenumber(
          review,
          review.confirmation,
        )).outcome,
        IscsiMappingCreateOutcome.rejected,
      );
      expect(h.updates, 0);
    },
  );

  testWidgets('multi-group renumber editor reviews every pair', (tester) async {
    final h = _Harness();
    _bindMultiTarget(h);
    h.api.extents.add({
      'id': 6,
      'name': 'disk-b',
      'type': 'DISK',
      'path': 'zvol/tank/second',
      'enabled': true,
      'locked': false,
    });
    h.api.mappings.addAll([
      {'id': 8, 'target': 3, 'extent': 5, 'lunid': 0},
      {'id': 9, 'target': 3, 'extent': 6, 'lunid': 1},
    ]);
    final overview = IscsiOverview.parse(
      portals: h.api.portals,
      initiators: h.api.initiators,
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
              child: IscsiMappingRenumberEditor(
                overview: overview,
                bound: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-mapping-bound-renumber-select')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('#9 target-a · LUN 1').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-mapping-bound-renumber-review')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Group 1: Portal #2 · initiator #4'), findsOneWidget);
    expect(find.text('Group 2: Portal #3 · initiator #5'), findsOneWidget);
    expect(h.updates, 0);
  });

  testWidgets('bound renumber editor reviews portal and initiator', (
    tester,
  ) async {
    final h = _Harness();
    _bindTarget(h);
    h.api.extents.add({
      'id': 6,
      'name': 'disk-b',
      'type': 'DISK',
      'path': 'zvol/tank/second',
      'enabled': true,
      'locked': false,
    });
    h.api.mappings.addAll([
      {'id': 8, 'target': 3, 'extent': 5, 'lunid': 0},
      {'id': 9, 'target': 3, 'extent': 6, 'lunid': 1},
    ]);
    final overview = IscsiOverview.parse(
      portals: h.api.portals,
      initiators: h.api.initiators,
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
              child: IscsiMappingRenumberEditor(
                overview: overview,
                bound: true,
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-mapping-bound-renumber-select')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('#9 target-a · LUN 1').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-mapping-bound-renumber-review')),
    );
    await tester.pumpAndSettle();
    expect(find.text('Portal #2 · initiator #4'), findsOneWidget);
    expect(h.updates, 0);
    await tester.enterText(
      find.byKey(const Key('iscsi-mapping-bound-renumber-confirmation')),
      'MOVE ISCSI LUN #9 1 TO 2 PORTAL #2 INITIATOR #4',
    );
    await tester.ensureVisible(
      find.byKey(const Key('iscsi-mapping-bound-renumber-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-mapping-bound-renumber-submit')),
    );
    await tester.pumpAndSettle();
    expect(h.updates, 1);
  });

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
