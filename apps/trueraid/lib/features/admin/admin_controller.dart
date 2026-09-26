import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final adminSessionProvider = Provider<AuthenticatedAdminSession?>((ref) {
  final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
  return switch (repository) {
    final AuthenticatedAdminSession admin => admin,
    _ => null,
  };
});

final adminPollDelayProvider = Provider<Future<void> Function()>((ref) {
  return () => Future<void>.delayed(const Duration(seconds: 1));
});

enum AdminPhase { idle, running, completed, failed, unknown }

final class AdminOperationState {
  const AdminOperationState({
    this.phase = AdminPhase.idle,
    this.operation,
    this.serverLabel,
    this.message,
    this.result,
    this.jobId,
  });
  final AdminPhase phase;
  final AdminOperationDefinition? operation;
  final String? serverLabel;
  final String? message;

  /// Gateway results contain redacted requests and bounded, sanitized values.
  final AdminResult? result;
  final int? jobId;
  bool get busy => phase == AdminPhase.running;
}

final adminControllerProvider =
    NotifierProvider<AdminController, AdminOperationState>(AdminController.new);

class AdminController extends Notifier<AdminOperationState> {
  AuthenticatedSession? _operationSession;
  AuthenticatedSession? get operationSession => _operationSession;
  @override
  AdminOperationState build() => const AdminOperationState();

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required AdminOperationDefinition operation,
    required AdminRequest request,
    required String serverLabel,
  }) async {
    if (state.busy) return;
    _operationSession = expectedSession;
    void fail(String message) {
      state = AdminOperationState(
        phase: AdminPhase.failed,
        operation: operation,
        serverLabel: serverLabel,
        message: message,
      );
    }

    if (!identical(ref.read(dashboardActiveSessionProvider), expectedSession)) {
      fail(
        'The server connection changed. Review the action on the selected server again.',
      );
      return;
    }
    if (!adminOperationDefinitions.any(
          (policy) => identical(policy, operation),
        ) ||
        request.method.name != operation.method ||
        operation.method == 'iscsi.global.update' ||
        operation.method == 'iscsi.portal.listen_ip_choices' ||
        operation.method == 'iscsi.portal.update' ||
        operation.method == 'iscsi.portal.delete' ||
        operation.method == 'iscsi.extent.get_instance' ||
        operation.method == 'iscsi.extent.update' ||
        operation.method == 'iscsi.target.validate_name' ||
        operation.method == 'iscsi.target.create' ||
        operation.method == 'iscsi.target.delete' ||
        operation.method == 'iscsi.target.update' ||
        operation.method == 'iscsi.target.get_instance' ||
        operation.method == 'iscsi.initiator.update' ||
        operation.method == 'iscsi.initiator.create' ||
        operation.method == 'iscsi.initiator.delete' ||
        operation.blockedReason != null) {
      fail('This action requires its dedicated workflow. Nothing was sent.');
      return;
    }
    final repository = expectedSession.repository;
    if (repository is! AuthenticatedAdminSession) {
      fail('Reconnect to load this server’s administration capabilities.');
      return;
    }
    final admin = repository as AuthenticatedAdminSession;
    final operationLock = ref.read(serverOperationLockProvider);
    final lockOwner = operationLock.acquire();
    if (lockOwner == null) {
      fail('Another server operation is still in progress.');
      return;
    }
    int? jobId;
    AdminResult? lastResult;
    state = AdminOperationState(
      phase: AdminPhase.running,
      operation: operation,
      serverLabel: serverLabel,
      message: operation.risk == AdminRisk.read
          ? 'Reading current server data…'
          : 'Submitting once. This operation will not be automatically retried.',
    );
    try {
      var result = await admin.invokeAdmin(request);
      if (!ref.mounted) return;
      lastResult = result;
      final watch = Stopwatch()..start();
      for (
        var attempt = 0;
        result is AdminJobSubmitted &&
            attempt < 30 &&
            watch.elapsed.inSeconds < 30;
        attempt++
      ) {
        jobId = result.jobId;
        state = AdminOperationState(
          phase: AdminPhase.running,
          operation: operation,
          serverLabel: serverLabel,
          result: result,
          jobId: jobId,
          message: 'Job #$jobId accepted. Checking its completion…',
        );
        await ref.read(adminPollDelayProvider)();
        if (!ref.mounted) return;
        if (!identical(
          ref.read(dashboardActiveSessionProvider),
          expectedSession,
        )) {
          state = AdminOperationState(
            phase: AdminPhase.unknown,
            operation: operation,
            serverLabel: serverLabel,
            result: result,
            jobId: jobId,
            message:
                'Connection changed. The accepted job may still be running '
                'on the original server. Verify it there before trying again.',
          );
          return;
        }
        result = await admin.pollAdminJob(result);
        if (!ref.mounted) return;
        lastResult = result;
      }
      jobId ??= switch (result) {
        AdminJobSubmitted(:final jobId) => jobId,
        AdminOutcomeUnknown(:final jobId) => jobId,
        _ => null,
      };
      state = AdminOperationState(
        phase: switch (result) {
          AdminCompleted() => AdminPhase.completed,
          AdminFailed() => AdminPhase.failed,
          _ => AdminPhase.unknown,
        },
        operation: operation,
        serverLabel: serverLabel,
        result: result,
        jobId: jobId,
        message: result is AdminJobSubmitted
            ? 'Job #$jobId is still pending. Check Jobs on the original server '
                  'before resubmitting. No command was resent.'
            : result.userMessage,
      );
      if (operation.risk != AdminRisk.read &&
          identical(
            ref.read(dashboardActiveSessionProvider),
            expectedSession,
          )) {
        for (final view in ['home', 'storage', 'workloads', 'alerts', 'jobs']) {
          ref.invalidate(dashboardLoadProvider(view));
        }
      }
    } on AdminException catch (error) {
      if (!ref.mounted) return;
      state = AdminOperationState(
        phase: jobId == null ? AdminPhase.failed : AdminPhase.unknown,
        operation: operation,
        serverLabel: serverLabel,
        result: lastResult,
        jobId: jobId,
        message: jobId == null
            ? error.userMessage
            : 'The accepted job could '
                  'not be verified. Check the original server before retrying.',
      );
    } catch (_) {
      if (!ref.mounted) return;
      state = AdminOperationState(
        phase: AdminPhase.unknown,
        operation: operation,
        serverLabel: serverLabel,
        result: lastResult,
        jobId: jobId,
        message:
            'The result could not be verified. Check the original server '
            'before trying again. No command was resent.',
      );
    } finally {
      operationLock.release(lockOwner);
    }
  }
}
