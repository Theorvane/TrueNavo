// Connector-free fixtures shared by offline demo and development preview.
import 'package:truenas_api/truenas_api.dart';

/// Static connector-free fixtures. Review is presentational; execute always
/// rejects. No instance state prevents use in a const preview repository.
mixin SnapshotSchedulesPreviewAdapter
    implements AuthenticatedSnapshotSchedulesSession {
  static const _datasets = [
    SnapshotScheduleDataset(id: 'tank/media', guid: '1001', kind: 'FILESYSTEM'),
    SnapshotScheduleDataset(
      id: 'tank/media/cache',
      guid: '1002',
      kind: 'FILESYSTEM',
    ),
    SnapshotScheduleDataset(
      id: 'tank/backups',
      guid: '1003',
      kind: 'FILESYSTEM',
    ),
    SnapshotScheduleDataset(
      id: 'tank/private',
      guid: '1004',
      kind: 'FILESYSTEM',
      blockedReason: 'Sample locked dataset is unavailable.',
    ),
  ];
  static final _inventory = SnapshotScheduleInventory(
    timezone: 'Asia/Seoul',
    datasets: _datasets,
    tasks: const [
      SnapshotScheduleTask(
        id: 1,
        state: 'FINISHED',
        settings: SnapshotScheduleSettings(
          dataset: 'tank/media',
          recursive: true,
          exclude: ['tank/media/cache'],
          cron: SnapshotScheduleCron(hour: '2'),
          lifetimeValue: 2,
          lifetimeUnit: 'WEEK',
        ),
      ),
      SnapshotScheduleTask(
        id: 2,
        state: 'ERROR',
        settings: SnapshotScheduleSettings(
          dataset: 'tank/backups',
          cron: SnapshotScheduleCron(hour: '3', dow: '7'),
          lifetimeValue: 3,
          lifetimeUnit: 'MONTH',
        ),
      ),
      SnapshotScheduleTask(
        id: 3,
        state: 'PENDING',
        settings: SnapshotScheduleSettings(
          dataset: 'tank/media',
          enabled: false,
          cron: SnapshotScheduleCron(hour: '9', dow: '1-5'),
          lifetimeValue: 7,
          lifetimeUnit: 'DAY',
          namingSchema: 'workday-%Y-%m-%d_%H-%M',
        ),
      ),
    ],
  );
  @override
  SnapshotSchedulesCapabilities get snapshotSchedulesCapabilities =>
      SnapshotSchedulesCapabilities(
        connected: true,
        versionSupported: true,
        methods: const {
          'pool.snapshottask.query',
          'pool.dataset.query',
          'pool.filesystem_choices',
          'pool.snapshot.query',
          'replication.query',
          'vmware.query',
          'system.general.config',
          'pool.snapshottask.create',
          'pool.snapshottask.update',
          'pool.snapshottask.delete',
          'pool.snapshottask.run',
          'pool.snapshottask.update_will_change_retention_for',
          'pool.snapshottask.delete_will_change_retention_for',
        },
      );
  @override
  Future<SnapshotScheduleInventory> loadSnapshotSchedules() async => _inventory;
  @override
  Future<SnapshotScheduleReview> reviewSnapshotSchedule(
    SnapshotScheduleRequest request,
  ) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      throw const SnapshotSchedulesException(
        SnapshotSchedulesExceptionReason.invalid,
      );
    }
    final settings = request.settings ?? request.task!.settings;
    return SnapshotScheduleReview(
      action: request.action,
      target: request.target,
      identity: 'Synthetic preview review',
      changes: [
        '${request.action.name}: ${request.target}',
        'Dataset: ${settings.dataset}; recursive: ${settings.recursive}; exclusions: ${settings.exclude.join(', ')}',
        'Retention: ${settings.lifetimeValue} ${settings.lifetimeUnit}; enabled: ${settings.enabled}',
      ],
      warnings: [
        'SAMPLE ONLY. This preview cannot submit schedule changes or run snapshots.',
        if (request.action == SnapshotScheduleAction.delete ||
            request.action == SnapshotScheduleAction.update)
          'Existing snapshots may have different future expiry eligibility after a real schedule change. No private retention-fixation job is launched.',
      ],
      affectedSnapshots:
          request.action == SnapshotScheduleAction.delete ||
              request.action == SnapshotScheduleAction.update
          ? ['${settings.dataset}@auto-2026-09-12_02-00']
          : const [],
    );
  }

  @override
  Future<SnapshotScheduleResult> executeSnapshotSchedule(
    SnapshotScheduleReview review,
    String confirmation,
  ) async => const SnapshotScheduleResult(
    SnapshotScheduleOutcome.rejected,
    'Sample preview: no schedule or snapshot request was sent.',
  );
}
