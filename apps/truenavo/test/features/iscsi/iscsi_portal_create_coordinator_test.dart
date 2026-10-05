import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/iscsi/iscsi_overview.dart';
import 'package:truenavo/features/iscsi/iscsi_portal_create_coordinator.dart';
import 'package:truenavo/features/iscsi/iscsi_portal_create_editor.dart';
import 'package:truenavo/features/iscsi/iscsi_portal_listener_editor.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

Map<String, Object?> _method({bool create = false, bool update = false}) => {
  'accepts': create || update
      ? [
          if (update) {'_name_': 'id', '_required_': true, 'type': 'integer'},
          {
            '_name_': 'data',
            '_required_': true,
            'type': 'object',
            'properties': {
              'listen': {
                'type': 'array',
                'items': {
                  'type': 'object',
                  'properties': {
                    'ip': {'type': 'string'},
                  },
                },
              },
              'comment': {'type': 'string'},
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
        'iscsi.portal.query': _method(),
        'iscsi.portal.create': _method(create: true),
        'iscsi.portal.update': _method(update: true),
        'iscsi.portal.listen_ip_choices': _method(),
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
      'comment': 'existing',
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
  final choices = <String, String>{
    '192.0.2.10': 'existing',
    '192.0.2.11': 'new static address',
  };
  final calls = <AdminRequest>[];
  String state = 'STOPPED';
  bool sessions = false;
  bool unknown = false;
  bool leavePortal = false;
  bool mutateTarget = false;
  bool mutateComment = false;
  bool mutatePort = false;

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
      case 'iscsi.portal.listen_ip_choices':
        return AdminCompleted(
          request,
          value: Map<String, String>.from(choices),
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
      case 'iscsi.portal.create':
        if (unknown) return AdminOutcomeUnknown(request);
        final data = request.arguments.single as Map;
        final ip = ((data['listen'] as List).single as Map)['ip'];
        final created = <String, Object?>{
          'id': 7,
          'tag': 8,
          'listen': [
            {'ip': ip, 'port': 3260},
          ],
          'comment': data['comment'],
        };
        if (!leavePortal) portals.add(created);
        if (mutateTarget) targets.single['name'] = 'changed';
        return AdminCompleted(request, value: created);
      case 'iscsi.portal.update':
        if (unknown) return AdminOutcomeUnknown(request);
        final row = portals.singleWhere(
          (row) => row['id'] == request.arguments.first,
        );
        final data = request.arguments[1] as Map;
        final ip = ((data['listen'] as List).single as Map)['ip'];
        if (!leavePortal) {
          row['listen'] = [
            {'ip': ip, 'port': mutatePort ? 3261 : 3260},
          ];
        }
        if (mutateComment) row['comment'] = 'unexpected';
        if (mutateTarget) targets.single['name'] = 'changed';
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
    coordinator = IscsiPortalCreateCoordinator(
      session: session,
      api: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final _Fake api;
  late final AuthenticatedSession session;
  late final IscsiPortalCreateCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes => api.calls
      .where((call) => call.method.name == 'iscsi.portal.create')
      .length;
  static const ip = '192.0.2.11';
}

void main() {
  test(
    'creates one unassigned portal with exact payload and readback',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(_Harness.ip, 'new portal');
      expect(h.writes, 0);
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, IscsiPortalCreateOutcome.completed);
      expect(h.writes, 1);
      expect(
        h.api.calls
            .singleWhere((call) => call.method.name == 'iscsi.portal.create')
            .arguments,
        [
          {
            'listen': [
              {'ip': _Harness.ip},
            ],
            'comment': 'new portal',
          },
        ],
      );
      expect(h.api.portals.last['id'], 7);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiPortalCreateOutcome.rejected,
      );
    },
  );

  test('unsupported, used or invalid IP and running service or sessions block review', () async {
    final h = _Harness();
    for (final ip in ['0.0.0.0', '999.1.1.1', '192.0.2.12', '192.0.2.10']) {
      await expectLater(h.coordinator.prepare(ip, ''), throwsStateError);
    }
    h.api.state = 'RUNNING';
    await expectLater(h.coordinator.prepare(_Harness.ip, ''), throwsStateError);
    h.api.state = 'STOPPED';
    h.api.sessions = true;
    await expectLater(h.coordinator.prepare(_Harness.ip, ''), throwsStateError);
    expect(h.writes, 0);
  });

  test('review drift, wrong phrase and expiry reject before write', () async {
    final h = _Harness();
    var review = await h.coordinator.prepare(_Harness.ip, 'new');
    expect(
      (await h.coordinator.execute(review, 'wrong')).outcome,
      IscsiPortalCreateOutcome.rejected,
    );
    review = await h.coordinator.prepare(_Harness.ip, 'new');
    h.api.choices.remove(_Harness.ip);
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiPortalCreateOutcome.rejected,
    );
    h.api.choices[_Harness.ip] = 'new static address';
    review = await h.coordinator.prepare(_Harness.ip, 'new');
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiPortalCreateOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test('session change and uncertain response fence further writes', () async {
    final h = _Harness();
    var review = await h.coordinator.prepare(_Harness.ip, 'new');
    h.current = false;
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiPortalCreateOutcome.rejected,
    );
    h.current = true;
    review = await h.coordinator.prepare(_Harness.ip, 'new');
    h.api.unknown = true;
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiPortalCreateOutcome.unknown,
    );
    expect(h.coordinator.locked, isTrue);
    await expectLater(
      h.coordinator.prepare(_Harness.ip, 'new'),
      throwsStateError,
    );
  });

  test('missing portal or changed target after write is uncertain', () async {
    for (final failure in [0, 1]) {
      final h = _Harness();
      h.api.leavePortal = failure == 0;
      h.api.mutateTarget = failure == 1;
      final review = await h.coordinator.prepare(_Harness.ip, 'new');
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiPortalCreateOutcome.unknown,
      );
      expect(h.coordinator.locked, isTrue);
    }
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
              child: IscsiPortalCreateEditor(overview: overview),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('iscsi-portal-create-ip')),
      _Harness.ip,
    );
    await tester.enterText(
      find.byKey(const Key('iscsi-portal-create-comment')),
      'new',
    );
    await tester.tap(find.byKey(const Key('iscsi-portal-create-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    await tester.enterText(
      find.byKey(const Key('iscsi-portal-create-confirmation')),
      'CREATE ISCSI PORTAL ${_Harness.ip}',
    );
    await tester.ensureVisible(
      find.byKey(const Key('iscsi-portal-create-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-portal-create-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
  });

  test(
    'replaces only an unreferenced single listener with exact payload',
    () async {
      final h = _Harness();
      final coordinator = IscsiPortalListenerCoordinator(
        session: h.session,
        api: h.api,
        lock: ServerOperationLock(),
        isCurrent: () => h.current,
        now: () => h.clock,
      );
      final review = await coordinator.prepare(3, _Harness.ip);
      expect(review.before, '192.0.2.10');
      expect(review.port, 3260);
      expect(
        h.api.calls.where((call) => call.method.name == 'iscsi.portal.update'),
        isEmpty,
      );
      final result = await coordinator.execute(review, review.confirmation);
      expect(result.outcome, IscsiPortalListenerOutcome.completed);
      expect(
        h.api.calls
            .singleWhere((call) => call.method.name == 'iscsi.portal.update')
            .arguments,
        [
          3,
          {
            'listen': [
              {'ip': _Harness.ip},
            ],
          },
        ],
      );
      expect(h.api.portals.single['comment'], 'existing');
      expect(
        (await coordinator.execute(review, review.confirmation)).outcome,
        IscsiPortalListenerOutcome.rejected,
      );
    },
  );

  test(
    'listener change blocks referenced, multi-listener and unavailable IP',
    () async {
      final h = _Harness();
      final coordinator = IscsiPortalListenerCoordinator(
        session: h.session,
        api: h.api,
        lock: ServerOperationLock(),
        isCurrent: () => h.current,
        now: () => h.clock,
      );
      h.api.targets.single['groups'] = [
        {'portal': 3, 'initiator': null, 'authmethod': 'NONE', 'auth': null},
      ];
      await expectLater(coordinator.prepare(3, _Harness.ip), throwsStateError);
      h.api.targets.single['groups'] = <Object?>[];
      h.api.portals.single['listen'] = [
        {'ip': '192.0.2.10', 'port': 3260},
        {'ip': '192.0.2.12', 'port': 3260},
      ];
      await expectLater(coordinator.prepare(3, _Harness.ip), throwsStateError);
      h.api.portals.single['listen'] = [
        {'ip': '192.0.2.10', 'port': 3260},
      ];
      h.api.choices.remove(_Harness.ip);
      await expectLater(coordinator.prepare(3, _Harness.ip), throwsStateError);
      h.api.choices[_Harness.ip] = 'new';
      h.api.state = 'RUNNING';
      await expectLater(coordinator.prepare(3, _Harness.ip), throwsStateError);
      h.api.state = 'STOPPED';
      h.api.sessions = true;
      await expectLater(coordinator.prepare(3, _Harness.ip), throwsStateError);
      expect(
        h.api.calls.where((call) => call.method.name == 'iscsi.portal.update'),
        isEmpty,
      );
    },
  );

  test(
    'listener review drift, phrase, expiry and session switch reject',
    () async {
      final h = _Harness();
      final coordinator = IscsiPortalListenerCoordinator(
        session: h.session,
        api: h.api,
        lock: ServerOperationLock(),
        isCurrent: () => h.current,
        now: () => h.clock,
      );
      var review = await coordinator.prepare(3, _Harness.ip);
      expect(
        (await coordinator.execute(review, 'wrong')).outcome,
        IscsiPortalListenerOutcome.rejected,
      );
      review = await coordinator.prepare(3, _Harness.ip);
      h.api.targets.single['name'] = 'changed';
      expect(
        (await coordinator.execute(review, review.confirmation)).outcome,
        IscsiPortalListenerOutcome.rejected,
      );
      h.api.targets.single['name'] = 'target';
      review = await coordinator.prepare(3, _Harness.ip);
      h.clock = h.clock.add(const Duration(minutes: 5));
      expect(
        (await coordinator.execute(review, review.confirmation)).outcome,
        IscsiPortalListenerOutcome.rejected,
      );
      review = await coordinator.prepare(3, _Harness.ip);
      h.current = false;
      expect(
        (await coordinator.execute(review, review.confirmation)).outcome,
        IscsiPortalListenerOutcome.rejected,
      );
      expect(
        h.api.calls.where((call) => call.method.name == 'iscsi.portal.update'),
        isEmpty,
      );
    },
  );

  test(
    'uncertain listener response and collateral change fence retry',
    () async {
      for (final failure in [0, 1, 2, 3]) {
        final h = _Harness();
        final coordinator = IscsiPortalListenerCoordinator(
          session: h.session,
          api: h.api,
          lock: ServerOperationLock(),
          isCurrent: () => h.current,
          now: () => h.clock,
        );
        h.api.unknown = failure == 0;
        h.api.leavePortal = failure == 1;
        h.api.mutateComment = failure == 2;
        h.api.mutatePort = failure == 3;
        final review = await coordinator.prepare(3, _Harness.ip);
        expect(
          (await coordinator.execute(review, review.confirmation)).outcome,
          IscsiPortalListenerOutcome.unknown,
        );
        expect(coordinator.locked, isTrue);
        await expectLater(
          coordinator.prepare(3, _Harness.ip),
          throwsStateError,
        );
      }
    },
  );

  testWidgets('listener editor requires review and exact confirmation', (
    tester,
  ) async {
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
              child: IscsiPortalListenerEditor(overview: overview),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-portal-listener-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Portal #3').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('iscsi-portal-listener-new')),
      _Harness.ip,
    );
    await tester.tap(find.byKey(const Key('iscsi-portal-listener-review')));
    await tester.pumpAndSettle();
    expect(
      h.api.calls.where((call) => call.method.name == 'iscsi.portal.update'),
      isEmpty,
    );
    await tester.enterText(
      find.byKey(const Key('iscsi-portal-listener-confirmation')),
      'REPLACE ISCSI PORTAL #3 192.0.2.10 WITH ${_Harness.ip}',
    );
    await tester.ensureVisible(
      find.byKey(const Key('iscsi-portal-listener-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-portal-listener-submit')));
    await tester.pumpAndSettle();
    expect(
      h.api.calls.where((call) => call.method.name == 'iscsi.portal.update'),
      hasLength(1),
    );
  });
}
