import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo/features/nvme/nvme_subsystem_oui_coordinator.dart';
import 'package:truenavo/features/nvme/nvme_subsystem_oui_editor.dart';
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
    'ieee_oui': null,
    'qid_max': 16,
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
        subsystem['ieee_oui'] = payload['ieee_oui'];
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
    coordinator = NvmeSubsystemOuiCoordinator(
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
  late final NvmeSubsystemOuiCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes =>
      api.calls.where((c) => c.method.name == 'nvmet.subsys.update').length;
}

void main() {
  test(
    'default to OUI sends only ieee_oui after exact review and readback',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(
        1,
        const NvmeOuiChoice('00A1B2'),
      );
      expect(review.oldLabel, 'server default');
      expect(review.newLabel, '00A1B2');
      expect(review.confirmation, 'SET NVME OUI 1 empty 00A1B2');
      expect(h.writes, 0);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmeOuiOutcome.completed,
      );
      expect(h.writes, 1);
      expect(
        h.api.calls
            .where((c) => c.method.name == 'nvmet.subsys.update')
            .single
            .arguments,
        [
          1,
          {'ieee_oui': '00A1B2'},
        ],
      );
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmeOuiOutcome.rejected,
      );
      expect(h.writes, 1);
    },
  );

  test('configured OUI to server default sends explicit null', () async {
    final h = _Harness();
    h.api.subsystem['ieee_oui'] = '001122';
    final review = await h.coordinator.prepare(1, const NvmeOuiChoice(null));
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      NvmeOuiOutcome.completed,
    );
    expect(
      h.api.calls
          .where((c) => c.method.name == 'nvmet.subsys.update')
          .single
          .arguments,
      [
        1,
        {'ieee_oui': null},
      ],
    );
  });

  test('missing OUI, any-host or associations prevent review', () async {
    final missing = _Harness();
    missing.api.subsystem.remove('ieee_oui');
    await expectLater(
      missing.coordinator.prepare(1, const NvmeOuiChoice('00A1B2')),
      throwsStateError,
    );
    final anyHost = _Harness();
    anyHost.api.subsystem['allow_any_host'] = true;
    await expectLater(
      anyHost.coordinator.prepare(1, const NvmeOuiChoice('00A1B2')),
      throwsStateError,
    );
    final host = _Harness();
    host.api.hostMappings.add({
      'id': 9,
      'host': {'id': 8},
      'subsys': {'id': 1},
    });
    await expectLater(
      host.coordinator.prepare(1, const NvmeOuiChoice('00A1B2')),
      throwsStateError,
    );
    final port = _Harness();
    port.api.portMappings.add({
      'id': 11,
      'port': {'id': 3},
      'subsys': {'id': 1},
    });
    await expectLater(
      port.coordinator.prepare(1, const NvmeOuiChoice('00A1B2')),
      throwsStateError,
    );
    final nqn = _Harness();
    nqn.api.subsystem.remove('subnqn');
    await expectLater(
      nqn.coordinator.prepare(1, const NvmeOuiChoice('00A1B2')),
      throwsStateError,
    );
    final same = _Harness();
    await expectLater(
      same.coordinator.prepare(1, const NvmeOuiChoice(null)),
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

  test('invalid OUI strings are rejected before any read', () async {
    final h = _Harness();
    await expectLater(
      h.coordinator.prepare(1, const NvmeOuiChoice('')),
      throwsStateError,
    );
    await expectLater(
      h.coordinator.prepare(1, const NvmeOuiChoice('bad space')),
      throwsStateError,
    );
    await expectLater(
      h.coordinator.prepare(
        1,
        const NvmeOuiChoice('123456789012345678901234567890123'),
      ),
      throwsStateError,
    );
    expect(h.api.calls, isEmpty);
  });

  test('wrong, expired and stale reviews send nothing', () async {
    final h = _Harness();
    final wrong = await h.coordinator.prepare(1, const NvmeOuiChoice('00A1B2'));
    expect(
      (await h.coordinator.execute(wrong, 'wrong')).outcome,
      NvmeOuiOutcome.rejected,
    );
    final expired = await h.coordinator.prepare(
      1,
      const NvmeOuiChoice('00A1B2'),
    );
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(expired, expired.confirmation)).outcome,
      NvmeOuiOutcome.rejected,
    );
    final drift = await h.coordinator.prepare(1, const NvmeOuiChoice('00A1B2'));
    h.api.subsystem['ana'] = true;
    expect(
      (await h.coordinator.execute(drift, drift.confirmation)).outcome,
      NvmeOuiOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test('ambiguous result or unrelated readback drift fences edits', () async {
    final unknown = _Harness();
    unknown.api.ambiguous = true;
    final review = await unknown.coordinator.prepare(
      1,
      const NvmeOuiChoice('00A1B2'),
    );
    expect(
      (await unknown.coordinator.execute(review, review.confirmation)).outcome,
      NvmeOuiOutcome.unknown,
    );
    expect(unknown.coordinator.locked, true);
    final drift = _Harness();
    drift.api.driftAfterWrite = true;
    final next = await drift.coordinator.prepare(
      1,
      const NvmeOuiChoice('00A1B2'),
    );
    expect(
      (await drift.coordinator.execute(next, next.confirmation)).outcome,
      NvmeOuiOutcome.unknown,
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
          nvmeSubsystemOuiCoordinatorProvider.overrideWith(
            (ref) => h.coordinator,
          ),
        ],
        child: MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: NvmeSubsystemOuiEditor()),
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('nvme-subsystem-oui-id')), '1');
    await tester.tap(find.byKey(const Key('nvme-subsystem-oui-default')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('nvme-subsystem-oui-value')),
      'bad space',
    );
    await tester.tap(find.byKey(const Key('nvme-subsystem-oui-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    expect(find.textContaining('1–32 letters'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('nvme-subsystem-oui-value')),
      '00A1B2',
    );
    await tester.tap(find.byKey(const Key('nvme-subsystem-oui-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    expect(find.text('IEEE OUI: server default → 00A1B2'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('nvme-subsystem-oui-confirmation')),
      'SET NVME OUI 1 empty 00A1B2',
    );
    await tester.ensureVisible(
      find.byKey(const Key('nvme-subsystem-oui-submit')),
    );
    await tester.tap(find.byKey(const Key('nvme-subsystem-oui-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
    expect(tester.takeException(), isNull);
  });
}
