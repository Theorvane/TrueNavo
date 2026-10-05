import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final systemPowerSessionProvider = Provider<AuthenticatedSystemPowerSession?>((
  ref,
) {
  final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repository is AuthenticatedSystemPowerSession
      ? repository as AuthenticatedSystemPowerSession
      : null;
});

final systemPowerInventoryProvider = FutureProvider<SystemPowerInventory>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider);
  final api = ref.watch(systemPowerSessionProvider);
  if (session?.endpoint == null || api == null) {
    throw StateError('A current system power connection is required.');
  }
  if (ref.read(systemPowerControllerProvider).locked) {
    throw StateError(
      'Unresolved power actions require explicit host verification.',
    );
  }
  final inventory = await api.loadSystemPower();
  if (!ref.mounted ||
      !identical(session, ref.read(dashboardActiveSessionProvider)) ||
      inventory.endpoint != session!.endpoint) {
    throw StateError('The system power inventory connection changed.');
  }
  return inventory;
}, retry: (_, _) => null);

final class SystemPowerState {
  const SystemPowerState({
    this.busy = false,
    this.result,
    this.server,
    this.target,
    this.hostId,
    this.connectionCurrent = true,
    this.verifying = false,
    this.hostVerified = false,
    this.verificationMessage,
  });
  final bool busy, connectionCurrent, verifying, hostVerified;
  final SystemPowerResult? result;
  final String? server, target, hostId, verificationMessage;
  bool get accepted => result?.outcome == SystemPowerOutcome.accepted;
  bool get unknown => result?.outcome == SystemPowerOutcome.unknown;
  bool get unresolved => accepted || unknown;
  bool get locked => busy || unresolved;
  SystemPowerState verification({
    bool verifying = false,
    bool verified = false,
    String? message,
  }) => SystemPowerState(
    busy: busy,
    result: result,
    server: server,
    target: target,
    hostId: hostId,
    connectionCurrent: connectionCurrent,
    verifying: verifying,
    hostVerified: verified,
    verificationMessage: message,
  );
}

final systemPowerControllerProvider =
    NotifierProvider<SystemPowerController, SystemPowerState>(
      SystemPowerController.new,
    );

