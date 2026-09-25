import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final bootEnvironmentsSessionProvider =
    Provider<AuthenticatedBootEnvironmentsSession?>((ref) {
      final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
      return repository is AuthenticatedBootEnvironmentsSession
          ? repository as AuthenticatedBootEnvironmentsSession
          : null;
    });

final bootEnvironmentsInventoryProvider =
    FutureProvider<BootEnvironmentInventory>((ref) async {
      // Watch the connection itself: a new session may reuse a repository.
      final session = ref.watch(dashboardActiveSessionProvider);
      final api = ref.watch(bootEnvironmentsSessionProvider);
      if (session?.endpoint == null || api == null) {
        throw StateError('A live connection is required.');
      }
      return api.loadBootEnvironments();
    });

final class BootEnvironmentsState {
  const BootEnvironmentsState({
    this.busy = false,
    this.result,
    this.server,
    this.target,
    this.action,
    this.connectionCurrent = true,
  });

  final bool busy, connectionCurrent;
  final BootEnvironmentResult? result;
  final String? server, target;
  final BootEnvironmentAction? action;
  bool get unknown => result?.outcome == BootEnvironmentOutcome.unknown;
  bool get locked => busy || unknown;
}

final bootEnvironmentsControllerProvider =
    NotifierProvider<BootEnvironmentsController, BootEnvironmentsState>(
      BootEnvironmentsController.new,
    );

class BootEnvironmentsController extends Notifier<BootEnvironmentsState> {
  AuthenticatedSession? _operationSession;
  ServerOperationLock? _lock;
  Object? _owner;
  var _generation = 0;

  @override
  BootEnvironmentsState build() {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _release();
      state = state.locked
          ? BootEnvironmentsState(
              server: state.server,
              target: state.target,
              action: state.action,
              connectionCurrent: false,
              result: const BootEnvironmentResult(
                outcome: BootEnvironmentOutcome.unknown,
                message:
                    'The connection changed before the outcome was verified. '
                    'Inspect boot environments on the original server before '
                    'making another change.',
              ),
            )
          : const BootEnvironmentsState();
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const BootEnvironmentsState();
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required BootEnvironmentReview review,
  }) async {
    if (state.locked) return;
    final request = review.request;
    if (expectedSession.endpoint == null ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      state = const BootEnvironmentsState(
        result: BootEnvironmentResult(
          outcome: BootEnvironmentOutcome.rejected,
          message:
              'The connection changed. Reload and review the change again.',
        ),
      );
      return;
    }
    final api = expectedSession.repository;
    if (api is! AuthenticatedBootEnvironmentsSession ||
        request.validationError != null) {
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const BootEnvironmentsState(
        result: BootEnvironmentResult(
          outcome: BootEnvironmentOutcome.rejected,
          message: 'Another server operation is in progress.',
        ),
      );
      return;
    }
    _operationSession = expectedSession;
    final generation = ++_generation;
    final target = request.targetName ?? request.snapshot.id;
    state = BootEnvironmentsState(
      busy: true,
      target: target,
      server: expectedSession.endpoint,
      action: request.action,
    );
    BootEnvironmentResult result;
    try {
      result = await (api as AuthenticatedBootEnvironmentsSession)
          .executeBootEnvironment(review);
    } on BootEnvironmentsException catch (error) {
      result = BootEnvironmentResult(
        outcome: BootEnvironmentOutcome.rejected,
        message: error.userMessage,
      );
    } on Object {
      result = const BootEnvironmentResult(
        outcome: BootEnvironmentOutcome.unknown,
        message:
            'The change could not be verified. Inspect boot environments on '
            'the original server before making another change.',
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    state = BootEnvironmentsState(
      result: result,
      server: expectedSession.endpoint,
      target: target,
      action: request.action,
    );
    if (!state.unknown) _release();
    ref.invalidate(bootEnvironmentsInventoryProvider);
  }

  bool get canAcknowledge {
    final session = ref.read(dashboardActiveSessionProvider);
    return state.unknown &&
        !state.connectionCurrent &&
        session?.endpoint != null &&
        session!.endpoint == state.server &&
        !identical(session, _operationSession);
  }

  /// Clears only the local warning after an explicit inspection acknowledgement.
  /// It never infers a server outcome, dispatches a command, or replays a review.
  void acknowledgeAfterReconnect() {
    if (!canAcknowledge) return;
    _release();
    state = const BootEnvironmentsState();
    ref.invalidate(bootEnvironmentsInventoryProvider);
  }

  void _release() {
    final owner = _owner;
    if (owner != null) _lock?.release(owner);
    _owner = null;
  }
}
