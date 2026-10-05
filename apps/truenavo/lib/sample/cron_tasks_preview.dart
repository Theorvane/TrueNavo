// Connector-free fixtures shared by offline demo and development preview.
import 'package:truenas_api/truenas_api.dart';

import 'scheduled_tasks_preview_readiness.dart';

/// Configuration-only fixture. No stored command bodies or scheduler exist.
mixin CronTasksPreviewAdapter implements AuthenticatedCronTasksSession {
  static final _inventory = CronTasksInventory(
    readiness: scheduledTasksPreviewReadiness,
    timezone: 'Asia/Seoul',
    directoryConfigured: false,
    users: const [
      CronTaskUser(id: 1, uid: 0, username: 'root'),
      CronTaskUser(id: 20, uid: 1000, username: 'operator'),
    ],
    tasks: const [
      CronTaskSnapshot(
        id: 11,
        enabled: true,
        settings: CronTaskSettings(
          user: 'operator',
          description: 'Sample daily task',
          schedule: CronTaskSchedule(),
          hideStdout: true,
          hideStderr: false,
        ),
      ),
      CronTaskSnapshot(
        id: 12,
        enabled: true,
        settings: CronTaskSettings(
          user: 'root',
          description: 'Sample weekly task',
          schedule: CronTaskSchedule(hour: '3', dow: '0'),
          hideStdout: true,
          hideStderr: true,
        ),
      ),
      CronTaskSnapshot(
        id: 13,
        enabled: false,
        settings: CronTaskSettings(
          user: 'operator',
          description: 'Sample disabled task',
          schedule: CronTaskSchedule(minute: '30', hour: '4'),
          hideStdout: false,
          hideStderr: false,
        ),
      ),
      CronTaskSnapshot(
        id: 14,
        enabled: false,
        settings: CronTaskSettings(
          user: 'root',
          description: 'Sample monthly task',
          schedule: CronTaskSchedule(dom: '1'),
          hideStdout: true,
          hideStderr: true,
        ),
      ),
    ],
  );
  @override
  CronTasksCapabilities get cronTasksCapabilities =>
      const CronTasksCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canCreate: true,
        canUpdate: true,
        canDelete: true,
      );
  @override
  Future<CronTasksInventory> loadCronTasks() async => _inventory;
  @override
  Future<CronTasksReview> reviewCronTasks(CronTasksRequest request) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      request.command?.dispose();
      throw const CronTasksException(CronTasksExceptionReason.invalidRequest);
    }
    return CronTasksReview(
      request: request,
      endpoint: _inventory.endpoint,
      warnings: const [
        'SAMPLE ONLY. No command is stored or executed, and no scheduler configuration is changed.',
        'Real enablement permits commands with the selected user authority. Cron regeneration affects the complete configured scheduler.',
        'Counts show configured tasks, not completion, next-run guarantees or successful delivery.',
      ],
    );
  }

  @override
  Future<CronTasksResult> executeCronTasks(
    CronTasksReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    review.request.command?.dispose();
    return const CronTasksResult(
      CronTasksOutcome.rejected,
      'Sample preview: no cron task, command, scheduler or email was changed or executed.',
    );
  }
}
