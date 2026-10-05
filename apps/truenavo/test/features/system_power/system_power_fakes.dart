import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/system_power/system_power_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const powerEndpoint = 'wss://sample.example/api/current';
const powerHost =
    '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const powerCaps = SystemPowerCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  canReboot: true,
  canShutdown: true,
);
SystemPowerInventory powerInventory({
  String endpoint = powerEndpoint,
  String hostId = powerHost,
  bool ha = false,
  bool jobs = false,
  bool healthy = true,
  String state = 'READY',
  bool differentNext = false,
  bool empty = false,
  bool bootable = true,
}) => SystemPowerInventory(
  endpoint: endpoint,
  hostId: hostId,
  bootId: '12345678-1234-4234-8234-123456789abc',
  currentVersion: '25.10.1',
  state: state,
  failoverLicensed: ha,
  conflictingJob: jobs,
  bootPool: 'boot-pool',
  bootHealthy: healthy,
  environments: empty
      ? []
      : [
          BootEnvironmentSnapshot(
            id: '25.10.1',
            dataset: 'boot-pool/ROOT/25.10.1',
            created: '2026-09-01T10:00:00',
            usedBytes: 4096,
            active: true,
            activated: !differentNext,
            keep: true,
            canActivate: bootable,
          ),
          const BootEnvironmentSnapshot(
            id: '25.10.0',
            dataset: 'boot-pool/ROOT/25.10.0',
            created: '2026-08-01T10:00:00',
            usedBytes: 2048,
            active: false,
            activated: false,
            keep: true,
            canActivate: true,
          ),
          if (differentNext)
            const BootEnvironmentSnapshot(
              id: '25.10.2',
              dataset: 'boot-pool/ROOT/25.10.2',
              created: '2026-09-10T10:00:00',
              usedBytes: 4096,
              active: false,
              activated: true,
              keep: true,
              canActivate: true,
            ),
        ],
);
SystemPowerRequest powerRequest(
  SystemPowerInventory inventory, {
  SystemPowerAction action = SystemPowerAction.reboot,
  String reason = 'Planned maintenance',
}) => SystemPowerRequest(inventory: inventory, action: action, reason: reason);
SystemPowerReview powerReview(
  SystemPowerInventory inventory, {
  SystemPowerAction action = SystemPowerAction.reboot,
}) => SystemPowerReview(
  request: powerRequest(inventory, action: action),
  endpoint: inventory.endpoint,
  warnings: const ['Synthetic fixture. All clients lose access.'],
);

class PowerFake implements SessionRepository, AuthenticatedSystemPowerSession {
  PowerFake({SystemPowerInventory? inventory, this.caps = powerCaps})
    : inventory = inventory ?? powerInventory();
  SystemPowerInventory inventory;
  SystemPowerCapabilities caps;
  int reads = 0;
  final reviews = <SystemPowerRequest>[], writes = <SystemPowerReview>[];
  Future<SystemPowerInventory> Function()? onLoad;
  Future<SystemPowerReview> Function(SystemPowerRequest)? onReview;
  Future<SystemPowerResult> Function(SystemPowerReview)? onExecute;
  @override
  SystemPowerCapabilities get systemPowerCapabilities => caps;
  @override
  Future<SystemPowerInventory> loadSystemPower() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<SystemPowerReview> reviewSystemPower(
    SystemPowerRequest request,
  ) async {
    reviews.add(request);
    return onReview?.call(request) ??
        SystemPowerReview(
          request: request,
          endpoint: inventory.endpoint,
          warnings: const ['Synthetic fixture. All clients lose access.'],
        );
  }

  @override
  Future<SystemPowerResult> executeSystemPower(
    SystemPowerReview review,
    String confirmation,
  ) async {
    writes.add(review);
    return onExecute?.call(review) ??
        const SystemPowerResult(
          SystemPowerOutcome.rejected,
          'Synthetic rejection. No real server was contacted.',
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
  }) => throw UnsupportedError('No connector in power fixtures.');
}

class PowerHarness {
  PowerHarness({PowerFake? fake}) : api = fake ?? PowerFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final PowerFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({String? endpoint = powerEndpoint}) =>
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

  Future<void> load() => container.read(systemPowerInventoryProvider.future);
  void dispose() => container.dispose();
}
