import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final alertPoliciesSessionProvider =
    Provider<AuthenticatedAlertPoliciesSession?>((ref) {
      final repo = ref.watch(dashboardActiveSessionProvider)?.repository;
      return repo is AuthenticatedAlertPoliciesSession
          ? repo as AuthenticatedAlertPoliciesSession
          : null;
    });
final alertPoliciesInventoryProvider = FutureProvider<AlertPoliciesInventory>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider),
      api = ref.watch(alertPoliciesSessionProvider);
  if (session?.endpoint == null ||
      api == null ||
      ref.read(alertPoliciesControllerProvider).locked) {
    throw StateError('Alert policies are unavailable.');
  }
  final value = await api.loadAlertPolicies();
  if (!ref.mounted ||
      !identical(session, ref.read(dashboardActiveSessionProvider)) ||
      value.endpoint != session!.endpoint) {
    throw StateError('The alert-policy connection changed.');
  }
  return value;
}, retry: (_, _) => null);

enum AlertPoliciesStatus {
  idle,
  reviewing,
  executing,
  completed,
  rejected,
  unknown,
}

final class AlertPoliciesState {
  const AlertPoliciesState({
    this.status = AlertPoliciesStatus.idle,
    this.message,
    this.server,
    this.hostId,
    this.connectionCurrent = true,
    this.verifying = false,
    this.hostVerified = false,
    this.verificationMessage,
  });
  final AlertPoliciesStatus status;
  final String? message, server, hostId, verificationMessage;
  final bool connectionCurrent, verifying, hostVerified;
  bool get busy =>
      status == AlertPoliciesStatus.reviewing ||
      status == AlertPoliciesStatus.executing;
  bool get unresolved => status == AlertPoliciesStatus.unknown;
  bool get locked => status == AlertPoliciesStatus.executing || unresolved;
  AlertPoliciesState verification({
    bool verifying = false,
    bool verified = false,
    String? message,
  }) => AlertPoliciesState(
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

final alertPoliciesControllerProvider =
    NotifierProvider<AlertPoliciesController, AlertPoliciesState>(
      AlertPoliciesController.new,
    );

class AlertPoliciesController extends Notifier<AlertPoliciesState> {
  AuthenticatedSession? _reviewSession, _operationSession, _verifiedSession;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0, _verificationGeneration = 0;
  bool _pending = false;
  final _issued = Expando<int>(), _used = Expando<bool>();
  bool isReviewCurrent(AlertPoliciesReview review) =>
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
  AlertPoliciesState build() {
    final lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) expireContext();
      },
    );
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (identical(a, b)) return;
      expireContext();
      if (state.unresolved) {
        state = AlertPoliciesState(
          status: AlertPoliciesStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          connectionCurrent: identical(_operationSession, b),
          message: 'The connection changed after an uncertain policy update. Inspect the original server; nothing is replayed.',
        );
      }
    });
    ref.onDispose(() {
      _generation++;
      _verificationGeneration++;
      lifecycle.dispose();
      _release();
    });
    return const AlertPoliciesState();
  }

  AlertPoliciesState _expired() => state.locked || _pending
      ? AlertPoliciesState(
          status: AlertPoliciesStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          connectionCurrent: state.connectionCurrent,
          message: 'Policy authorization expired. A submitted update may have affected alert visibility or external reporting. Inspect the original server; do not repeat it.',
        )
      : const AlertPoliciesState(
          status: AlertPoliciesStatus.rejected,
          message: 'The policy review expired. Reload and review again; no update is sent automatically.',
        );
  void expireContext() {
    if (!ref.mounted) return;
    _generation++;
    _verificationGeneration++;
    _reviewSession = null;
    _verifiedSession = null;
    state = _expired();
  }

  void abandonRoute() {
    if (!ref.mounted) return;
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
    _generation++;
    _verificationGeneration++;
    _reviewSession = null;
    _verifiedSession = null;
    state = const AlertPoliciesState();
    ref.invalidate(alertPoliciesInventoryProvider);
  }

  Future<AlertPoliciesReview?> review({
    required AuthenticatedSession expectedSession,
    required AlertPoliciesRequest request,
    required bool Function() isRouteCurrent,
  }) async {
    final snapshot = ref.read(alertPoliciesInventoryProvider),
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
        api is! AuthenticatedAlertPoliciesSession ||
        !(api as AuthenticatedAlertPoliciesSession)
            .alertPoliciesCapabilities
            .canConfigure) {
      return null;
    }
    final generation = ++_generation;
    _reviewSession = expectedSession;
    state = const AlertPoliciesState(
      status: AlertPoliciesStatus.reviewing,
      message: 'Reviewing policy configuration and readiness. No update, notification or support request has started.',
    );
    try {
      final review = await (api as AuthenticatedAlertPoliciesSession)
          .reviewAlertPolicies(request);
      if (!ref.mounted || generation != _generation) return null;
      final current = ref.read(alertPoliciesInventoryProvider);
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
        throw StateError('Mismatched policy review.');
      }
      _issued[review] = generation;
      state = const AlertPoliciesState();
      return review;
    } on Object {
      if (ref.mounted && generation == _generation) {
        _generation++;
        _reviewSession = null;
        state = const AlertPoliciesState(
          status: AlertPoliciesStatus.rejected,
          message: 'Policy review could not be verified. Remote details were withheld. Reload before another review.',
        );
      }
      return null;
    }
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required AlertPoliciesReview review,
    required String confirmation,
    required bool configurationImpactAccepted,
    required bool visibilityImpactAccepted,
    required bool supportDisclosureAccepted,
    required bool Function() isRouteCurrent,
  }) async {
    if (state.busy || state.locked || !isReviewCurrent(review)) return;
    final snapshot = ref.read(alertPoliciesInventoryProvider),
        api = expectedSession.repository;
    final after =
        review.request.afterOverrides.policy ??
        AlertPolicyFrequency.immediately;
    if (!_active ||
        !_route(isRouteCurrent) ||
        !configurationImpactAccepted ||
        after == AlertPolicyFrequency.never && !visibilityImpactAccepted ||
        review.request.changesProactiveSupport && !supportDisclosureAccepted ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        review.request.validationError != null ||
        snapshot.isLoading ||
        !identical(snapshot.asData?.value, review.request.inventory) ||
        !identical(_reviewSession, expectedSession) ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        api is! AuthenticatedAlertPoliciesSession ||
        !(api as AuthenticatedAlertPoliciesSession)
            .alertPoliciesCapabilities
            .canConfigure) {
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const AlertPoliciesState(
        status: AlertPoliciesStatus.rejected,
        message: 'Another management operation is unresolved. No policy update was sent.',
      );
      return;
    }
    _used[review] = true;
    _pending = true;
    _operationSession = expectedSession;
    final generation = ++_generation,
        server = expectedSession.endpoint,
        host = review.request.inventory.hostId;
    state = AlertPoliciesState(
      status: AlertPoliciesStatus.executing,
      server: server,
      hostId: host,
      message: 'Submitting one full-map update preserving unrelated policies. No automatic send, retry or support ticket is requested.',
    );
    bool current() {
      if (!ref.mounted || generation != _generation) return false;
      final value = ref.read(alertPoliciesInventoryProvider);
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
      final result = await (api as AuthenticatedAlertPoliciesSession)
          .executeAlertPolicies(review, confirmation, isCurrent: current);
      if (!current()) return;
      state = AlertPoliciesState(
        status: switch (result.outcome) {
          AlertPoliciesOutcome.completed => AlertPoliciesStatus.completed,
          AlertPoliciesOutcome.rejected => AlertPoliciesStatus.rejected,
          _ => AlertPoliciesStatus.unknown,
        },
        server: server,
        hostId: host,
        message: switch (result.outcome) {
          AlertPoliciesOutcome.completed => 'The saved class map was verified. Alert delivery, support ticket creation and visibility in every client are not established. Read fresh configuration before another change.',
          AlertPoliciesOutcome.rejected => 'The reviewed policy update was rejected. Reload before another review; no successful write is claimed.',
          _ => 'The policy update outcome is unknown. Visibility or external reporting may already have changed. Independently inspect the original server; do not retry.',
        },
      );
    } on Object {
      if (ref.mounted && generation == _generation) {
        state = AlertPoliciesState(
          status: AlertPoliciesStatus.unknown,
          server: server,
          hostId: host,
          message: 'Policy submission could not be verified. A write may already have occurred. Remote details were withheld; inspect the original server without retrying.',
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
        api = ref.read(alertPoliciesSessionProvider);
    if (api == null) return;
    final generation = ++_verificationGeneration;
    _verifiedSession = null;
    state = state.verification(verifying: true);
    AlertPoliciesInventory? value;
    try {
      value = await api.loadAlertPolicies();
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
          ? 'The claimed original host and readiness match. This is not attestation or proof of policy outcome; inspect policies and external reporting independently.'
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
    state = const AlertPoliciesState(
      status: AlertPoliciesStatus.rejected,
      message: 'Independent original-server inspection acknowledged. The earlier policy update remains unverified and is not replayed.',
    );
    ref.invalidate(alertPoliciesInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
