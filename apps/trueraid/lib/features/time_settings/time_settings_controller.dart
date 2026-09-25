import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final timeSettingsSessionProvider = Provider<AuthenticatedTimeSettingsSession?>(
  (ref) {
    final repo = ref.watch(dashboardActiveSessionProvider)?.repository;
    return repo is AuthenticatedTimeSettingsSession
        ? repo as AuthenticatedTimeSettingsSession
        : null;
  },
);
final timeSettingsInventoryProvider = FutureProvider<TimeSettingsInventory>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider),
      api = ref.watch(timeSettingsSessionProvider);
  if (session?.endpoint == null ||
      api == null ||
      ref.read(timeSettingsControllerProvider).locked) {
    throw StateError('Current time configuration is unavailable.');
  }
  final inventory = await api.loadTimeSettings();
  if (!ref.mounted ||
      !identical(session, ref.read(dashboardActiveSessionProvider)) ||
      inventory.endpoint != session!.endpoint) {
    throw StateError('Time settings connection changed.');
  }
  return inventory;
}, retry: (_, _) => null);

enum TimeSettingsStatus {
  idle,
  reviewing,
  executing,
  completed,
  rejected,
  unknown,
}

final class TimeSettingsState {
  const TimeSettingsState({
    this.status = TimeSettingsStatus.idle,
    this.message,
    this.server,
    this.hostId,
    this.connectionCurrent = true,
    this.verifying = false,
    this.hostVerified = false,
    this.verificationMessage,
  });
  final TimeSettingsStatus status;
  final String? message, server, hostId, verificationMessage;
  final bool connectionCurrent, verifying, hostVerified;
  bool get busy =>
      status == TimeSettingsStatus.reviewing ||
      status == TimeSettingsStatus.executing;
  bool get unresolved => status == TimeSettingsStatus.unknown;
  bool get locked => status == TimeSettingsStatus.executing || unresolved;
  TimeSettingsState verification({
    bool verifying = false,
    bool verified = false,
    String? message,
  }) => TimeSettingsState(
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

final timeSettingsControllerProvider =
    NotifierProvider<TimeSettingsController, TimeSettingsState>(
      TimeSettingsController.new,
    );

class TimeSettingsController extends Notifier<TimeSettingsState> {
  AuthenticatedSession? _reviewSession, _operationSession, _verifiedSession;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0, _verificationGeneration = 0;
  bool _pending = false;
  final _issued = Expando<int>(), _used = Expando<bool>();
  bool isReviewCurrent(TimeSettingsReview review) =>
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
  TimeSettingsState build() {
    final lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) expireContext();
      },
    );
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      expireContext();
      if (state.unresolved) {
        state = TimeSettingsState(
          status: TimeSettingsStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          connectionCurrent: identical(_operationSession, next),
          message: 'The connection changed after an unverified time-settings write. Inspect the original server independently. No operation is replayed; configured values do not prove time accuracy or synchronization.',
        );
      }
    });
    ref.onDispose(() {
      _generation++;
      _verificationGeneration++;
      lifecycle.dispose();
      _release();
    });
    return const TimeSettingsState();
  }

  TimeSettingsState _expiredState() => state.locked || _pending
      ? TimeSettingsState(
          status: TimeSettingsStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          connectionCurrent: state.connectionCurrent,
          message: 'Time-settings authorization expired. A submitted write or service restart may already have occurred. Independently inspect the original server; do not repeat the request.',
        )
      : const TimeSettingsState(
          status: TimeSettingsStatus.rejected,
          message: 'The time-settings review expired. Reload and review again. Nothing is sent automatically.',
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
    state = const TimeSettingsState();
    ref.invalidate(timeSettingsInventoryProvider);
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

  Future<TimeSettingsReview?> review({
    required AuthenticatedSession expectedSession,
    required TimeSettingsRequest request,
    required bool Function() isRouteCurrent,
  }) async {
    final snapshot = ref.read(timeSettingsInventoryProvider),
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
        api is! AuthenticatedTimeSettingsSession ||
        !(api as AuthenticatedTimeSettingsSession).timeSettingsCapabilities
            .supports(request.action)) {
      return null;
    }
    final generation = ++_generation;
    _reviewSession = expectedSession;
    state = const TimeSettingsState(
      status: TimeSettingsStatus.reviewing,
      message: 'Reviewing configuration and write readiness. No NTP probe or time-settings write has started.',
    );
    try {
      final review = await (api as AuthenticatedTimeSettingsSession)
          .reviewTimeSettings(request);
      if (!ref.mounted || generation != _generation) return null;
      final current = ref.read(timeSettingsInventoryProvider);
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
        throw StateError('Mismatched time-settings review.');
      }
      _issued[review] = generation;
      state = const TimeSettingsState();
      return review;
    } on Object {
      if (ref.mounted && generation == _generation) {
        _generation++;
        _reviewSession = null;
        state = const TimeSettingsState(
          status: TimeSettingsStatus.rejected,
          message: 'Time-settings review could not be verified. Remote details were withheld. Reload before a new review.',
        );
      }
      return null;
    }
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required TimeSettingsReview review,
    required String confirmation,
    required bool serviceImpactAccepted,
    required bool probeAccepted,
    required bool scheduleImpactAccepted,
    required bool remainingSourcesAccepted,
    required bool controlledBurstAccepted,
    required bool Function() isRouteCurrent,
  }) async {
    if (state.locked || state.busy || !isReviewCurrent(review)) return;
    final snapshot = ref.read(timeSettingsInventoryProvider),
        api = expectedSession.repository;
    final action = review.request.action;
    final probe =
        action == TimeSettingsAction.createNtp ||
        action == TimeSettingsAction.updateNtp;
    if (!_active ||
        !_route(isRouteCurrent) ||
        !serviceImpactAccepted ||
        probe && !probeAccepted ||
        probe &&
            review.request.settings?.burst == true &&
            !controlledBurstAccepted ||
        action == TimeSettingsAction.timezone && !scheduleImpactAccepted ||
        action == TimeSettingsAction.deleteNtp && !remainingSourcesAccepted ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        review.request.validationError != null ||
        snapshot.isLoading ||
        !identical(snapshot.asData?.value, review.request.inventory) ||
        !identical(_reviewSession, expectedSession) ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        api is! AuthenticatedTimeSettingsSession ||
        !(api as AuthenticatedTimeSettingsSession).timeSettingsCapabilities
            .supports(action)) {
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const TimeSettingsState(
        status: TimeSettingsStatus.rejected,
        message: 'Another management operation is unresolved. No time-settings write was sent.',
      );
      return;
    }
    _used[review] = true;
    _pending = true;
    _operationSession = expectedSession;
    final generation = ++_generation,
        server = expectedSession.endpoint,
        hostId = review.request.inventory.hostId;
    state = TimeSettingsState(
      status: TimeSettingsStatus.executing,
      server: server,
      hostId: hostId,
      message: probe
          ? 'Submitting one reviewed NTP change. The server can probe this address, commit configuration and restart ntpd. This is not a dry run.'
          : 'Submitting one reviewed configuration change. Service side effects can occur before the final result is known.',
    );
    bool current() {
      if (!ref.mounted || generation != _generation) return false;
      final inventory = ref.read(timeSettingsInventoryProvider);
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
      final result = await (api as AuthenticatedTimeSettingsSession)
          .executeTimeSettings(review, confirmation, isCurrent: current);
      if (!current()) return;
      final completed = result.outcome == TimeSettingsOutcome.completed,
          rejected = result.outcome == TimeSettingsOutcome.rejected;
      state = TimeSettingsState(
        status: completed
            ? TimeSettingsStatus.completed
            : rejected
            ? TimeSettingsStatus.rejected
            : TimeSettingsStatus.unknown,
        server: server,
        hostId: hostId,
        message: completed
            ? 'Configured values were verified after the change. This does not prove clock accuracy, NTP synchronization, source reachability or future scheduled execution. Refresh configuration explicitly when needed.'
            : rejected
            ? 'The reviewed time-settings change was rejected. No successful write or synchronization is claimed. Reload before another review.'
            : 'The time-settings write outcome is unverified. Configuration or service state may already have changed. Do not repeat it; inspect the original server independently. No automatic retry or reconnect occurs.',
      );
    } on Object {
      if (ref.mounted && generation == _generation) {
        state = TimeSettingsState(
          status: TimeSettingsStatus.unknown,
          server: server,
          hostId: hostId,
          message: 'Time-settings submission could not be verified. Remote details were withheld. A configuration write, NTP probe or service restart may already have occurred. Inspect the original server; do not repeat it.',
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
        api = ref.read(timeSettingsSessionProvider);
    if (api == null) return;
    final generation = ++_verificationGeneration;
    _verifiedSession = null;
    state = state.verification(verifying: true);
    TimeSettingsInventory? inventory;
    try {
      inventory = await api.loadTimeSettings();
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
        inventory?.blockedReason == null;
    _verifiedSession = verified ? session : null;
    state = state.verification(
      verified: verified,
      message: verified
          ? 'The claimed original host identifier and current configuration readiness match. This is not remote attestation or proof of the prior operation, clock accuracy or NTP synchronization. Inspect the configured values independently.'
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
    state = const TimeSettingsState(
      status: TimeSettingsStatus.rejected,
      message: 'Independent original-server inspection acknowledged. The prior operation remains unverified and is not replayed; time synchronization is not established.',
    );
    ref.invalidate(timeSettingsInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
