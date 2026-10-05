import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/app_shell/adaptive_shell.dart';
import 'package:truenavo/features/apps/apps_page.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/connection/connection_screen.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_layout_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_page.dart';
import 'package:truenavo/features/dashboard/live_metrics_controller.dart';
import 'package:truenavo/features/offline_demo/offline_demo_screen.dart';
import 'package:truenavo/features/search/global_search.dart';
import 'package:truenavo/features/server_profiles/server_profile.dart';
import 'package:truenavo/features/server_profiles/server_profile_store.dart';
import 'package:truenavo/features/server_profiles/server_profiles_controller.dart';
import 'package:truenavo/features/tls_trust/tls_trust_providers.dart';
import 'package:truenavo/truenavo_app.dart';
import 'package:truenavo/sample/sample_backend.dart';
import 'package:truenas_api/truenas_api.dart';

const _realProfile = ServerProfile(
  id: 'existing-real-profile',
  displayName: 'My private NAS',
  originalHostInput: 'private.example',
  normalizedEndpoint: 'wss://private.example/api/current',
  lastKnownVersion: '25.10.1',
);

Future<void> _enterDemo(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('explore-offline-demo')));
  await tester.tap(find.byKey(const Key('explore-offline-demo')));
  await tester.pumpAndSettle();
}

ProviderContainer _demoContainer(WidgetTester tester) =>
    ProviderScope.containerOf(tester.element(find.byType(AdaptiveShell)));

