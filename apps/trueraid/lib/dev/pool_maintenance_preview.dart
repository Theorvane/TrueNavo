import 'package:truenas_api/truenas_api.dart';

/// Immutable connector-free samples; no pool scan, schedule change, job lookup,
/// key use, timer or transport is executed by this adapter.
mixin PoolMaintenancePreviewAdapter
    implements AuthenticatedPoolMaintenanceSession {
  static final _inventory = PoolMaintenanceInventory(
    endpoint: 'wss://nas-demo.example/api/current',
    timezone: 'Asia/Seoul',
    failoverLicensed: false,
    pools: [
      PoolMaintenancePool(
        id: 1,
        name: 'tank',
        guid: '1001',
        status: 'ONLINE',
        healthy: true,
        warning: false,
        scan: PoolMaintenanceScan(
          function: 'SCRUB',
          state: 'FINISHED',
          percentage: 100,
          errors: 0,
          startTime: DateTime.utc(2026, 9, 13, 1),
          endTime: DateTime.utc(2026, 9, 13, 3),
        ),
      ),
      PoolMaintenancePool(
        id: 2,
        name: 'archive',
        guid: '1002',
        status: 'ONLINE',
        healthy: true,
        warning: false,
        scan: PoolMaintenanceScan(
          function: 'SCRUB',
          state: 'CANCELED',
          percentage: 42.5,
          errors: 0,
          startTime: DateTime.utc(2026, 9, 12, 1),
          endTime: DateTime.utc(2026, 9, 12, 2),
        ),
      ),
      const PoolMaintenancePool(
        id: 3,
        name: 'backup',
        guid: '1003',
        status: 'ONLINE',
        healthy: true,
        warning: false,
      ),
    ],
    schedules: const [
      PoolScrubSchedule(
        id: 11,
        poolId: 1,
        poolName: 'tank',
        settings: PoolScrubScheduleSettings(
          description: 'Weekly eligibility check',
          cron: PoolScrubCron(hour: '2'),
        ),
      ),
      PoolScrubSchedule(
        id: 12,
        poolId: 2,
        poolName: 'archive',
        settings: PoolScrubScheduleSettings(
          description: 'Archive maintenance paused',
          enabled: false,
          threshold: 14,
          cron: PoolScrubCron(hour: '3', dow: '6'),
        ),
      ),
    ],
  );
  @override
  PoolMaintenanceCapabilities get poolMaintenanceCapabilities =>
      const PoolMaintenanceCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canScrub: true,
        canCreateSchedule: true,
        canUpdateSchedule: true,
        canDeleteSchedule: true,
      );
  @override
  Future<PoolMaintenanceInventory> loadPoolMaintenance() async => _inventory;
  @override
  Future<PoolMaintenanceReview> reviewPoolMaintenance(
    PoolMaintenanceRequest request,
  ) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      throw const PoolMaintenanceException(
        PoolMaintenanceExceptionReason.invalidRequest,
      );
    }
    return PoolMaintenanceReview(
      request: request,
      endpoint: _inventory.endpoint,
      warnings: const [
        'SAMPLE ONLY. No scrub, schedule update, job lookup or network request will occur.',
        'On a real server, scrub operations affect pool I/O; schedule changes affect future maintenance and do not stop an active scan.',
      ],
    );
  }

  @override
  Future<PoolMaintenanceResult> executePoolMaintenance(
    PoolMaintenanceReview review,
    String confirmation,
  ) async => const PoolMaintenanceResult(
    PoolMaintenanceOutcome.rejected,
    'Sample preview: no scrub or schedule request was sent.',
  );
  @override
  Future<PoolMaintenanceResult> checkPoolMaintenanceJob(
    PoolMaintenanceJob job,
  ) async => const PoolMaintenanceResult(
    PoolMaintenanceOutcome.rejected,
    'Sample preview: no job lookup or network request was made.',
  );
}
