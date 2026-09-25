import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final configurationResetSessionProvider =
    Provider<AuthenticatedConfigurationResetSession?>((ref) {
      final repo = ref.watch(dashboardActiveSessionProvider)?.repository;
      return repo is AuthenticatedConfigurationResetSession
          ? repo as AuthenticatedConfigurationResetSession
          : null;
    });
final configurationResetInventoryProvider =
    FutureProvider<ConfigurationResetInventory>((ref) async {
      final session = ref.watch(dashboardActiveSessionProvider),
          api = ref.watch(configurationResetSessionProvider);
      if (session?.endpoint == null ||
          api == null ||
          ref.read(configurationResetControllerProvider).locked) {
        throw StateError('Current reset readiness is unavailable.');
      }
      final inventory = await api.loadConfigurationReset();
      if (!ref.mounted ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          inventory.endpoint != session!.endpoint) {
        throw StateError('Reset readiness connection changed.');
      }
      return inventory;
    }, retry: (_, _) => null);

enum ConfigurationResetStatus {
  idle,
  reviewing,
  executing,
  accepted,
  rejected,
  unknown,
}

final class ConfigurationResetState {
  const ConfigurationResetState({
    this.status = ConfigurationResetStatus.idle,
    this.message,
    this.server,
    this.hostId,
    this.jobId,
    this.connectionCurrent = true,
    this.verifying = false,
    this.hostVerified = false,
    this.verifiedEndpoint,
    this.changedAddressAccepted = false,
    this.verificationMessage,
  });
  final ConfigurationResetStatus status;
  final String? message, server, hostId, verifiedEndpoint, verificationMessage;
  final int? jobId;
  final bool connectionCurrent, verifying, hostVerified, changedAddressAccepted;
  bool get busy =>
      status == ConfigurationResetStatus.reviewing ||
      status == ConfigurationResetStatus.executing;
  bool get unresolved =>
      status == ConfigurationResetStatus.accepted ||
      status == ConfigurationResetStatus.unknown;
  bool get locked => status == ConfigurationResetStatus.executing || unresolved;
  bool get addressChanged =>
      hostVerified && verifiedEndpoint != null && verifiedEndpoint != server;
  ConfigurationResetState verification({
    bool verifying = false,
    bool verified = false,
    String? endpoint,
    bool addressAccepted = false,
    String? message,
  }) => ConfigurationResetState(
    status: status,
    message: this.message,
    server: server,
    hostId: hostId,
    jobId: jobId,
    connectionCurrent: connectionCurrent,
    verifying: verifying,
    hostVerified: verified,
    verifiedEndpoint: endpoint,
    changedAddressAccepted: addressAccepted,
    verificationMessage: message,
  );
}

final configurationResetControllerProvider =
    NotifierProvider<ConfigurationResetController, ConfigurationResetState>(
      ConfigurationResetController.new,
    );

