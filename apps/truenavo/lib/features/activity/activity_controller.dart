import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final activitySessionProvider = Provider<AuthenticatedActivitySession?>((ref) {
  final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repository is AuthenticatedActivitySession
      ? repository as AuthenticatedActivitySession
      : null;
});
final activityJobsProvider = FutureProvider.autoDispose
    .family<JobPage, JobQuery>((ref, query) async {
      final api = ref.watch(activitySessionProvider);
      if (api == null) {
        throw const ActivityException(ActivityExceptionReason.disconnected);
      }
      return api.loadActivityJobs(query);
    }, retry: (_, _) => null);
final activityAuditProvider = FutureProvider.autoDispose
    .family<AuditPage, AuditQuery>((ref, query) async {
      final api = ref.watch(activitySessionProvider);
      if (api == null) {
        throw const ActivityException(ActivityExceptionReason.disconnected);
      }
      return api.loadAuditEvents(query);
    }, retry: (_, _) => null);

final class ActivityState {
  const ActivityState({this.busy = false, this.result, this.server, this.job});
  final bool busy;
  final JobCancelResult? result;
  final String? server;
  final ActivityJob? job;
  bool get pending => result?.outcome == JobCancelOutcome.pending;
  bool get unresolved => result?.outcome == JobCancelOutcome.unknown;
}

final activityControllerProvider =
    NotifierProvider<ActivityController, ActivityState>(ActivityController.new);

class ActivityController extends Notifier<ActivityState> {
  AuthenticatedSession? _operationSession;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  @override
  ActivityState build() {
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (_operationSession == null || identical(_operationSession, next)) {
        return;
      }
      _generation++;
      _release();
      if (state.busy || state.pending || state.unresolved) {
        state = ActivityState(
          server: state.server,
          job: state.job,
          result: const JobCancelResult(
            JobCancelOutcome.unknown,
            'The connection changed. Inspect the cancellation on the original server before making another change.',
          ),
        );
      } else {
        _operationSession = null;
        state = const ActivityState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const ActivityState();
  }

  Future<void> cancel(
    AuthenticatedSession expectedSession,
    ActivityJob job,
    String confirmation,
  ) async {
    if (state.busy || state.pending || state.unresolved) return;
    if (!identical(ref.read(dashboardActiveSessionProvider), expectedSession) ||
        expectedSession.endpoint == null ||
        expectedSession.repository is! AuthenticatedActivitySession ||
        confirmation != job.confirmation ||
        !job.canCancel) {
      state = const ActivityState(
        result: JobCancelResult(
          JobCancelOutcome.rejected,
          'Reload and confirm the job on the current server. Nothing was sent.',
        ),
      );
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const ActivityState(
        result: JobCancelResult(
          JobCancelOutcome.rejected,
          'Another server change is in progress.',
        ),
      );
      return;
    }
    _operationSession = expectedSession;
    await _run(
      job,
      () => (expectedSession.repository as AuthenticatedActivitySession)
          .cancelActivityJob(job, confirmation),
    );
  }

  Future<void> check() async {
    final session = _operationSession;
    final job = state.job;
    if (state.busy ||
        !state.pending ||
        session == null ||
        job == null ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    await _run(
      job,
      () => (session.repository as AuthenticatedActivitySession)
          .checkActivityCancellation(job),
    );
  }

  Future<void> _run(
    ActivityJob job,
    Future<JobCancelResult> Function() action,
  ) async {
    final generation = ++_generation;
    final previous = state.result;
    state = ActivityState(
      busy: true,
      job: job,
      server: _operationSession?.endpoint,
      result: previous,
    );
    JobCancelResult result;
    try {
      result = await action();
    } on ActivityException catch (error) {
      result = previous?.outcome == JobCancelOutcome.pending
          ? JobCancelResult(
              JobCancelOutcome.pending,
              error.userMessage,
              job: job,
            )
          : JobCancelResult(JobCancelOutcome.rejected, error.userMessage);
    } on Object {
      result = const JobCancelResult(
        JobCancelOutcome.unknown,
        'Cancellation could not be verified. Inspect the original server and reconnect; do not retry.',
      );
    }
    if (!ref.mounted || generation != _generation) return;
    state = ActivityState(
      result: result,
      job: job,
      server: _operationSession?.endpoint,
    );
    if (result.outcome == JobCancelOutcome.verified ||
        result.outcome == JobCancelOutcome.rejected) {
      _release();
    }
    ref.invalidate(activityJobsProvider);
  }

  bool get canAcknowledgeUnknown =>
      state.unresolved &&
      ref.read(dashboardActiveSessionProvider) != null &&
      !identical(_operationSession, ref.read(dashboardActiveSessionProvider));
  void acknowledgeUnknown() {
    if (!canAcknowledgeUnknown) return;
    _release();
    _operationSession = null;
    state = const ActivityState();
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
