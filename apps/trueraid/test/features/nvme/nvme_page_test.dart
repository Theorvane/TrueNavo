import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/nvme/nvme_overview.dart';
import 'package:trueraid/features/nvme/nvme_page.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _names = [
  'nvmet.subsys.query',
  'nvmet.port.query',
  'nvmet.namespace.query',
  'nvmet.port_subsys.query',
];

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

class _Fake implements SessionRepository, AuthenticatedAdminSession {
  _Fake({this.supported = true}) {
    adminCatalog = AdminCatalog.fromMetadata(
      version: '25.10.1',
      metadata: {
        for (final name in supported ? _names : _names.take(3)) name: _method(),
      },
    );
  }
  final bool supported;
  @override
  late final AdminCatalog adminCatalog;
  final calls = <AdminRequest>[];

  @override
  Future<AdminResult> invokeAdmin(AdminRequest request) async {
    calls.add(request);
    final value = switch (request.method.name) {
      'nvmet.subsys.query' => [
        {
          'id': 1,
          'name': 'finance',
          'allow_any_host': false,
          'serial': 'hidden-serial',
        },
        {'id': 2, 'name': 'public', 'allow_any_host': true},
      ],
      'nvmet.port.query' => [
        {
          'id': 3,
          'addr_trtype': 'TCP',
          'enabled': true,
          'addr_traddr': 'private-address',
        },
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
      expect(find.textContaining('private-address'), findsNothing);
      expect(find.textContaining('/mnt/private-backing'), findsNothing);
      expect(find.textContaining('hidden-serial'), findsNothing);
      final filter = find.byKey(const Key('nvme-filter'));
      await tester.ensureVisible(filter);
      await tester.enterText(filter, 'finance');
      await tester.pumpAndSettle();
      expect(find.text('1 matching subsystems'), findsOneWidget);
      final tile = find.byKey(const Key('nvme-subsystem-1'));
      await tester.ensureVisible(tile);
      await tester.tap(tile);
      await tester.pumpAndSettle();
      expect(find.text('Namespace 1 · ZVOL'), findsOneWidget);
      expect(find.text('Port #3 · TCP'), findsOneWidget);
      await tester.tap(find.byKey(const Key('nvme-refresh')));
      await tester.pumpAndSettle();
      expect(fake.calls.length, 8);
      expect(tester.widget<TextField>(filter).controller!.text, isEmpty);
      expect(tester.takeException(), isNull);
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
}
