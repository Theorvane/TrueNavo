import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'server_operation_lock.dart';

enum ManagementPhase { idle, running, completed, failed, unknown }

final class ManagementState {
  const ManagementState({
    this.phase = ManagementPhase.idle,
    this.command,
    this.serverLabel,
    this.message,
    this.result,
  });

  final ManagementPhase phase;
  final ManagementCommand? command;
  final String? serverLabel;
  final String? message;
  final ManagementResult? result;
  bool get busy => phase == ManagementPhase.running;
}

/// Kept above routes so leaving a screen cannot permit duplicate submissions.
final managementControllerProvider =
    NotifierProvider<ManagementController, ManagementState>(
      ManagementController.new,
    );

final managementPollDelayProvider = Provider<Future<void> Function()>((ref) {
  return () => Future<void>.delayed(const Duration(seconds: 1));
});

class ManagementController extends Notifier<ManagementState> {
  @override
  ManagementState build() => const ManagementState();

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required String serverLabel,
    required ManagementCommand command,
  }) async {
    if (state.busy) return;
    if (!identical(ref.read(dashboardActiveSessionProvider), expectedSession)) {
      state = ManagementState(
        phase: ManagementPhase.failed,
        command: command,
        serverLabel: serverLabel,
        message: 'The server connection changed. Review the target again.',
      );
      return;
    }
    final repository = expectedSession.repository;
    if (repository is! AuthenticatedSessionManagement) {
      state = ManagementState(
        phase: ManagementPhase.failed,
        command: command,
        serverLabel: serverLabel,
        message: 'Management is unavailable on this connection.',
      );
      return;
    }
    final manager = repository as AuthenticatedSessionManagement;
    final operationLock = ref.read(serverOperationLockProvider);
    final lockOwner = operationLock.acquire();
    if (lockOwner == null) {
      state = ManagementState(
        phase: ManagementPhase.failed,
        command: command,
        serverLabel: serverLabel,
        message: 'Another server operation is still in progress.',
      );
      return;
    }
    state = ManagementState(
      phase: ManagementPhase.running,
      command: command,
      serverLabel: serverLabel,
      message: 'Sending once. Keep this target unchanged until it finishes.',
    );
    try {
      var result = await manager.execute(command);
      if (!ref.mounted) return;
      // Only poll a job returned by this exact operation. Never repeat a write.
      for (
        var attempt = 0;
        result is ManagementJobSubmitted && attempt < 30;
        attempt++
      ) {
        state = ManagementState(
          phase: ManagementPhase.running,
          command: command,
          serverLabel: serverLabel,
          result: result,
          message: 'Job #${result.jobId} accepted. Waiting for completion…',
        );
        await ref.read(managementPollDelayProvider)();
        if (!ref.mounted) return;
        if (!identical(
          ref.read(dashboardActiveSessionProvider),
          expectedSession,
        )) {
          state = ManagementState(
            phase: ManagementPhase.unknown,
            command: command,
            serverLabel: serverLabel,
            result: result,
            message:
                'Connection changed while the job was running. '
                'It may still finish on the original server. Check Jobs there '
                'before trying again.',
          );
          return;
        }
        result = await manager.pollJob(result);
        if (!ref.mounted) return;
      }
      state = ManagementState(
        phase: switch (result) {
          ManagementCompleted() => ManagementPhase.completed,
          ManagementFailed() => ManagementPhase.failed,
          _ => ManagementPhase.unknown,
        },
        command: command,
        serverLabel: serverLabel,
        result: result,
        message: result is ManagementJobSubmitted
            ? 'Job #${result.jobId} is still pending. Check Jobs on this '
                  'server before trying again. No command was resent.'
            : result.userMessage,
      );
      if (identical(
        ref.read(dashboardActiveSessionProvider),
        expectedSession,
      )) {
        for (final view in ['home', 'storage', 'workloads', 'jobs']) {
          ref.invalidate(dashboardLoadProvider(view));
        }
      }
    } on ManagementException catch (error) {
      if (!ref.mounted) return;
      final accepted = state.result is ManagementJobSubmitted;
      state = ManagementState(
        phase: accepted ? ManagementPhase.unknown : ManagementPhase.failed,
        command: command,
        serverLabel: serverLabel,
        result: state.result,
        message: accepted
            ? 'The accepted job could not be verified. Check it on the original '
                  'server before trying again. No command was resent.'
            : error.userMessage,
      );
    } catch (_) {
      if (!ref.mounted) return;
      state = ManagementState(
        phase: ManagementPhase.unknown,
        command: command,
        serverLabel: serverLabel,
        result: state.result,
        message:
            'The result could not be verified. Check the original server '
            'before trying again. No command was resent.',
      );
    } finally {
      operationLock.release(lockOwner);
    }
  }
}
