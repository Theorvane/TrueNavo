import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final nfsSettingsSessionProvider = Provider<AuthenticatedNfsSettingsSession?>((
  ref,
) {
  final repo = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repo is AuthenticatedNfsSettingsSession
      ? repo as AuthenticatedNfsSettingsSession
      : null;
});
final nfsSettingsInventoryProvider = FutureProvider<NfsSettingsInventory>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider),
      api = ref.watch(nfsSettingsSessionProvider);
  if (session?.endpoint == null ||
      api == null ||
      ref.read(nfsSettingsControllerProvider).locked) {
    throw StateError('Global NFS configuration is unavailable.');
  }
  final inventory = await api.loadNfsSettings();
  if (!ref.mounted ||
      !identical(session, ref.read(dashboardActiveSessionProvider)) ||
      inventory.endpoint != session!.endpoint) {
    throw StateError('Global NFS connection changed.');
  }
  return inventory;
}, retry: (_, _) => null);

enum NfsSettingsStatus {
  idle,
  reviewing,
  executing,
  completed,
  rejected,
  unknown,
}

final class NfsSettingsState {
  const NfsSettingsState({
    this.status = NfsSettingsStatus.idle,
    this.message,
    this.server,
    this.hostId,
    this.connectionCurrent = true,
    this.verifying = false,
    this.hostVerified = false,
    this.verificationMessage,
  });
  final NfsSettingsStatus status;
  final String? message, server, hostId, verificationMessage;
  final bool connectionCurrent, verifying, hostVerified;
  bool get busy =>
      status == NfsSettingsStatus.reviewing ||
      status == NfsSettingsStatus.executing;
  bool get unresolved => status == NfsSettingsStatus.unknown;
  bool get locked => status == NfsSettingsStatus.executing || unresolved;
  NfsSettingsState verification({
    bool verifying = false,
    bool verified = false,
    String? message,
  }) => NfsSettingsState(
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

final nfsSettingsControllerProvider =
    NotifierProvider<NfsSettingsController, NfsSettingsState>(
      NfsSettingsController.new,
    );

class NfsSettingsController extends Notifier<NfsSettingsState> {
  AuthenticatedSession? _reviewSession, _operationSession, _verifiedSession;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0, _verificationGeneration = 0;
  bool _pending = false;
  final _issued = Expando<int>(), _used = Expando<bool>();
  bool isReviewCurrent(NfsSettingsReview review) =>
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
  NfsSettingsState build() {
    final lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) expireContext();
      },
    );
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      expireContext();
      if (state.unresolved) {
        state = NfsSettingsState(
          status: NfsSettingsStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          connectionCurrent: identical(_operationSession, next),
          message: 'The connection changed after an unverified global NFS write. Inspect the original server independently. No operation is replayed; configured values do not prove NFS client access.',
        );
      }
    });
    ref.onDispose(() {
      _generation++;
      _verificationGeneration++;
      lifecycle.dispose();
      _release();
    });
    return const NfsSettingsState();
  }

  NfsSettingsState _expiredState() => state.locked || _pending
      ? NfsSettingsState(
          status: NfsSettingsStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          connectionCurrent: state.connectionCurrent,
          message: 'Global NFS authorization expired. A submitted write or NFS client access may already have occurred. Independently inspect the original server; do not repeat the request.',
        )
      : const NfsSettingsState(
          status: NfsSettingsStatus.rejected,
          message: 'The global NFS review expired. Reload and review again. Nothing is sent automatically.',
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
    state = const NfsSettingsState();
    ref.invalidate(nfsSettingsInventoryProvider);
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

  Future<NfsSettingsReview?> review({
    required AuthenticatedSession expectedSession,
    required NfsSettingsRequest request,
    required bool Function() isRouteCurrent,
  }) async {
    final snapshot = ref.read(nfsSettingsInventoryProvider),
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
        api is! AuthenticatedNfsSettingsSession ||
        !(api as AuthenticatedNfsSettingsSession)
            .nfsSettingsCapabilities
            .canConfigure) {
      return null;
    }
    final generation = ++_generation;
    _reviewSession = expectedSession;
    state = const NfsSettingsState(
      status: NfsSettingsStatus.reviewing,
      message: 'Reviewing configuration and write readiness. No NFS update has started.',
    );
    try {
      final review = await (api as AuthenticatedNfsSettingsSession)
          .reviewNfsSettings(request);
      if (!ref.mounted || generation != _generation) return null;
      final current = ref.read(nfsSettingsInventoryProvider);
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
        throw StateError('Mismatched global NFS review.');
      }
      _issued[review] = generation;
      state = const NfsSettingsState();
      return review;
    } on Object {
      if (ref.mounted && generation == _generation) {
        _generation++;
        _reviewSession = null;
        state = const NfsSettingsState(
          status: NfsSettingsStatus.rejected,
          message: 'Global NFS review could not be verified. Remote details were withheld. Reload before a new review.',
        );
      }
      return null;
    }
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required NfsSettingsReview review,
    required String confirmation,
    required bool configurationImpactAccepted,
    required bool clientImpactAccepted,
    required bool bindingExposureAccepted,
    required bool Function() isRouteCurrent,
  }) async {
    if (state.locked || state.busy || !isReviewCurrent(review)) return;
    _used[review] = true;
    final snapshot = ref.read(nfsSettingsInventoryProvider),
        api = expectedSession.repository;
    if (!_active ||
        !_route(isRouteCurrent) ||
        !configurationImpactAccepted ||
        !clientImpactAccepted ||
        review.request.changesBindings && !bindingExposureAccepted ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        review.request.validationError != null ||
        snapshot.isLoading ||
        !identical(snapshot.asData?.value, review.request.inventory) ||
        !identical(_reviewSession, expectedSession) ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        api is! AuthenticatedNfsSettingsSession ||
        !(api as AuthenticatedNfsSettingsSession)
            .nfsSettingsCapabilities
            .canConfigure) {
      expireContext();
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const NfsSettingsState(
        status: NfsSettingsStatus.rejected,
        message: 'Another management operation is unresolved. No NFS write was sent.',
      );
      return;
    }
    _used[review] = true;
    _pending = true;
    _operationSession = expectedSession;
    final generation = ++_generation,
        server = expectedSession.endpoint,
        hostId = review.request.inventory.hostId;
    state = NfsSettingsState(
      status: NfsSettingsStatus.executing,
      server: server,
      hostId: hostId,
      message: 'Submitting one reviewed global NFS update. Configuration and service-side effects may occur; no automatic service start, retry or probe is offered.',
    );
    bool current() {
      if (!ref.mounted || generation != _generation) return false;
      final inventory = ref.read(nfsSettingsInventoryProvider);
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
      final result = await (api as AuthenticatedNfsSettingsSession)
          .executeNfsSettings(review, confirmation, isCurrent: current);
      if (!current()) return;
      final completed = result.outcome == NfsSettingsOutcome.completed,
          rejected = result.outcome == NfsSettingsOutcome.rejected;
      state = NfsSettingsState(
        status: completed
            ? NfsSettingsStatus.completed
            : rejected
            ? NfsSettingsStatus.rejected
            : NfsSettingsStatus.unknown,
        server: server,
        hostId: hostId,
        message: completed
            ? 'Global NFS configuration was verified. This does not prove effective exports, service operation, client access or performance. Read fresh configuration explicitly before another change.'
            : rejected
            ? 'The reviewed global NFS change was rejected. No successful write or client access is claimed. Reload before another review.'
            : 'The global NFS write outcome is unverified. Configuration or NFS client access may already have changed. Do not repeat it; inspect the original server independently. No automatic retry or reconnect occurs.',
      );
    } on Object {
      if (ref.mounted && generation == _generation) {
        state = NfsSettingsState(
          status: NfsSettingsStatus.unknown,
          server: server,
          hostId: hostId,
          message: 'Global NFS submission could not be verified. Remote details were withheld. A configuration write or NFS client access may already have occurred. Inspect the original server; do not repeat it.',
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
        api = ref.read(nfsSettingsSessionProvider);
    if (api == null) return;
    final generation = ++_verificationGeneration;
    _verifiedSession = null;
    state = state.verification(verifying: true);
    NfsSettingsInventory? inventory;
    try {
      inventory = await api.loadNfsSettings();
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
          ? 'The claimed original host identifier and current readiness match. This is not remote attestation or proof of the prior write or NFS client access. Inspect NFS settings and client access independently.'
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
    state = const NfsSettingsState(
      status: NfsSettingsStatus.rejected,
      message: 'Independent original-server inspection acknowledged. The prior operation remains unverified and is not replayed; NFS client access is not established.',
    );
    ref.invalidate(nfsSettingsInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
