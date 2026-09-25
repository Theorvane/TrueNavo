import 'package:truenas_api/truenas_api.dart';

/// Isolated synthetic adapter. There is no connector or mutation transport.
mixin ActivityPreviewAdapter implements AuthenticatedActivitySession {
  @override
  ActivityCapabilities get activityCapabilities => const ActivityCapabilities(
    supported: true,
    canReadJobs: true,
    canCancelJobs: true,
    canReadAudit: true,
  );
  @override
  Future<JobPage> loadActivityJobs(JobQuery query) async {
    final rows = [
      ActivityJob(
        id: 1042,
        method: 'pool.scrub.scrub',
        state: ActivityJobState.running,
        abortable: true,
        progressPercent: 64,
        startedAt: DateTime.utc(2026, 9, 12, 3, 12),
      ),
      ActivityJob(
        id: 1041,
        method: 'replication.run',
        state: ActivityJobState.success,
        abortable: false,
        progressPercent: 100,
        startedAt: DateTime.utc(2026, 9, 12, 2, 40),
        finishedAt: DateTime.utc(2026, 9, 12, 3, 8),
      ),
      ActivityJob(
        id: 1040,
        method: 'app.update',
        state: ActivityJobState.success,
        abortable: false,
        progressPercent: 100,
        startedAt: DateTime.utc(2026, 9, 12, 1, 55),
        finishedAt: DateTime.utc(2026, 9, 12, 1, 56),
      ),
      ActivityJob(
        id: 1039,
        method: 'cloudsync.sync',
        state: ActivityJobState.failed,
        abortable: false,
        startedAt: DateTime.utc(2026, 9, 12, 1, 30),
        finishedAt: DateTime.utc(2026, 9, 12, 1, 31),
      ),
    ];
    return JobPage(
      entries: query.page == 0
          ? rows
                .where(
                  (row) =>
                      (query.state == null || query.state == row.state) &&
                      (query.method.isEmpty || query.method == row.method),
                )
                .toList()
          : [],
      hasMore: false,
    );
  }

  @override
  Future<AuditPage> loadAuditEvents(AuditQuery query) async => AuditPage(
    entries: query.page == 0
        ? [
            for (var n = 0; n < 4; n++)
              if (query.success == null || query.success == (n != 3))
                AuditEvent(
                  id: 'sample-event-${n + 1}',
                  timestamp: query.until.subtract(Duration(minutes: n * 7 + 1)),
                  username: query.username.isEmpty
                      ? 'sample-operator'
                      : query.username,
                  address: '192.0.2.10',
                  service: query.service,
                  event: n == 0 ? 'AUTHENTICATION' : 'METHOD_CALL',
                  method: n == 0 || query.service != AuditService.middleware
                      ? null
                      : n == 1
                      ? 'pool.snapshot.create'
                      : 'app.update',
                  success: n != 3,
                ),
          ]
        : [],
    hasMore: false,
  );
  @override
  Future<JobCancelResult> cancelActivityJob(
    ActivityJob job,
    String confirmation,
  ) async => const JobCancelResult(
    JobCancelOutcome.rejected,
    'Sample preview never sends changes.',
  );
  @override
  Future<JobCancelResult> checkActivityCancellation(ActivityJob job) async =>
      const JobCancelResult(
        JobCancelOutcome.rejected,
        'Sample preview has no pending server job.',
      );
}
