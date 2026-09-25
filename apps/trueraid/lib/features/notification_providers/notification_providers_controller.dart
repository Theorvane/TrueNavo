import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final notificationProvidersSessionProvider =
    Provider<AuthenticatedNotificationProvidersSession?>((ref) {
      final repo = ref.watch(dashboardActiveSessionProvider)?.repository;
      return repo is AuthenticatedNotificationProvidersSession
          ? repo as AuthenticatedNotificationProvidersSession
          : null;
    });
final notificationProvidersInventoryProvider =
    FutureProvider<NotificationProvidersInventory>((ref) async {
      final session = ref.watch(dashboardActiveSessionProvider),
          api = ref.watch(notificationProvidersSessionProvider);
      if (session?.endpoint == null ||
          api == null ||
          ref.read(notificationProvidersControllerProvider).locked) {
        throw StateError('Notification-provider configuration is unavailable.');
      }
      final inventory = await api.loadNotificationProviders();
      if (!ref.mounted ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          inventory.endpoint != session!.endpoint) {
        throw StateError('Notification-provider connection changed.');
      }
      return inventory;
    }, retry: (_, _) => null);

enum NotificationProvidersStatus {
  idle,
  reviewing,
  executing,
  completed,
  rejected,
  unknown,
}

final class NotificationProvidersState {
  const NotificationProvidersState({
    this.status = NotificationProvidersStatus.idle,
    this.message,
    this.server,
    this.hostId,
    this.connectionCurrent = true,
    this.verifying = false,
    this.hostVerified = false,
    this.verificationMessage,
  });
  final NotificationProvidersStatus status;
  final String? message, server, hostId, verificationMessage;
  final bool connectionCurrent, verifying, hostVerified;
  bool get busy =>
      status == NotificationProvidersStatus.reviewing ||
      status == NotificationProvidersStatus.executing;
  bool get unresolved => status == NotificationProvidersStatus.unknown;
  bool get locked =>
      status == NotificationProvidersStatus.executing || unresolved;
  NotificationProvidersState verification({
    bool verifying = false,
    bool verified = false,
    String? message,
  }) => NotificationProvidersState(
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

final notificationProvidersControllerProvider =
    NotifierProvider<
      NotificationProvidersController,
      NotificationProvidersState
    >(NotificationProvidersController.new);

class NotificationProvidersController
    extends Notifier<NotificationProvidersState> {
  AuthenticatedSession? _reviewSession, _operationSession, _verifiedSession;
  NotificationProviderCredentials? _credential;
  void _discardCredential() {
    _credential?.dispose();
    _credential = null;
  }

  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0, _verificationGeneration = 0;
  bool _pending = false;
  final _issued = Expando<int>(), _used = Expando<bool>();
  bool isReviewCurrent(NotificationProvidersReview review) =>
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
  NotificationProvidersState build() {
    final lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) expireContext();
      },
    );
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      expireContext();
      if (state.unresolved) {
        state = NotificationProvidersState(
          status: NotificationProvidersStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          connectionCurrent: identical(_operationSession, next),
          message: 'The connection changed after an unverified notification-provider write. Inspect the original server independently. No operation is replayed; configured services do not prove delivery.',
        );
      }
    });
    ref.onDispose(() {
      _generation++;
      _verificationGeneration++;
      lifecycle.dispose();
      _discardCredential();
      _release();
    });
    return const NotificationProvidersState();
  }

  NotificationProvidersState _expiredState() => state.locked || _pending
      ? NotificationProvidersState(
          status: NotificationProvidersStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          connectionCurrent: state.connectionCurrent,
          message: 'Notification-provider authorization expired. A submitted write or alert delivery may already have occurred. Independently inspect the original server; do not repeat the request.',
        )
      : const NotificationProvidersState(
          status: NotificationProvidersStatus.rejected,
          message: 'The notification-provider review expired. Reload and review again. Nothing is sent automatically.',
        );
  void expireContext() {
    if (!ref.mounted) return;
    _generation++;
    _verificationGeneration++;
    _verifiedSession = null;
    _reviewSession = null;
    _discardCredential();
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
    _discardCredential();
    state = const NotificationProvidersState();
    ref.invalidate(notificationProvidersInventoryProvider);
  }

  void abandonRoute() {
    if (!ref.mounted) return;
    final generation = ++_generation;
    _verificationGeneration++;
    _verifiedSession = null;
    _reviewSession = null;
    _discardCredential();
    final next = _expiredState();
    scheduleMicrotask(() {
      if (ref.mounted && generation == _generation) state = next;
    });
  }

  Future<NotificationProvidersReview?> review({
    required AuthenticatedSession expectedSession,
    required NotificationProvidersRequest request,
    required bool Function() isRouteCurrent,
  }) async {
    final snapshot = ref.read(notificationProvidersInventoryProvider),
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
        api is! AuthenticatedNotificationProvidersSession ||
        !(api as AuthenticatedNotificationProvidersSession)
            .notificationProvidersCapabilities
            .supports(request.action)) {
      if (!identical(request.credentials, _credential)) {
        request.credentials?.dispose();
      }
      return null;
    }
    _discardCredential();
    _credential = request.credentials;
    final generation = ++_generation;
    _reviewSession = expectedSession;
    state = const NotificationProvidersState(
      status: NotificationProvidersStatus.reviewing,
      message: 'Reviewing configuration and write readiness. No service write or test notification has started.',
    );
    try {
      final review = await (api as AuthenticatedNotificationProvidersSession)
          .reviewNotificationProviders(request);
      if (!ref.mounted || generation != _generation) {
        request.credentials?.dispose();
        return null;
      }
      final current = ref.read(notificationProvidersInventoryProvider);
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
        throw StateError('Mismatched notification-provider review.');
      }
      _issued[review] = generation;
      state = const NotificationProvidersState();
      return review;
    } on Object {
      _discardCredential();
      if (ref.mounted && generation == _generation) {
        _generation++;
        _reviewSession = null;
        state = const NotificationProvidersState(
          status: NotificationProvidersStatus.rejected,
          message: 'Notification-provider review could not be verified. Remote details were withheld. Reload before a new review.',
        );
      }
      return null;
    }
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required NotificationProvidersReview review,
    required String confirmation,
    required bool configurationImpactAccepted,
    required bool externalDeliveryAccepted,
    required bool noRecallAccepted,
    required bool unencryptedDisclosureAccepted,
    required bool Function() isRouteCurrent,
  }) async {
    if (state.locked || state.busy || !isReviewCurrent(review)) return;
    final snapshot = ref.read(notificationProvidersInventoryProvider),
        api = expectedSession.repository;
    final action = review.request.action;
    final enabling = action == NotificationProvidersAction.enable;
    final stopping =
        action == NotificationProvidersAction.disable ||
        action == NotificationProvidersAction.delete;
    if (!_active ||
        !_route(isRouteCurrent) ||
        !configurationImpactAccepted ||
        enabling && !externalDeliveryAccepted ||
        enabling && review.unencrypted && !unencryptedDisclosureAccepted ||
        stopping && !noRecallAccepted ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        review.request.validationError != null ||
        snapshot.isLoading ||
        !identical(snapshot.asData?.value, review.request.inventory) ||
        !identical(_reviewSession, expectedSession) ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        api is! AuthenticatedNotificationProvidersSession ||
        !(api as AuthenticatedNotificationProvidersSession)
            .notificationProvidersCapabilities
            .supports(action)) {
      _used[review] = true;
      _generation++;
      _reviewSession = null;
      _discardCredential();
      state = const NotificationProvidersState(
        status: NotificationProvidersStatus.rejected,
        message: 'Provider submission authorization was rejected. Enter fresh credentials and review again; no write was sent.',
      );
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      _used[review] = true;
      _generation++;
      _reviewSession = null;
      _discardCredential();
      state = const NotificationProvidersState(
        status: NotificationProvidersStatus.rejected,
        message: 'Another management operation is unresolved. No notification-provider write was sent.',
      );
      return;
    }
    _used[review] = true;
    _pending = true;
    _operationSession = expectedSession;
    final generation = ++_generation,
        server = expectedSession.endpoint,
        hostId = review.request.inventory.hostId;
    state = NotificationProvidersState(
      status: NotificationProvidersStatus.executing,
      server: server,
      hostId: hostId,
      message: 'Submitting one reviewed notification-provider change. A saved or enabled service can affect future alert delivery; there is no automatic test or retry.',
    );
    bool current() {
      if (!ref.mounted || generation != _generation) return false;
      final inventory = ref.read(notificationProvidersInventoryProvider);
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
      final result = await (api as AuthenticatedNotificationProvidersSession)
          .executeNotificationProviders(
            review,
            confirmation,
            isCurrent: current,
          );
      if (!current()) return;
      final completed =
              result.outcome == NotificationProvidersOutcome.completed,
          rejected = result.outcome == NotificationProvidersOutcome.rejected;
      state = NotificationProvidersState(
        status: completed
            ? NotificationProvidersStatus.completed
            : rejected
            ? NotificationProvidersStatus.rejected
            : NotificationProvidersStatus.unknown,
        server: server,
        hostId: hostId,
        message: completed
            ? 'Configured service values were verified after the change. This does not prove alert generation, SMTP acceptance, recipient delivery or inbox placement. Read fresh configuration explicitly before another change.'
            : rejected
            ? 'The reviewed notification-provider change was rejected. No successful write or delivery is claimed. Reload before another review.'
            : 'The notification-provider write outcome is unverified. Configuration or alert delivery may already have changed. Do not repeat it; inspect the original server independently. No automatic retry or reconnect occurs.',
      );
    } on Object {
      if (ref.mounted && generation == _generation) {
        state = NotificationProvidersState(
          status: NotificationProvidersStatus.unknown,
          server: server,
          hostId: hostId,
          message: 'Notification-provider submission could not be verified. Remote details were withheld. A configuration write or alert delivery may already have occurred. Inspect the original server; do not repeat it.',
        );
      }
    } finally {
      _discardCredential();
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
        api = ref.read(notificationProvidersSessionProvider);
    if (api == null) return;
    final generation = ++_verificationGeneration;
    _verifiedSession = null;
    state = state.verification(verifying: true);
    NotificationProvidersInventory? inventory;
    try {
      inventory = await api.loadNotificationProviders();
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
    state = const NotificationProvidersState(
      status: NotificationProvidersStatus.rejected,
      message: 'Independent original-server inspection acknowledged. The prior operation remains unverified and is not replayed; alert delivery is not established.',
    );
    ref.invalidate(notificationProvidersInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
