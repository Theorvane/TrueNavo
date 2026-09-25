import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final zvolsSessionProvider = Provider<AuthenticatedZvolsSession?>((ref) {
  final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repository is AuthenticatedZvolsSession
      ? repository as AuthenticatedZvolsSession
      : null;
});
final zvolsInventoryProvider = FutureProvider<ZvolInventory>((ref) async {
  final api = ref.watch(zvolsSessionProvider);
  if (api == null) {
    throw const ZvolException(ZvolExceptionReason.notAuthenticated);
  }
  return api.loadZvols();
}, retry: (_, _) => null);

final class ZvolsState {
  const ZvolsState({
    this.busy = false,
    this.result,
    this.target,
    this.server,
    this.connectionCurrent = true,
  });
  final bool busy, connectionCurrent;
  final ZvolResult? result;
  final String? target, server;
  bool get unknown => result?.outcome == ZvolOutcome.unknown;
  bool get locked => busy || unknown;
}

final zvolsControllerProvider = NotifierProvider<ZvolsController, ZvolsState>(
  ZvolsController.new,
);

class ZvolsController extends Notifier<ZvolsState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  var _generation = 0;
  @override
  ZvolsState build() {
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (identical(_session, next)) return;
      _generation++;
      _release();
      state = state.locked
          ? ZvolsState(
              connectionCurrent: false,
              target: state.target,
              server: state.server,
              result: const ZvolResult(
                ZvolOutcome.unknown,
                'The original storage operation may have applied. Inspect that server; do not replay it.',
              ),
            )
          : const ZvolsState();
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const ZvolsState();
  }

  Future<void> execute(
    AuthenticatedSession session,
    ZvolReview review,
    String confirmation,
  ) async {
    if (state.locked ||
        confirmation != review.target ||
        session.endpoint == null ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final api = ref.read(zvolsSessionProvider);
    if (api == null) return;
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const ZvolsState(
        result: ZvolResult(
          ZvolOutcome.rejected,
          'Another server change is already in progress.',
        ),
      );
      return;
    }
    _session = session;
    final generation = ++_generation;
    state = ZvolsState(
      busy: true,
      target: review.target,
      server: session.endpoint,
    );
    ZvolResult result;
    try {
      result = await api.executeZvolReview(review, confirmation);
    } on ZvolException catch (error) {
      result = ZvolResult(ZvolOutcome.rejected, error.userMessage);
    } on Object {
      result = const ZvolResult(
        ZvolOutcome.unknown,
        'Storage may have changed. Inspect the original server and reconnect; do not retry.',
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    state = ZvolsState(
      result: result,
      target: review.target,
      server: session.endpoint,
    );
    if (!state.unknown) _release();
    ref.invalidate(zvolsInventoryProvider);
  }

  void acknowledgeAfterReconnect() {
    final current = ref.read(dashboardActiveSessionProvider);
    if (state.unknown &&
        !state.connectionCurrent &&
        current != null &&
        current.endpoint == state.server &&
        !identical(current, _session)) {
      _release();
      state = const ZvolsState();
      ref.invalidate(zvolsInventoryProvider);
    }
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
