import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nvme/nvme_subsystem_pi_coordinator.dart';
import 'package:truenavo/features/nvme/nvme_subsystem_pi_editor.dart';
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
    'pi_enable': null,
    'qid_max': 16,
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
        subsystem['pi_enable'] = payload['pi_enable'];
        final returned = Map.of(subsystem);
        if (driftAfterWrite) subsystem['qid_max'] = 32;
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
    coordinator = NvmeSubsystemPiCoordinator(
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
  late final NvmeSubsystemPiCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes =>
      api.calls.where((c) => c.method.name == 'nvmet.subsys.update').length;
}

void main() {
  test('default to on sends only PI after exact review and readback', () async {
    final h = _Harness();
    final review = await h.coordinator.prepare(1, NvmePiChoice.on);
    expect(review.oldLabel, 'server default');
    expect(review.newLabel, 'on');
    expect(review.confirmation, 'SET NVME PI 1 empty ON');
    expect(h.writes, 0);
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      NvmePiOutcome.completed,
    );
    expect(h.writes, 1);
    expect(
      h.api.calls
          .where((c) => c.method.name == 'nvmet.subsys.update')
          .single
          .arguments,
      [
        1,
        {'pi_enable': true},
      ],
    );
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      NvmePiOutcome.rejected,
    );
    expect(h.writes, 1);
  });

  test('off to server default sends explicit null', () async {
    final h = _Harness();
    h.api.subsystem['pi_enable'] = false;
    final review = await h.coordinator.prepare(1, NvmePiChoice.serverDefault);
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      NvmePiOutcome.completed,
    );
    expect(
      h.api.calls
          .where((c) => c.method.name == 'nvmet.subsys.update')
          .single
          .arguments,
      [
        1,
        {'pi_enable': null},
      ],
    );
  });

  test('missing PI, any-host or associations prevent review', () async {
    final missing = _Harness();
    missing.api.subsystem.remove('pi_enable');
    await expectLater(
      missing.coordinator.prepare(1, NvmePiChoice.on),
      throwsStateError,
    );
    final anyHost = _Harness();
    anyHost.api.subsystem['allow_any_host'] = true;
    await expectLater(
      anyHost.coordinator.prepare(1, NvmePiChoice.on),
      throwsStateError,
    );
    final host = _Harness();
    host.api.hostMappings.add({
      'id': 9,
      'host': {'id': 8},
      'subsys': {'id': 1},
    });
    await expectLater(
      host.coordinator.prepare(1, NvmePiChoice.on),
      throwsStateError,
    );
    final port = _Harness();
    port.api.portMappings.add({
      'id': 11,
      'port': {'id': 3},
      'subsys': {'id': 1},
    });
    await expectLater(
      port.coordinator.prepare(1, NvmePiChoice.on),
      throwsStateError,
    );
    final nqn = _Harness();
    nqn.api.subsystem.remove('subnqn');
    await expectLater(
      nqn.coordinator.prepare(1, NvmePiChoice.on),
      throwsStateError,
    );
    final same = _Harness();
    await expectLater(
      same.coordinator.prepare(1, NvmePiChoice.serverDefault),
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

  test('wrong, expired and stale reviews send nothing', () async {
    final h = _Harness();
    final wrong = await h.coordinator.prepare(1, NvmePiChoice.on);
    expect(
      (await h.coordinator.execute(wrong, 'wrong')).outcome,
      NvmePiOutcome.rejected,
    );
    final expired = await h.coordinator.prepare(1, NvmePiChoice.on);
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(expired, expired.confirmation)).outcome,
      NvmePiOutcome.rejected,
    );
    final drift = await h.coordinator.prepare(1, NvmePiChoice.on);
    h.api.subsystem['ana'] = true;
    expect(
      (await h.coordinator.execute(drift, drift.confirmation)).outcome,
      NvmePiOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test('ambiguous result or unrelated readback drift fences edits', () async {
    final unknown = _Harness();
    unknown.api.ambiguous = true;
    final review = await unknown.coordinator.prepare(1, NvmePiChoice.on);
    expect(
      (await unknown.coordinator.execute(review, review.confirmation)).outcome,
      NvmePiOutcome.unknown,
    );
    expect(unknown.coordinator.locked, true);
    final drift = _Harness();
    drift.api.driftAfterWrite = true;
    final next = await drift.coordinator.prepare(1, NvmePiChoice.on);
    expect(
      (await drift.coordinator.execute(next, next.confirmation)).outcome,
      NvmePiOutcome.unknown,
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
          nvmeSubsystemPiCoordinatorProvider.overrideWith(
            (ref) => h.coordinator,
          ),
        ],
        child: MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: NvmeSubsystemPiEditor()),
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('nvme-subsystem-pi-id')), '1');
    await tester.tap(find.byKey(const Key('nvme-subsystem-pi-choice')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('On').last);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('nvme-subsystem-pi-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    expect(find.text('PI: server default → on'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('nvme-subsystem-pi-confirmation')),
      'SET NVME PI 1 empty ON',
    );
    await tester.ensureVisible(
      find.byKey(const Key('nvme-subsystem-pi-submit')),
    );
    await tester.tap(find.byKey(const Key('nvme-subsystem-pi-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
    expect(tester.takeException(), isNull);
  });
}
