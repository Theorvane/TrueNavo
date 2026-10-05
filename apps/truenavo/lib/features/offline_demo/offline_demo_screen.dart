import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../../app_shell/adaptive_shell.dart';
import '../../sample/configuration_backup_preview.dart';
import '../../sample/configuration_restore_preview.dart';
import '../../sample/sample_backend.dart';
import '../configuration_backup/configuration_backup_file.dart';
import '../configuration_restore/configuration_restore_file.dart';
import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../dashboard/dashboard_layout_controller.dart';
import '../dashboard/dashboard_layout_store.dart';
import '../search/global_search.dart';
import '../server_profiles/server_profile.dart';
import '../server_profiles/server_profile_store.dart';
import '../server_profiles/server_profiles_controller.dart';
import '../tls_trust/tls_trust_providers.dart';
import 'offline_demo_mode.dart';

const offlineDemoProfile = ServerProfile(
  id: 'offline-demo',
  displayName: 'Atlas · Offline demo',
  originalHostInput: 'nas-demo.example',
  normalizedEndpoint: 'wss://nas-demo.example/api/current',
  lastKnownVersion: '25.10.1',
);

/// A release-available, opt-in sample workspace, never a login bypass.
/// Its independent container cannot inherit the live app's repository, vault,
/// database, selected profiles or certificate probes. No host is contacted.
class OfflineDemoScreen extends StatefulWidget {
  const OfflineDemoScreen({required this.onExit, super.key});
  final VoidCallback onExit;

  @override
  State<OfflineDemoScreen> createState() => _OfflineDemoScreenState();
}

class _OfflineDemoScreenState extends State<OfflineDemoScreen> {
  late final ProviderContainer _container;

  @override
  void initState() {
    super.initState();
    const repository = SampleRepository();
    const session = AuthenticatedSession(
      profileId: 'offline-demo',
      repository: repository,
      availableMethodNames: sampleMethodNames,
      version: '25.10.1',
      endpoint: 'wss://nas-demo.example/api/current',
    );
    final snapshot = ServerProfileSnapshot(
      profiles: const [offlineDemoProfile],
      selectedProfileId: offlineDemoProfile.id,
    );
    _container = ProviderContainer(
      // Deliberately no parent: overrides in a nested live scope are unsafe
      // for unrelated providers that might retain a real connection or store.
      overrides: [
        offlineDemoModeProvider.overrideWithValue(true),
        serverProfileStoreProvider.overrideWithValue(
          MemoryServerProfileStore(initialSnapshot: snapshot),
        ),
        initialServerProfileSnapshotProvider.overrideWithValue(snapshot),
        dashboardActiveSessionProvider.overrideWith((ref) {
          final selected = ref
              .watch(serverProfilesControllerProvider)
              .selectedProfileId;
          return selected == offlineDemoProfile.id ? session : null;
        }),
        credentialVaultProvider.overrideWithValue(const NoopCredentialVault()),
        rpcConnectorProvider.overrideWithValue(const DisabledSampleConnector()),
        sessionRepositoryFactoryProvider.overrideWithValue(
          ({required connector, required credentialVault}) => repository,
        ),
        // Even an accidental native-trust path cannot create an OS backend.
        tlsTrustRouteProvider.overrideWithValue(
          TlsTrustRoute.platformValidated,
        ),
        nativeCertificateProbeProvider.overrideWith(
          (_) => throw StateError('Certificate probes are disabled in demo.'),
        ),
        pinnedRpcConnectorProvider.overrideWith(
          (_) => throw StateError('Pinned connections are disabled in demo.'),
        ),
        pinStoreProvider.overrideWith(
          (_) => throw StateError('Certificate storage is disabled in demo.'),
        ),
        dashboardLayoutStoreProvider.overrideWithValue(
          MemoryDashboardLayoutStore(),
        ),
        configurationRestoreFilePickerProvider.overrideWithValue(
          const ConfigurationRestorePreviewFilePicker(),
        ),
        configurationBackupFileSaverProvider.overrideWithValue(
          const ConfigurationBackupPreviewFileSaver(),
        ),
      ],
    );
  }

  @override
  void dispose() {
    _container.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UncontrolledProviderScope(
    container: _container,
    child: GlobalSearchHost(
      builder: (navigatorKey, observer) => MaterialApp(
        navigatorKey: navigatorKey,
        navigatorObservers: [observer],
        title: 'TrueNavo · Offline demo',
        debugShowCheckedModeBanner: false,
        theme: TrueNavoTheme.light(),
        darkTheme: TrueNavoTheme.dark(),
        themeMode: ThemeMode.system,
        builder: (context, child) => LayoutBuilder(
          builder: (context, constraints) {
            final density = TrueNavoDensity.resolve(constraints.maxWidth);
            final highContrast = MediaQuery.highContrastOf(context);
            final dark = Theme.of(context).brightness == Brightness.dark;
            return Theme(
              data: dark
                  ? TrueNavoTheme.dark(
                      density: density,
                      highContrast: highContrast,
                    )
                  : TrueNavoTheme.light(
                      density: density,
                      highContrast: highContrast,
                    ),
              child: _DemoChrome(onExit: widget.onExit, child: child!),
            );
          },
        ),
        home: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) widget.onExit();
          },
          child: const AdaptiveShell(),
        ),
      ),
    ),
  );
}

/// Outside the demo navigator so every page and dialog keeps the disclosure
/// and the exit action. Exiting destroys all sample state, not real profiles.
class _DemoChrome extends StatelessWidget {
  const _DemoChrome({required this.onExit, required this.child});
  final VoidCallback onExit;
  final Widget child;

  @override
  Widget build(BuildContext context) => Material(
    child: SafeArea(
      bottom: false,
      child: Column(
        children: [
          Container(
            key: const Key('offline-demo-banner'),
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            color: context.tdTheme.statusWarning,
            child: DefaultTextStyle(
              style: TdTypography.body.copyWith(color: Colors.black),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Wrap(
                    spacing: 16,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const Text('OFFLINE DEMO · SAMPLE DATA'),
                      TextButton.icon(
                        key: const Key('exit-offline-demo'),
                        style: TextButton.styleFrom(
                          foregroundColor: Colors.black,
                        ),
                        onPressed: onExit,
                        icon: const Icon(Icons.close),
                        label: const Text('Exit demo'),
                      ),
                    ],
                  ),
                  const Text('No server connection. Changes are not applied.'),
                ],
              ),
            ),
          ),
          Expanded(child: child),
        ],
      ),
    ),
  );
}
