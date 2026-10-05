import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nvme/nvme_subsystem_create_coordinator.dart';
import 'package:truenavo/features/nvme/nvme_subsystem_create_editor.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _queries = [
  'nvmet.subsys.query',
  'nvmet.port.query',
  'nvmet.namespace.query',
  'nvmet.port_subsys.query',
];

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
              'allow_any_host': {'type': 'boolean'},
            },
          },
        ]
      : <Object?>[],
  'returns': [
    {'type': 'object', 'properties': <String, Object?>{}},
  ],
  'job': false,
  'filterable': !create,
  'no_auth_required': false,
  'uploadable': false,
  'downloadable': false,
  'roles': ['FULL_ADMIN'],
};

class _Fake
    implements
        SessionRepository,
        AuthenticatedAdminSession,
        AuthenticatedNvmeHostSession {
  _Fake({this.advertiseCreate = true, this.advertiseHostMappings = true}) {
    adminCatalog = AdminCatalog.fromMetadata(
      version: '25.10.1',
      metadata: {
        for (final name in _queries) name: _method(),
        'nvmet.host.query': _method(),
        if (advertiseHostMappings) 'nvmet.host_subsys.query': _method(),
        if (advertiseCreate) 'nvmet.subsys.create': _method(create: true),
      },
    );
  }

  final bool advertiseCreate;
  final bool advertiseHostMappings;
  @override
  late final AdminCatalog adminCatalog;
  final calls = <AdminRequest>[];
  final subsystems = <Map<String, Object?>>[
    {'id': 1, 'name': 'existing', 'allow_any_host': false},
  ];
  final mappings = <Map<String, Object?>>[];
  final hostMappings = <Map<String, Object?>>[];
  bool unknownCreate = false;
  bool attachAfterCreate = false;
  bool attachHostAfterCreate = false;
  int subsysReads = 0;
  int hostReads = 0;
  bool driftOnSecondRead = false;

  @override
  Future<NvmeHostPublicRows> loadNvmeHostReferences() async {
    hostReads++;
    return NvmeHostPublicRows.project(
      [
        {'id': 8, 'hostnqn': 'nqn.2026-09.example:host'},
      ],
      [for (final row in hostMappings) Map.of(row)],
    );
  }

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
      case 'nvmet.subsys.query':
        subsysReads++;
        if (driftOnSecondRead && subsysReads == 2) {
          subsystems.add({'id': 4, 'name': 'other', 'allow_any_host': false});
        }
        return AdminCompleted(
          request,
          value: [for (final row in subsystems) Map.of(row)],
        );
      case 'nvmet.port.query':
        return AdminCompleted(request, value: <Object?>[]);
      case 'nvmet.namespace.query':
        return AdminCompleted(request, value: <Object?>[]);
      case 'nvmet.port_subsys.query':
        return AdminCompleted(
          request,
          value: [for (final row in mappings) Map.of(row)],
        );
      case 'nvmet.subsys.create':
        if (unknownCreate) return AdminOutcomeUnknown(request);
        final payload = request.arguments.single as Map;
        final row = <String, Object?>{
          'id': 7,
          'name': payload['name'],
          'allow_any_host': payload['allow_any_host'],
        };
        subsystems.add(row);
        if (attachAfterCreate) {
          mappings.add({
            'id': 9,
            'port': {'id': 5},
            'subsys': {'id': 7},
          });
        }
        if (attachHostAfterCreate) {
          hostMappings.add({
            'id': 10,
            'host': {'id': 8},
            'subsys': {'id': 7},
          });
        }
        return AdminCompleted(request, value: Map.of(row));
      default:
        throw StateError('Unexpected fake call');
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Harness {
  _Harness({bool advertiseCreate = true, bool advertiseHostMappings = true})
    : api = _Fake(
        advertiseCreate: advertiseCreate,
        advertiseHostMappings: advertiseHostMappings,
      ) {
    session = AuthenticatedSession(
      profileId: 'fixture',
      repository: api,
      availableMethodNames: const {},
      endpoint: 'wss://fixture.example/api/current',
    );
    coordinator = NvmeSubsystemCreateCoordinator(
      session: session,
      api: api,
      hostsApi: api,
      lock: ServerOperationLock(),
      isCurrent: () => current,
      now: () => clock,
    );
  }

  final _Fake api;
  late final AuthenticatedSession session;
  late final NvmeSubsystemCreateCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes => api.calls
      .where((call) => call.method.name == 'nvmet.subsys.create')
      .length;
}

void main() {
  test(
    'creates only an unbound, restricted subsystem after two complete reads',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare('new');
      expect(review.confirmation, 'CREATE NVME SUBSYSTEM new');
      expect(h.writes, 0);
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, NvmeCreateOutcome.completed);
      expect(h.writes, 1);
      expect(h.api.hostReads, 3);
      expect(h.api.calls.map((call) => call.method.name), [
        ..._queries,
        ..._queries,
        'nvmet.subsys.create',
        ..._queries,
      ]);
      expect(h.api.calls[8].arguments, [
        {'name': 'new', 'allow_any_host': false},
      ]);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmeCreateOutcome.rejected,
      );
    },
  );

  test(
    'missing create method, duplicate and unresolved references block review',
    () async {
      final missing = _Harness(advertiseCreate: false);
      expect(missing.coordinator.available, false);
      await expectLater(missing.coordinator.prepare('new'), throwsStateError);
      final noHostInventory = _Harness(advertiseHostMappings: false);
      expect(noHostInventory.coordinator.available, false);
      await expectLater(
        noHostInventory.coordinator.prepare('new'),
        throwsStateError,
      );
      final h = _Harness();
      await expectLater(h.coordinator.prepare('EXISTING'), throwsStateError);
      h.api.mappings.add({
        'id': 9,
        'port': {'id': 77},
        'subsys': {'id': 1},
      });
      await expectLater(h.coordinator.prepare('new'), throwsStateError);
      expect(h.writes, 0);
    },
  );

  test('wrong phrase, expiry, endpoint loss and drift never submit', () async {
    final h = _Harness();
    final first = await h.coordinator.prepare('new');
    expect(
      (await h.coordinator.execute(first, 'wrong')).outcome,
      NvmeCreateOutcome.rejected,
    );
    final second = await h.coordinator.prepare('new');
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(second, second.confirmation)).outcome,
      NvmeCreateOutcome.rejected,
    );
    final third = await h.coordinator.prepare('new');
    h.current = false;
    expect(
      (await h.coordinator.execute(third, third.confirmation)).outcome,
      NvmeCreateOutcome.rejected,
    );
    h.current = true;
    h.api.driftOnSecondRead = false;
    final fourth = await h.coordinator.prepare('new');
    h.api.subsystems.add({'id': 4, 'name': 'other', 'allow_any_host': false});
    expect(
      (await h.coordinator.execute(fourth, fourth.confirmation)).outcome,
      NvmeCreateOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test(
    'host association change after review blocks the create request',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare('new');
      h.api.hostMappings.add({
        'id': 11,
        'host': {'id': 8},
        'subsys': {'id': 1},
      });
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmeCreateOutcome.rejected,
      );
      expect(h.writes, 0);
    },
  );

  test(
    'ambiguous result or postwrite association fences the connection',
    () async {
      final h = _Harness();
      h.api.unknownCreate = true;
      final review = await h.coordinator.prepare('new');
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmeCreateOutcome.unknown,
      );
      expect(h.coordinator.locked, true);
      await expectLater(h.coordinator.prepare('another'), throwsStateError);
      expect(h.writes, 1);

      final other = _Harness();
      other.api.attachAfterCreate = true;
      final otherReview = await other.coordinator.prepare('new');
      expect(
        (await other.coordinator.execute(
          otherReview,
          otherReview.confirmation,
        )).outcome,
        NvmeCreateOutcome.unknown,
      );
      expect(other.coordinator.locked, true);

      final linked = _Harness();
      linked.api.attachHostAfterCreate = true;
      final linkedReview = await linked.coordinator.prepare('new');
      expect(
        (await linked.coordinator.execute(
          linkedReview,
          linkedReview.confirmation,
        )).outcome,
        NvmeCreateOutcome.unknown,
      );
      expect(linked.coordinator.locked, true);
    },
  );

  testWidgets(
    'editor requires exact confirmation and submits only fake request',
    (tester) async {
      final h = _Harness();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dashboardActiveSessionProvider.overrideWith((ref) => h.session),
          ],
          child: MaterialApp(
            theme: TrueNavoTheme.dark(),
            home: const Scaffold(
              body: SingleChildScrollView(child: NvmeSubsystemCreateEditor()),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('nvme-subsystem-create-name')),
        'new',
      );
      await tester.tap(find.byKey(const Key('nvme-subsystem-create-review')));
      await tester.pumpAndSettle();
      expect(h.writes, 0);
      expect(find.text('New subsystem: new'), findsOneWidget);
      await tester.enterText(
        find.byKey(const Key('nvme-subsystem-create-confirmation')),
        'CREATE NVME SUBSYSTEM new',
      );
      await tester.tap(find.byKey(const Key('nvme-subsystem-create-submit')));
      await tester.pumpAndSettle();
      expect(h.writes, 1);
      expect(h.api.subsystems.last['name'], 'new');
    },
  );
}
