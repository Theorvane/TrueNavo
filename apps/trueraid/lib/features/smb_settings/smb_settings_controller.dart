import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final smbSettingsSessionProvider = Provider<AuthenticatedSmbSettingsSession?>((
  ref,
) {
  final repo = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repo is AuthenticatedSmbSettingsSession
      ? repo as AuthenticatedSmbSettingsSession
      : null;
});
final smbSettingsInventoryProvider = FutureProvider<SmbSettingsInventory>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider),
      api = ref.watch(smbSettingsSessionProvider);
  if (session?.endpoint == null ||
      api == null ||
      ref.read(smbSettingsControllerProvider).locked) {
    throw StateError('Global SMB settings are unavailable.');
  }
  final value = await api.loadSmbSettings();
  if (!ref.mounted ||
      !identical(session, ref.read(dashboardActiveSessionProvider)) ||
      value.endpoint != session!.endpoint) {
    throw StateError('The SMB-settings connection changed.');
  }
  return value;
}, retry: (_, _) => null);

enum SmbSettingsStatus {
  idle,
  reviewing,
  executing,
  completed,
  rejected,
  unknown,
}

final class SmbSettingsState {
  const SmbSettingsState({
    this.status = SmbSettingsStatus.idle,
    this.message,
    this.server,
    this.hostId,
    this.connectionCurrent = true,
    this.verifying = false,
    this.hostVerified = false,
    this.verificationMessage,
  });
  final SmbSettingsStatus status;
  final String? message, server, hostId, verificationMessage;
  final bool connectionCurrent, verifying, hostVerified;
  bool get busy =>
      status == SmbSettingsStatus.reviewing ||
      status == SmbSettingsStatus.executing;
  bool get unresolved => status == SmbSettingsStatus.unknown;
  bool get locked => status == SmbSettingsStatus.executing || unresolved;
  SmbSettingsState verification({
    bool verifying = false,
    bool verified = false,
    String? message,
  }) => SmbSettingsState(
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

final smbSettingsControllerProvider =
    NotifierProvider<SmbSettingsController, SmbSettingsState>(
      SmbSettingsController.new,
    );

class SmbSettingsController extends Notifier<SmbSettingsState> {
  AuthenticatedSession? _reviewSession, _operationSession, _verifiedSession;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0, _verificationGeneration = 0;
  bool _pending = false;
  final _issued = Expando<int>(), _used = Expando<bool>();
  bool isReviewCurrent(SmbSettingsReview review) =>
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
  SmbSettingsState build() {
    final lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) expireContext();
      },
    );
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (identical(a, b)) return;
      expireContext();
      if (state.unresolved) {
        state = SmbSettingsState(
          status: SmbSettingsStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          connectionCurrent: identical(_operationSession, b),
          message: 'The connection changed after an uncertain SMB update. Inspect the original server; nothing is replayed.',
        );
      }
    });
    ref.onDispose(() {
      _generation++;
      _verificationGeneration++;
      lifecycle.dispose();
      _release();
    });
    return const SmbSettingsState();
  }

  SmbSettingsState _expired() => state.locked || _pending
      ? SmbSettingsState(
          status: SmbSettingsStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          connectionCurrent: state.connectionCurrent,
          message: 'SMB authorization expired. A submitted update may have affected alert SMB clients or configuration. Inspect the original server; do not repeat it.',
        )
      : const SmbSettingsState(
          status: SmbSettingsStatus.rejected,
          message: 'The SMB review expired. Reload and review again; no update is sent automatically.',
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
    state = const SmbSettingsState();
    ref.invalidate(smbSettingsInventoryProvider);
  }

  Future<SmbSettingsReview?> review({
    required AuthenticatedSession expectedSession,
    required SmbSettingsRequest request,
    required bool Function() isRouteCurrent,
  }) async {
    final snapshot = ref.read(smbSettingsInventoryProvider),
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
        api is! AuthenticatedSmbSettingsSession ||
        !(api as AuthenticatedSmbSettingsSession)
            .smbSettingsCapabilities
            .canConfigure) {
      return null;
    }
    final generation = ++_generation;
    _reviewSession = expectedSession;
    state = const SmbSettingsState(
      status: SmbSettingsStatus.reviewing,
      message: 'Reviewing saved SMB configuration and readiness. No update, restart or client probe has started.',
    );
    try {
      final review = await (api as AuthenticatedSmbSettingsSession)
          .reviewSmbSettings(request);
      if (!ref.mounted || generation != _generation) return null;
      final current = ref.read(smbSettingsInventoryProvider);
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
        throw StateError('Mismatched SMB review.');
      }
      _issued[review] = generation;
      state = const SmbSettingsState();
      return review;
    } on Object {
      if (ref.mounted && generation == _generation) {
        _generation++;
        _reviewSession = null;
        state = const SmbSettingsState(
          status: SmbSettingsStatus.rejected,
          message: 'SMB review could not be verified. Remote details were withheld. Reload before another review.',
        );
      }
      return null;
    }
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required SmbSettingsReview review,
    required String confirmation,
    required bool configurationImpactAccepted,
    required bool identityImpactAccepted,
    required bool compatibilityImpactAccepted,
    required bool Function() isRouteCurrent,
  }) async {
    if (state.busy || state.locked || !isReviewCurrent(review)) return;
    final snapshot = ref.read(smbSettingsInventoryProvider),
        api = expectedSession.repository;
    if (!_active ||
        !_route(isRouteCurrent) ||
        !configurationImpactAccepted ||
        review.request.changesIdentity && !identityImpactAccepted ||
        (review.request.strengthensEncryption ||
                review.request.settings.multichannel !=
                    review.request.inventory.config.settings.multichannel) &&
            !compatibilityImpactAccepted ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        review.request.validationError != null ||
        snapshot.isLoading ||
        !identical(snapshot.asData?.value, review.request.inventory) ||
        !identical(_reviewSession, expectedSession) ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        api is! AuthenticatedSmbSettingsSession ||
        !(api as AuthenticatedSmbSettingsSession)
            .smbSettingsCapabilities
            .canConfigure) {
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const SmbSettingsState(
        status: SmbSettingsStatus.rejected,
        message: 'Another management operation is unresolved. No SMB update was sent.',
      );
      return;
    }
    _used[review] = true;
    _pending = true;
    _operationSession = expectedSession;
    final generation = ++_generation,
        server = expectedSession.endpoint,
        host = review.request.inventory.hostId;
    state = SmbSettingsState(
      status: SmbSettingsStatus.executing,
      server: server,
      hostId: host,
      message: 'Submitting one changed-field global SMB update. Configuration regeneration and a running-service restart can interrupt clients. No automatic retry is requested.',
    );
    bool current() {
      if (!ref.mounted || generation != _generation) return false;
      final value = ref.read(smbSettingsInventoryProvider);
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
      final result = await (api as AuthenticatedSmbSettingsSession)
          .executeSmbSettings(review, confirmation, isCurrent: current);
      if (!current()) return;
      state = SmbSettingsState(
        status: switch (result.outcome) {
          SmbSettingsOutcome.completed => SmbSettingsStatus.completed,
          SmbSettingsOutcome.rejected => SmbSettingsStatus.rejected,
          _ => SmbSettingsStatus.unknown,
        },
        server: server,
        hostId: host,
        message: switch (result.outcome) {
          SmbSettingsOutcome.completed => 'Saved global SMB settings were verified. Client connectivity, runtime encryption, password synchronization and share availability were not established. Read fresh configuration before another change.',
          SmbSettingsOutcome.rejected => 'The reviewed SMB update was rejected. Reload before another review; no successful write is claimed.',
          _ => 'The SMB update outcome is unknown. SMB clients or configuration may already have changed. Independently inspect the original server; do not retry.',
        },
      );
    } on Object {
      if (ref.mounted && generation == _generation) {
        state = SmbSettingsState(
          status: SmbSettingsStatus.unknown,
          server: server,
          hostId: host,
          message: 'SMB submission could not be verified. A write may already have occurred. Remote details were withheld; inspect the original server without retrying.',
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
        api = ref.read(smbSettingsSessionProvider);
    if (api == null) return;
    final generation = ++_verificationGeneration;
    _verifiedSession = null;
    state = state.verification(verifying: true);
    SmbSettingsInventory? value;
    try {
      value = await api.loadSmbSettings();
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
          ? 'The claimed original host and readiness match. This is not attestation or proof of the SMB outcome; inspect SMB configuration and client access independently.'
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
    state = const SmbSettingsState(
      status: SmbSettingsStatus.rejected,
      message: 'Independent original-server inspection acknowledged. The earlier SMB update remains unverified and is not replayed.',
    );
    ref.invalidate(smbSettingsInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
