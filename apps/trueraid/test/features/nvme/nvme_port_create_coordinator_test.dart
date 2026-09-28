import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid/features/nvme/nvme_port_create_coordinator.dart';
import 'package:trueraid/features/nvme/nvme_port_create_editor.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
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
        'nvmet.port.create': _method(),
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
    'addr_traddr': '10.0.0.1',
    'addr_trsvcid': 4420,
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
  final created = <Map<String, Object?>>[];
  bool corruptResponse = false;
  bool enableAfterCreate = false;
  bool attachAfterCreate = false;
  bool missingBinding = false;
  bool bindingMismatch = false;
  bool wrongAddressAfterCreate = false;
  bool normalizeIpv6 = false;
  bool ambiguous = false;
  bool driftAfterWrite = false;
  bool queueDriftAfterWrite = false;

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
        final rows = [Map.of(port), for (final p in created) Map.of(p)];
        if (missingBinding) rows.first.remove('addr_traddr');
        final options = request.arguments[1] as Map;
        if (bindingMismatch &&
            (options['select'] as List).contains('addr_traddr')) {
          rows.first['id'] = 999;
        }
        return AdminCompleted(request, value: rows);
      case 'nvmet.port_subsys.query':
        return AdminCompleted(
          request,
          value: [for (final row in mappings) Map.of(row)],
        );
      case 'nvmet.port.create':
        if (ambiguous) return AdminOutcomeUnknown(request);
        final payload = request.arguments.single as Map;
        final row = <String, Object?>{
          'id': 7,
          ...payload.cast<String, Object?>(),
          'inline_data_size': null,
          'max_queue_size': null,
          'pi_enable': null,
        };
        created.add(row);
        if (normalizeIpv6) row['addr_traddr'] = '2001:0db8:0:0:0:0:0:0002';
        final returned = Map.of(row);
        if (corruptResponse) returned['id'] = 3;
        if (driftAfterWrite) port['pi_enable'] = true;
        if (queueDriftAfterWrite) row['max_queue_size'] = 128;
        if (wrongAddressAfterCreate) row['addr_traddr'] = '10.0.0.99';
        if (enableAfterCreate) row['enabled'] = true;
        if (attachAfterCreate) {
          mappings.add({
            'id': 8,
            'port': {'id': 7},
            'subsys': {'id': 2},
          });
        }
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
    coordinator = NvmePortCreateCoordinator(
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
  late final NvmePortCreateCoordinator coordinator;
  bool current = true;
  DateTime clock = DateTime.utc(2026);
  int get writes =>
      api.calls.where((c) => c.method.name == 'nvmet.port.create').length;
}

const _choice = NvmePortCreateChoice('10.0.0.2', 4420);

