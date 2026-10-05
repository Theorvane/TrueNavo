import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final nfsSharesSessionProvider = Provider<AuthenticatedNfsSharesSession?>((
  ref,
) {
  final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repository is AuthenticatedNfsSharesSession
      ? repository as AuthenticatedNfsSharesSession
      : null;
});
final nfsSharesInventoryProvider = FutureProvider<NfsShareInventory>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider);
  final api = ref.watch(nfsSharesSessionProvider);
  if (session?.endpoint == null || api == null) {
    throw StateError('A live NFS connection is required.');
  }
  return api.loadNfsShares();
}, retry: (_, _) => null);

final class NfsSharesState {
  const NfsSharesState({
    this.busy = false,
    this.result,
    this.server,
    this.target,
    this.action,
    this.connectionCurrent = true,
    this.recoveryMessage,
  });
  final bool busy, connectionCurrent;
  final NfsShareResult? result;
  final String? server, target, recoveryMessage;
  final NfsShareAction? action;
  bool get unknown => result?.outcome == NfsShareOutcome.unknown;
  bool get locked => busy || unknown;
}

final nfsSharesControllerProvider =
    NotifierProvider<NfsSharesController, NfsSharesState>(
      NfsSharesController.new,
    );

class NfsSharesController extends Notifier<NfsSharesState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  final _used = Expando<bool>();
  AuthenticatedSession? get operationSession => _session;
  @override
  NfsSharesState build() {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _release();
      if (state.locked) {
        state = NfsSharesState(
          server: state.server,
          target: state.target,
          action: state.action,
          connectionCurrent: identical(_session, next),
          result: const NfsShareResult(
            NfsShareOutcome.unknown,
            'The connection changed. Inspect NFS configuration and clients on the original server. No request is replayed.',
          ),
        );
        if (identical(_session, next)) _owner = _lock?.acquire();
      } else {
        _session = null;
        state = const NfsSharesState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const NfsSharesState();
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required NfsShareReview review,
    required String confirmation,
  }) async {
    if (state.locked || _used[review] == true) return;
    if (expectedSession.endpoint == null ||
        confirmation != review.target ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      state = const NfsSharesState(
        result: NfsShareResult(
          NfsShareOutcome.rejected,
          'The exact target or connection changed. Nothing was sent.',
        ),
      );
      return;
    }
    final repository = expectedSession.repository;
    if (repository is! AuthenticatedNfsSharesSession) return;
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const NfsSharesState(
        result: NfsShareResult(
          NfsShareOutcome.rejected,
          'Another server operation is in progress. Nothing was sent.',
        ),
      );
      return;
    }
    _session = expectedSession;
    _used[review] = true;
    final generation = ++_generation;
    state = NfsSharesState(
      busy: true,
      server: expectedSession.endpoint,
      target: review.target,
      action: review.action,
    );
    NfsShareResult result;
    try {
      result = await (repository as AuthenticatedNfsSharesSession)
          .executeNfsShare(review, confirmation);
    } on NfsSharesException catch (e) {
      result = NfsShareResult(NfsShareOutcome.rejected, e.userMessage);
    } on Object {
      result = const NfsShareResult(
        NfsShareOutcome.unknown,
        'The outcome could not be verified. Inspect the original server and clients; do not repeat this request.',
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    state = NfsSharesState(
      server: expectedSession.endpoint,
      target: review.target,
      action: review.action,
      result: result,
    );
    if (!state.unknown) {
      _release();
      ref.invalidate(nfsSharesInventoryProvider);
    }
  }

  bool get canAcknowledge {
    final current = ref.read(dashboardActiveSessionProvider);
    return state.unknown &&
        !state.connectionCurrent &&
        current?.endpoint != null &&
        current!.endpoint == state.server &&
        !identical(current, _session);
  }

  void acknowledgeAfterReconnect() {
    if (!canAcknowledge) return;
    _release();
    _session = null;
    state = const NfsSharesState(
      recoveryMessage: 'Prior completion remains unverified. Current inventory is reloaded; no prior request was replayed.',
    );
    ref.invalidate(nfsSharesInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