class ConfigurationResetController extends Notifier<ConfigurationResetState> {
  AuthenticatedSession? _reviewSession, _operationSession, _verifiedSession;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0, _verificationGeneration = 0;
  bool _pending = false;
  final _issued = Expando<int>(), _used = Expando<bool>();
  bool isReviewCurrent(ConfigurationResetReview review) =>
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
  ConfigurationResetState build() {
    final lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next == AppLifecycleState.resumed) return;
        _verificationGeneration++;
        _verifiedSession = null;
        expireContext();
      },
    );
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _verificationGeneration++;
      _verifiedSession = null;
      expireContext();
      if (state.unresolved) {
        state = ConfigurationResetState(
          status: ConfigurationResetStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          jobId: state.jobId,
          connectionCurrent: identical(_operationSession, next),
          message: 'The connection changed after an unresolved factory reset. Independently inspect the original machine. A lost connection is not reset or reboot completion; nothing is replayed.',
        );
      }
    });
    ref.onDispose(() {
      _generation++;
      _verificationGeneration++;
      lifecycle.dispose();
      _release();
    });
    return const ConfigurationResetState();
  }

  ConfigurationResetState _expiredState() => state.locked || _pending
      ? ConfigurationResetState(
          status: ConfigurationResetStatus.unknown,
          server: state.server,
          hostId: state.hostId,
          jobId: state.jobId,
          connectionCurrent: state.connectionCurrent,
          message: 'Factory-reset authorization expired. A submitted request may already have replaced configuration, even if a later hook or reboot fails. Inspect the original machine; do not repeat the request.',
        )
      : const ConfigurationResetState(
          status: ConfigurationResetStatus.rejected,
          message: 'The reset review expired. Nothing is submitted automatically. Reload and review again.',
        );
  void expireContext() {
    if (!ref.mounted) return;
    _generation++;
    _verificationGeneration++;
    _verifiedSession = null;
    _reviewSession = null;
    state = _expiredState();
  }

  /// Invalidate dispatch synchronously; defer status publication during teardown.
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

  Future<ConfigurationResetReview?> review({
    required AuthenticatedSession expectedSession,
    required ConfigurationResetInventory inventory,
    required bool Function() isRouteCurrent,
  }) async {
    final snapshot = ref.read(configurationResetInventoryProvider);
    final api = expectedSession.repository;
    if (state.busy ||
        state.locked ||
        !_active ||
        !_route(isRouteCurrent) ||
        snapshot.isLoading ||
        !identical(snapshot.asData?.value, inventory) ||
        inventory.endpoint != expectedSession.endpoint ||
        inventory.blockedReason != null ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        api is! AuthenticatedConfigurationResetSession ||
        !(api as AuthenticatedConfigurationResetSession)
            .configurationResetCapabilities
            .canReset) {
      return null;
    }
    final generation = ++_generation;
    _reviewSession = expectedSession;
    state = const ConfigurationResetState(
      status: ConfigurationResetStatus.reviewing,
      message:
          'Checking current reset readiness. No factory reset has started.',
    );
    try {
      final request = ConfigurationResetRequest(inventory: inventory);
      final review = await (api as AuthenticatedConfigurationResetSession)
          .reviewConfigurationReset(request);
      if (!ref.mounted || generation != _generation) return null;
      final current = ref.read(configurationResetInventoryProvider);
      if (!_active ||
          !_route(isRouteCurrent) ||
          !identical(
            expectedSession,
            ref.read(dashboardActiveSessionProvider),
          ) ||
          current.isLoading ||
          !identical(current.asData?.value, inventory)) {
        expireContext();
        return null;
      }
      if (!identical(review.request, request) ||
          review.endpoint != expectedSession.endpoint) {
        throw StateError('Mismatched reset review.');
      }
      _issued[review] = generation;
      state = const ConfigurationResetState();
      return review;
    } on Object {
      if (ref.mounted && generation == _generation) {
        _generation++;
        _reviewSession = null;
        state = const ConfigurationResetState(
          status: ConfigurationResetStatus.rejected,
          message: 'Factory-reset review could not be verified. Remote details were withheld. Reload before a new review.',
        );
      }
      return null;
    }
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required ConfigurationResetReview review,
    required String confirmation,
    required bool consoleAccessAccepted,
    required bool independentBackupAccepted,
    required bool dataAndKeyRecoveryAccepted,
    required bool configurationLossAccepted,
    required bool rebootAndPartialFailureAccepted,
    required bool pendingRestoreCheckedAccepted,
    required bool Function() isRouteCurrent,
  }) async {
    if (state.locked ||
        state.busy ||
        _used[review] == true ||
        _issued[review] != _generation) {
      return;
    }
    final inventory = ref.read(configurationResetInventoryProvider),
        api = expectedSession.repository;
    if (!_active ||
        !_route(isRouteCurrent) ||
        !consoleAccessAccepted ||
        !independentBackupAccepted ||
        !dataAndKeyRecoveryAccepted ||
        !configurationLossAccepted ||
        !rebootAndPartialFailureAccepted ||
        !pendingRestoreCheckedAccepted ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        review.request.validationError != null ||
        inventory.isLoading ||
        !identical(inventory.asData?.value, review.request.inventory) ||
        !identical(_reviewSession, expectedSession) ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider)) ||
        api is! AuthenticatedConfigurationResetSession ||
        !(api as AuthenticatedConfigurationResetSession)
            .configurationResetCapabilities
            .canReset) {
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const ConfigurationResetState(
        status: ConfigurationResetStatus.rejected,
        message: 'Another operation is unresolved. No factory-reset request was sent.',
      );
      return;
    }
    _used[review] = true;
    _pending = true;
    _operationSession = expectedSession;
    final generation = ++_generation,
        server = expectedSession.endpoint,
        hostId = review.request.inventory.hostId;
    state = ConfigurationResetState(
      status: ConfigurationResetStatus.executing,
      server: server,
      hostId: hostId,
      message: 'Submitting reset with automatic reboot fixed on. Configuration may change before any job or reboot completion is known.',
    );
    bool current() {
      if (!ref.mounted || generation != _generation) return false;
      final snapshot = ref.read(configurationResetInventoryProvider);
      if (!_active ||
          !_route(isRouteCurrent) ||
          !identical(
            expectedSession,
            ref.read(dashboardActiveSessionProvider),
          ) ||
          snapshot.isLoading ||
          !identical(snapshot.asData?.value, review.request.inventory)) {
        expireContext();
        return false;
      }
      return generation == _generation;
    }

    try {
      final result = await (api as AuthenticatedConfigurationResetSession)
          .executeConfigurationReset(review, confirmation, isCurrent: current);
      if (!current()) return;
      final accepted =
          result.outcome == ConfigurationResetOutcome.accepted &&
          result.jobId != null &&
          result.jobId! > 0 &&
          result.jobId! <= 9007199254740991;
      final rejected = result.outcome == ConfigurationResetOutcome.rejected;
      state = ConfigurationResetState(
        status: accepted
            ? ConfigurationResetStatus.accepted
            : rejected
            ? ConfigurationResetStatus.rejected
            : ConfigurationResetStatus.unknown,
        server: server,
        hostId: hostId,
        jobId: accepted ? result.jobId : null,
        message: accepted
            ? 'Factory-reset job accepted; configuration replacement and reboot completion remain unverified. Independently inspect the original machine. No polling, retry or automatic reconnect occurs.'
            : rejected
            ? 'The reviewed reset was rejected. No completion is claimed. Reload readiness before considering another review.'
            : 'The reset outcome is unverified. Configuration may already have changed and reboot may occur or fail. Independently inspect the original machine before reconnecting; do not repeat the request.',
      );
    } on Object {
      if (ref.mounted && generation == _generation) {
        state = ConfigurationResetState(
          status: ConfigurationResetStatus.unknown,
          server: server,
          hostId: hostId,
          message: 'Factory-reset submission could not be verified. Details were withheld. The factory database or hooks may already have changed the system. Inspect the original machine; do not repeat the reset.',
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
            endpoint: state.verifiedEndpoint,
            addressAccepted: state.changedAddressAccepted,
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
        current?.endpoint != null &&
        !identical(current, _operationSession);
  }

  Future<void> verifyReconnectedServer() async {
    if (!canVerifyReconnectedServer || !_active) return;
    final session = ref.read(dashboardActiveSessionProvider)!,
        api = ref.read(configurationResetSessionProvider);
    if (api == null) return;
    final generation = ++_verificationGeneration;
    _verifiedSession = null;
    state = state.verification(verifying: true);
    ConfigurationResetInventory? inventory;
    try {
      inventory = await api.loadConfigurationReset();
    } on Object {
      /* Fixed public outcome. */
    }
    if (!ref.mounted ||
        generation != _verificationGeneration ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final verified =
        inventory?.hostId == state.hostId &&
        inventory?.endpoint == session.endpoint &&
        inventory?.blockedReason == null;
    _verifiedSession = verified ? session : null;
    state = state.verification(
      verified: verified,
      endpoint: verified ? session.endpoint : null,
      message: verified
          ? 'The claimed permanent host identifier and current readiness match. This is not remote attestation or proof of reset, secure erasure, data recovery or reboot success. Independently inspect the machine and any changed address.'
          : 'The reconnected original host and readiness could not be verified. Details were withheld; writes remain locked.',
    );
  }

  void acknowledgeChangedAddress(bool accepted) {
    if (!_active ||
        !state.addressChanged ||
        !state.hostVerified ||
        !identical(
          _verifiedSession,
          ref.read(dashboardActiveSessionProvider),
        )) {
      return;
    }
    state = state.verification(
      verified: true,
      endpoint: state.verifiedEndpoint,
      addressAccepted: accepted,
      message: state.verificationMessage,
    );
  }

  bool get canAcknowledge =>
      !_pending &&
      canVerifyReconnectedServer &&
      state.hostVerified &&
      (!state.addressChanged || state.changedAddressAccepted) &&
      identical(_verifiedSession, ref.read(dashboardActiveSessionProvider));
  void acknowledgeAfterReconnect() {
    if (!canAcknowledge || !_active) return;
    _release();
    _operationSession = null;
    _verifiedSession = null;
    state = const ConfigurationResetState(
      status: ConfigurationResetStatus.rejected,
      message: 'Independent original-machine inspection acknowledged. The prior reset remains unverified and is not replayed.',
    );
    ref.invalidate(configurationResetInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
