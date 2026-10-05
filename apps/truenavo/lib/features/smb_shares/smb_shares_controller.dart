import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final smbSharesSessionProvider = Provider<AuthenticatedSmbSharesSession?>((
  ref,
) {
  final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repository is AuthenticatedSmbSharesSession
      ? repository as AuthenticatedSmbSharesSession
      : null;
});
final smbSharesInventoryProvider = FutureProvider<SmbShareInventory>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider);
  final api = ref.watch(smbSharesSessionProvider);
  if (session?.endpoint == null || api == null) {
    throw StateError('A current SMB connection is required.');
  }
  return api.loadSmbShares();
}, retry: (_, _) => null);

/// The SDK also proves all attachment and mount dependencies at review.
Iterable<SmbShareDataset> smbCreationDatasets(SmbShareInventory inventory) =>
    inventory.datasets.where(
      (dataset) =>
          dataset.editable &&
          !inventory.shares.any((share) => share.path == dataset.mountpoint),
    );

final class SmbSharesState {
  const SmbSharesState({
    this.busy = false,
    this.result,
    this.server,
    this.target,
    this.action,
    this.connectionCurrent = true,
    this.recoveryMessage,
  });
  final bool busy, connectionCurrent;
  final SmbShareResult? result;
  final String? server, target, recoveryMessage;
  final SmbShareAction? action;
  bool get unknown => result?.outcome == SmbShareOutcome.unknown;
  bool get locked => busy || unknown;
}

final smbSharesControllerProvider =
    NotifierProvider<SmbSharesController, SmbSharesState>(
      SmbSharesController.new,
    );

class SmbSharesController extends Notifier<SmbSharesState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  final _used = Expando<bool>();
  @override
  SmbSharesState build() {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _release();
      if (state.locked) {
        state = SmbSharesState(
          server: state.server,
          target: state.target,
          action: state.action,
          connectionCurrent: identical(_session, next),
          result: const SmbShareResult(
            SmbShareOutcome.unknown,
            'The connection changed. Inspect the original SMB configuration and clients before another change. Nothing is replayed.',
          ),
        );
        if (identical(_session, next)) _owner = _lock?.acquire();
      } else {
        _session = null;
        state = const SmbSharesState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const SmbSharesState();
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required SmbShareReview review,
    required String confirmation,
  }) async {
    if (state.locked || _used[review] == true) return;
    if (expectedSession.endpoint == null ||
        confirmation != review.target ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      state = const SmbSharesState(
        result: SmbShareResult(
          SmbShareOutcome.rejected,
          'The exact target or connection changed. Nothing was sent.',
        ),
      );
      return;
    }
    final api = expectedSession.repository;
    if (api is! AuthenticatedSmbSharesSession) return;
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const SmbSharesState(
        result: SmbShareResult(
          SmbShareOutcome.rejected,
          'Another server operation is in progress. Nothing was sent.',
        ),
      );
      return;
    }
    _session = expectedSession;
    _used[review] = true;
    final generation = ++_generation;
    state = SmbSharesState(
      busy: true,
      server: expectedSession.endpoint,
      target: review.target,
      action: review.action,
    );
    SmbShareResult result;
    try {
      result = await (api as AuthenticatedSmbSharesSession).executeSmbShare(
        review,
        confirmation,
      );
    } on SmbSharesException catch (error) {
      // The SDK throws typed failures before dispatch; ambiguous writes return
      // an unknown result. Never turn an untyped failure into a retryable write.
      result = SmbShareResult(SmbShareOutcome.rejected, error.userMessage);
    } on Object {
      result = const SmbShareResult(
        SmbShareOutcome.unknown,
        'The outcome could not be verified. Inspect the original server and clients, then reconnect. Do not repeat this request.',
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    state = SmbSharesState(
      server: expectedSession.endpoint,
      target: review.target,
      action: review.action,
      result: result,
    );
    if (!state.unknown) {
      _release();
      ref.invalidate(smbSharesInventoryProvider);
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
    state = const SmbSharesState(
      recoveryMessage: 'Prior completion remains unverified. Current inventory is reloaded; no prior request was replayed.',
    );
    ref.invalidate(smbSharesInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