void main() {
  test(
    'sample feed can close before subscribing without blocking resume',
    () async {
      final api = const SampleRepository() as AuthenticatedRealtimeSession;
      final feed = await api.openRealtimeFeed();
      await feed.close().timeout(const Duration(seconds: 1));
      expect(await feed.samples.toList(), isEmpty);
      await feed.close();
    },
  );

  testWidgets('no credentials, live stores or network are needed to explore', (
    tester,
  ) async {
    var liveBoundaryReads = 0;
    Never rejectLiveBoundary() {
      liveBoundaryReads++;
      throw StateError('Live boundary reached by demo');
    }

    final original = ServerProfileSnapshot(
      profiles: const [_realProfile],
      selectedProfileId: _realProfile.id,
    );
    final liveStore = MemoryServerProfileStore(initialSnapshot: original);
    final live = ProviderContainer(
      overrides: [
        serverProfileStoreProvider.overrideWithValue(liveStore),
        initialServerProfileSnapshotProvider.overrideWithValue(original),
        tlsTrustRouteProvider.overrideWithValue(
          TlsTrustRoute.platformValidated,
        ),
        credentialVaultProvider.overrideWith((_) => rejectLiveBoundary()),
        rpcConnectorProvider.overrideWith((_) => rejectLiveBoundary()),
        sessionRepositoryProvider.overrideWith((_) => rejectLiveBoundary()),
        dashboardLayoutStoreProvider.overrideWith((_) => rejectLiveBoundary()),
        nativeCertificateProbeProvider.overrideWith(
          (_) => rejectLiveBoundary(),
        ),
        pinStoreProvider.overrideWith((_) => rejectLiveBoundary()),
      ],
    );
    addTearDown(live.dispose);
    await tester.pumpWidget(
      UncontrolledProviderScope(container: live, child: const TrueNavoApp()),
    );
    await _enterDemo(tester);
    expect(find.text('OFFLINE DEMO · SAMPLE DATA'), findsOneWidget);
    expect(find.text('Atlas · Offline demo'), findsWidgets);
    expect(
      find.byKey(const Key('dashboard-performance-graphs')),
      findsOneWidget,
    );
    expect(find.byType(MaterialApp), findsOneWidget);
    expect(find.byType(ConnectionScreen), findsNothing);
    final demo = _demoContainer(tester);
    expect(identical(demo, live), isFalse);
    expect(
      demo.read(dashboardActiveSessionProvider)?.profileId,
      'offline-demo',
    );
    expect(demo.read(serverProfileStoreProvider), isNot(same(liveStore)));
    await demo
        .read(serverProfilesControllerProvider.notifier)
        .remove(offlineDemoProfile.id);
    await tester.pumpAndSettle();
    expect(demo.read(serverProfilesControllerProvider).profiles, isEmpty);
    expect(
      live.read(serverProfilesControllerProvider).selectedProfileId,
      _realProfile.id,
    );
    expect((await liveStore.load()).profiles.single, same(_realProfile));
    expect(liveBoundaryReads, 0);
    await tester.tap(find.byKey(const Key('exit-offline-demo')));
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionScreen), findsOneWidget);
    expect(find.byKey(const Key('offline-demo-banner')), findsNothing);
    await _enterDemo(tester);
    expect(
      _demoContainer(tester)
          .read(serverProfilesControllerProvider)
          .selectedProfileId,
      offlineDemoProfile.id,
    );
    expect(liveBoundaryReads, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
  });

  testWidgets('root search dialogs and pages retain the isolated demo scope', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: TrueNavoApp()));
    await _enterDemo(tester);
    final demo = _demoContainer(tester);
    await tester.tap(find.byKey(const Key('open-global-search')));
    await tester.pumpAndSettle();
    final dialogContext = tester.element(find.byType(GlobalSearchDialog));
    expect(ProviderScope.containerOf(dialogContext), same(demo));
    expect(find.byKey(const Key('offline-demo-banner')), findsOneWidget);
    Navigator.of(dialogContext, rootNavigator: true).pop();
    await tester.pumpAndSettle();
    expect(
      demo.read(liveMetricsControllerProvider).phase,
      LiveMetricsPhase.live,
    );
    Navigator.of(tester.element(find.byType(AdaptiveShell)))
        .push(MaterialPageRoute<void>(builder: (_) => const AppsPage()));
    await tester.pumpAndSettle();
    expect(
      ProviderScope.containerOf(tester.element(find.byType(AppsPage))),
      same(demo),
    );
    expect(find.text('sample-media'), findsWidgets);
    expect(find.byKey(const Key('exit-offline-demo')), findsOneWidget);
    await tester.tap(find.byKey(const Key('exit-offline-demo')));
    await tester.pumpAndSettle();
    expect(find.byType(ConnectionScreen), findsOneWidget);
    expect(find.byType(AppsPage), findsNothing);
  });

  testWidgets('demo cannot connect or save credentials even via connect form', (
    tester,
  ) async {
    await tester.pumpWidget(const ProviderScope(child: TrueNavoApp()));
    await _enterDemo(tester);
    final demo = _demoContainer(tester);
    expect(demo.read(credentialVaultProvider), isA<NoopCredentialVault>());
    await expectLater(
      demo
          .read(rpcConnectorProvider)
          .connect(Uri.parse('wss://private.example')),
      throwsUnsupportedError,
    );
    final disabled = throwsA(
      predicate<Object>(
        (error) => error.toString().contains('disabled in demo'),
      ),
    );
    expect(() => demo.read(nativeCertificateProbeProvider), disabled);
    expect(() => demo.read(pinnedRpcConnectorProvider), disabled);
    expect(() => demo.read(pinStoreProvider), disabled);
    Navigator.of(
      tester.element(find.byType(AdaptiveShell)),
    ).push(MaterialPageRoute<void>(builder: (_) => const ConnectionScreen()));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('server-url-field')),
      'https://private.example',
    );
    await tester.enterText(find.byKey(const Key('username-field')), 'test');
    await tester.enterText(find.byKey(const Key('api-key-field')), 'fake-key');
    await tester.ensureVisible(find.byKey(const Key('connect-button')));
    await tester.tap(find.byKey(const Key('connect-button')));
    await tester.pumpAndSettle();
    expect(demo.read(activeAuthenticatedSessionProvider), isNull);
    expect(
      demo.read(serverProfilesControllerProvider).profiles.single.id,
      offlineDemoProfile.id,
    );
    expect(find.byKey(const Key('offline-demo-banner')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'back from demo home exits; management never changes sample data',
    (tester) async {
      await tester.pumpWidget(const ProviderScope(child: TrueNavoApp()));
      await _enterDemo(tester);
      final repository = _demoContainer(tester)
          .read(dashboardActiveSessionProvider)!
          .repository;
      final apps = repository as AuthenticatedAppsSession;
      final before = await apps.loadAppsInventory();
      final result = await apps.changeAppState(
        before.apps.first,
        AppLifecycleAction.stop,
      );
      expect(result.outcome, AppOperationOutcome.rejected);
      expect((await apps.loadAppsInventory()).apps.first.state, 'RUNNING');
      expect(find.byType(DashboardPage), findsOneWidget);
      await Navigator.of(tester.element(find.byType(AdaptiveShell))).maybePop();
      await tester.pumpAndSettle();
      expect(find.byType(ConnectionScreen), findsOneWidget);
    },
  );

  for (final width in [390.0, 1000.0]) {
    testWidgets('demo banner and navigation fit ${width}px', (tester) async {
      await tester.binding.setSurfaceSize(Size(width, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(const ProviderScope(child: TrueNavoApp()));
      await _enterDemo(tester);
      expect(find.byKey(const Key('offline-demo-banner')), findsOneWidget);
      expect(find.byKey(const Key('exit-offline-demo')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }
}