void main() {
  test('invalid IPv4 and service ports reject before reads', () async {
    final h = _Harness();
    for (final address in [
      '',
      '0.0.0.0',
      '::1',
      'host',
      '01.2.3.4',
      '256.1.2.3',
      '224.1.2.3',
      ' 10.0.0.2',
      '10.0.0.2\n',
    ]) {
      await expectLater(
        h.coordinator.prepare(NvmePortCreateChoice(address, 4420)),
        throwsStateError,
      );
    }
    for (final port in [0, 1023, 65536]) {
      await expectLater(
        h.coordinator.prepare(NvmePortCreateChoice('10.0.0.2', port)),
        throwsStateError,
      );
    }
    expect(h.api.calls, isEmpty);
  });

  test(
    'create sends only TCP binding and disabled flag and verifies readback',
    () async {
      final h = _Harness();
      final review = await h.coordinator.prepare(_choice);
      expect(review.confirmation, 'CREATE DISABLED NVME TCP 10.0.0.2:4420');
      expect(h.writes, 0);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmePortCreateOutcome.completed,
      );
      expect(h.writes, 1);
      expect(
        h.api.calls
            .where((c) => c.method.name == 'nvmet.port.create')
            .single
            .arguments,
        [
          {
            'addr_trtype': 'TCP',
            'addr_traddr': '10.0.0.2',
            'addr_trsvcid': 4420,
            'enabled': false,
          },
        ],
      );
      expect(h.api.port['max_queue_size'], 16);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmePortCreateOutcome.rejected,
      );
    },
  );

  test('duplicate and wildcard bindings reject even if disabled', () async {
    for (final address in ['10.0.0.2', '', '0.0.0.0', '::']) {
      final h = _Harness();
      h.api.port['addr_traddr'] = address;
      await expectLater(h.coordinator.prepare(_choice), throwsStateError);
      expect(h.writes, 0);
    }
  });

  test('IPv6 create accepts equivalent server address normalization', () async {
    final h = _Harness();
    h.api.normalizeIpv6 = true;
    const choice = NvmePortCreateChoice('2001:DB8::2', 4420);
    final review = await h.coordinator.prepare(choice);
    expect(review.confirmation, 'CREATE DISABLED NVME TCP [2001:DB8::2]:4420');
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      NvmePortCreateOutcome.completed,
    );
    expect(h.writes, 1);
    final payload =
        h.api.calls
                .where((c) => c.method.name == 'nvmet.port.create')
                .single
                .arguments
                .single
            as Map;
    expect(payload, {
      'addr_trtype': 'TCP',
      'addr_traddr': choice.address,
      'addr_trsvcid': 4420,
      'enabled': false,
    });
  });

  test(
    'equivalent IPv6 and wildcard spellings conflict before writes',
    () async {
      for (final address in [
        '2001:0DB8:0:0:0:0:0:0002',
        '::',
        '0:0:0:0:0:0:0:0',
      ]) {
        final h = _Harness();
        h.api.port['addr_traddr'] = address;
        await expectLater(
          h.coordinator.prepare(
            const NvmePortCreateChoice('2001:db8::2', 4420),
          ),
          throwsStateError,
        );
        expect(h.writes, 0);
      }
    },
  );

  test('existing IPv4-mapped alias conflicts with IPv4 creation', () async {
    final h = _Harness();
    h.api.port['addr_traddr'] = '::ffff:10.0.0.2';
    await expectLater(h.coordinator.prepare(_choice), throwsStateError);
    expect(h.writes, 0);
  });

  test('unsupported existing TCP bind address fails closed', () async {
    final h = _Harness();
    h.api.port['addr_traddr'] = 'fe80::1%eth0';
    await expectLater(h.coordinator.prepare(_choice), throwsStateError);
    expect(h.writes, 0);
  });

  test('unsupported IPv6 choices reject before reads', () async {
    final h = _Harness();
    for (final address in [
      '::',
      'fe80::2',
      'ff02::2',
      '::ffff:10.0.0.2',
      'fe80::2%eth0',
      '[2001:db8::2]',
      '2001::db8::2',
    ]) {
      await expectLater(
        h.coordinator.prepare(NvmePortCreateChoice(address, 4420)),
        throwsStateError,
      );
    }
    expect(h.api.calls, isEmpty);
  });

  test('different TCP service port is allowed', () async {
    final h = _Harness();
    h.api.port['addr_traddr'] = _choice.address;
    final review = await h.coordinator.prepare(
      NvmePortCreateChoice(_choice.address, 4421),
    );
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      NvmePortCreateOutcome.completed,
    );
  });

  test('missing binding field fails closed', () async {
    final h = _Harness();
    h.api.missingBinding = true;
    await expectLater(h.coordinator.prepare(_choice), throwsStateError);
    expect(h.writes, 0);
  });

  test('disagreeing binding and topology inventories reject review', () async {
    final h = _Harness();
    h.api.bindingMismatch = true;
    await expectLater(h.coordinator.prepare(_choice), throwsStateError);
    expect(h.writes, 0);
  });

  test('binding query is selected and bounded', () async {
    final h = _Harness();
    await h.coordinator.prepare(_choice);
    final bindingRead = h.api.calls
        .where((c) => c.method.name == 'nvmet.port.query')
        .last;
    expect(bindingRead.arguments, [
      [],
      {
        'select': [
          'id',
          'addr_trtype',
          'addr_traddr',
          'addr_trsvcid',
          'enabled',
        ],
        'limit': 101,
      },
    ]);
    expect(h.writes, 0);
  });

  test('capacity limit leaves room for verifiable creation', () async {
    final h = _Harness();
    for (var i = 0; i < 99; i++) {
      h.api.created.add({...h.api.port, 'id': i + 100});
    }
    await expectLater(h.coordinator.prepare(_choice), throwsStateError);
    expect(h.writes, 0);
  });

  test('wrong phrase expiry and session change send nothing', () async {
    final h = _Harness();
    final wrong = await h.coordinator.prepare(_choice);
    expect(
      (await h.coordinator.execute(wrong, 'wrong')).outcome,
      NvmePortCreateOutcome.rejected,
    );
    final expired = await h.coordinator.prepare(_choice);
    h.clock = h.clock.add(const Duration(minutes: 5));
    expect(
      (await h.coordinator.execute(expired, expired.confirmation)).outcome,
      NvmePortCreateOutcome.rejected,
    );
    final stale = await h.coordinator.prepare(_choice);
    h.current = false;
    expect(
      (await h.coordinator.execute(stale, stale.confirmation)).outcome,
      NvmePortCreateOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  test('changed bind address invalidates review before submission', () async {
    final h = _Harness();
    final review = await h.coordinator.prepare(_choice);
    h.api.port['addr_traddr'] = '10.0.0.3';
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      NvmePortCreateOutcome.rejected,
    );
    expect(h.writes, 0);
  });

  for (final mode in [
    'ambiguous',
    'reused ID',
    'existing drift',
    'new queue drift',
    'enabled',
    'attached',
    'wrong address',
  ]) {
    test('$mode fences subsequent writes without automatic retry', () async {
      final h = _Harness();
      h.api.ambiguous = mode == 'ambiguous';
      h.api.corruptResponse = mode == 'reused ID';
      h.api.driftAfterWrite = mode == 'existing drift';
      h.api.queueDriftAfterWrite = mode == 'new queue drift';
      h.api.enableAfterCreate = mode == 'enabled';
      h.api.attachAfterCreate = mode == 'attached';
      h.api.wrongAddressAfterCreate = mode == 'wrong address';
      final review = await h.coordinator.prepare(_choice);
      expect(
        (await h.coordinator.execute(review, review.confirmation)).outcome,
        NvmePortCreateOutcome.unknown,
      );
      expect(h.writes, 1);
      expect(h.coordinator.locked, true);
      await expectLater(h.coordinator.prepare(_choice), throwsStateError);
      expect(h.writes, 1);
    });
  }

  testWidgets('editor reviews exact binding before fake create', (
    tester,
  ) async {
    final h = _Harness();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => h.session),
          nvmePortCreateCoordinatorProvider.overrideWith(
            (ref) => h.coordinator,
          ),
        ],
        child: MaterialApp(
          theme: TrueRAIDTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(child: NvmePortCreateEditor()),
          ),
        ),
      ),
    );
    await tester.enterText(
      find.byKey(const Key('nvme-port-create-address')),
      '10.0.0.2',
    );
    await tester.tap(find.byKey(const Key('nvme-port-create-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    expect(find.text('TCP 10.0.0.2:4420, disabled'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('nvme-port-create-service')),
      '1023',
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('nvme-port-create-confirmation')),
      findsNothing,
    );
    await tester.tap(find.byKey(const Key('nvme-port-create-review')));
    await tester.pumpAndSettle();
    expect(h.writes, 0);
    expect(find.textContaining('port from 1024 to 65535'), findsOneWidget);
    await tester.enterText(
      find.byKey(const Key('nvme-port-create-service')),
      '4420',
    );
    await tester.tap(find.byKey(const Key('nvme-port-create-review')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('nvme-port-create-confirmation')),
      'CREATE DISABLED NVME TCP 10.0.0.2:4420',
    );
    await tester.ensureVisible(
      find.byKey(const Key('nvme-port-create-submit')),
    );
    await tester.tap(find.byKey(const Key('nvme-port-create-submit')));
    await tester.pumpAndSettle();
    expect(h.writes, 1);
    expect(tester.takeException(), isNull);
  });

  test('different IPv6 readback address fences further edits', () async {
    final h = _Harness();
    h.api.wrongAddressAfterCreate = true;
    final review = await h.coordinator.prepare(
      const NvmePortCreateChoice('fd00::2', 4420),
    );
    expect(
      (await h.coordinator.execute(review, review.confirmation)).outcome,
      NvmePortCreateOutcome.unknown,
    );
    expect(h.writes, 1);
    expect(h.coordinator.locked, true);
  });

  for (final width in [320.0, 430.0]) {
    testWidgets('IPv6 creation review fits at $width and 200 percent text', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 900);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final h = _Harness();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dashboardActiveSessionProvider.overrideWith((ref) => h.session),
            nvmePortCreateCoordinatorProvider.overrideWith(
              (ref) => h.coordinator,
            ),
          ],
          child: MaterialApp(
            theme: TrueRAIDTheme.dark(),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: const TextScaler.linear(2)),
              child: child!,
            ),
            home: const Scaffold(
              body: SingleChildScrollView(child: NvmePortCreateEditor()),
            ),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('nvme-port-create-address')),
        '2001:0db8:0000:0000:0000:0000:0000:0002',
      );
      await tester.ensureVisible(
        find.byKey(const Key('nvme-port-create-review')),
      );
      await tester.tap(find.byKey(const Key('nvme-port-create-review')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const Key('nvme-port-create-confirmation')),
      );
      await tester.enterText(
        find.byKey(const Key('nvme-port-create-confirmation')),
        'CREATE DISABLED NVME TCP [2001:0db8:0000:0000:0000:0000:0000:0002]:4420',
      );
      await tester.pumpAndSettle();
      expect(h.writes, 0);
      expect(tester.takeException(), isNull);
    });
  }
}
