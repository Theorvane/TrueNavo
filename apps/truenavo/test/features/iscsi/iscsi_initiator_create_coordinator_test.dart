import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/iscsi/iscsi_initiator_create_coordinator.dart';
import 'package:truenavo/features/iscsi/iscsi_initiator_create_editor.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

Map<String, Object?> _method({bool create = false}) => {
  'accepts': create
      ? [
          {
            '_name_': 'data',
            '_required_': true,
            'type': 'object',
            'properties': {
              'initiators': {
                'type': 'array',
                'items': {'type': 'string'},
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
  _Fake({this.advertiseCreate = true}) {
    adminCatalog = AdminCatalog.fromMetadata(
      version: '25.10.1',
      metadata: {
        'iscsi.initiator.query': _method(),
        if (advertiseCreate) 'iscsi.initiator.create': _method(create: true),
        'iscsi.target.query': _method(),
        'service.query': _method(),
        'iscsi.global.sessions': _method(),
      },
    );
  }
  final bool advertiseCreate;
  @override
  late final AdminCatalog adminCatalog;
  final initiators = <Map<String, Object?>>[
    {
      'id': 2,
      'initiators': ['iqn.2026-01.example.com:old'],
      'comment': 'old',
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
  bool unknownCreate = false;
  bool attachAfterCreate = false;

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
      case 'iscsi.initiator.query':
        return AdminCompleted(
          request,
          value: [for (final row in initiators) Map<String, Object?>.from(row)],
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
      case 'iscsi.initiator.create':
        if (unknownCreate) return AdminOutcomeUnknown(request);
        final payload = request.arguments.single as Map;
        final row = <String, Object?>{
          'id': 7,
          'initiators': payload['initiators'],
          'comment': payload['comment'],
        };
        initiators.add(row);
        if (attachAfterCreate) {
          targets.single['groups'] = [
            {'portal': 1, 'initiator': 7, 'authmethod': 'NONE', 'auth': null},
          ];
        }
        return AdminCompleted(request, value: Map<String, Object?>.from(row));
      default:
        throw StateError('Unexpected fake call');
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness({bool advertiseCreate = true})
    : api = _Fake(advertiseCreate: advertiseCreate) {
    session = AuthenticatedSession(
      profileId: 'fixture',
      repository: api,
      availableMethodNames: const {},
      endpoint: 'wss://fixture.example/api/current',
    );
    coordinator = IscsiInitiatorCreateCoordinator(
      session: session,
      api: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final _Fake api;
  late final AuthenticatedSession session;
  late final IscsiInitiatorCreateCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes => api.calls
      .where((call) => call.method.name == 'iscsi.initiator.create')
      .length;
}

const iqn = 'iqn.2026-01.example.com:host';

void main() {
  test(
    'creates one unassigned IQN after two service and dependency reads',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(iqn, 'host');
      expect(h.writes, 0);
      expect(review.confirmation, 'CREATE ISCSI INITIATOR $iqn');
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, IscsiInitiatorCreateOutcome.completed);
      expect(h.writes, 1);
      expect(
        h.api.calls
            .singleWhere((call) => call.method.name == 'iscsi.initiator.create')
            .arguments,
        [
          {
            'initiators': [iqn],
            'comment': 'host',
          },
        ],
      );
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiInitiatorCreateOutcome.rejected,
      );
    },
  );

  test(
    'wildcard, IP, duplicate, running service and sessions block review',
    () async {
      final h = _Harness();
      await expectLater(h.coordinator.prepare('*', ''), throwsStateError);
      await expectLater(
        h.coordinator.prepare('192.0.2.1', ''),
        throwsStateError,
      );
      await expectLater(
        h.coordinator.prepare('iqn.2026-01.example.com:old', ''),
        throwsStateError,
      );
      h.api.state = 'RUNNING';
      await expectLater(h.coordinator.prepare(iqn, ''), throwsStateError);
      h.api.state = 'STOPPED';
      h.api.sessions = true;
      await expectLater(h.coordinator.prepare(iqn, ''), throwsStateError);
      expect(h.writes, 0);
      expect(_Harness(advertiseCreate: false).coordinator.available, isFalse);
    },
  );

  test('bounded inventories and malformed target access fail closed', () async {
    final h = _Harness();
    for (var id = 10; id < 108; id++) {
      h.api.initiators.add({
        'id': id,
        'initiators': ['iqn.2026-01.example.com:node$id'],
        'comment': '',
      });
    }
    expect(h.api.initiators.length, 99);
    await expectLater(h.coordinator.prepare(iqn, ''), throwsStateError);
    h.api.initiators.removeRange(1, h.api.initiators.length);
    h.api.targets.single['groups'] = [
      {'portal': 1, 'initiator': 'bad'},
    ];
    await expectLater(h.coordinator.prepare(iqn, ''), throwsStateError);
    expect(h.writes, 0);
  });

  test('drift, expiry and wrong phrase reject without submission', () async {
    final h = _Harness();
    final first = await h.coordinator.prepare(iqn, 'host');
    h.api.targets.single['name'] = 'changed';
    expect(
      (await h.coordinator.execute(first, first.confirmation)).outcome,
      IscsiInitiatorCreateOutcome.rejected,
    );
    h.api.targets.single['name'] = 'target';
    final second = await h.coordinator.prepare(iqn, 'host');
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(second, second.confirmation)).outcome,
      IscsiInitiatorCreateOutcome.rejected,
    );
    final third = await h.coordinator.prepare(iqn, 'host');
    expect(
      (await h.coordinator.execute(third, 'wrong')).outcome,
      IscsiInitiatorCreateOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test(
    'unknown result or unexpected target assignment fences writes',
    () async {
      final h = _Harness();
      h.api.unknownCreate = true;
      final review = await h.coordinator.prepare(iqn, 'host');
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiInitiatorCreateOutcome.unknown,
      );
      expect(h.coordinator.locked, isTrue);
      await expectLater(h.coordinator.prepare(iqn, ''), throwsStateError);

      final other = _Harness();
      other.api.attachAfterCreate = true;
      final otherReview = await other.coordinator.prepare(iqn, 'host');
      expect(
        (await other.coordinator.execute(
          otherReview,
          otherReview.confirmation,
        )).outcome,
        IscsiInitiatorCreateOutcome.unknown,
      );
      expect(other.coordinator.locked, isTrue);
    },
  );

  testWidgets('editor requires review and exact confirmation', (tester) async {
    final h = _Harness();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
          // Reuse the controlled fixture clock; do not depend on wall time.
          iscsiInitiatorCreateCoordinatorProvider.overrideWithValue(
            h.coordinator,
          ),
        ],
        child: MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: IscsiInitiatorCreateEditor()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('iscsi-initiator-create-iqn')),
      iqn,
    );
    await tester.enterText(
      find.byKey(const Key('iscsi-initiator-create-comment')),
      'host',
    );
    await tester.tap(find.byKey(const Key('iscsi-initiator-create-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    await tester.enterText(
      find.byKey(const Key('iscsi-initiator-create-confirmation')),
      'CREATE ISCSI INITIATOR $iqn',
    );
    await tester.ensureVisible(
      find.byKey(const Key('iscsi-initiator-create-submit')),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('iscsi-initiator-create-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
  });
}
