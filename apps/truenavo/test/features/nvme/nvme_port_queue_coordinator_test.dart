import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nvme/nvme_port_queue_coordinator.dart';
import 'package:truenavo/features/nvme/nvme_port_queue_editor.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _queries = [
  'nvmet.subsys.query',
  'nvmet.port.query',
  'nvmet.namespace.query',
  'nvmet.port_subsys.query',
];

Map<String, Object?> _method() => {
  'accepts': <Object?>[],
  'returns': [
    {'type': 'object'},
  ],
  'job': false,
  'filterable': false,
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
  _Fake() {
    adminCatalog = AdminCatalog.fromMetadata(
      version: '25.10.1',
      metadata: {
        for (final name in _queries) name: _method(),
        'nvmet.host.query': _method(),
        'nvmet.host_subsys.query': _method(),
        'nvmet.port.update': _method(),
      },
    );
  }

  @override
  late final AdminCatalog adminCatalog;
  final calls = <AdminRequest>[];
  final port = <String, Object?>{
    'id': 3,
    'addr_trtype': 'TCP',
    'enabled': false,
    'pi_enable': null,
    'max_queue_size': 16,
    'inline_data_size': 4096,
  };
  final subsystem = <String, Object?>{
    'id': 2,
    'name': 'unused',
    'subnqn': 'nqn.2026-09.example:unused',
    'allow_any_host': false,
  };
  final mappings = <Map<String, Object?>>[];
  bool ambiguous = false;
  bool driftAfterWrite = false;

  @override
  Future<NvmeHostPublicRows> loadNvmeHostReferences() async =>
      NvmeHostPublicRows.project(<Object?>[], <Object?>[]);

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
      case 'nvmet.subsys.query':
        return AdminCompleted(request, value: [Map.of(subsystem)]);
      case 'nvmet.namespace.query':
        return AdminCompleted(request, value: <Object?>[]);
      case 'nvmet.port.query':
        return AdminCompleted(request, value: [Map.of(port)]);
      case 'nvmet.port_subsys.query':
        return AdminCompleted(
          request,
          value: [for (final row in mappings) Map.of(row)],
        );
      case 'nvmet.port.update':
        if (ambiguous) return AdminOutcomeUnknown(request);
        final payload = request.arguments[1] as Map;
        port['max_queue_size'] = payload['max_queue_size'];
        final returned = Map.of(port);
        if (driftAfterWrite) port['pi_enable'] = true;
        return AdminCompleted(request, value: returned);
      default:
        throw StateError('Unexpected method');
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
    coordinator = NvmePortQueueCoordinator(
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
  late final NvmePortQueueCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes =>
      api.calls.where((c) => c.method.name == 'nvmet.port.update').length;
}

void main() {
  test('invalid sizes are rejected before inventory reads', () async {
    final h = _Harness();
    for (final size in [0, -1, 2147483648]) {
      await expectLater(
        h.coordinator.prepare(3, NvmePortQueueChoice(size)),
        throwsStateError,
      );
    }
    expect(h.api.calls, isEmpty);
  });

  test(
    'explicit size and server default send only their queue value',
    () async {
      for (final choice in [
        const NvmePortQueueChoice(64),
        const NvmePortQueueChoice(null),
      ]) {
        final h = _Harness();
        h.api.port['max_queue_size'] = 32;
        final review = await h.coordinator.prepare(3, choice);
        expect(
          (await h.coordinator.execute(review, review.confirmation)).outcome,
          NvmePortQueueOutcome.completed,
        );
        expect(
          h.api.calls
              .where((c) => c.method.name == 'nvmet.port.update')
              .single
              .arguments,
          [
            3,
            {'max_queue_size': choice.wireValue},
          ],
        );
      }
    },
  );

  test(
    'missing queue size and unchanged value reject review without writes',
    () async {
      final missing = _Harness();
      missing.api.port.remove('max_queue_size');
      await expectLater(
        missing.coordinator.prepare(3, const NvmePortQueueChoice(32)),
        throwsStateError,
      );
      final same = _Harness();
      await expectLater(
        same.coordinator.prepare(3, const NvmePortQueueChoice(16)),
        throwsStateError,
      );
      expect(missing.writes + same.writes, 0);
    },
  );

  test(
    'port-only queue size edit sends one-field patch and verifies readback',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(
        3,
        const NvmePortQueueChoice(32),
      );
      expect(review.confirmation, 'SET NVME PORT QUEUE 3 TCP 32');
      expect(h.writes, 0);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmePortQueueOutcome.completed,
      );
      expect(h.writes, 1);
      expect(
        h.api.calls
            .where((c) => c.method.name == 'nvmet.port.update')
            .single
            .arguments,
        [
          3,
          {'max_queue_size': 32},
        ],
      );
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmePortQueueOutcome.rejected,
      );
    },
  );

  test('enabled, associated and absent ports cannot be reviewed', () async {
    final enabled = _Harness();
    enabled.api.port['enabled'] = true;
    await expectLater(
      enabled.coordinator.prepare(3, const NvmePortQueueChoice(32)),
      throwsStateError,
    );
    final associated = _Harness();
    associated.api.mappings.add({
      'id': 8,
      'port': {'id': 3},
      'subsys': {'id': 2},
    });
    await expectLater(
      associated.coordinator.prepare(3, const NvmePortQueueChoice(32)),
      throwsStateError,
    );
    final absent = _Harness();
    await expectLater(
      absent.coordinator.prepare(2, const NvmePortQueueChoice(32)),
      throwsStateError,
    );
    await expectLater(
      absent.coordinator.prepare(4, const NvmePortQueueChoice(32)),
      throwsStateError,
    );
    expect(enabled.writes + associated.writes + absent.writes, 0);
  });

  test('wrong phrase, expiry and topology drift send nothing', () async {
    final h = _Harness();
    final wrong = await h.coordinator.prepare(3, const NvmePortQueueChoice(32));
    expect(
      (await h.coordinator.execute(wrong, 'wrong')).outcome,
      NvmePortQueueOutcome.rejected,
    );
    final expired = await h.coordinator.prepare(
      3,
      const NvmePortQueueChoice(32),
    );
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(expired, expired.confirmation)).outcome,
      NvmePortQueueOutcome.rejected,
    );
    final drift = await h.coordinator.prepare(3, const NvmePortQueueChoice(32));
    h.api.port['addr_trtype'] = 'RDMA';
    expect(
      (await h.coordinator.execute(drift, drift.confirmation)).outcome,
      NvmePortQueueOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test('ambiguous response and readback drift fence further edits', () async {
    final unknown = _Harness();
    unknown.api.ambiguous = true;
    final review = await unknown.coordinator.prepare(
      3,
      const NvmePortQueueChoice(32),
    );
    expect(
      (await unknown.coordinator.execute(review, review.confirmation)).outcome,
      NvmePortQueueOutcome.unknown,
    );
    expect(unknown.coordinator.locked, true);
    final drift = _Harness();
    drift.api.driftAfterWrite = true;
    final next = await drift.coordinator.prepare(
      3,
      const NvmePortQueueChoice(32),
    );
    expect(
      (await drift.coordinator.execute(next, next.confirmation)).outcome,
      NvmePortQueueOutcome.unknown,
    );
    expect(drift.coordinator.locked, true);
  });

  testWidgets('editor requires review and exact phrase before fake write', (
    tester,
  ) async {
    final h = _Harness();
    h.api.port['max_queue_size'] = 32;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
          nvmePortQueueCoordinatorProvider.overrideWith((ref) => h.coordinator),
        ],
        child: MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: NvmePortQueueEditor()),
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('nvme-port-queue-id')), '3');
    await tester.tap(find.byKey(const Key('nvme-port-queue-default')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('nvme-port-queue-limit')), '0');
    await tester.tap(find.byKey(const Key('nvme-port-queue-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    expect(
      find.textContaining('queue size from 1 to 2147483647'),
      findsOneWidget,
    );
    await tester.enterText(
      find.byKey(const Key('nvme-port-queue-limit')),
      '64',
    );
    await tester.tap(find.byKey(const Key('nvme-port-queue-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    expect(find.text('Disabled port #3: TCP'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('nvme-port-queue-confirmation')),
      'SET NVME PORT QUEUE 3 TCP 64',
    );
    await tester.ensureVisible(find.byKey(const Key('nvme-port-queue-submit')));
    await tester.tap(find.byKey(const Key('nvme-port-queue-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
    expect(tester.takeException(), isNull);
  });
}
