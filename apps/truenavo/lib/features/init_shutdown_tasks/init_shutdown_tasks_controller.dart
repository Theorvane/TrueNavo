import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final initShutdownTasksSessionProvider =
    Provider<AuthenticatedInitShutdownTasksSession?>((ref) {
      final repo = ref.watch(dashboardActiveSessionProvider)?.repository;
      return repo is AuthenticatedInitShutdownTasksSession
          ? repo as AuthenticatedInitShutdownTasksSession
          : null;
    });
final initShutdownTasksInventoryProvider =
    FutureProvider<InitShutdownTasksInventory>((ref) async {
      final session = ref.watch(dashboardActiveSessionProvider),
          api = ref.watch(initShutdownTasksSessionProvider);
      if (session?.endpoint == null ||
          api == null ||
          ref.read(initShutdownTasksControllerProvider).locked) {
        throw StateError('Init/shutdown task configuration is unavailable.');
      }
      final inventory = await api.loadInitShutdownTasks();
      if (!ref.mounted ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          inventory.endpoint != session!.endpoint) {
        throw StateError('Init/shutdown task connection changed.');
      }
      return inventory;
    }, retry: (_, _) => null);

enum InitShutdownTasksStatus {
  idle,
  reviewing,
  executing,
  completed,
  rejected,
  unknown,
}

final class InitShutdownTasksState {
  const InitShutdownTasksState({
    this.status = InitShutdownTasksStatus.idle,
    this.message,
    this.server,
    this.hostId,
    this.connectionCurrent = true,
    this.verifying = false,
    this.hostVerified = false,
    this.verificationMessage,
  });
  final InitShutdownTasksStatus status;
  final String? message, server, hostId, verificationMessage;
  final bool connectionCurrent, verifying, hostVerified;
  bool get busy =>
      status == InitShutdownTasksStatus.reviewing ||
      status == InitShutdownTasksStatus.executing;
  bool get unresolved => status == InitShutdownTasksStatus.unknown;
  bool get locked => status == InitShutdownTasksStatus.executing || unresolved;
  InitShutdownTasksState verification({
    bool verifying = false,
    bool verified = false,
    String? message,
  }) => InitShutdownTasksState(
    status: status,
    message: this.message,
    server: server,
    hostId: hostId,
    connectionCurrent: connectionCurrent,
    verifying: verifying,
    hostVerified: verified,
    verificationMessage: message,
  );
}

final initShutdownTasksControllerProvider =
    NotifierProvider<InitShutdownTasksController, InitShutdownTasksState>(
      InitShutdownTasksController.new,
    );

class InitShutdownTasksController extends Notifier<InitShutdownTasksState> {
  AuthenticatedSession? _reviewSession, _operationSession, _verifiedSession;
  InitShutdownTaskCommand? _command;
  void _discardCommand() {
    _command?.dispose();
    _command = null;
  }

  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0, _verificationGeneration = 0;
  bool _pending = false;
  final _issued = Expando<int>(), _used = Expando<bool>();
  bool isReviewCurrent(InitShutdownTasksReview review) =>
      _issued[review] == _generation && _used[review] != true;
  bool get _active =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  bool _route(bool Function() check) {
    try {
      return check();
    } on Object {
      return false;
    }
  }

