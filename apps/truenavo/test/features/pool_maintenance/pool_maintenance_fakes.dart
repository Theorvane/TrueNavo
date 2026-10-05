import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const pmEndpoint = 'wss://sample.example/api/current';
const pmCaps = PoolMaintenanceCapabilities(
  connected: true,
  versionSupported: true,
  available: true,
  canScrub: true,
  canCreateSchedule: true,
  canUpdateSchedule: true,
  canDeleteSchedule: true,
);
PoolMaintenanceInventory pmInventory({
  bool active = false,
  bool ha = false,
  bool empty = false,
  bool unhealthy = false,
  String function = 'SCRUB',
  double? percentage = 42.5,
  bool paused = false,
  bool unknownStart = false,
  bool jobs = false,
}) => PoolMaintenanceInventory(
  endpoint: pmEndpoint,
  timezone: 'Asia/Seoul',
  failoverLicensed: ha,
  pools: empty
      ? []
      : [
          PoolMaintenancePool(
            id: 1,
            name: 'tank',
            guid: '1001',
            status: unhealthy ? 'DEGRADED' : 'ONLINE',
            healthy: !unhealthy,
            warning: unhealthy,
            scan: PoolMaintenanceScan(
              function: function,
              state: active ? 'SCANNING' : 'FINISHED',
              percentage: percentage,
              errors: 0,
              startTime: unknownStart ? null : DateTime.utc(2026, 9, 14, 1),
              pauseTime: paused ? DateTime.utc(2026, 9, 14, 2) : null,
              remainingSeconds: active ? 3600 : 0,
            ),
          ),
          const PoolMaintenancePool(
            id: 2,
            name: 'archive',
            guid: '1002',
            status: 'ONLINE',
            healthy: true,
            warning: false,
          ),
        ],
  schedules: empty
      ? []
      : [
          const PoolScrubSchedule(
            id: 11,
            poolId: 1,
            poolName: 'tank',
            settings: PoolScrubScheduleSettings(
              description: 'Weekly pool scrub',
              cron: PoolScrubCron(hour: '2'),
            ),
          ),
        ],
  jobs: jobs
      ? [
          const PoolMaintenanceActiveJob(
            id: 75,
            method: 'cloudsync.sync',
            state: 'RUNNING',
          ),
        ]
      : [],
);
PoolMaintenanceRequest pmRequest(
  PoolMaintenanceInventory inventory, {
  PoolMaintenanceAction action = PoolMaintenanceAction.startScrub,
  int pool = 0,
}) => PoolMaintenanceRequest(
  inventory: inventory,
  action: action,
  pool: inventory.pools[pool],
);
PoolMaintenanceReview pmReview(
  PoolMaintenanceInventory inventory, {
  PoolMaintenanceAction action = PoolMaintenanceAction.startScrub,
  int pool = 0,
}) => PoolMaintenanceReview(
  request: pmRequest(inventory, action: action, pool: pool),
  endpoint: pmEndpoint,
  warnings: const [
    'Synthetic review: scrub work affects pool I/O.',
    'An accepted job is not a completed scrub.',
  ],
);
PoolMaintenanceJob pmJob({
  int id = 80,
  PoolMaintenanceAction action = PoolMaintenanceAction.startScrub,
  int poolId = 1,
}) => PoolMaintenanceJob(
  id: id,
  endpoint: pmEndpoint,
  poolId: poolId,
  poolName: poolId == 1 ? 'tank' : 'archive',
  poolGuid: poolId == 1 ? '1001' : '1002',
  action: action,
);

class PmFake implements SessionRepository, AuthenticatedPoolMaintenanceSession {
  PmFake({PoolMaintenanceInventory? inventory, this.caps = pmCaps})
    : inventory = inventory ?? pmInventory();
  PoolMaintenanceInventory inventory;
  PoolMaintenanceCapabilities caps;
  int reads = 0;
  final reviews = <PoolMaintenanceRequest>[],
      writes = <PoolMaintenanceReview>[],
      checks = <PoolMaintenanceJob>[];
  Future<PoolMaintenanceInventory> Function()? onLoad;
  Future<PoolMaintenanceReview> Function(PoolMaintenanceRequest)? onReview;
  Future<PoolMaintenanceResult> Function(PoolMaintenanceReview)? onExecute;
  Future<PoolMaintenanceResult> Function(PoolMaintenanceJob)? onCheck;
  @override
  PoolMaintenanceCapabilities get poolMaintenanceCapabilities => caps;
  @override
  Future<PoolMaintenanceInventory> loadPoolMaintenance() async {
    reads++;
    return onLoad?.call() ?? inventory;
  }

  @override
  Future<PoolMaintenanceReview> reviewPoolMaintenance(
    PoolMaintenanceRequest request,
  ) async {
    reviews.add(request);
    return onReview?.call(request) ??
        PoolMaintenanceReview(
          request: request,
          endpoint: pmEndpoint,
          warnings: const ['Synthetic maintenance review. Confirm once only.'],
        );
  }

  @override
  Future<PoolMaintenanceResult> executePoolMaintenance(
    PoolMaintenanceReview review,
    String confirmation,
  ) async {
    writes.add(review);
    return onExecute?.call(review) ??
        const PoolMaintenanceResult(
          PoolMaintenanceOutcome.succeeded,
          'Synthetic configuration observed; no server was contacted.',
        );
  }

  @override
  Future<PoolMaintenanceResult> checkPoolMaintenanceJob(
    PoolMaintenanceJob job,
  ) async {
    checks.add(job);
    return onCheck?.call(job) ??
        const PoolMaintenanceResult(
          PoolMaintenanceOutcome.succeeded,
          'Synthetic owned job verified.',
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
  }) => throw UnsupportedError('No connector in fixtures.');
}

class PmHarness {
  PmHarness({PmFake? fake}) : api = fake ?? PmFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [dashboardActiveSessionProvider.overrideWith((ref) => active)],
    );
  }
  final PmFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({String? endpoint = pmEndpoint}) =>
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

  void dispose() => container.dispose();
}
