import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nvme/nvme_subsystem_qid_coordinator.dart';
import 'package:truenavo/features/nvme/nvme_subsystem_qid_editor.dart';
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
        'nvmet.subsys.update': _method(),
      },
    );
  }

  @override
  late final AdminCatalog adminCatalog;
  final calls = <AdminRequest>[];
  final subsystem = <String, Object?>{
    'id': 1,
    'name': 'empty',
    'subnqn': 'nqn.2026-09.example:empty',
    'allow_any_host': false,
    'ana': null,
    'qid_max': null,
    'pi_enable': null,
  };
  final hostMappings = <Map<String, Object?>>[];
  final portMappings = <Map<String, Object?>>[];
  bool ambiguous = false;
  bool driftAfterWrite = false;

  @override
  Future<NvmeHostPublicRows> loadNvmeHostReferences() async =>
      NvmeHostPublicRows.project(
        [
          {'id': 8, 'hostnqn': 'nqn.2026-09.example:host'},
        ],
        [for (final row in hostMappings) Map.of(row)],
      );

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    switch (request.method.name) {
      case 'nvmet.subsys.query':
        return AdminCompleted(request, value: [Map.of(subsystem)]);
      case 'nvmet.port.query':
      case 'nvmet.namespace.query':
        return AdminCompleted(request, value: <Object?>[]);
      case 'nvmet.port_subsys.query':
        return AdminCompleted(
          request,
          value: [for (final row in portMappings) Map.of(row)],
        );
      case 'nvmet.subsys.update':
        if (ambiguous) return AdminOutcomeUnknown(request);
        final payload = request.arguments[1] as Map;
        subsystem['qid_max'] = payload['qid_max'];
        final returned = Map.of(subsystem);
        if (driftAfterWrite) subsystem['pi_enable'] = true;
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
    coordinator = NvmeSubsystemQidCoordinator(
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
  late final NvmeSubsystemQidCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes =>
      api.calls.where((c) => c.method.name == 'nvmet.subsys.update').length;
}

void main() {
  test(
    'default to 32 sends only qid_max after exact review and readback',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(1, const NvmeQidChoice(32));
      expect(review.oldLabel, 'server default');
      expect(review.newLabel, '32');
      expect(review.confirmation, 'SET NVME QID 1 empty 32');
      expect(h.writes, 0);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmeQidOutcome.completed,
      );
      expect(h.writes, 1);
      expect(
        h.api.calls
            .where((c) => c.method.name == 'nvmet.subsys.update')
            .single
            .arguments,
        [
          1,
          {'qid_max': 32},
        ],
      );
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmeQidOutcome.rejected,
      );
      expect(h.writes, 1);
    },
  );

  test('16 to server default sends explicit null', () async {
    final h = _Harness();
    h.api.subsystem['qid_max'] = 16;
    final review = await h.coordinator.prepare(1, const NvmeQidChoice(null));
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      NvmeQidOutcome.completed,
    );
    expect(
      h.api.calls
          .where((c) => c.method.name == 'nvmet.subsys.update')
          .single
          .arguments,
      [
        1,
        {'qid_max': null},
      ],
    );
  });

  test('missing QID, any-host or associations prevent review', () async {
    final missing = _Harness();
    missing.api.subsystem.remove('qid_max');
    await expectLater(
      missing.coordinator.prepare(1, const NvmeQidChoice(32)),
      throwsStateError,
    );
    final anyHost = _Harness();
    anyHost.api.subsystem['allow_any_host'] = true;
    await expectLater(
      anyHost.coordinator.prepare(1, const NvmeQidChoice(32)),
      throwsStateError,
    );
    final host = _Harness();
    host.api.hostMappings.add({
      'id': 9,
      'host': {'id': 8},
      'subsys': {'id': 1},
    });
    await expectLater(
      host.coordinator.prepare(1, const NvmeQidChoice(32)),
      throwsStateError,
    );
    final port = _Harness();
    port.api.portMappings.add({
      'id': 11,
      'port': {'id': 3},
      'subsys': {'id': 1},
    });
    await expectLater(
      port.coordinator.prepare(1, const NvmeQidChoice(32)),
      throwsStateError,
    );
    final nqn = _Harness();
    nqn.api.subsystem.remove('subnqn');
    await expectLater(
      nqn.coordinator.prepare(1, const NvmeQidChoice(32)),
      throwsStateError,
    );
    final same = _Harness();
    await expectLater(
      same.coordinator.prepare(1, const NvmeQidChoice(null)),
      throwsStateError,
    );
    expect(
      missing.writes +
          anyHost.writes +
          host.writes +
          port.writes +
          nqn.writes +
          same.writes,
      0,
    );
  });

  test(
    'nonpositive and oversized limits are rejected before any read',
    () async {
      final h = _Harness();
      await expectLater(
        h.coordinator.prepare(1, const NvmeQidChoice(0)),
        throwsStateError,
      );
      await expectLater(
        h.coordinator.prepare(1, const NvmeQidChoice(-1)),
        throwsStateError,
      );
      await expectLater(
        h.coordinator.prepare(1, const NvmeQidChoice(2147483648)),
        throwsStateError,
      );
      expect(h.api.calls, isEmpty);
    },
  );

  test('wrong, expired and stale reviews send nothing', () async {
    final h = _Harness();
    final wrong = await h.coordinator.prepare(1, const NvmeQidChoice(32));
    expect(
      (await h.coordinator.execute(wrong, 'wrong')).outcome,
      NvmeQidOutcome.rejected,
    );
    final expired = await h.coordinator.prepare(1, const NvmeQidChoice(32));
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(expired, expired.confirmation)).outcome,
      NvmeQidOutcome.rejected,
    );
    final drift = await h.coordinator.prepare(1, const NvmeQidChoice(32));
    h.api.subsystem['ana'] = true;
    expect(
      (await h.coordinator.execute(drift, drift.confirmation)).outcome,
      NvmeQidOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test('ambiguous result or unrelated readback drift fences edits', () async {
    final unknown = _Harness();
    unknown.api.ambiguous = true;
    final review = await unknown.coordinator.prepare(
      1,
      const NvmeQidChoice(32),
    );
    expect(
      (await unknown.coordinator.execute(review, review.confirmation)).outcome,
      NvmeQidOutcome.unknown,
    );
    expect(unknown.coordinator.locked, true);
    final drift = _Harness();
    drift.api.driftAfterWrite = true;
    final next = await drift.coordinator.prepare(1, const NvmeQidChoice(32));
    expect(
      (await drift.coordinator.execute(next, next.confirmation)).outcome,
      NvmeQidOutcome.unknown,
    );
    expect(drift.coordinator.locked, true);
  });

  testWidgets('editor requires review and exact phrase before fake write', (
    tester,
  ) async {
    final h = _Harness();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
          nvmeSubsystemQidCoordinatorProvider.overrideWith(
            (ref) => h.coordinator,
          ),
        ],
        child: MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: NvmeSubsystemQidEditor()),
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('nvme-subsystem-qid-id')), '1');
    await tester.tap(find.byKey(const Key('nvme-subsystem-qid-default')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('nvme-subsystem-qid-limit')),
      '0',
    );
    await tester.tap(find.byKey(const Key('nvme-subsystem-qid-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    expect(find.textContaining('limit from 1 to 2147483647'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('nvme-subsystem-qid-limit')),
      '32',
    );
    await tester.tap(find.byKey(const Key('nvme-subsystem-qid-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    expect(find.text('Maximum queue IDs: server default → 32'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('nvme-subsystem-qid-confirmation')),
      'SET NVME QID 1 empty 32',
    );
    await tester.ensureVisible(
      find.byKey(const Key('nvme-subsystem-qid-submit')),
    );
    await tester.tap(find.byKey(const Key('nvme-subsystem-qid-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
    expect(tester.takeException(), isNull);
  });
}
