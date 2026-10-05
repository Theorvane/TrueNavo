import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nvme/nvme_port_disable_coordinator.dart';
import 'package:truenavo/features/nvme/nvme_port_disable_editor.dart';
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
    'enabled': true,
    'pi_enable': null,
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
        port['enabled'] = payload['enabled'];
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
    coordinator = NvmePortDisableCoordinator(
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
  late final NvmePortDisableCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes =>
      api.calls.where((c) => c.method.name == 'nvmet.port.update').length;
}

void main() {
  test(
    'disables only an enabled unassociated port with one-field patch',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(3);
      expect(review.confirmation, 'DISABLE NVME PORT 3 TCP');
      expect(h.writes, 0);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmePortDisableOutcome.completed,
      );
      expect(h.writes, 1);
      expect(
        h.api.calls
            .where((c) => c.method.name == 'nvmet.port.update')
            .single
            .arguments,
        [
          3,
          {'enabled': false},
        ],
      );
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmePortDisableOutcome.rejected,
      );
    },
  );

  test('disabled, associated and absent ports cannot be reviewed', () async {
    final disabled = _Harness();
    disabled.api.port['enabled'] = false;
    await expectLater(disabled.coordinator.prepare(3), throwsStateError);
    final associated = _Harness();
    associated.api.mappings.add({
      'id': 8,
      'port': {'id': 3},
      'subsys': {'id': 2},
    });
    await expectLater(associated.coordinator.prepare(3), throwsStateError);
    final absent = _Harness();
    await expectLater(absent.coordinator.prepare(4), throwsStateError);
    expect(disabled.writes + associated.writes + absent.writes, 0);
  });

  test('wrong phrase, expiry and topology drift send nothing', () async {
    final h = _Harness();
    final wrong = await h.coordinator.prepare(3);
    expect(
      (await h.coordinator.execute(wrong, 'wrong')).outcome,
      NvmePortDisableOutcome.rejected,
    );
    final expired = await h.coordinator.prepare(3);
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(expired, expired.confirmation)).outcome,
      NvmePortDisableOutcome.rejected,
    );
    final drift = await h.coordinator.prepare(3);
    h.api.port['addr_trtype'] = 'RDMA';
    expect(
      (await h.coordinator.execute(drift, drift.confirmation)).outcome,
      NvmePortDisableOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test('ambiguous response and readback drift fence further edits', () async {
    final unknown = _Harness();
    unknown.api.ambiguous = true;
    final review = await unknown.coordinator.prepare(3);
    expect(
      (await unknown.coordinator.execute(review, review.confirmation)).outcome,
      NvmePortDisableOutcome.unknown,
    );
    expect(unknown.coordinator.locked, true);
    final drift = _Harness();
    drift.api.driftAfterWrite = true;
    final next = await drift.coordinator.prepare(3);
    expect(
      (await drift.coordinator.execute(next, next.confirmation)).outcome,
      NvmePortDisableOutcome.unknown,
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
          nvmePortDisableCoordinatorProvider.overrideWith(
            (ref) => h.coordinator,
          ),
        ],
        child: MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: NvmePortDisableEditor()),
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('nvme-port-disable-id')), '3');
    await tester.tap(find.byKey(const Key('nvme-port-disable-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    expect(find.text('Enabled port #3: TCP'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('nvme-port-disable-confirmation')),
      'DISABLE NVME PORT 3 TCP',
    );
    await tester.ensureVisible(
      find.byKey(const Key('nvme-port-disable-submit')),
    );
    await tester.tap(find.byKey(const Key('nvme-port-disable-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
    expect(tester.takeException(), isNull);
  });
}
