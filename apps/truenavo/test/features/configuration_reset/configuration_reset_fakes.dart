import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/configuration_reset/configuration_reset_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const resetEndpoint = 'wss://sample.example/api/current';
const resetHost =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const resetCaps = ConfigurationResetCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
);
ConfigurationResetInventory resetInventory({
  String endpoint = resetEndpoint,
  String hostId = resetHost,
  bool admin = true,
  bool ha = false,
  bool jobs = false,
  bool healthy = true,
  String state = 'READY',
  bool nextChanged = false,
}) => ConfigurationResetInventory(
  endpoint: endpoint,
  hostId: hostId,
  bootId: '12345678-1234-4234-8234-123456789abc',
  currentVersion: '25.10.1',
  state: state,
  fullAdmin: admin,
  failoverLicensed: ha,
  conflictingJob: jobs,
  bootPool: 'boot-pool',
  bootHealthy: healthy,
  environments: [
    BootEnvironmentSnapshot(
      id: '25.10.1',
      dataset: 'boot-pool/ROOT/25.10.1',
      created: '2026-09-01T10:00:00',
      usedBytes: 512,
      active: true,
      activated: !nextChanged,
      keep: true,
      canActivate: true,
    ),
    if (nextChanged)
      const BootEnvironmentSnapshot(
        id: '25.10.2',
        dataset: 'boot-pool/ROOT/25.10.2',
        created: '2026-09-10T10:00:00',
        usedBytes: 512,
        active: false,
        activated: true,
        keep: true,
        canActivate: true,
      ),
  ],
);

class ResetFake
    implements SessionRepository, AuthenticatedConfigurationResetSession {
  ResetFake({ConfigurationResetInventory? inventory, this.caps = resetCaps})
    : inventory = inventory ?? resetInventory();
  ConfigurationResetInventory inventory;
  ConfigurationResetCapabilities caps;
  int reads = 0, mutations = 0;
  final reviews = <ConfigurationResetRequest>[],
      executes = <ConfigurationResetReview>[];
  Future<ConfigurationResetInventory> Function()? onLoad;
  Future<ConfigurationResetReview> Function(ConfigurationResetRequest)?
  onReview;
  Future<ConfigurationResetResult> Function(
    ConfigurationResetReview,
    bool Function(),
  )?
  onExecute;
  @override
  ConfigurationResetCapabilities get configurationResetCapabilities => caps;
  @override
  Future<ConfigurationResetInventory> loadConfigurationReset() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<ConfigurationResetReview> reviewConfigurationReset(
    ConfigurationResetRequest request,
  ) async {
    reviews.add(request);
    return onReview?.call(request) ??
        ConfigurationResetReview(
          request: request,
          endpoint: inventory.endpoint,
          warnings: const [
            'Synthetic review only. Configuration reset replaces settings and schedules automatic reboot.',
          ],
        );
  }

  @override
  Future<ConfigurationResetResult> executeConfigurationReset(
    ConfigurationResetReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    executes.add(review);
    if (onExecute != null) return onExecute!(review, isCurrent);
    if (isCurrent()) mutations++;
    return const ConfigurationResetResult(
      ConfigurationResetOutcome.rejected,
      'Synthetic rejection. No real reset.',
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
  }) => throw UnsupportedError('No connector in reset fixtures.');
}

class ResetHarness {
  ResetHarness({ResetFake? fake}) : api = fake ?? ResetFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final ResetFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({String? endpoint = resetEndpoint}) =>
      AuthenticatedSession(
        profileId: 'sample',
        repository: api,
        availableMethodNames: const {},
        version: '25.10.1',
        endpoint: endpoint,
      );
  void select(AuthenticatedSession? next) {
    active = next;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  Future<void> load() =>
      container.read(configurationResetInventoryProvider.future);
  void dispose() => container.dispose();
}
