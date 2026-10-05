import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/network/network_controller.dart';
import 'package:truenavo/features/network/network_page.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _endpoint = 'wss://nas.example/api/current';

void main() {
  testWidgets('offline page neither reads interfaces nor exposes editing', (
    tester,
  ) async {
    final fixture = await _pump(tester, connected: false);
    expect(find.text('A live connection is required'), findsOneWidget);
    expect(find.textContaining('VLANs, bonds, bridges, IPv6'), findsOneWidget);
    expect(_key('network-edit-eth0'), findsNothing);
    expect(fixture.api.inventoryReads, 0);
    expect(fixture.api.requests, isEmpty);
  });

  testWidgets('missing authenticated endpoint requires reconnect', (
    tester,
  ) async {
    final fixture = await _pump(tester, endpoint: null);
    expect(find.text('A live connection is required'), findsOneWidget);
    expect(fixture.api.inventoryReads, 0);
    expect(_key('network-edit-eth0'), findsNothing);
  });

  testWidgets(
    'inventory distinguishes editable physical and blocked topology',
    (tester) async {
      final fixture = await _pump(tester);
      expect(find.text('192.168.10.20/24'), findsOneWidget);
      expect(find.text('Editable IPv4'), findsOneWidget);
      expect(find.text('Read-only'), findsOneWidget);
      expect(
        tester.widget<OutlinedButton>(_key('network-edit-eth0')).onPressed,
        isNotNull,
      );
      await _reveal(tester, 'network-edit-br0');
      expect(
        tester.widget<OutlinedButton>(_key('network-edit-br0')).onPressed,
        isNull,
      );
      expect(fixture.api.requests, isEmpty);
    },
  );

  testWidgets('foreign pending changes disable all interface editors', (
    tester,
  ) async {
    final fixture = await _pump(tester, pending: true);
    expect(find.text('Changes are currently protected'), findsOneWidget);
    expect(
      tester.widget<OutlinedButton>(_key('network-edit-eth0')).onPressed,
      isNull,
    );
    expect(fixture.api.requests, isEmpty);
  });

  testWidgets('unsupported version does not fetch or offer network actions', (
    tester,
  ) async {
    final fixture = await _pump(tester, versionSupported: false);
    expect(find.text('Network editing is unavailable'), findsOneWidget);
    expect(find.textContaining('stable TrueNAS 25.10'), findsOneWidget);
    expect(fixture.api.inventoryReads, 0);
  });

  testWidgets(
    'opening editor performs no write and shows original configuration',
    (tester) async {
      final fixture = await _pump(tester);
      await _tap(tester, 'network-edit-eth0');
      expect(find.byType(NetworkInterfacePage), findsOneWidget);
      expect(find.text('Current configuration'), findsOneWidget);
      expect(find.text('192.168.10.20/24'), findsOneWidget);
      expect(find.text(_endpoint), findsOneWidget);
      expect(fixture.api.requests, isEmpty);
    },
  );

  testWidgets(
    'before-after review requires exact interface and disconnect acknowledgement',
    (tester) async {
      final fixture = await _pump(tester);
      await _openChangedEditor(tester);
      await _tap(tester, 'network-review-test');
      expect(find.byType(NetworkReviewDialog), findsOneWidget);
      expect(find.text('Before'), findsOneWidget);
      expect(find.text('After · temporary'), findsOneWidget);
      expect(find.text('192.168.10.20/24'), findsWidgets);
      expect(find.text('192.168.10.21/24'), findsOneWidget);
      expect(fixture.api.requests, isEmpty);
      await _reveal(tester, 'network-confirm-interface');
      await tester.enterText(_key('network-confirm-interface'), 'eth0');
      await tester.pump();
      expect(_confirmButton(tester).onPressed, isNull);
      await _tap(tester, 'network-confirm-acknowledge');
      for (final invalid in ['ETH0', 'eth0 ', ' eth0', 'eth']) {
        await tester.enterText(_key('network-confirm-interface'), invalid);
        await tester.pump();
        expect(_confirmButton(tester).onPressed, isNull, reason: invalid);
      }
      await tester.enterText(_key('network-confirm-interface'), 'eth0');
      await tester.pump();
      await _tap(tester, 'network-confirm-test');
      expect(fixture.api.requests, hasLength(1));
      expect(fixture.api.requests.single.interfaceId, 'eth0');
      expect(
        fixture.api.requests.single.ipv4Aliases.single.address,
        '192.168.10.21',
      );
      expect(fixture.api.keeps, 0);
    },
  );

  testWidgets('cancel and malformed IPv4 cannot send network writes', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    await _openChangedEditor(tester);
    await tester.enterText(_key('network-address-0'), '999.0.0.1');
    await _tap(tester, 'network-review-test');
    expect(find.byType(NetworkReviewDialog), findsNothing);
    expect(fixture.api.requests, isEmpty);
    await _reveal(tester, 'network-address-0');
    await tester.enterText(_key('network-address-0'), '192.168.10.21');
    await _tap(tester, 'network-review-test');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(fixture.api.requests, isEmpty);
  });

  testWidgets(
    'DHCP sends zero static aliases and preserves description and MTU',
    (tester) async {
      final fixture = await _pump(tester);
      await _tap(tester, 'network-edit-eth0');
      await _reveal(tester, 'network-description');
      await tester.enterText(_key('network-description'), 'Management uplink');
      await _tap(tester, 'network-dhcp');
      expect(_key('network-address-0'), findsNothing);
      await _tap(tester, 'network-review-test');
      await _approve(tester);
      final request = fixture.api.requests.single;
      expect(request.dhcp, isTrue);
      expect(request.ipv4Aliases, isEmpty);
      expect(request.description, 'Management uplink');
      expect(request.mtu, 1500);
    },
  );

  testWidgets('empty static aliases and invalid prefix or MTU are blocked', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    await _tap(tester, 'network-edit-eth0');
    await _reveal(tester, 'network-prefix-0');
    await tester.enterText(_key('network-prefix-0'), '0');
    await _tap(tester, 'network-review-test');
    expect(find.byType(NetworkReviewDialog), findsNothing);
    await _reveal(tester, 'network-prefix-0');
    await tester.enterText(_key('network-prefix-0'), '24');
    await _reveal(tester, 'network-mtu');
    await tester.enterText(_key('network-mtu'), '9001');
    await _tap(tester, 'network-review-test');
    expect(find.byType(NetworkReviewDialog), findsNothing);
    await _reveal(tester, 'network-mtu');
    await tester.enterText(_key('network-mtu'), '1500');
    await _tap(tester, 'network-remove-address-0');
    await _tap(tester, 'network-review-test');
    expect(find.byType(NetworkReviewDialog), findsNothing);
    expect(fixture.api.requests, isEmpty);
  });

  testWidgets('connection changed during review sends nothing', (tester) async {
    final fixture = await _pump(tester);
    await _openChangedEditor(tester);
    await _tap(tester, 'network-review-test');
    fixture.container.read(_sessionProvider.notifier).select(null);
    await tester.pump();
    await _approve(tester);
    expect(fixture.api.requests, isEmpty);
    expect(
      find.textContaining('connection changed during review'),
      findsOneWidget,
    );
  });

  testWidgets('keep requires a second explicit connectivity acknowledgement', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    await fixture.begin();
    await tester.pumpAndSettle();
    expect(find.text('60 s'), findsOneWidget);
    expect(
      tester.widget<FilledButton>(_key('network-keep-changes')).onPressed,
      isNull,
    );
    expect(fixture.api.keeps, 0);
    await _tap(tester, 'network-connectivity-verified');
    await _tap(tester, 'network-keep-changes');
    expect(fixture.api.keeps, 1);
    expect(find.text('Changes kept'), findsOneWidget);
  });

  testWidgets('explicit revert restores state without ever keeping changes', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    await fixture.begin();
    await tester.pumpAndSettle();
    await _tap(tester, 'network-revert-changes');
    expect(fixture.api.reverts, 1);
    expect(fixture.api.keeps, 0);
    expect(find.text('Previous configuration restored'), findsOneWidget);
  });

  testWidgets(
    'unconfirmed staging does not display an armed rollback countdown',
    (tester) async {
      final fixture = await _pump(tester, unknown: true);
      await fixture.begin();
      await tester.pumpAndSettle();
      expect(find.text('Network outcome needs verification'), findsOneWidget);
      expect(_key('network-countdown'), findsNothing);
      expect(
        find.textContaining('timer has not been confirmed'),
        findsOneWidget,
      );
      expect(
        tester.widget<FilledButton>(_key('network-keep-changes')).onPressed,
        isNull,
      );
      expect(
        tester.widget<OutlinedButton>(_key('network-revert-changes')).onPressed,
        isNotNull,
      );
      expect(fixture.api.keeps, 0);
    },
  );

  testWidgets(
    'expired estimate disables keep without claiming rollback succeeded',
    (tester) async {
      final fixture = await _pump(tester);
      await fixture.begin();
      await tester.pumpAndSettle();
      fixture.elapsed = const Duration(seconds: 60);
      await tester.pump(const Duration(seconds: 1));
      expect(find.text('Network outcome needs verification'), findsOneWidget);
      expect(find.textContaining('does not prove rollback'), findsOneWidget);
      expect(find.text('Previous configuration restored'), findsNothing);
      expect(
        tester.widget<FilledButton>(_key('network-keep-changes')).onPressed,
        isNull,
      );
      expect(fixture.api.keeps, 0);
    },
  );

  testWidgets('leaving editor retains active test without keep or revert', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    await _openChangedEditor(tester);
    await _tap(tester, 'network-review-test');
    await _approve(tester);
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.byType(NetworkPage), findsOneWidget);
    expect(
      fixture.container.read(networkControllerProvider).phase,
      NetworkPhase.testing,
    );
    expect(find.text('Temporary settings · not yet kept'), findsOneWidget);
    expect(fixture.api.keeps, 0);
    expect(fixture.api.reverts, 0);
  });

  testWidgets(
    'reconnect recovery is read-only and does not claim prior rollback',
    (tester) async {
      final fixture = await _pump(tester);
      await fixture.begin();
      await tester.pumpAndSettle();
      final freshApi = _Network(
        pending: false,
        unknown: false,
        versionSupported: true,
      );
      final freshSession = AuthenticatedSession(
        profileId: 'nas',
        repository: freshApi,
        availableMethodNames: const {},
        version: '25.10.1',
        endpoint: _endpoint,
      );
      fixture.container.read(_sessionProvider.notifier).select(freshSession);
      await tester.pumpAndSettle();
      expect(find.textContaining('previous connection'), findsOneWidget);
      expect(
        tester.widget<FilledButton>(_key('network-keep-changes')).onPressed,
        isNull,
      );
      expect(
        tester.widget<OutlinedButton>(_key('network-revert-changes')).onPressed,
        isNull,
      );
      await _tap(tester, 'network-verify-reconnected');
      expect(freshApi.requests, isEmpty);
      expect(freshApi.keeps, 0);
      expect(freshApi.reverts, 0);
      expect(fixture.api.keeps, 0);
      expect(find.text('Current network state checked'), findsOneWidget);
      expect(find.text('Previous configuration restored'), findsNothing);
      expect(
        fixture.container.read(networkControllerProvider).unresolved,
        isFalse,
      );
    },
  );

  testWidgets(
    'mixed DHCP snapshot exposes existing static aliases in before review',
    (tester) async {
      final old = NetworkInterfaceSnapshot(
        id: 'eth0',
        name: 'eth0',
        type: 'PHYSICAL',
        description: 'Mixed',
        dhcp: true,
        ipv6Auto: false,
        mtu: 1500,
        aliases: const [NetworkAddress(address: '192.168.10.20', netmask: 24)],
      );
      final inventory = NetworkInventory(
        interfaces: [old],
        failoverLicensed: false,
        hasPendingChanges: false,
        checkinWaitingSeconds: null,
      );
      await tester.pumpWidget(
        MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: Scaffold(
            body: NetworkReviewDialog(
              serverLabel: _endpoint,
              original: old,
              request: NetworkChangeRequest(
                inventory: inventory,
                interfaceId: 'eth0',
                description: 'DHCP only',
                dhcp: true,
                ipv4Aliases: const [],
                mtu: 1500,
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('192.168.10.20/24'), findsOneWidget);
      expect(find.text('None · assigned by DHCP'), findsOneWidget);
      expect(
        find.textContaining(
          'Staging alone does not confirm rollback protection',
        ),
        findsOneWidget,
      );
    },
  );

  testWidgets('320px at 2x text supports scrolling, keyboard and review', (
    tester,
  ) async {
    await _pump(tester, width: 320, scale: 2);
    expect(tester.takeException(), isNull);
    await _openChangedEditor(tester);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pump();
    expect(tester.takeException(), isNull);
    tester.view.resetViewInsets();
    await _tap(tester, 'network-review-test');
    expect(find.byType(NetworkReviewDialog), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _reveal(tester, 'network-confirm-interface');
    await tester.enterText(_key('network-confirm-interface'), 'eth0');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}

Future<void> _openChangedEditor(WidgetTester tester) async {
  await _tap(tester, 'network-edit-eth0');
  await _reveal(tester, 'network-address-0');
  await tester.enterText(_key('network-address-0'), '192.168.10.21');
}

Future<void> _approve(WidgetTester tester) async {
  await _tap(tester, 'network-confirm-acknowledge');
  await _reveal(tester, 'network-confirm-interface');
  await tester.enterText(_key('network-confirm-interface'), 'eth0');
  await tester.pump();
  await _tap(tester, 'network-confirm-test');
}

Finder _key(String key) => find.byKey(ValueKey(key));
FilledButton _confirmButton(WidgetTester tester) =>
    tester.widget<FilledButton>(_key('network-confirm-test'));
Future<void> _tap(WidgetTester tester, String key) async {
  await _reveal(tester, key);
  await tester.tap(_key(key));
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, String key) async {
  if (_key(key).evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      _key(key),
      350,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(_key(key));
  await tester.pumpAndSettle();
}

final _sessionProvider = NotifierProvider<_Session, AuthenticatedSession?>(
  _Session.new,
);

class _Session extends Notifier<AuthenticatedSession?> {
  _Session([this.initial]);
  final AuthenticatedSession? initial;
  @override
  AuthenticatedSession? build() => initial;
  void select(AuthenticatedSession? session) => state = session;
}

Future<_Fixture> _pump(
  WidgetTester tester, {
  bool connected = true,
  String? endpoint = _endpoint,
  bool pending = false,
  bool unknown = false,
  bool versionSupported = true,
  double width = 800,
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  addTearDown(tester.view.resetViewInsets);
  final fixture = _Fixture(
    pending: pending,
    unknown: unknown,
    versionSupported: versionSupported,
    endpoint: endpoint,
  );
  final overrides = [
    _sessionProvider.overrideWith(
      () => _Session(connected ? fixture.session : null),
    ),
    dashboardActiveSessionProvider.overrideWith(
      (ref) => ref.watch(_sessionProvider),
    ),
    networkElapsedProvider.overrideWithValue(() => fixture.elapsed),
  ];
  await tester.pumpWidget(
    ProviderScope(
      overrides: overrides,
      child: MaterialApp(
        theme: TrueNavoTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: const NetworkPage(),
      ),
    ),
  );
  fixture.container = ProviderScope.containerOf(
    tester.element(find.byType(NetworkPage)),
  );
  await tester.pumpAndSettle();
  return fixture;
}

class _Fixture {
  _Fixture({
    required bool pending,
    required bool unknown,
    required bool versionSupported,
    required String? endpoint,
  }) : api = _Network(
         pending: pending,
         unknown: unknown,
         versionSupported: versionSupported,
       ) {
    session = AuthenticatedSession(
      profileId: 'nas',
      repository: api,
      availableMethodNames: const {},
      version: '25.10.1',
      endpoint: endpoint,
    );
  }
  final _Network api;
  late final AuthenticatedSession session;
  late final ProviderContainer container;
  Duration elapsed = Duration.zero;
  Future<void> begin() => container
      .read(networkControllerProvider.notifier)
      .begin(
        expectedSession: session,
        serverLabel: _endpoint,
        request: NetworkChangeRequest(
          inventory: api.inventory,
          interfaceId: 'eth0',
          description: 'Management',
          dhcp: false,
          ipv4Aliases: const [
            NetworkAddress(address: '192.168.10.21', netmask: 24),
          ],
          mtu: 1500,
        ),
      );
}

class _Network implements SessionRepository, AuthenticatedNetworkSession {
  _Network({
    required bool pending,
    required this.unknown,
    required this.versionSupported,
  }) : inventory = NetworkInventory(
         interfaces: [
           NetworkInterfaceSnapshot(
             id: 'eth0',
             name: 'eth0',
             type: 'PHYSICAL',
             description: 'Management',
             dhcp: false,
             ipv6Auto: false,
             mtu: 1500,
             aliases: const [
               NetworkAddress(address: '192.168.10.20', netmask: 24),
             ],
           ),
           NetworkInterfaceSnapshot(
             id: 'br0',
             name: 'br0',
             type: 'BRIDGE',
             description: 'VM bridge',
             dhcp: false,
             ipv6Auto: false,
             mtu: 1500,
             aliases: const [],
             blockedReason:
                 'Bridge interfaces require a topology-aware workflow.',
           ),
         ],
         failoverLicensed: false,
         hasPendingChanges: pending,
         checkinWaitingSeconds: null,
       );
  final NetworkInventory inventory;
  final bool unknown;
  final bool versionSupported;
  final requests = <NetworkChangeRequest>[];
  var inventoryReads = 0;
  var keeps = 0;
  var reverts = 0;
  @override
  NetworkCapabilities get networkCapabilities => NetworkCapabilities(
    connected: true,
    versionSupported: versionSupported,
    available: true,
  );
  @override
  Future<NetworkInventory> loadNetworkInventory() async {
    inventoryReads++;
    return inventory;
  }

  @override
  Future<NetworkChangeResult> beginNetworkTest(
    NetworkChangeRequest request,
  ) async {
    requests.add(request);
    final transaction = NetworkTransaction(
      interfaceId: request.interfaceId,
      original: inventory.interfaces.first,
      requested: request,
    );
    return NetworkChangeResult(
      phase: unknown ? NetworkChangePhase.unknown : NetworkChangePhase.testing,
      transaction: transaction,
      secondsRemaining: unknown ? null : 60,
    );
  }

  @override
  Future<NetworkChangeResult> checkNetworkTest(
    NetworkTransaction transaction,
  ) async => NetworkChangeResult(
    phase: unknown ? NetworkChangePhase.unknown : NetworkChangePhase.testing,
    transaction: transaction,
    secondsRemaining: unknown ? null : 50,
  );
  @override
  Future<NetworkChangeResult> keepNetworkTest(
    NetworkTransaction transaction,
  ) async {
    keeps++;
    return NetworkChangeResult(
      phase: NetworkChangePhase.kept,
      transaction: transaction,
    );
  }

  @override
  Future<NetworkChangeResult> revertNetworkTest(
    NetworkTransaction transaction,
  ) async {
    reverts++;
    return NetworkChangeResult(
      phase: NetworkChangePhase.reverted,
      transaction: transaction,
    );
  }

  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw StateError('Widget fixtures never open network connections');
}
