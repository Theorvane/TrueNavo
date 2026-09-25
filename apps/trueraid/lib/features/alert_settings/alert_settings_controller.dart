import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final alertSettingsSessionProvider =
    Provider<AuthenticatedAlertSettingsSession?>((ref) {
      final repo = ref.watch(dashboardActiveSessionProvider)?.repository;
      return repo is AuthenticatedAlertSettingsSession
          ? repo as AuthenticatedAlertSettingsSession
          : null;
    });
final alertSettingsInventoryProvider = FutureProvider<AlertSettingsInventory>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider),
      api = ref.watch(alertSettingsSessionProvider);
  if (session?.endpoint == null ||
      api == null ||
      ref.read(alertSettingsControllerProvider).locked) {
    throw StateError('Notification-service configuration is unavailable.');
  }
  final inventory = await api.loadAlertSettings();
  if (!ref.mounted ||
      !identical(session, ref.read(dashboardActiveSessionProvider)) ||
      inventory.endpoint != session!.endpoint) {
    throw StateError('Notification-service connection changed.');
  }
  return inventory;
}, retry: (_, _) => null);

enum AlertSettingsStatus {
  idle,
  reviewing,
  executing,
  completed,
  rejected,
  unknown,
}

final class AlertSettingsState {
  const AlertSettingsState({
    this.status = AlertSettingsStatus.idle,
    this.message,
    this.server,
    this.hostId,
    this.connectionCurrent = true,
    this.verifying = false,
    this.hostVerified = false,
    this.verificationMessage,
  });
  final AlertSettingsStatus status;
  final String? message, server, hostId, verificationMessage;
  final bool connectionCurrent, verifying, hostVerified;
  bool get busy =>
      status == AlertSettingsStatus.reviewing ||
      status == AlertSettingsStatus.executing;
  bool get unresolved => status == AlertSettingsStatus.unknown;
  bool get locked => status == AlertSettingsStatus.executing || unresolved;
  AlertSettingsState verification({
    bool verifying = false,
    bool verified = false,
    String? message,
  }) => AlertSettingsState(
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

final alertSettingsControllerProvider =
    NotifierProvider<AlertSettingsController, AlertSettingsState>(
      AlertSettingsController.new,
    );

class AlertSettingsController extends Notifier<AlertSettingsState> {
  AuthenticatedSession? _reviewSession, _operationSession, _verifiedSession;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0, _verificationGeneration = 0;
  bool _pending = false;
  final _issued = Expando<int>(), _used = Expando<bool>();
  bool isReviewCurrent(AlertSettingsReview review) =>
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
  AlertSettingsState build() {
    final lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) expireContext();
      },
    );
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      expireContext();
      if (state.unresolved) {
        state = AlertSettingsState(
          status: AlertSettingsStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          connectionCurrent: identical(_operationSession, next),
          message: 'The connection changed after an unverified notification-service write. Inspect the original server independently. No operation is replayed; configured services do not prove delivery.',
        );
      }
    });
    ref.onDispose(() {
      _generation++;
      _verificationGeneration++;
      lifecycle.dispose();
      _release();
    });
    return const AlertSettingsState();
  }

  AlertSettingsState _expiredState() => state.locked || _pending
      ? AlertSettingsState(
          status: AlertSettingsStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          connectionCurrent: state.connectionCurrent,
          message: 'Notification-service authorization expired. A submitted write or alert delivery may already have occurred. Independently inspect the original server; do not repeat the request.',
        )
      : const AlertSettingsState(
          status: AlertSettingsStatus.rejected,
          message: 'The notification-service review expired. Reload and review again. Nothing is sent automatically.',
        );
  void expireContext() {
    if (!ref.mounted) return;
    _generation++;
    _verificationGeneration++;
    _verifiedSession = null;
    _reviewSession = null;
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
    state = const AlertSettingsState();
    ref.invalidate(alertSettingsInventoryProvider);
  }

  void abandonRoute() {
    if (!ref.mounted) return;
    final generation = ++_generation;
    _verificationGeneration++;
    _verifiedSession = null;
    _reviewSession = null;
    final next = _expiredState();
    scheduleMicrotask(() {
      if (ref.mounted && generation == _generation) state = next;
    });
  }

  Future<AlertSettingsReview?> review({
    required AuthenticatedSession expectedSession,
    required AlertSettingsRequest request,
    required bool Function() isRouteCurrent,
  }) async {
    final snapshot = ref.read(alertSettingsInventoryProvider),
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
        api is! AuthenticatedAlertSettingsSession ||
        !(api as AuthenticatedAlertSettingsSession).alertSettingsCapabilities
            .supports(request.action)) {
      return null;
    }
    final generation = ++_generation;
    _reviewSession = expectedSession;
    state = const AlertSettingsState(
      status: AlertSettingsStatus.reviewing,
      message: 'Reviewing configuration and write readiness. No service write or test notification has started.',
    );
    try {
      final review = await (api as AuthenticatedAlertSettingsSession)
          .reviewAlertSettings(request);
      if (!ref.mounted || generation != _generation) return null;
      final current = ref.read(alertSettingsInventoryProvider);
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
        throw StateError('Mismatched notification-service review.');
      }
      _issued[review] = generation;
      state = const AlertSettingsState();
      return review;
    } on Object {
      if (ref.mounted && generation == _generation) {
        _generation++;
        _reviewSession = null;
        state = const AlertSettingsState(
          status: AlertSettingsStatus.rejected,
          message: 'Notification-service review could not be verified. Remote details were withheld. Reload before a new review.',
        );
      }
      return null;
    }
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required AlertSettingsReview review,
    required String confirmation,
    required bool configurationImpactAccepted,
    required bool externalDeliveryAccepted,
    required bool noRecallAccepted,
    required bool Function() isRouteCurrent,
  }) async {
    if (state.locked || state.busy || !isReviewCurrent(review)) return;
    final snapshot = ref.read(alertSettingsInventoryProvider),
        api = expectedSession.repository;
    final action = review.request.action;
    final enabling = action == AlertSettingsAction.enableEmail;
    final stopping =
        action == AlertSettingsAction.disableEmail ||
        action == AlertSettingsAction.deleteEmail;
    if (!_active ||
        !_route(isRouteCurrent) ||
        !configurationImpactAccepted ||
        enabling && !externalDeliveryAccepted ||
        stopping && !noRecallAccepted ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        review.request.validationError != null ||
        snapshot.isLoading ||
        !identical(snapshot.asData?.value, review.request.inventory) ||
        !identical(_reviewSession, expectedSession) ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        api is! AuthenticatedAlertSettingsSession ||
        !(api as AuthenticatedAlertSettingsSession).alertSettingsCapabilities
            .supports(action)) {
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const AlertSettingsState(
        status: AlertSettingsStatus.rejected,
        message: 'Another management operation is unresolved. No notification-service write was sent.',
      );
      return;
    }
    _used[review] = true;
    _pending = true;
    _operationSession = expectedSession;
    final generation = ++_generation,
        server = expectedSession.endpoint,
        hostId = review.request.inventory.hostId;
    state = AlertSettingsState(
      status: AlertSettingsStatus.executing,
      server: server,
      hostId: hostId,
      message: 'Submitting one reviewed notification-service change. A saved or enabled service can affect future alert delivery; there is no automatic test or retry.',
    );
    bool current() {
      if (!ref.mounted || generation != _generation) return false;
      final inventory = ref.read(alertSettingsInventoryProvider);
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
      final result = await (api as AuthenticatedAlertSettingsSession)
          .executeAlertSettings(review, confirmation, isCurrent: current);
      if (!current()) return;
      final completed = result.outcome == AlertSettingsOutcome.completed,
          rejected = result.outcome == AlertSettingsOutcome.rejected;
      state = AlertSettingsState(
        status: completed
            ? AlertSettingsStatus.completed
            : rejected
            ? AlertSettingsStatus.rejected
            : AlertSettingsStatus.unknown,
        server: server,
        hostId: hostId,
        message: completed
            ? 'Configured service values were verified after the change. This does not prove alert generation, SMTP acceptance, recipient delivery or inbox placement. Read fresh configuration explicitly before another change.'
            : rejected
            ? 'The reviewed notification-service change was rejected. No successful write or delivery is claimed. Reload before another review.'
            : 'The notification-service write outcome is unverified. Configuration or alert delivery may already have changed. Do not repeat it; inspect the original server independently. No automatic retry or reconnect occurs.',
      );
    } on Object {
      if (ref.mounted && generation == _generation) {
        state = AlertSettingsState(
          status: AlertSettingsStatus.unknown,
          server: server,
          hostId: hostId,
          message: 'Notification-service submission could not be verified. Remote details were withheld. A configuration write or alert delivery may already have occurred. Inspect the original server; do not repeat it.',
        );
      }
    } finally {
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
        api = ref.read(alertSettingsSessionProvider);
    if (api == null) return;
    final generation = ++_verificationGeneration;
    _verifiedSession = null;
    state = state.verification(verifying: true);
    AlertSettingsInventory? inventory;
    try {
      inventory = await api.loadAlertSettings();
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
          ? 'The claimed original host identifier and current readiness match. This is not remote attestation or proof of the prior write or alert delivery. Inspect service settings and any external delivery independently.'
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
    state = const AlertSettingsState(
      status: AlertSettingsStatus.rejected,
      message: 'Independent original-server inspection acknowledged. The prior operation remains unverified and is not replayed; alert delivery is not established.',
    );
    ref.invalidate(alertSettingsInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
