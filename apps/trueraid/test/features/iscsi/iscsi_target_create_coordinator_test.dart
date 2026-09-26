import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/iscsi/iscsi_target_create_coordinator.dart';
import 'package:trueraid/features/iscsi/iscsi_target_create_editor.dart';
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
            'required': ['name'],
            'properties': {
              'name': {'type': 'string'},
              'mode': {'type': 'string'},
              'groups': {
                'type': 'array',
                'items': {'type': 'object'},
              },
              'auth_networks': {
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
  _Fake({this.advertiseCreate = true}) {
    adminCatalog = AdminCatalog.fromMetadata(
      version: '25.10.1',
      metadata: {
        'iscsi.target.query': _method(),
        'iscsi.target.validate_name': _method(),
        if (advertiseCreate) 'iscsi.target.create': _method(create: true),
        'service.query': _method(),
        'iscsi.global.sessions': _method(),
      },
    );
  }
  final bool advertiseCreate;
  @override
  late final AdminCatalog adminCatalog;
  final targets = <Map<String, Object?>>[
    {
      'id': 3,
      'name': 'existing',
      'mode': 'ISCSI',
      'groups': [],
      'auth_networks': [],
    },
  ];
  final calls = <AdminRequest>[];
  String state = 'STOPPED';
  bool sessions = false;
  bool rejectName = false;
  bool unknownCreate = false;
  bool attachGroupAfterCreate = false;

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
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
      case 'iscsi.target.validate_name':
        return AdminCompleted(request, value: rejectName ? 'invalid' : null);
      case 'iscsi.target.create':
        if (unknownCreate) return AdminOutcomeUnknown(request);
        final payload = request.arguments.single as Map;
        final row = <String, Object?>{
          'id': 7,
          'name': payload['name'],
          'mode': payload['mode'],
          'groups': attachGroupAfterCreate
              ? [
                  <String, Object?>{'portal': 1},
                ]
              : [],
          'auth_networks': payload['auth_networks'],
        };
        targets.add(row);
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
    coordinator = IscsiTargetCreateCoordinator(
      session: session,
      api: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
  }
  final _Fake api;
  late final AuthenticatedSession session;
  late final IscsiTargetCreateCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes =>
      api.calls.where((c) => c.method.name == 'iscsi.target.create').length;
}

void main() {
  test(
    'creates only an unbound target after two stopped-service checks',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare('new-target');
      expect(h.writes, 0);
      expect(review.confirmation, 'CREATE ISCSI TARGET new-target');
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, IscsiTargetCreateOutcome.completed);
      expect(h.writes, 1);
      expect(
        h.api.calls
            .singleWhere((c) => c.method.name == 'iscsi.target.create')
            .arguments,
        [
          {
            'name': 'new-target',
            'mode': 'ISCSI',
            'groups': [],
            'auth_networks': [],
          },
        ],
      );
      expect(
        h.api.calls
            .where((c) => c.method.name == 'iscsi.target.validate_name')
            .length,
        2,
      );
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiTargetCreateOutcome.rejected,
      );
    },
  );

  test('active service, sessions, duplicate or server-invalid name block preflight', () async {
    final h = _Harness();
    h.api.state = 'RUNNING';
    await expectLater(h.coordinator.prepare('new'), throwsStateError);
    h.api.state = 'STOPPED';
    h.api.sessions = true;
    await expectLater(h.coordinator.prepare('new'), throwsStateError);
    h.api.sessions = false;
    await expectLater(h.coordinator.prepare('existing'), throwsStateError);
    h.api.rejectName = true;
    await expectLater(h.coordinator.prepare('new'), throwsStateError);
    expect(h.writes, 0);
  });

  test(
    'inventory boundary rejects creation before an unverifiable readback',
    () async {
      final h = _Harness();
      for (var id = 10; id < 108; id++) {
        h.api.targets.add({
          'id': id,
          'name': 'target-$id',
          'mode': 'ISCSI',
          'groups': <Object?>[],
          'auth_networks': <Object?>[],
        });
      }
      expect(h.api.targets.length, 99);
      await expectLater(h.coordinator.prepare('new'), throwsStateError);
      expect(h.writes, 0);
    },
  );

  test('drift, expiration and wrong phrase reject before submission', () async {
    final h = _Harness();
    final review = await h.coordinator.prepare('new');
    h.api.targets.add({
      'id': 4,
      'name': 'other',
      'mode': 'ISCSI',
      'groups': [],
      'auth_networks': [],
    });
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      IscsiTargetCreateOutcome.rejected,
    );
    h.api.targets.removeLast();
    final next = await h.coordinator.prepare('new');
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(next, next.confirmation)).outcome,
      IscsiTargetCreateOutcome.rejected,
    );
    final last = await h.coordinator.prepare('new');
    expect(
      (await h.coordinator.execute(last, 'wrong')).outcome,
      IscsiTargetCreateOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test(
    'unknown result or unexpected access group fences all iSCSI writes',
    () async {
      final h = _Harness();
      h.api.unknownCreate = true;
      final review = await h.coordinator.prepare('new');
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        IscsiTargetCreateOutcome.unknown,
      );
      expect(h.coordinator.locked, isTrue);
      expect(h.writes, 1);
      await expectLater(h.coordinator.prepare('again'), throwsStateError);

      final other = _Harness();
      other.api.attachGroupAfterCreate = true;
      final otherReview = await other.coordinator.prepare('new');
      expect(
        (await other.coordinator.execute(
          otherReview,
          otherReview.confirmation,
        )).outcome,
        IscsiTargetCreateOutcome.unknown,
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
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: IscsiTargetCreateEditor()),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('iscsi-target-create-name')),
      'new',
    );
    await tester.tap(find.byKey(const Key('iscsi-target-create-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    expect(find.text('New target: new'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('iscsi-target-create-confirmation')),
      'CREATE ISCSI TARGET new',
    );
    await tester.tap(find.byKey(const Key('iscsi-target-create-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
    expect(h.api.targets.last['name'], 'new');
  });
}
