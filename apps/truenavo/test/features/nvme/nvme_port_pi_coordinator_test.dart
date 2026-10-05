import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nvme/nvme_port_pi_coordinator.dart';
import 'package:truenavo/features/nvme/nvme_port_pi_editor.dart';
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
        port['pi_enable'] = payload['pi_enable'];
        final returned = Map.of(port);
        if (driftAfterWrite) port['max_queue_size'] = 128;
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
    coordinator = NvmePortPiCoordinator(
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
  late final NvmePortPiCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes =>
      api.calls.where((c) => c.method.name == 'nvmet.port.update').length;
}

void main() {
  test(
    'off and server default each send only their explicit PI value',
    () async {
      for (final choice in [
        NvmePortPiChoice.off,
        NvmePortPiChoice.serverDefault,
      ]) {
        final h = _Harness();
        h.api.port['pi_enable'] = true;
        final review = await h.coordinator.prepare(3, choice);
        expect(
          (await h.coordinator.execute(review, review.confirmation)).outcome,
          NvmePortPiOutcome.completed,
        );
        expect(
          h.api.calls
              .where((c) => c.method.name == 'nvmet.port.update')
              .single
              .arguments,
          [
            3,
            {'pi_enable': choice == NvmePortPiChoice.off ? false : null},
          ],
        );
      }
    },
  );

  test('missing PI and unchanged value reject review without writes', () async {
    final missing = _Harness();
    missing.api.port.remove('pi_enable');
    await expectLater(
      missing.coordinator.prepare(3, NvmePortPiChoice.on),
      throwsStateError,
    );
    final same = _Harness();
    await expectLater(
      same.coordinator.prepare(3, NvmePortPiChoice.serverDefault),
      throwsStateError,
    );
    expect(missing.writes + same.writes, 0);
  });

  test(
    'port-only PI edit sends one-field patch and verifies readback',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(3, NvmePortPiChoice.on);
      expect(review.confirmation, 'SET NVME PORT PI 3 TCP ON');
      expect(h.writes, 0);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmePortPiOutcome.completed,
      );
      expect(h.writes, 1);
      expect(
        h.api.calls
            .where((c) => c.method.name == 'nvmet.port.update')
            .single
            .arguments,
        [
          3,
          {'pi_enable': true},
        ],
      );
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmePortPiOutcome.rejected,
      );
    },
  );

  test('enabled, associated and absent ports cannot be reviewed', () async {
    final enabled = _Harness();
    enabled.api.port['enabled'] = true;
    await expectLater(
      enabled.coordinator.prepare(3, NvmePortPiChoice.on),
      throwsStateError,
    );
    final associated = _Harness();
    associated.api.mappings.add({
      'id': 8,
      'port': {'id': 3},
      'subsys': {'id': 2},
    });
    await expectLater(
      associated.coordinator.prepare(3, NvmePortPiChoice.on),
      throwsStateError,
    );
    final absent = _Harness();
    await expectLater(
      absent.coordinator.prepare(2, NvmePortPiChoice.on),
      throwsStateError,
    );
    await expectLater(
      absent.coordinator.prepare(4, NvmePortPiChoice.on),
      throwsStateError,
    );
    expect(enabled.writes + associated.writes + absent.writes, 0);
  });

  test('wrong phrase, expiry and topology drift send nothing', () async {
    final h = _Harness();
    final wrong = await h.coordinator.prepare(3, NvmePortPiChoice.on);
    expect(
      (await h.coordinator.execute(wrong, 'wrong')).outcome,
      NvmePortPiOutcome.rejected,
    );
    final expired = await h.coordinator.prepare(3, NvmePortPiChoice.on);
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(expired, expired.confirmation)).outcome,
      NvmePortPiOutcome.rejected,
    );
    final drift = await h.coordinator.prepare(3, NvmePortPiChoice.on);
    h.api.port['addr_trtype'] = 'RDMA';
    expect(
      (await h.coordinator.execute(drift, drift.confirmation)).outcome,
      NvmePortPiOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test('ambiguous response and readback drift fence further edits', () async {
    final unknown = _Harness();
    unknown.api.ambiguous = true;
    final review = await unknown.coordinator.prepare(3, NvmePortPiChoice.on);
    expect(
      (await unknown.coordinator.execute(review, review.confirmation)).outcome,
      NvmePortPiOutcome.unknown,
    );
    expect(unknown.coordinator.locked, true);
    final drift = _Harness();
    drift.api.driftAfterWrite = true;
    final next = await drift.coordinator.prepare(3, NvmePortPiChoice.on);
    expect(
      (await drift.coordinator.execute(next, next.confirmation)).outcome,
      NvmePortPiOutcome.unknown,
    );
    expect(drift.coordinator.locked, true);
  });

  testWidgets('editor requires review and exact phrase before fake write', (
    tester,
  ) async {
    final h = _Harness();
    h.api.port['pi_enable'] = true;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
          nvmePortPiCoordinatorProvider.overrideWith((ref) => h.coordinator),
        ],
        child: MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: NvmePortPiEditor()),
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('nvme-port-pi-id')), '3');
    await tester.tap(find.byKey(const Key('nvme-port-pi-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    expect(find.text('Disabled port #3: TCP'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('nvme-port-pi-confirmation')),
      'SET NVME PORT PI 3 TCP DEFAULT',
    );
    await tester.ensureVisible(find.byKey(const Key('nvme-port-pi-submit')));
    await tester.tap(find.byKey(const Key('nvme-port-pi-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
    expect(tester.takeException(), isNull);
  });
}
