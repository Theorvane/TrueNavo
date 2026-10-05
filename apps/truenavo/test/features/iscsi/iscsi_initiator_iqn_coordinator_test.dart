import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/iscsi/iscsi_initiator_iqn_coordinator.dart';
import 'package:truenavo/features/iscsi/iscsi_initiator_iqn_editor.dart';
import 'package:truenavo/features/iscsi/iscsi_initiator_iqn_remove_editor.dart';
import 'package:truenavo/features/iscsi/iscsi_overview.dart';
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
              'initiators': {
                'type': 'array',
                'items': {'type': 'string'},
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
        'iscsi.initiator.query': _method(),
        'iscsi.initiator.update': _method(update: true),
        'iscsi.target.query': _method(),
        'service.query': _method(),
        'iscsi.global.sessions': _method(),
      },
    );
  }
  @override
  late final AdminCatalog adminCatalog;
  final groups = <Map<String, Object?>>[
    {
      'id': 3,
      'initiators': ['iqn.2026-01.example.com:old'],
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
  bool unknown = false;
  bool mutateComment = false;

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
      case 'iscsi.initiator.update':
        if (unknown) return AdminOutcomeUnknown(request);
        final row = groups.singleWhere(
          (row) => row['id'] == request.arguments.first,
        );
        row['initiators'] = (request.arguments[1] as Map)['initiators'];
        if (mutateComment) row['comment'] = 'unexpected';
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
    coordinator = IscsiInitiatorIqnCoordinator(
      session: session,
      api: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final _Fake api;
  late final AuthenticatedSession session;
  late final IscsiInitiatorIqnCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes => api.calls
      .where((call) => call.method.name == 'iscsi.initiator.update')
      .length;
  static const next = 'iqn.2026-01.example.com:new';
}

void main() {
  testWidgets('remove editor requires review and exact confirmation', (
    tester,
  ) async {
    final h = _Harness();
    h.api.groups.single['initiators'] = [
      'iqn.2026-01.example.com:old',
      'iqn.2026-01.example.com:second',
    ];
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
          theme: TrueNavoTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: IscsiInitiatorIqnRemoveEditor(overview: overview),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-initiator-iqn-remove-select')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('#3 (2 IQNs)').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-initiator-iqn-remove-name')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('iqn.2026-01.example.com:old').last);
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-initiator-iqn-remove-review')),
    );
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    await tester.enterText(
      find.byKey(const Key('iscsi-initiator-iqn-remove-confirmation')),
      'REMOVE ISCSI INITIATOR #3 iqn.2026-01.example.com:old',
    );
    await tester.ensureVisible(
      find.byKey(const Key('iscsi-initiator-iqn-remove-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.byKey(const Key('iscsi-initiator-iqn-remove-submit')),
    );
    await tester.pumpAndSettle();
    expect(h.writes, 1);
  });

  test('removes one IQN while preserving remaining list and comment', () async {
    final h = _Harness();
    h.api.groups.single['initiators'] = [
      'iqn.2026-01.example.com:old',
      'iqn.2026-01.example.com:second',
      'iqn.2026-01.example.com:third',
    ];
    final review = await h.coordinator.prepareRemove(
      3,
      'iqn.2026-01.example.com:second',
    );
    expect(() => review.before.add(_Harness.next), throwsUnsupportedError);
    expect(h.writes, 0);
    final result = await h.coordinator.executeRemove(
      review,
      review.confirmation,
    );
    expect(result.outcome, IscsiInitiatorIqnOutcome.completed);
    expect(
      h.api.calls
          .singleWhere((call) => call.method.name == 'iscsi.initiator.update')
          .arguments,
      [
        3,
        {
          'initiators': [
            'iqn.2026-01.example.com:old',
            'iqn.2026-01.example.com:third',
          ],
        },
      ],
    );
    expect(h.api.groups.single['comment'], 'host');
    expect(
      (await h.coordinator.executeRemove(review, review.confirmation)).outcome,
      IscsiInitiatorIqnOutcome.rejected,
    );
  });

  test(
    'remove rejects last IQN, wildcard, reference, drift and expiry',
    () async {
      final h = _Harness();
      await expectLater(
        h.coordinator.prepareRemove(3, 'iqn.2026-01.example.com:old'),
        throwsStateError,
      );
      h.api.groups.single['initiators'] = [
        'ALL',
        'iqn.2026-01.example.com:old',
      ];
      await expectLater(
        h.coordinator.prepareRemove(3, 'iqn.2026-01.example.com:old'),
        throwsStateError,
      );
      h.api.groups.single['initiators'] = [
        'iqn.2026-01.example.com:old',
        'iqn.2026-01.example.com:second',
      ];
      h.api.targets.single['groups'] = [
        {'portal': 1, 'initiator': 3, 'authmethod': 'NONE', 'auth': null},
      ];
      await expectLater(
        h.coordinator.prepareRemove(3, 'iqn.2026-01.example.com:old'),
        throwsStateError,
      );
      h.api.targets.single['groups'] = <Object?>[];
      h.api.state = 'RUNNING';
      await expectLater(
        h.coordinator.prepareRemove(3, 'iqn.2026-01.example.com:old'),
        throwsStateError,
      );
      h.api.state = 'STOPPED';
      h.api.sessions = true;
      await expectLater(
        h.coordinator.prepareRemove(3, 'iqn.2026-01.example.com:old'),
        throwsStateError,
      );
      h.api.sessions = false;
      var review = await h.coordinator.prepareRemove(
        3,
        'iqn.2026-01.example.com:old',
      );
      expect(
        (await h.coordinator.executeRemove(review, 'wrong')).outcome,
        IscsiInitiatorIqnOutcome.rejected,
      );
      review = await h.coordinator.prepareRemove(
        3,
        'iqn.2026-01.example.com:old',
      );
      h.api.groups.single['comment'] = 'changed';
      expect(
        (await h.coordinator.executeRemove(
          review,
          review.confirmation,
        )).outcome,
        IscsiInitiatorIqnOutcome.rejected,
      );
      h.api.groups.single['comment'] = 'host';
      review = await h.coordinator.prepareRemove(
        3,
        'iqn.2026-01.example.com:old',
      );
      h.clock = h.clock.add(const Duration(minutes: 5));
      expect(
        (await h.coordinator.executeRemove(
          review,
          review.confirmation,
        )).outcome,
        IscsiInitiatorIqnOutcome.rejected,
      );
      expect(h.writes, 0);
    },
  );

  test('remove unknown outcome fences the session', () async {
    final h = _Harness();
    h.api.groups.single['initiators'] = [
      'iqn.2026-01.example.com:old',
      'iqn.2026-01.example.com:second',
    ];
    final review = await h.coordinator.prepareRemove(
      3,
      'iqn.2026-01.example.com:old',
    );
    h.api.unknown = true;
    expect(
      (await h.coordinator.executeRemove(review, review.confirmation)).outcome,
      IscsiInitiatorIqnOutcome.unknown,
    );
    expect(h.coordinator.locked, isTrue);
  });

  test('adds one IQN while preserving existing list and comment', () async {
    final h = _Harness();
    h.api.groups.single['initiators'] = [
      'iqn.2026-01.example.com:old',
      'iqn.2026-01.example.com:second',
    ];
    final review = await h.coordinator.prepareAdd(3, _Harness.next);
    expect(h.writes, 0);
    expect(review.before, hasLength(2));
    final result = await h.coordinator.executeAdd(review, review.confirmation);
    expect(result.outcome, IscsiInitiatorIqnOutcome.completed);
    expect(h.writes, 1);
    expect(
      h.api.calls
          .singleWhere((call) => call.method.name == 'iscsi.initiator.update')
          .arguments,
      [
        3,
        {
          'initiators': [
            'iqn.2026-01.example.com:old',
            'iqn.2026-01.example.com:second',
            _Harness.next,
          ],
        },
      ],
    );
    expect(h.api.groups.single['comment'], 'host');
    expect(
      (await h.coordinator.executeAdd(review, review.confirmation)).outcome,
      IscsiInitiatorIqnOutcome.rejected,
    );
  });

  test(
    'add blocks references, service, sessions, duplicate and malformed lists',
    () async {
      final h = _Harness();
      h.api.targets.single['groups'] = [
        {'portal': 1, 'initiator': 3, 'authmethod': 'NONE', 'auth': null},
      ];
      await expectLater(
        h.coordinator.prepareAdd(3, _Harness.next),
        throwsStateError,
      );
      h.api.targets.single['groups'] = <Object?>[];
      h.api.state = 'RUNNING';
      await expectLater(
        h.coordinator.prepareAdd(3, _Harness.next),
        throwsStateError,
      );
      h.api.state = 'STOPPED';
      h.api.sessions = true;
      await expectLater(
        h.coordinator.prepareAdd(3, _Harness.next),
        throwsStateError,
      );
      h.api.sessions = false;
      h.api.groups.single['initiators'] = ['ALL'];
      await expectLater(
        h.coordinator.prepareAdd(3, _Harness.next),
        throwsStateError,
      );
      h.api.groups.single['initiators'] = ['iqn.2026-01.example.com:old'];
      h.api.groups.add({
        'id': 5,
        'initiators': [_Harness.next],
        'comment': '',
      });
      await expectLater(
        h.coordinator.prepareAdd(3, _Harness.next),
        throwsStateError,
      );
      h.api.groups.removeLast();
      h.api.groups.single['initiators'] = [
        for (var index = 0; index < 10; index++)
          'iqn.2026-01.example.com:host$index',
      ];
      await expectLater(
        h.coordinator.prepareAdd(3, _Harness.next),
        throwsStateError,
      );
      h.api.groups.single['initiators'] = ['iqn.2026-01.example.com:old'];
      await expectLater(
        h.coordinator.prepareAdd(3, 'iqn.BAD'),
        throwsStateError,
      );
      expect(h.writes, 0);
    },
  );

  test(
    'add recheck rejects drift, phrase mismatch and expired review',
    () async {
      final h = _Harness();
      var review = await h.coordinator.prepareAdd(3, _Harness.next);
      expect(
        (await h.coordinator.executeAdd(review, 'wrong')).outcome,
        IscsiInitiatorIqnOutcome.rejected,
      );
      review = await h.coordinator.prepareAdd(3, _Harness.next);
      h.api.groups.single['comment'] = 'changed';
      expect(
        (await h.coordinator.executeAdd(review, review.confirmation)).outcome,
        IscsiInitiatorIqnOutcome.rejected,
      );
      h.api.groups.single['comment'] = 'host';
      review = await h.coordinator.prepareAdd(3, _Harness.next);
      h.clock = h.clock.add(const Duration(minutes: 5));
      expect(
        (await h.coordinator.executeAdd(review, review.confirmation)).outcome,
        IscsiInitiatorIqnOutcome.rejected,
      );
      expect(h.writes, 0);
    },
  );

  test('add unknown result fences the session', () async {
    final h = _Harness();
    final review = await h.coordinator.prepareAdd(3, _Harness.next);
    h.api.unknown = true;
    expect(
      (await h.coordinator.executeAdd(review, review.confirmation)).outcome,
      IscsiInitiatorIqnOutcome.unknown,
    );
    expect(h.coordinator.locked, isTrue);
  });

  test(
    'add unexpected post-write comment mutation fences the session',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepareAdd(3, _Harness.next);
      h.api.mutateComment = true;
      expect(
        (await h.coordinator.executeAdd(review, review.confirmation)).outcome,
        IscsiInitiatorIqnOutcome.unknown,
      );
      expect(h.coordinator.locked, isTrue);
      expect(h.writes, 1);
    },
  );

  test(
    'replaces one unreferenced IQN with exact payload and readback',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(3, _Harness.next);
      expect(h.writes, 0);
      expect(review.before, 'iqn.2026-01.example.com:old');
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, IscsiInitiatorIqnOutcome.completed);
      expect(h.writes, 1);
      expect(
        h.api.calls
            .singleWhere((call) => call.method.name == 'iscsi.initiator.update')
            .arguments,
        [
          3,
          {
            'initiators': [_Harness.next],
          },
        ],
      );
      expect(h.api.groups.single['comment'], 'host');
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiInitiatorIqnOutcome.rejected,
      );
    },
  );

  test(
    'references, running service, sessions and multiple IQNs block review',
    () async {
      final h = _Harness();
      h.api.targets.single['groups'] = [
        {'portal': 1, 'initiator': 3, 'authmethod': 'NONE', 'auth': null},
      ];
      await expectLater(
        h.coordinator.prepare(3, _Harness.next),
        throwsStateError,
      );
      h.api.targets.single['groups'] = <Object?>[];
      h.api.state = 'RUNNING';
      await expectLater(
        h.coordinator.prepare(3, _Harness.next),
        throwsStateError,
      );
      h.api.state = 'STOPPED';
      h.api.sessions = true;
      await expectLater(
        h.coordinator.prepare(3, _Harness.next),
        throwsStateError,
      );
      h.api.sessions = false;
      h.api.groups.single['initiators'] = [
        'iqn.2026-01.example.com:old',
        _Harness.next,
      ];
      await expectLater(
        h.coordinator.prepare(3, 'iqn.2026-01.example.com:third'),
        throwsStateError,
      );
      expect(h.writes, 0);
    },
  );

  test(
    'duplicate, invalid IQN, inventory drift and review expiry never write',
    () async {
      final h = _Harness();
      h.api.groups.add({
        'id': 5,
        'initiators': [_Harness.next],
        'comment': '',
      });
      await expectLater(
        h.coordinator.prepare(3, _Harness.next),
        throwsStateError,
      );
      h.api.groups.removeLast();
      await expectLater(h.coordinator.prepare(3, 'iqn.BAD'), throwsStateError);
      var review = await h.coordinator.prepare(3, _Harness.next);
      h.api.targets.single['name'] = 'changed';
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiInitiatorIqnOutcome.rejected,
      );
      h.api.targets.single['name'] = 'target';
      review = await h.coordinator.prepare(3, _Harness.next);
      h.clock = h.clock.add(const Duration(minutes: 5));
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiInitiatorIqnOutcome.rejected,
      );
      expect(h.writes, 0);
    },
  );

  test(
    'wrong phrase and session change reject; unknown outcome fences retry',
    () async {
      final h = _Harness();
      var review = await h.coordinator.prepare(3, _Harness.next);
      expect(
        (await h.coordinator.execute(review, 'wrong')).outcome,
        IscsiInitiatorIqnOutcome.rejected,
      );
      review = await h.coordinator.prepare(3, _Harness.next);
      h.current = false;
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiInitiatorIqnOutcome.rejected,
      );
      h.current = true;
      review = await h.coordinator.prepare(3, _Harness.next);
      h.api.unknown = true;
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiInitiatorIqnOutcome.unknown,
      );
      expect(h.coordinator.locked, isTrue);
      await expectLater(
        h.coordinator.prepare(3, _Harness.next),
        throwsStateError,
      );
      expect(h.writes, 1);
    },
  );

  test('unexpected comment mutation leaves uncertain state', () async {
    final h = _Harness();
    h.api.mutateComment = true;
    final review = await h.coordinator.prepare(3, _Harness.next);
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiInitiatorIqnOutcome.unknown,
    );
    expect(h.coordinator.locked, isTrue);
  });

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
          theme: TrueNavoTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: IscsiInitiatorIqnEditor(overview: overview),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-initiator-iqn-select')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('#3 iqn.2026-01.example.com:old').last);
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('iscsi-initiator-iqn-new')),
      _Harness.next,
    );
    await tester.tap(find.byKey(const Key('iscsi-initiator-iqn-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    await tester.enterText(
      find.byKey(const Key('iscsi-initiator-iqn-confirmation')),
      'REPLACE ISCSI INITIATOR #3 iqn.2026-01.example.com:old WITH ${_Harness.next}',
    );
    await tester.ensureVisible(
      find.byKey(const Key('iscsi-initiator-iqn-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-initiator-iqn-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
  });
}