class SystemPowerController extends Notifier<SystemPowerState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  int _verificationGeneration = 0;
  AuthenticatedSession? _verifiedSession;
  final _used = Expando<bool>();

  @override
  SystemPowerState build() {
    final lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next == AppLifecycleState.resumed) return;
        _verificationGeneration++;
        _verifiedSession = null;
        if (state.verifying || state.hostVerified) {
          state = state.verification(
            message: 'Reconnected-host verification expired while the app was not active. Verify again explicitly.',
          );
        }
      },
    );
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _verificationGeneration++;
      _verifiedSession = null;
      if (state.locked) {
        // An expected disconnect proves neither reboot nor shutdown. Keep the
        // shared write fence, even across navigation or a replacement session.
        state = SystemPowerState(
          server: state.server,
          target: state.target,
          hostId: state.hostId,
          connectionCurrent: identical(_session, next),
          result: const SystemPowerResult(
            SystemPowerOutcome.unknown,
            'The connection changed. Independently inspect the original server. Disconnection is not completion; no power request is replayed.',
          ),
        );
      } else {
        _session = null;
        state = const SystemPowerState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _verificationGeneration++;
      lifecycle.dispose();
      _release();
    });
    return const SystemPowerState();
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required SystemPowerReview review,
    required String confirmation,
  }) async {
    if (state.locked || _used[review] == true) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    final inventory = ref.read(systemPowerInventoryProvider);
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed ||
        expectedSession.endpoint == null ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        review.request.validationError != null ||
        inventory.isLoading ||
        !identical(inventory.asData?.value, review.request.inventory) ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      state = const SystemPowerState(
        result: SystemPowerResult(
          SystemPowerOutcome.rejected,
          'The exact target, current inventory or connection changed. Nothing was sent. Reload and review again.',
        ),
      );
      return;
    }
    final api = expectedSession.repository;
    if (api is! AuthenticatedSystemPowerSession ||
        !(api as AuthenticatedSystemPowerSession).systemPowerCapabilities
            .supports(review.action)) {
      return;
    }
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const SystemPowerState(
        result: SystemPowerResult(
          SystemPowerOutcome.rejected,
          'Another operation is pending or unverified. Nothing was sent.',
        ),
      );
      return;
    }
    _session = expectedSession;
    _used[review] = true;
    final generation = ++_generation;
    state = SystemPowerState(
      busy: true,
      server: expectedSession.endpoint,
      target: review.target,
      hostId: review.request.inventory.hostId,
    );
    SystemPowerResult result;
    try {
      result = await (api as AuthenticatedSystemPowerSession)
          .executeSystemPower(review, confirmation);
    } on SystemPowerException catch (error) {
      result = SystemPowerResult(
        SystemPowerOutcome.rejected,
        error.userMessage,
      );
    } on Object {
      result = const SystemPowerResult(
        SystemPowerOutcome.unknown,
        'The power request outcome could not be verified. Independently inspect the original server before reconnecting. Do not repeat the request.',
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    if (result.outcome == SystemPowerOutcome.accepted &&
        (result.jobId == null || result.jobId! <= 0)) {
      result = const SystemPowerResult(
        SystemPowerOutcome.unknown,
        'The accepted power job identity was not verified. Independently inspect the original server. Do not repeat the request.',
      );
    }
    state = SystemPowerState(
      server: state.server,
      target: state.target,
      hostId: state.hostId,
      result: result,
    );
    if (!state.locked) _release();
    // No job checks, automatic reads, timers, reconnects, or replay after power.
  }

  bool get canVerifyReconnectedServer {
    final current = ref.read(dashboardActiveSessionProvider);
    return state.unresolved &&
        !state.verifying &&
        !state.connectionCurrent &&
        current?.endpoint != null &&
        current!.endpoint == state.server &&
        !identical(current, _session);
  }

  Future<void> verifyReconnectedServer() async {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!canVerifyReconnectedServer ||
        lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return;
    }
    final session = ref.read(dashboardActiveSessionProvider)!;
    final api = session.repository;
    if (api is! AuthenticatedSystemPowerSession) return;
    final generation = ++_verificationGeneration;
    _verifiedSession = null;
    state = state.verification(verifying: true);
    SystemPowerInventory? inventory;
    try {
      inventory = await (api as AuthenticatedSystemPowerSession)
          .loadSystemPower();
    } on Object {
      // Public fixed error below; retain the original-server write fence.
    }
    if (!ref.mounted ||
        generation != _verificationGeneration ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final verified =
        inventory != null &&
        inventory.endpoint == state.server &&
        inventory.endpoint == session.endpoint &&
        inventory.hostId == state.hostId;
    _verifiedSession = verified ? session : null;
    state = state.verification(
      verified: verified,
      message: verified
          ? 'The reconnected public host identity matches. This does not prove the prior power operation completed; independent inspection is still required.'
          : 'The reconnected host identity could not be verified as the original machine. Details were withheld. The write lock remains.',
    );
  }

  bool get canAcknowledge =>
      canVerifyReconnectedServer &&
      state.hostVerified &&
      identical(_verifiedSession, ref.read(dashboardActiveSessionProvider));

  void acknowledgeAfterReconnect() {
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (!canAcknowledge ||
        lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      return;
    }
    _release();
    _session = null;
    _verifiedSession = null;
    state = const SystemPowerState(
      result: SystemPowerResult(
        SystemPowerOutcome.rejected,
        'You acknowledged independent inspection after reconnecting. The prior power operation is not marked successful. Reload readiness; no request was replayed.',
      ),
    );
    ref.invalidate(systemPowerInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