  @override
  InitShutdownTasksState build() {
    final lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) expireContext();
      },
    );
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      expireContext();
      if (state.unresolved) {
        state = InitShutdownTasksState(
          status: InitShutdownTasksStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          connectionCurrent: identical(_operationSession, next),
          message: 'The connection changed after an unverified init/shutdown task write. Inspect the original server independently. No operation is replayed; task headers do not prove successful execution.',
        );
      }
    });
    ref.onDispose(() {
      _generation++;
      _verificationGeneration++;
      lifecycle.dispose();
      _discardCommand();
      _release();
    });
    return const InitShutdownTasksState();
  }

  InitShutdownTasksState _expiredState() => state.locked || _pending
      ? InitShutdownTasksState(
          status: InitShutdownTasksStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          connectionCurrent: state.connectionCurrent,
          message: 'Init/shutdown task authorization expired. A submitted write or root task execution may already have occurred. Independently inspect the original server; do not repeat the request.',
        )
      : const InitShutdownTasksState(
          status: InitShutdownTasksStatus.rejected,
          message: 'The init/shutdown task review expired. Reload and review again. Nothing is sent automatically.',
        );
  void expireContext() {
    if (!ref.mounted) return;
    _generation++;
    _verificationGeneration++;
    _verifiedSession = null;
    _reviewSession = null;
    _discardCommand();
    state = _expiredState();
  }

  /// A consumed or expired review never reuses the pre-change inventory.
  /// This is a user-triggered read, not a post-write retry or polling loop.
  void refreshConfiguration() {
    if (!ref.mounted || state.busy || state.locked) return;
    _generation++;
    _verificationGeneration++;
    _reviewSession = null;
    _verifiedSession = null;
    _discardCommand();
    state = const InitShutdownTasksState();
    ref.invalidate(initShutdownTasksInventoryProvider);
  }

  void abandonRoute() {
    if (!ref.mounted) return;
    final generation = ++_generation;
    _verificationGeneration++;
    _verifiedSession = null;
    _reviewSession = null;
    _discardCommand();
    final next = _expiredState();
    scheduleMicrotask(() {
      if (ref.mounted && generation == _generation) state = next;
    });
  }

  Future<InitShutdownTasksReview?> review({
    required AuthenticatedSession expectedSession,
    required InitShutdownTasksRequest request,
    required bool Function() isRouteCurrent,
  }) async {
    final snapshot = ref.read(initShutdownTasksInventoryProvider),
        api = expectedSession.repository;
    if (state.busy ||
        state.locked ||
        !_active ||
        !_route(isRouteCurrent) ||
        snapshot.isLoading ||
        !identical(snapshot.asData?.value, request.inventory) ||
        request.inventory.endpoint != expectedSession.endpoint ||
        request.validationError != null ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        api is! AuthenticatedInitShutdownTasksSession ||
        !(api as AuthenticatedInitShutdownTasksSession)
            .initShutdownTasksCapabilities
            .supports(request.action)) {
      if (!identical(request.command, _command)) {
        request.command?.dispose();
      }
      return null;
    }
    _discardCommand();
    _command = request.command;
    final generation = ++_generation;
    _reviewSession = expectedSession;
    state = const InitShutdownTasksState(
      status: InitShutdownTasksStatus.reviewing,
      message: 'Reviewing configuration and write readiness. No task write or execution has started.',
    );
    try {
      final review = await (api as AuthenticatedInitShutdownTasksSession)
          .reviewInitShutdownTasks(request);
      if (!ref.mounted || generation != _generation) {
        request.command?.dispose();
        return null;
      }
      final current = ref.read(initShutdownTasksInventoryProvider);
      if (!_active ||
          !_route(isRouteCurrent) ||
          !identical(
            expectedSession,
            ref.read(dashboardActiveSessionProvider),
          ) ||
          current.isLoading ||
          !identical(current.asData?.value, request.inventory)) {
        expireContext();
        return null;
      }
      if (!identical(review.request, request) ||
          review.endpoint != expectedSession.endpoint ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(review.commandReference)) {
        throw StateError('Mismatched init/shutdown task review.');
      }
      _issued[review] = generation;
      state = const InitShutdownTasksState();
      return review;
    } on Object {
      _discardCommand();
      if (ref.mounted && generation == _generation) {
        _generation++;
        _reviewSession = null;
        state = const InitShutdownTasksState(
          status: InitShutdownTasksStatus.rejected,
          message: 'Init/shutdown task review could not be verified. Remote details were withheld. Reload before a new review.',
        );
      }
      return null;
    }
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required InitShutdownTasksReview review,
    required String confirmation,
    required bool configurationImpactAccepted,
    required bool rootExecutionAccepted,
    required bool independentlyInspectedCommand,
    required bool noCancellationAccepted,
    required bool waitBudgetRiskAccepted,
    required bool Function() isRouteCurrent,
  }) async {
    if (state.locked || state.busy || !isReviewCurrent(review)) return;
    final snapshot = ref.read(initShutdownTasksInventoryProvider),
        api = expectedSession.repository;
    final action = review.request.action;
    final enabling = action == InitShutdownTasksAction.enable;
    final stopping =
        action == InitShutdownTasksAction.disable ||
        action == InitShutdownTasksAction.delete;
    if (!_active ||
        !_route(isRouteCurrent) ||
        !configurationImpactAccepted ||
        enabling &&
            (!rootExecutionAccepted ||
                !independentlyInspectedCommand ||
                !waitBudgetRiskAccepted) ||
        stopping && !noCancellationAccepted ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        review.request.validationError != null ||
        snapshot.isLoading ||
        !identical(snapshot.asData?.value, review.request.inventory) ||
        !identical(_reviewSession, expectedSession) ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        api is! AuthenticatedInitShutdownTasksSession ||
        !(api as AuthenticatedInitShutdownTasksSession)
            .initShutdownTasksCapabilities
            .supports(action)) {
      _used[review] = true;
      _generation++;
      _reviewSession = null;
      _discardCommand();
      state = const InitShutdownTasksState(
        status: InitShutdownTasksStatus.rejected,
        message: 'Task submission authorization was rejected. Enter a fresh command and review again; no write was sent.',
      );
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      _used[review] = true;
      _generation++;
      _reviewSession = null;
      _discardCommand();
      state = const InitShutdownTasksState(
        status: InitShutdownTasksStatus.rejected,
        message: 'Another management operation is unresolved. No init/shutdown task write was sent.',
      );
      return;
    }
    _used[review] = true;
    _pending = true;
    _operationSession = expectedSession;
    final generation = ++_generation,
        server = expectedSession.endpoint,
        hostId = review.request.inventory.hostId;
    state = InitShutdownTasksState(
      status: InitShutdownTasksStatus.executing,
      server: server,
      hostId: hostId,
      message: 'Submitting one reviewed init/shutdown task change. A saved or enabled task can affect boot/shutdown root execution; there is no automatic test or retry.',
    );
    bool current() {
      if (!ref.mounted || generation != _generation) return false;
      final inventory = ref.read(initShutdownTasksInventoryProvider);
      if (!_active ||
          !_route(isRouteCurrent) ||
          !identical(
            expectedSession,
            ref.read(dashboardActiveSessionProvider),
          ) ||
          inventory.isLoading ||
          !identical(inventory.asData?.value, review.request.inventory)) {
        expireContext();
        return false;
      }
      return generation == _generation;
    }

    try {
      final result = await (api as AuthenticatedInitShutdownTasksSession)
          .executeInitShutdownTasks(review, confirmation, isCurrent: current);
      if (!current()) return;
      final completed = result.outcome == InitShutdownTasksOutcome.completed,
          rejected = result.outcome == InitShutdownTasksOutcome.rejected;
      state = InitShutdownTasksState(
        status: completed
            ? InitShutdownTasksStatus.completed
            : rejected
            ? InitShutdownTasksStatus.rejected
            : InitShutdownTasksStatus.unknown,
        server: server,
        hostId: hostId,
        message: completed
            ? 'Task configuration was verified after the change. This does not prove execution safety, completion, process termination or boot/shutdown availability. Read fresh task headers explicitly before another change.'
            : rejected
            ? 'The reviewed init/shutdown task change was rejected. No successful write or execution is claimed. Reload before another review.'
            : 'The init/shutdown task write outcome is unverified. Configuration or root task execution may already have changed. Do not repeat it; inspect the original server independently. No automatic retry or reconnect occurs.',
      );
    } on Object {
      if (ref.mounted && generation == _generation) {
        state = InitShutdownTasksState(
          status: InitShutdownTasksStatus.unknown,
          server: server,
          hostId: hostId,
          message: 'Init/shutdown task submission could not be verified. Remote details were withheld. A configuration write or root task execution may already have occurred. Inspect the original server; do not repeat it.',
        );
      }
    } finally {
      _discardCommand();
      _pending = false;
      _reviewSession = null;
      if (ref.mounted) {
        if (!state.locked) {
          _release();
        } else {
          state = state.verification(
            verifying: state.verifying,
            verified: state.hostVerified,
            message: state.verificationMessage,
          );
        }
      }
    }
  }

  bool get canVerifyReconnectedServer {
    final current = ref.read(dashboardActiveSessionProvider);
    return state.unresolved &&
        !state.verifying &&
        !state.connectionCurrent &&
        current?.endpoint == state.server &&
        !identical(current, _operationSession);
  }

  Future<void> verifyReconnectedServer() async {
    if (!canVerifyReconnectedServer || !_active) return;
    final session = ref.read(dashboardActiveSessionProvider)!,
        api = ref.read(initShutdownTasksSessionProvider);
    if (api == null) return;
    final generation = ++_verificationGeneration;
    _verifiedSession = null;
    state = state.verification(verifying: true);
    InitShutdownTasksInventory? inventory;
    try {
      inventory = await api.loadInitShutdownTasks();
    } on Object {
      /* Fixed public result. */
    }
    if (!ref.mounted ||
        generation != _verificationGeneration ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final verified =
        inventory?.hostId == state.hostId &&
        inventory?.endpoint == state.server &&
        inventory?.readinessBlockedReason == null;
    _verifiedSession = verified ? session : null;
    state = state.verification(
      verified: verified,
      message: verified
          ? 'The claimed original host identifier and current readiness match. This is not remote attestation or proof of the prior write or root task execution. Inspect task settings, command bodies and active processes independently.'
          : 'Original-host identity and readiness could not be verified. Details were withheld; management writes remain locked.',
    );
  }

  bool get canAcknowledge =>
      !_pending &&
      canVerifyReconnectedServer &&
      state.hostVerified &&
      identical(_verifiedSession, ref.read(dashboardActiveSessionProvider));
  void acknowledgeAfterReconnect() {
    if (!canAcknowledge || !_active) return;
    _release();
    _operationSession = null;
    _verifiedSession = null;
    state = const InitShutdownTasksState(
      status: InitShutdownTasksStatus.rejected,
      message: 'Independent original-server inspection acknowledged. The prior operation remains unverified and is not replayed; root task completion is not established.',
    );
    ref.invalidate(initShutdownTasksInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
