import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final cronTasksSessionProvider = Provider<AuthenticatedCronTasksSession?>((
  ref,
) {
  final repo = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repo is AuthenticatedCronTasksSession
      ? repo as AuthenticatedCronTasksSession
      : null;
});
final cronTasksInventoryProvider = FutureProvider<CronTasksInventory>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider),
      api = ref.watch(cronTasksSessionProvider);
  if (session?.endpoint == null ||
      api == null ||
      ref.read(cronTasksControllerProvider).locked) {
    throw StateError('Cron tasks are unavailable.');
  }
  final value = await api.loadCronTasks();
  if (!ref.mounted ||
      !identical(session, ref.read(dashboardActiveSessionProvider)) ||
      value.endpoint != session!.endpoint) {
    throw StateError('The cron-tasks connection changed.');
  }
  return value;
}, retry: (_, _) => null);

enum CronTasksStatus {
  idle,
  reviewing,
  executing,
  completed,
  rejected,
  unknown,
}

final class CronTasksState {
  const CronTasksState({
    this.status = CronTasksStatus.idle,
    this.message,
    this.server,
    this.hostId,
    this.connectionCurrent = true,
    this.verifying = false,
    this.hostVerified = false,
    this.verificationMessage,
  });
  final CronTasksStatus status;
  final String? message, server, hostId, verificationMessage;
  final bool connectionCurrent, verifying, hostVerified;
  bool get busy =>
      status == CronTasksStatus.reviewing ||
      status == CronTasksStatus.executing;
  bool get unresolved => status == CronTasksStatus.unknown;
  bool get locked => status == CronTasksStatus.executing || unresolved;
  CronTasksState verification({
    bool verifying = false,
    bool verified = false,
    String? message,
  }) => CronTasksState(
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

final cronTasksControllerProvider =
    NotifierProvider<CronTasksController, CronTasksState>(
      CronTasksController.new,
    );

class CronTasksController extends Notifier<CronTasksState> {
  CronTaskCommand? _command;
  void _discardCommand() {
    _command?.dispose();
    _command = null;
  }

  AuthenticatedSession? _reviewSession, _operationSession, _verifiedSession;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0, _verificationGeneration = 0;
  bool _pending = false;
  final _issued = Expando<int>(), _used = Expando<bool>();
  bool isReviewCurrent(CronTasksReview review) =>
      _issued[review] == _generation && _used[review] != true;
  bool get _active =>
      WidgetsBinding.instance.lifecycleState == null ||
      WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  bool _route(bool Function() callback) {
    try {
      return callback();
    } on Object {
      return false;
    }
  }

  @override
  CronTasksState build() {
    final lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) expireContext();
      },
    );
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (identical(a, b)) return;
      expireContext();
      if (state.unresolved) {
        state = CronTasksState(
          status: CronTasksStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          connectionCurrent: identical(_operationSession, b),
          message: 'The connection changed after an uncertain cron update. Inspect the original server; nothing is replayed.',
        );
      }
    });
    ref.onDispose(() {
      _discardCommand();
      _generation++;
      _verificationGeneration++;
      lifecycle.dispose();
      _release();
    });
    return const CronTasksState();
  }

  CronTasksState _expired() => state.locked || _pending
      ? CronTasksState(
          status: CronTasksStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          connectionCurrent: state.connectionCurrent,
          message: 'Cron authorization expired. A submitted change may have affected scheduled commands or configuration. Inspect the original server; do not repeat it.',
        )
      : const CronTasksState(
          status: CronTasksStatus.rejected,
          message: 'The cron review expired. Reload and review again; no update is sent automatically.',
        );
  void expireContext() {
    if (!ref.mounted) return;
    _discardCommand();
    _generation++;
    _verificationGeneration++;
    _reviewSession = null;
    _verifiedSession = null;
    state = _expired();
  }

  void abandonRoute() {
    if (!ref.mounted) return;
    _discardCommand();
    final generation = ++_generation;
    _verificationGeneration++;
    _reviewSession = null;
    _verifiedSession = null;
    final next = _expired();
    scheduleMicrotask(() {
      if (ref.mounted && generation == _generation) state = next;
    });
  }

  void refreshConfiguration() {
    if (!ref.mounted || state.busy || state.locked) return;
    _discardCommand();
    _generation++;
    _verificationGeneration++;
    _reviewSession = null;
    _verifiedSession = null;
    state = const CronTasksState();
    ref.invalidate(cronTasksInventoryProvider);
  }

  Future<CronTasksReview?> review({
    required AuthenticatedSession expectedSession,
    required CronTasksRequest request,
    required bool Function() isRouteCurrent,
  }) async {
    final snapshot = ref.read(cronTasksInventoryProvider),
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
        api is! AuthenticatedCronTasksSession ||
        !(api as AuthenticatedCronTasksSession).cronTasksCapabilities.allows(
          request.action,
        )) {
      if (!identical(request.command, _command)) request.command?.dispose();
      return null;
    }
    final generation = ++_generation;
    _discardCommand();
    _command = request.command;
    _reviewSession = expectedSession;
    state = const CronTasksState(
      status: CronTasksStatus.reviewing,
      message: 'Reviewing saved cron configuration and readiness. No mutation, manual execution or account probe has started.',
    );
    try {
      final review = await (api as AuthenticatedCronTasksSession)
          .reviewCronTasks(request);
      if (!ref.mounted || generation != _generation) return null;
      final current = ref.read(cronTasksInventoryProvider);
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
          review.endpoint != expectedSession.endpoint) {
        throw StateError('Mismatched cron review.');
      }
      _issued[review] = generation;
      state = const CronTasksState();
      return review;
    } on Object {
      if (ref.mounted && generation == _generation) {
        _discardCommand();
        _generation++;
        _reviewSession = null;
        state = const CronTasksState(
          status: CronTasksStatus.rejected,
          message: 'cron review could not be verified. Remote details were withheld. Reload before another review.',
        );
      }
      return null;
    }
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required CronTasksReview review,
    required String confirmation,
    required bool configurationImpactAccepted,
    required bool executionImpactAccepted,
    required bool commandRiskAccepted,
    required bool disclosureAccepted,
    required bool Function() isRouteCurrent,
  }) async {
    if (state.busy || state.locked || !isReviewCurrent(review)) return;
    final snapshot = ref.read(cronTasksInventoryProvider),
        api = expectedSession.repository;
    if (!_active ||
        !_route(isRouteCurrent) ||
        !configurationImpactAccepted ||
        (review.request.action == CronTasksAction.enable ||
                review.request.action == CronTasksAction.run) &&
            !executionImpactAccepted ||
        (review.request.action == CronTasksAction.enable ||
                review.request.action == CronTasksAction.create ||
                review.request.action == CronTasksAction.edit ||
                review.request.action == CronTasksAction.run) &&
            !commandRiskAccepted ||
        (review.request.action == CronTasksAction.enable ||
                review.request.action == CronTasksAction.run) &&
            !disclosureAccepted ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        review.request.validationError != null ||
        snapshot.isLoading ||
        !identical(snapshot.asData?.value, review.request.inventory) ||
        !identical(_reviewSession, expectedSession) ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        api is! AuthenticatedCronTasksSession ||
        !(api as AuthenticatedCronTasksSession).cronTasksCapabilities.allows(
          review.request.action,
        )) {
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const CronTasksState(
        status: CronTasksStatus.rejected,
        message: 'Another management operation is unresolved. No cron update was sent.',
      );
      return;
    }
    _used[review] = true;
    _pending = true;
    _operationSession = expectedSession;
    final generation = ++_generation,
        server = expectedSession.endpoint,
        host = review.request.inventory.hostId;
    state = CronTasksState(
      status: CronTasksStatus.executing,
      server: server,
      hostId: host,
      message: review.request.action == CronTasksAction.run
          ? 'Submitting one reviewed manual cron run. The server job may queue, run or fail after acceptance; no logs, output or completion status will be read.'
          : 'Submitting one reviewed cron lifecycle change. Global schedule regeneration can affect scheduled work. No command is run manually and no automatic retry is requested.',
    );
    bool current() {
      if (!ref.mounted || generation != _generation) return false;
      final value = ref.read(cronTasksInventoryProvider);
      if (!_active ||
          !_route(isRouteCurrent) ||
          !identical(
            expectedSession,
            ref.read(dashboardActiveSessionProvider),
          ) ||
          value.isLoading ||
          !identical(value.asData?.value, review.request.inventory)) {
        expireContext();
        return false;
      }
      return generation == _generation;
    }

    try {
      final result = await (api as AuthenticatedCronTasksSession)
          .executeCronTasks(review, confirmation, isCurrent: current);
      if (!current()) return;
      state = CronTasksState(
        status: switch (result.outcome) {
          CronTasksOutcome.completed => CronTasksStatus.completed,
          CronTasksOutcome.rejected => CronTasksStatus.rejected,
          _ => CronTasksStatus.unknown,
        },
        server: server,
        hostId: host,
        message: switch (result.outcome) {
          CronTasksOutcome.completed
              when review.request.action == CronTasksAction.run =>
            'The manual cron job was accepted by the server. It may still be waiting, running or failed; no logs, output, email delivery or completion status were read.',
          CronTasksOutcome.completed => 'Saved cron tasks were verified. Command execution, scheduler timing and cancellation were not established. Read fresh configuration before another change.',
          CronTasksOutcome.rejected => 'The reviewed cron update was rejected. Reload before another review; no successful write is claimed.',
          _ => 'The cron update outcome is unknown. cron scheduled commands or configuration may already have changed. Independently inspect the original server; do not retry.',
        },
      );
    } on Object {
      if (ref.mounted && generation == _generation) {
        state = CronTasksState(
          status: CronTasksStatus.unknown,
          server: server,
          hostId: host,
          message: 'cron submission could not be verified. A write may already have occurred. Remote details were withheld; inspect the original server without retrying.',
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
        api = ref.read(cronTasksSessionProvider);
    if (api == null) return;
    final generation = ++_verificationGeneration;
    _verifiedSession = null;
    state = state.verification(verifying: true);
    CronTasksInventory? value;
    try {
      value = await api.loadCronTasks();
    } on Object {
      /* Fixed safe message. */
    }
    if (!ref.mounted ||
        generation != _verificationGeneration ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final verified =
        value?.hostId == state.hostId &&
        value?.endpoint == state.server &&
        value?.readinessBlockedReason == null;
    _verifiedSession = verified ? session : null;
    state = state.verification(
      verified: verified,
      message: verified
          ? 'The claimed original host and readiness match. This is not attestation or proof of the cron outcome; inspect cron configuration and command effects independently.'
          : 'Original-host identity and readiness could not be verified. Management writes remain locked.',
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
    state = const CronTasksState(
      status: CronTasksStatus.rejected,
      message: 'Independent original-server inspection acknowledged. The earlier cron update remains unverified and is not replayed.',
    );
    ref.invalidate(cronTasksInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
