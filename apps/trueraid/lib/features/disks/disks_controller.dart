import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final disksSessionProvider = Provider<AuthenticatedDisksSession?>((ref) {
  final repo = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repo is AuthenticatedDisksSession
      ? repo as AuthenticatedDisksSession
      : null;
});
final disksInventoryProvider = FutureProvider<DiskInventory>((ref) async {
  final session = ref.watch(dashboardActiveSessionProvider),
      api = ref.watch(disksSessionProvider);
  if (session?.endpoint == null || api == null) {
    throw StateError('A current disk connection is required.');
  }
  final inventory = await api.loadDisks();
  if (!ref.mounted ||
      !identical(session, ref.read(dashboardActiveSessionProvider)) ||
      inventory.endpoint != session!.endpoint) {
    throw StateError('The disk inventory connection changed.');
  }
  return inventory;
}, retry: (_, _) => null);

final class DisksState {
  const DisksState({
    this.busy = false,
    this.result,
    this.server,
    this.target,
    this.connectionCurrent = true,
  });
  final bool busy, connectionCurrent;
  final DiskResult? result;
  final String? server, target;
  bool get unknown => result?.outcome == DiskOutcome.unknown;
  bool get locked => busy || unknown;
}

final disksControllerProvider = NotifierProvider<DisksController, DisksState>(
  DisksController.new,
);

class DisksController extends Notifier<DisksState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  final _used = Expando<bool>();
  @override
  DisksState build() {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _release();
      if (state.locked) {
        state = DisksState(
          server: state.server,
          target: state.target,
          connectionCurrent: identical(_session, next),
          result: const DiskResult(
            DiskOutcome.unknown,
            'The connection changed. Inspect the original server; no disk setting change is replayed.',
          ),
        );
        if (identical(_session, next)) _owner = _lock?.acquire();
      } else {
        _session = null;
        state = const DisksState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const DisksState();
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required DiskReview review,
    required String confirmation,
  }) async {
    if (state.locked || _used[review] == true) return;
    if (expectedSession.endpoint == null ||
        confirmation != review.target ||
        review.endpoint != expectedSession.endpoint ||
        review.request.inventory.endpoint != expectedSession.endpoint ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      state = const DisksState(
        result: DiskResult(
          DiskOutcome.rejected,
          'The exact target or connection changed. Nothing was sent.',
        ),
      );
      return;
    }
    final api = expectedSession.repository;
    if (api is! AuthenticatedDisksSession) return;
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const DisksState(
        result: DiskResult(
          DiskOutcome.rejected,
          'Another operation is pending or unverified. Nothing was sent.',
        ),
      );
      return;
    }
    _session = expectedSession;
    _used[review] = true;
    final generation = ++_generation;
    state = DisksState(
      busy: true,
      server: expectedSession.endpoint,
      target: review.target,
    );
    DiskResult result;
    try {
      result = await (api as AuthenticatedDisksSession).executeDisk(
        review,
        confirmation,
      );
    } on DisksException catch (e) {
      result = DiskResult(DiskOutcome.rejected, e.userMessage);
    } on Object {
      result = const DiskResult(
        DiskOutcome.unknown,
        'The disk outcome could not be verified. Inspect the original server before reconnecting. Do not repeat the request.',
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    state = DisksState(
      server: state.server,
      target: state.target,
      result: result,
    );
    if (!state.locked) {
      _release();
      ref.invalidate(disksInventoryProvider);
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
    state = const DisksState(
      result: DiskResult(
        DiskOutcome.rejected,
        'Prior effects remain unverified. Current disk settings are reloaded without replaying the operation.',
      ),
    );
    ref.invalidate(disksInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
