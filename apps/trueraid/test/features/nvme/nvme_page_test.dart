import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/nvme/nvme_overview.dart';
import 'package:trueraid/features/nvme/nvme_host_overview.dart';
import 'package:trueraid/features/nvme/nvme_page.dart';
import 'package:trueraid/features/nvme/nvme_global_panel.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _names = [
  'nvmet.subsys.query',
  'nvmet.port.query',
  'nvmet.namespace.query',
  'nvmet.port_subsys.query',
];
const _hostNames = ['nvmet.host.query', 'nvmet.host_subsys.query'];

Map<String, Object?> _method() => {
  'accepts': <Object?>[],
  'returns': [
    {
      'type': 'array',
      'items': {'type': 'object'},
    },
  ],
  'job': false,
  'filterable': true,
  'no_auth_required': false,
  'uploadable': false,
  'downloadable': false,
  'roles': ['READONLY_ADMIN'],
};

class _Fake
    implements
        SessionRepository,
        AuthenticatedAdminSession,
        AuthenticatedNvmeHostSession {
  _Fake({
    this.supported = true,
    this.hostSupported = true,
    this.unassociatedPort = false,
    this.globalSupported = false,
    this.serviceSupported = false,
    this.serviceRows,
  }) {
    adminCatalog = AdminCatalog.fromMetadata(
      version: '25.10.1',
      metadata: {
        for (final name in supported ? _names : _names.take(3)) name: _method(),
        for (final name in hostSupported ? _hostNames : _hostNames.take(1))
          name: _method(),
        if (globalSupported)
          'nvmet.global.config': {
            ..._method(),
            'filterable': false,
            'returns': [
              {'type': 'object'},
            ],
          },
        if (serviceSupported) 'service.query': _method(),
      },
    );
  }
  final bool supported;
  final bool hostSupported;
  final bool unassociatedPort;
  final bool globalSupported;
  final bool serviceSupported;
  final List<Object?>? serviceRows;
  @override
  late final AdminCatalog adminCatalog;
  final calls = <AdminRequest>[];
  final hostCalls = <String>[];

  @override
  Future<NvmeHostPublicRows> loadNvmeHostReferences() async {
    if (!hostSupported) throw const NvmeHostException();
    hostCalls.addAll(_hostNames);
    return NvmeHostPublicRows.project(
      [
        {
          'id': 6,
          'hostnqn': 'nqn.2026-09.example:alpha',
          'dhchap_key': 'private-host-key',
        },
        {'id': 7, 'hostnqn': 'nqn.2026-09.example:beta'},
      ],
      [
        {
          'id': 8,
          'host': {'id': 6, 'dhchap_ctrl_key': 'private-controller-key'},
          'subsys': {'id': 1},
        },
      ],
    );
  }

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    final value = switch (request.method.name) {
      'nvmet.global.config' => {
        'id': 1,
        'basenqn': 'nqn.2026-09.example',
        'kernel': true,
        'ana': false,
        'rdma': true,
        'xport_referral': false,
        'unexpected_private_field': 'do-not-render',
      },
      'service.query' =>
        serviceRows ??
            [
              {
                'service': 'nvmet',
                'enable': true,
                'state': 'RUNNING',
                'pids': [42],
              },
            ],
      'nvmet.subsys.query' => [
        {
          'id': 1,
          'name': 'finance',
          'subnqn': 'nqn.2026-09.example:finance',
          'allow_any_host': false,
          'ana': true,
          'pi_enable': true,
          'qid_max': 16,
          'ieee_oui': '00A1B2',
          'serial': 'hidden-serial',
        },
        {
          'id': 2,
          'name': 'public',
          'allow_any_host': true,
          'ana': null,
          'pi_enable': null,
          'qid_max': null,
          'ieee_oui': null,
        },
      ],
      'nvmet.port.query' => [
        {
          'id': 3,
          'addr_trtype': 'TCP',
          'enabled': true,
          'addr_traddr': 'private-address',
        },
        if (unassociatedPort)
          {'id': 7, 'addr_trtype': 'RDMA', 'enabled': false},
      ],
      'nvmet.namespace.query' => [
        {
          'id': 4,
          'nsid': 1,
          'subsys': {'id': 1},
          'device_type': 'ZVOL',
          'enabled': true,
          'locked': false,
          'device_path': '/mnt/private-backing',
        },
      ],
      'nvmet.port_subsys.query' => [
        {
          'id': 5,
          'port': {'id': 3},
          'subsys': {'id': 1},
        },
      ],
      _ => throw StateError('Unexpected method'),
    };
    return AdminCompleted(request, value: value);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test(
    'global projection excludes unknown fields and rejects partial data',
    () {
      final config = NvmeGlobalConfig.parse({
        'basenqn': 'nqn.2026-09.example',
        'kernel': true,
        'ana': false,
        'rdma': true,
        'xport_referral': false,
        'unexpected_private_field': 'do-not-retain',
      });
      expect(config.baseNqn, 'nqn.2026-09.example');
      expect(config.toString(), isNot(contains('do-not-retain')));
      expect(
        () => NvmeGlobalConfig.parse({
          'basenqn': 'nqn.2026-09.example',
          'kernel': true,
          'ana': false,
          'rdma': true,
        }),
        throwsFormatException,
      );
      expect(
        () => NvmeGlobalConfig.parse({
          'basenqn': 'nqn.bad\nname',
          'kernel': true,
          'ana': false,
          'rdma': true,
          'xport_referral': false,
        }),
        throwsFormatException,
      );
    },
  );

  test('service projection rejects missing, duplicate and malformed rows', () {
    expect(NvmeServiceStatus.parse([]), isNull);
    expect(
      NvmeServiceStatus.parse([
        {'service': 'nvmet', 'enable': true, 'state': 'RUNNING'},
        {'service': 'nvmet', 'enable': false, 'state': 'STOPPED'},
      ]),
      isNull,
    );
    expect(
      NvmeServiceStatus.parse([
        {'service': 'iscsitarget', 'enable': true, 'state': 'RUNNING'},
      ]),
      isNull,
    );
    expect(
      NvmeServiceStatus.parse([
        {'service': 'nvmet', 'enable': true, 'state': 'RUNNING\nsecret'},
      ]),
      isNull,
    );
  });

  test('subsystem projection rejects malformed PI, queue and OUI values', () {
    const row = {'id': 1, 'name': 'test', 'allow_any_host': false};
    expect(NvmeSubsystem.parse({...row, 'pi_enable': 'true'}), isNull);
    expect(NvmeSubsystem.parse({...row, 'qid_max': -1}), isNull);
    expect(NvmeSubsystem.parse({...row, 'qid_max': 2147483648}), isNull);
    expect(NvmeSubsystem.parse({...row, 'ieee_oui': 'bad\nvalue'}), isNull);
    expect(
      NvmeSubsystem.parse({...row, 'ieee_oui': List.filled(33, 'x').join()}),
      isNull,
    );
    final absent = NvmeSubsystem.parse(row)!;
    expect(absent.piReported, false);
    expect(absent.qidReported, false);
    expect(absent.ieeeOuiReported, false);
    final defaults = NvmeSubsystem.parse({
      ...row,
      'pi_enable': null,
      'qid_max': null,
      'ieee_oui': null,
    })!;
    expect(defaults.piReported, true);
    expect(defaults.qidReported, true);
    expect(defaults.ieeeOuiReported, true);
    expect(defaults.piEnable, isNull);
    expect(defaults.qidMax, isNull);
    expect(defaults.ieeeOui, isNull);
  });

  testWidgets('service state is a separate selected read', (tester) async {
    final fake = _Fake(globalSupported: true, serviceSupported: true);
    final session = AuthenticatedSession(
      profileId: 'fixture',
      repository: fake,
      availableMethodNames: {..._names, 'nvmet.global.config', 'service.query'},
      endpoint: 'wss://fixture.example/api/current',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => session),
        ],
        child: MaterialApp(theme: TrueRAIDTheme.dark(), home: const NvmePage()),
      ),
    );
    await tester.pumpAndSettle();
    final calls = fake.calls
        .where((call) => call.method.name == 'service.query')
        .toList();
    expect(calls, hasLength(1));
    expect(calls.single.arguments, [
      [
        ['service', '=', 'nvmet'],
      ],
      {
        'select': ['service', 'enable', 'state'],
        'limit': 2,
      },
    ]);
    expect(find.text('Service: RUNNING'), findsOneWidget);
    expect(find.text('Start on boot: Enabled'), findsOneWidget);
    expect(find.textContaining('pids'), findsNothing);
    expect(
      find.textContaining('Neither proves that a listener is reachable'),
      findsOneWidget,
    );
  });

  testWidgets(
    'missing service row stays unknown without losing configuration',
    (tester) async {
      final fake = _Fake(
        globalSupported: true,
        serviceSupported: true,
        serviceRows: const [],
      );
      final session = AuthenticatedSession(
        profileId: 'fixture',
        repository: fake,
        availableMethodNames: {
          ..._names,
          'nvmet.global.config',
          'service.query',
        },
        endpoint: 'wss://fixture.example/api/current',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dashboardActiveSessionProvider.overrideWith((ref) => session),
          ],
          child: MaterialApp(
            theme: TrueRAIDTheme.dark(),
            home: const NvmePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('Base NQN: nqn.2026-09.example'), findsOneWidget);
      expect(find.text('Service: Status unavailable'), findsOneWidget);
      expect(find.text('Start on boot: Unknown'), findsOneWidget);
    },
  );

  testWidgets('global settings read uses no arguments and refreshes', (
    tester,
  ) async {
    final fake = _Fake(globalSupported: true);
    final session = AuthenticatedSession(
      profileId: 'fixture',
      repository: fake,
      availableMethodNames: {..._names, 'nvmet.global.config'},
      endpoint: 'wss://fixture.example/api/current',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => session),
        ],
        child: MaterialApp(theme: TrueRAIDTheme.dark(), home: const NvmePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(
      fake.calls.where((c) => c.method.name == 'nvmet.global.config').length,
      1,
    );
    expect(
      fake.calls
          .firstWhere((c) => c.method.name == 'nvmet.global.config')
          .arguments,
      isEmpty,
    );
    expect(find.text('Base NQN: nqn.2026-09.example'), findsOneWidget);
    expect(find.text('RDMA: Configured on'), findsOneWidget);
    expect(find.textContaining('do-not-render'), findsNothing);
    await tester.tap(find.byKey(const Key('nvme-refresh')));
    await tester.pumpAndSettle();
    expect(
      fake.calls.where((c) => c.method.name == 'nvmet.global.config').length,
      2,
    );
    expect(tester.takeException(), isNull);
  });

  test('host projection is bounded and flags unresolved associations', () {
    final overview = NvmeHostOverview.parse(
      hosts: [
        {'id': 1, 'hostnqn': 'nqn.example:one', 'dhchap_key': 'hidden'},
      ],
      mappings: [
        {
          'id': 2,
          'host': {'id': 1},
          'subsys': {'id': 4},
        },
        {
          'id': 3,
          'host': {'id': 9},
          'subsys': {'id': 4},
        },
      ],
    );
    expect(overview.unresolvedReferences({4}), 1);
    expect(overview.hosts.single.toString(), isNot(contains('hidden')));
    expect(() => overview.hosts.clear(), throwsUnsupportedError);
    expect(
      () => NvmeHostOverview.parse(
        hosts: List.generate(101, (i) => {'id': i + 1, 'hostnqn': 'nqn:$i'}),
        mappings: [],
      ),
      throwsFormatException,
    );
    expect(
      () => NvmeHostOverview.parse(
        hosts: [
          {'id': 1, 'hostnqn': 'nqn:one'},
          {'id': 1, 'hostnqn': 'nqn:two'},
        ],
        mappings: [],
      ),
      throwsFormatException,
    );
  });

  test('projection rejects truncation and excludes backing details', () {
    final result = NvmeOverview.parse(
      subsystems: [
        {
          'id': 1,
          'name': 'finance',
          'allow_any_host': false,
          'serial': 'secret',
        },
      ],
      ports: [
        {
          'id': 3,
          'addr_trtype': 'TCP',
          'enabled': true,
          'addr_traddr': 'private',
        },
      ],
      namespaces: [
        {
          'id': 4,
          'nsid': 1,
          'subsys': {'id': 1},
          'device_type': 'ZVOL',
          'enabled': true,
          'locked': false,
          'device_path': '/mnt/private',
        },
      ],
      portMappings: [
        {
          'id': 5,
          'port': {'id': 3},
          'subsys': {'id': 1},
        },
      ],
    );
    expect(result.exposedSubsystems, 1);
    expect(result.unresolvedReferences, 0);
    expect(result.namespaces.single.deviceType, 'ZVOL');
    expect(result.subsystems.single.subnqn, isNull);
    expect(
      result.namespaces.single.toString(),
      isNot(contains('/mnt/private')),
    );
    expect(() => result.namespaces.clear(), throwsUnsupportedError);
    expect(
      () => NvmeOverview.parse(
        subsystems: [
          ...List.generate(
            100,
            (i) => {'id': i + 1, 'name': 'x', 'allow_any_host': false},
          ),
          '[additional items omitted]',
        ],
        ports: [],
        namespaces: [],
        portMappings: [],
      ),
      throwsFormatException,
    );
    expect(
      () => NvmeOverview.parse(
        subsystems: [
          {
            'id': 1,
            'name': 'one',
            'allow_any_host': false,
            'subnqn': 'invalid-nqn',
          },
        ],
        ports: [],
        namespaces: [],
        portMappings: [],
      ),
      throwsFormatException,
    );
  });

  test('unresolved relationships are counted without inventing endpoints', () {
    final result = NvmeOverview.parse(
      subsystems: [
        {'id': 1, 'name': 'one', 'allow_any_host': false},
      ],
      ports: [],
      namespaces: [
        {
          'id': 2,
          'nsid': null,
          'subsys': {'id': 99},
          'device_type': 'FILE',
          'enabled': false,
          'locked': null,
        },
      ],
      portMappings: [
        {
          'id': 3,
          'port': {'id': 88},
          'subsys': {'id': 1},
        },
      ],
    );
    expect(result.unresolvedReferences, 2);
    expect(result.exposedSubsystems, 1);
    expect(result.portById(88), isNull);
    expect(
      () => NvmeOverview.parse(
        subsystems: [
          {'id': 1, 'name': 'one', 'allow_any_host': false, 'ana': 'on'},
        ],
        ports: [],
        namespaces: [],
        portMappings: [],
      ),
      throwsFormatException,
    );
    expect(
      () => NvmeOverview.parse(
        subsystems: [
          {'id': 1, 'name': 'one', 'allow_any_host': '[redacted]'},
        ],
        ports: [],
        namespaces: [],
        portMappings: [],
      ),
      throwsFormatException,
    );
  });

  testWidgets(
    'reads four selected public inventories in order and charts topology',
    (tester) async {
      final fake = _Fake();
      final session = AuthenticatedSession(
        profileId: 'fixture',
        repository: fake,
        availableMethodNames: _names.toSet(),
        endpoint: 'wss://fixture.example/api/current',
      );
      tester.view.physicalSize = const Size(320, 900);
      tester.view.devicePixelRatio = 1;
      tester.binding.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(
        tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dashboardActiveSessionProvider.overrideWith((ref) => session),
          ],
          child: MaterialApp(
            theme: TrueRAIDTheme.dark(),
            home: const NvmePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(fake.calls.map((c) => c.method.name).toList(), _names);
      expect((fake.calls.first.arguments[1] as Map)['select'], [
        'id',
        'name',
        'subnqn',
        'allow_any_host',
        'ana',
        'pi_enable',
        'qid_max',
        'ieee_oui',
      ]);
      for (final call in fake.calls) {
        expect(call.arguments.first, isEmpty);
        expect((call.arguments[1] as Map)['limit'], 101);
        expect((call.arguments[1] as Map)['select'], isNotEmpty);
      }
      expect(
        fake.calls[2].arguments.toString(),
        isNot(contains('device_path')),
      );
      expect(
        find.textContaining('2 subsystems · 1 ports · 1 namespaces'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const Key('nvme-port-association-ratio')),
            )
            .value,
        0.5,
      );
      expect(find.byKey(const Key('nvme-ana-donut')), findsOneWidget);
      expect(find.byKey(const Key('nvme-pi-donut')), findsOneWidget);
      expect(find.text('ANA'), findsOneWidget);
      expect(find.text('PI'), findsOneWidget);
      expect(find.text('on: 1'), findsNWidgets(2));
      expect(find.text('inherit: 1'), findsOneWidget);
      expect(find.text('server default: 1'), findsOneWidget);
      expect(find.textContaining('private-address'), findsNothing);
      expect(find.textContaining('/mnt/private-backing'), findsNothing);
      expect(find.textContaining('hidden-serial'), findsNothing);
      final filter = find.byKey(const Key('nvme-filter'));
      await tester.ensureVisible(filter);
      await tester.enterText(filter, '00a1b2');
      await tester.pumpAndSettle();
      expect(find.text('1 matching subsystems'), findsOneWidget);
      await tester.enterText(filter, 'finance');
      await tester.pumpAndSettle();
      expect(find.text('1 matching subsystems'), findsOneWidget);
      final tile = find.byKey(const Key('nvme-subsystem-1'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.text('Namespace 1 · ZVOL'), findsOneWidget);
      expect(find.text('Port #3 · TCP'), findsWidgets);
      expect(find.text('nqn.2026-09.example:finance'), findsOneWidget);
      expect(find.text('Configured on for this subsystem'), findsOneWidget);
      expect(find.text('Protection information (PI)'), findsOneWidget);
      expect(find.text('Configured on'), findsOneWidget);
      expect(find.text('Maximum queue IDs'), findsOneWidget);
      expect(find.text('16'), findsOneWidget);
      expect(find.text('IEEE OUI'), findsOneWidget);
      expect(find.text('00A1B2'), findsOneWidget);
      await tester.tap(find.byKey(const Key('nvme-refresh')));
      await tester.pumpAndSettle();
      expect(fake.calls.length, 8);
      expect(tester.widget<TextField>(filter).controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'unused disabled port is identifiable without exposing its address',
    (tester) async {
      final fake = _Fake(unassociatedPort: true);
      final session = AuthenticatedSession(
        profileId: 'fixture',
        repository: fake,
        availableMethodNames: _names.toSet(),
        endpoint: 'wss://fixture.example/api/current',
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            dashboardActiveSessionProvider.overrideWith((ref) => session),
          ],
          child: MaterialApp(
            theme: TrueRAIDTheme.dark(),
            home: const NvmePage(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('nvme-port-7')), findsOneWidget);
      expect(find.text('Port #7 · RDMA'), findsOneWidget);
      expect(find.text('Disabled · 0 subsystem associations'), findsOneWidget);
      expect(find.textContaining('private-address'), findsNothing);
    },
  );

  testWidgets('missing method is unavailable with no request', (tester) async {
    final fake = _Fake(supported: false);
    final session = AuthenticatedSession(
      profileId: 'fixture',
      repository: fake,
      availableMethodNames: _names.toSet(),
      endpoint: 'wss://fixture.example/api/current',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => session),
        ],
        child: MaterialApp(theme: TrueRAIDTheme.dark(), home: const NvmePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(fake.calls, isEmpty);
    expect(find.textContaining('Counts are unknown, not zero'), findsOneWidget);
  });

  testWidgets('host access is opt-in, selected and secret-free', (
    tester,
  ) async {
    final fake = _Fake();
    final session = AuthenticatedSession(
      profileId: 'fixture',
      repository: fake,
      availableMethodNames: _names.toSet(),
      endpoint: 'wss://fixture.example/api/current',
    );
    tester.view.physicalSize = const Size(320, 900);
    tester.view.devicePixelRatio = 1;
    tester.binding.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    addTearDown(
      tester.binding.platformDispatcher.clearTextScaleFactorTestValue,
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => session),
        ],
        child: MaterialApp(theme: TrueRAIDTheme.dark(), home: const NvmePage()),
      ),
    );
    await tester.pumpAndSettle();
    expect(fake.calls.map((call) => call.method.name), _names);
    final load = find.byKey(const Key('nvme-host-load'));
    await tester.ensureVisible(load);
    await tester.tap(load);
    await tester.pumpAndSettle();
    expect(fake.calls.map((call) => call.method.name), _names);
    expect(fake.hostCalls, _hostNames);
    expect(
      find.textContaining('2 hosts · 1 host–subsystem associations'),
      findsOneWidget,
    );
    expect(
      tester
          .widget<LinearProgressIndicator>(
            find.byKey(const Key('nvme-host-association-ratio')),
          )
          .value,
      0.5,
    );
    expect(find.textContaining('private-host-key'), findsNothing);
    expect(find.textContaining('private-controller-key'), findsNothing);
    final host = find.byKey(const Key('nvme-host-6'));
    await tester.ensureVisible(host);
    await tester.tap(host);
    await tester.pumpAndSettle();
    expect(find.text('finance'), findsWidgets);
    expect(find.textContaining('Association #8'), findsOneWidget);
    final filter = find.byKey(const Key('nvme-host-filter'));
    await tester.ensureVisible(filter);
    await tester.enterText(filter, 'beta');
    await tester.pumpAndSettle();
    expect(find.text('1 matching hosts'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('missing host association method never sends a host read', (
    tester,
  ) async {
    final fake = _Fake(hostSupported: false);
    final session = AuthenticatedSession(
      profileId: 'fixture',
      repository: fake,
      availableMethodNames: _names.toSet(),
      endpoint: 'wss://fixture.example/api/current',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          dashboardActiveSessionProvider.overrideWith((ref) => session),
        ],
        child: MaterialApp(theme: TrueRAIDTheme.dark(), home: const NvmePage()),
      ),
    );
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('nvme-host-load')));
    await tester.tap(find.byKey(const Key('nvme-host-load')));
    await tester.pumpAndSettle();
    expect(fake.calls.map((call) => call.method.name), _names);
    expect(fake.hostCalls, isEmpty);
    expect(find.textContaining('counts are unknown, not zero'), findsOneWidget);
  });
}
