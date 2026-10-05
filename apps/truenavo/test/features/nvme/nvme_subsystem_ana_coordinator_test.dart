import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nvme/nvme_subsystem_ana_coordinator.dart';
import 'package:truenavo/features/nvme/nvme_subsystem_ana_editor.dart';
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
        subsystem['ana'] = payload['ana'];
        final returned = Map.of(subsystem);
        if (driftAfterWrite) subsystem['name'] = 'unexpected';
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
    coordinator = NvmeSubsystemAnaCoordinator(
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
  late final NvmeSubsystemAnaCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes =>
      api.calls.where((c) => c.method.name == 'nvmet.subsys.update').length;
}

void main() {
  test(
    'inherit to on submits only ANA after exact review and readback',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(1, NvmeAnaChoice.on);
      expect(review.oldLabel, 'inherit');
      expect(review.newLabel, 'on');
      expect(h.writes, 0);
      final result = await h.coordinator.execute(review, review.confirmation);
      expect(result.outcome, NvmeAnaOutcome.completed);
      expect(h.writes, 1);
      expect(
        h.api.calls
            .where((c) => c.method.name == 'nvmet.subsys.update')
            .single
            .arguments,
        [
          1,
          {'ana': true},
        ],
      );
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmeAnaOutcome.rejected,
      );
    },
  );

  test('off to inherit sends an explicit null override', () async {
    final h = _Harness();
    h.api.subsystem['ana'] = false;
    final review = await h.coordinator.prepare(1, NvmeAnaChoice.inherit);
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      NvmeAnaOutcome.completed,
    );
    expect(
      h.api.calls
          .where((c) => c.method.name == 'nvmet.subsys.update')
          .single
          .arguments,
      [
        1,
        {'ana': null},
      ],
    );
  });

  test('unsafe or unknown target cannot be reviewed', () async {
    final missing = _Harness();
    missing.api.subsystem.remove('ana');
    await expectLater(
      missing.coordinator.prepare(1, NvmeAnaChoice.on),
      throwsStateError,
    );
    final anyHost = _Harness();
    anyHost.api.subsystem['allow_any_host'] = true;
    await expectLater(
      anyHost.coordinator.prepare(1, NvmeAnaChoice.on),
      throwsStateError,
    );
    final host = _Harness();
    host.api.hostMappings.add({
      'id': 9,
      'host': {'id': 8},
      'subsys': {'id': 1},
    });
    await expectLater(
      host.coordinator.prepare(1, NvmeAnaChoice.on),
      throwsStateError,
    );
    final port = _Harness();
    port.api.portMappings.add({
      'id': 11,
      'port': {'id': 3},
      'subsys': {'id': 1},
    });
    await expectLater(
      port.coordinator.prepare(1, NvmeAnaChoice.on),
      throwsStateError,
    );
    final nqn = _Harness();
    nqn.api.subsystem.remove('subnqn');
    await expectLater(
      nqn.coordinator.prepare(1, NvmeAnaChoice.on),
      throwsStateError,
    );
    final same = _Harness();
    await expectLater(
      same.coordinator.prepare(1, NvmeAnaChoice.inherit),
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

  test('stale review or changed config sends nothing', () async {
    final h = _Harness();
    final wrong = await h.coordinator.prepare(1, NvmeAnaChoice.on);
    expect(
      (await h.coordinator.execute(wrong, 'wrong')).outcome,
      NvmeAnaOutcome.rejected,
    );
    final expired = await h.coordinator.prepare(1, NvmeAnaChoice.on);
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(expired, expired.confirmation)).outcome,
      NvmeAnaOutcome.rejected,
    );
    final drift = await h.coordinator.prepare(1, NvmeAnaChoice.on);
    h.api.subsystem['ana'] = false;
    expect(
      (await h.coordinator.execute(drift, drift.confirmation)).outcome,
      NvmeAnaOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test(
    'ambiguous outcome and divergent readback fence further edits',
    () async {
      final unknown = _Harness();
      unknown.api.ambiguous = true;
      final review = await unknown.coordinator.prepare(1, NvmeAnaChoice.on);
      expect(
        (await unknown.coordinator.execute(
          review,
          review.confirmation,
        )).outcome,
        NvmeAnaOutcome.unknown,
      );
      expect(unknown.coordinator.locked, true);
      final drift = _Harness();
      drift.api.driftAfterWrite = true;
      final next = await drift.coordinator.prepare(1, NvmeAnaChoice.on);
      expect(
        (await drift.coordinator.execute(next, next.confirmation)).outcome,
        NvmeAnaOutcome.unknown,
      );
      expect(drift.coordinator.locked, true);
    },
  );

  testWidgets('editor requires review and exact phrase before fake write', (
    tester,
  ) async {
    final h = _Harness();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
          nvmeSubsystemAnaCoordinatorProvider.overrideWith(
            (ref) => h.coordinator,
          ),
        ],
        child: MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: NvmeSubsystemAnaEditor()),
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('nvme-subsystem-ana-id')), '1');
    await tester.tap(find.byKey(const Key('nvme-subsystem-ana-choice')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Override: on').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nvme-subsystem-ana-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    expect(find.text('ANA: inherit → on'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('nvme-subsystem-ana-confirmation')),
      'SET NVME ANA 1 empty ON',
    );
    await tester.ensureVisible(
      find.byKey(const Key('nvme-subsystem-ana-submit')),
    );
    await tester.tap(find.byKey(const Key('nvme-subsystem-ana-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
    expect(tester.takeException(), isNull);
  });
}
