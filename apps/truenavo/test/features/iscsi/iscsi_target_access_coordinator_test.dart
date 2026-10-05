import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/iscsi/iscsi_overview.dart';
import 'package:truenavo/features/iscsi/iscsi_target_access_coordinator.dart';
import 'package:truenavo/features/iscsi/iscsi_target_access_editor.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

Map<String, Object?> _method({bool update = false}) => {
  'accepts': update
      ? [
          {'_name_': 'id', '_required_': true, 'type': 'integer'},
          {
            '_name_': 'data',
            '_required_': true,
            'type': 'object',
            'properties': {
              'groups': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {
                    'portal': {'type': 'integer'},
                    'initiator': {'type': 'integer'},
                    'authmethod': {'type': 'string'},
                    'auth': {'type': 'integer'},
                  },
                },
              },
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
        'iscsi.target.update': _method(update: true),
        'iscsi.portal.query': _method(),
        'iscsi.initiator.query': _method(),
        'iscsi.targetextent.query': _method(),
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
      'alias': null,
      'mode': 'ISCSI',
      'groups': <Object?>[],
      'auth_networks': <Object?>[],
      'rel_tgt_id': 1,
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
  bool unknown = false;
  bool driftAfterUpdate = false;
  bool sessions = false;
  String state = 'STOPPED';

  Object _copy(Object value) => jsonDecode(jsonEncode(value)) as Object;

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
      case 'iscsi.target.query':
        return AdminCompleted(request, value: _copy(targets));
      case 'iscsi.portal.query':
        return AdminCompleted(request, value: _copy(portals));
      case 'iscsi.initiator.query':
        return AdminCompleted(request, value: _copy(initiators));
      case 'iscsi.targetextent.query':
        return AdminCompleted(request, value: _copy(mappings));
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
      case 'iscsi.target.update':
        if (unknown) return AdminOutcomeUnknown(request);
        targets.single['groups'] = _copy(
          (request.arguments[1] as Map)['groups'] as Object,
        );
        if (driftAfterUpdate) targets.single['alias'] = 'unexpected';
        return AdminCompleted(request, value: _copy(targets.single));
      default:
        throw StateError('Unexpected fake method');
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
    coordinator = IscsiTargetAccessCoordinator(
      session: session,
      api: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final _Fake api;
  late final AuthenticatedSession session;
  late final IscsiTargetAccessCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes => api.calls
      .where((call) => call.method.name == 'iscsi.target.update')
      .length;
}

void main() {
  test('detaches only the sole reviewed LUN-free access group', () async {
    final h = _Harness();
    h.api.targets.single['groups'] = [
      {'portal': 2, 'initiator': 4, 'authmethod': 'NONE', 'auth': null},
    ];
    final review = await h.coordinator.prepareDetach(3, 2, 4);
    expect(
      review.confirmation,
      'DETACH ISCSI TARGET #3 PORTAL #2 INITIATOR #4',
    );
    expect(h.writes, 0);
    final result = await h.coordinator.executeDetach(
      review,
      review.confirmation,
    );
    expect(result.outcome, IscsiTargetAccessOutcome.completed);
    expect(
      h.api.calls
          .singleWhere((call) => call.method.name == 'iscsi.target.update')
          .arguments,
      [
        3,
        {'groups': <Object?>[]},
      ],
    );
    expect(h.api.targets.single['groups'], isEmpty);
    expect(h.api.portals, hasLength(1));
    expect(h.api.initiators, hasLength(1));
    expect(h.writes, 1);
  });

  test(
    'detach rejects CHAP, added LUN, dependency drift and wrong review mode',
    () async {
      final h = _Harness();
      h.api.targets.single['groups'] = [
        {'portal': 2, 'initiator': 4, 'authmethod': 'CHAP', 'auth': 7},
      ];
      await expectLater(h.coordinator.prepareDetach(3, 2, 4), throwsStateError);
      h.api.targets.single['groups'] = [
        {'portal': 2, 'initiator': 4, 'authmethod': 'NONE', 'auth': null},
      ];
      h.api.mappings.add({'id': 8, 'target': 3, 'extent': 5, 'lunid': 0});
      await expectLater(h.coordinator.prepareDetach(3, 2, 4), throwsStateError);
      h.api.mappings.clear();
      var review = await h.coordinator.prepareDetach(3, 2, 4);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiTargetAccessOutcome.rejected,
      );
      review = await h.coordinator.prepareDetach(3, 2, 4);
      h.api.portals.single['comment'] = 'changed';
      expect(
        (await h.coordinator.executeDetach(
          review,
          review.confirmation,
        )).outcome,
        IscsiTargetAccessOutcome.rejected,
      );
      expect(h.writes, 0);
    },
  );

  testWidgets(
    'detach editor reviews the current group and requires confirmation',
    (tester) async {
      final h = _Harness();
      h.api.targets.single['groups'] = [
        {'portal': 2, 'initiator': 4, 'authmethod': 'NONE', 'auth': null},
      ];
      final overview = IscsiOverview.parse(
        portals: h.api.portals,
        initiators: h.api.initiators,
        targets: h.api.targets,
        extents: [],
        mappings: h.api.mappings,
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
                child: IscsiTargetAccessEditor(
                  overview: overview,
                  detach: true,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('iscsi-access-detach-target')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('#3 target-a').last);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('iscsi-access-detach-review')));
      await tester.pumpAndSettle();
      expect(h.writes, 0);
      await tester.enterText(
        find.byKey(const Key('iscsi-access-detach-confirmation')),
        'DETACH ISCSI TARGET #3 PORTAL #2 INITIATOR #4',
      );
      await tester.ensureVisible(
        find.byKey(const Key('iscsi-access-detach-submit')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('iscsi-access-detach-submit')));
      await tester.pumpAndSettle();
      expect(h.writes, 1);
    },
  );

  test(
    'attaches only explicit portal and initiator to LUN-free target',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(3, 2, 4);
      expect(
        review.confirmation,
        'ATTACH ISCSI TARGET #3 PORTAL #2 INITIATOR #4',
      );
      expect(h.writes, 0);
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, IscsiTargetAccessOutcome.completed);
      expect(h.writes, 1);
      expect(
        h.api.calls
            .singleWhere((call) => call.method.name == 'iscsi.target.update')
            .arguments,
        [
          3,
          {
            'groups': [
              {'portal': 2, 'initiator': 4, 'authmethod': 'NONE', 'auth': null},
            ],
          },
        ],
      );
      expect(h.api.mappings, isEmpty);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiTargetAccessOutcome.rejected,
      );
    },
  );

  test(
    'rejects wildcard initiator, wildcard portal, LUN and running service',
    () async {
      final h = _Harness();
      h.api.initiators.single['initiators'] = ['ALL'];
      await expectLater(h.coordinator.prepare(3, 2, 4), throwsStateError);
      h.api.initiators.single['initiators'] = ['iqn.2026-09.example:client'];
      (h.api.portals.single['listen'] as List).single['ip'] = '0.0.0.0';
      await expectLater(h.coordinator.prepare(3, 2, 4), throwsStateError);
      (h.api.portals.single['listen'] as List).single['ip'] = '192.0.2.10';
      h.api.mappings.add({'id': 8, 'target': 3, 'extent': 5, 'lunid': 0});
      await expectLater(h.coordinator.prepare(3, 2, 4), throwsStateError);
      h.api.mappings.clear();
      h.api.state = 'RUNNING';
      await expectLater(h.coordinator.prepare(3, 2, 4), throwsStateError);
      expect(h.writes, 0);
    },
  );

  test('dependency drift and expired review never submit', () async {
    final h = _Harness();
    var review = await h.coordinator.prepare(3, 2, 4);
    h.api.initiators.single['comment'] = 'changed';
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiTargetAccessOutcome.rejected,
    );
    h.api.initiators.single['comment'] = '';
    review = await h.coordinator.prepare(3, 2, 4);
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiTargetAccessOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test('unknown or mismatched readback fences further iSCSI changes', () async {
    final unknown = _Harness();
    final review = await unknown.coordinator.prepare(3, 2, 4);
    unknown.api.unknown = true;
    expect(
      (await unknown.coordinator.execute(review, review.confirmation)).outcome,
      IscsiTargetAccessOutcome.unknown,
    );
    expect(unknown.coordinator.locked, isTrue);

    final drift = _Harness();
    final second = await drift.coordinator.prepare(3, 2, 4);
    drift.api.driftAfterUpdate = true;
    expect(
      (await drift.coordinator.execute(second, second.confirmation)).outcome,
      IscsiTargetAccessOutcome.unknown,
    );
    expect(drift.coordinator.locked, isTrue);
  });

  testWidgets('editor sends only after reviewed exact confirmation', (
    tester,
  ) async {
    final h = _Harness();
    final overview = IscsiOverview.parse(
      portals: h.api.portals,
      initiators: h.api.initiators,
      targets: h.api.targets,
      extents: [],
      mappings: h.api.mappings,
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
              child: IscsiTargetAccessEditor(overview: overview),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-access-target')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#3 target-a').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-access-portal')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#2 192.0.2.10').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-access-initiator')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#4 iqn.2026-09.example:client').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-access-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    await tester.enterText(
      find.byKey(const Key('iscsi-access-confirmation')),
      'ATTACH ISCSI TARGET #3 PORTAL #2 INITIATOR #4',
    );
    await tester.ensureVisible(find.byKey(const Key('iscsi-access-submit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-access-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
  });
}
