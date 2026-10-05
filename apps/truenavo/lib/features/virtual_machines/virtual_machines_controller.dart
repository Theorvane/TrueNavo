import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final virtualMachinesSessionProvider =
    Provider<AuthenticatedVirtualMachinesSession?>((ref) {
      final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
      return repository is AuthenticatedVirtualMachinesSession
          ? repository as AuthenticatedVirtualMachinesSession
          : null;
    });
final virtualMachinesInventoryProvider = FutureProvider<VmInventory>((
  ref,
) async {
  final api = ref.watch(virtualMachinesSessionProvider);
  if (api == null) throw const VmException(VmExceptionReason.disconnected);
  return api.loadVirtualMachines();
});
final virtualMachineChoicesProvider = FutureProvider.autoDispose<VmChoices>((
  ref,
) async {
  final api = ref.watch(virtualMachinesSessionProvider);
  if (api == null) throw const VmException(VmExceptionReason.disconnected);
  return api.loadVmChoices();
});

final class VirtualMachinesState {
  const VirtualMachinesState({
    this.busy = false,
    this.result,
    this.target,
    this.server,
    this.identity,
    this.connectionCurrent = true,
  });
  final bool busy, connectionCurrent;
  final VmOperationResult? result;
  final String? target, server, identity;
  bool get pending =>
      result?.outcome == VmOperationOutcome.submitted ||
      result?.outcome == VmOperationOutcome.running;
  bool get unknown => result?.outcome == VmOperationOutcome.unknown;
  bool get locked => busy || pending || unknown;
}

final virtualMachinesControllerProvider =
    NotifierProvider<VirtualMachinesController, VirtualMachinesState>(
      VirtualMachinesController.new,
    );

class VirtualMachinesController extends Notifier<VirtualMachinesState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  Timer? _timer;
  int _generation = 0, _polls = 0;
  @override
  VirtualMachinesState build() {
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (identical(_session, next)) return;
      _generation++;
      _timer?.cancel();
      _release();
      state = state.locked
          ? VirtualMachinesState(
              connectionCurrent: false,
              target: state.target,
              server: state.server,
              identity: state.identity,
              result: VmOperationResult(
                outcome: VmOperationOutcome.unknown,
                operation: state.result?.operation,
              ),
            )
          : const VirtualMachinesState();
    });
    ref.onDispose(() {
      _generation++;
      _timer?.cancel();
      _release();
    });
    return const VirtualMachinesState();
  }

  Future<void> execute(
    AuthenticatedSession session,
    VmReview review,
    String confirmation,
  ) async {
    if (state.locked ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final api = ref.read(virtualMachinesSessionProvider);
    if (api == null) return;
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const VirtualMachinesState(
        result: VmOperationResult(outcome: VmOperationOutcome.rejected),
      );
      return;
    }
    _session = session;
    final generation = ++_generation;
    _polls = 0;
    state = VirtualMachinesState(
      busy: true,
      target: review.targetName,
      server: session.endpoint,
      identity: review.identity,
    );
    VmOperationResult result;
    try {
      result = await api.executeVmReview(review, confirmation: confirmation);
    } on VmException {
      result = const VmOperationResult(outcome: VmOperationOutcome.rejected);
    } on Object {
      result = const VmOperationResult(outcome: VmOperationOutcome.unknown);
    }
    if (_current(generation)) {
      _accept(result);
    } else if (ref.mounted &&
        identical(_session, session) &&
        state.unknown &&
        !state.connectionCurrent &&
        result.operation != null) {
      // A late receipt belongs only to the clearly labeled original operation.
      // It is not polled or treated as current-connection success.
      state = VirtualMachinesState(
        target: state.target,
        server: state.server,
        identity: state.identity,
        connectionCurrent: false,
        result: VmOperationResult(
          outcome: VmOperationOutcome.unknown,
          operation: result.operation,
        ),
      );
    }
  }

  Future<void> checkProgress() async {
    final handle = state.result?.operation;
    final api = ref.read(virtualMachinesSessionProvider);
    if (!state.pending ||
        state.busy ||
        handle == null ||
        api == null ||
        !_current(_generation)) {
      return;
    }
    final generation = _generation;
    _timer?.cancel();
    state = VirtualMachinesState(
      busy: true,
      result: state.result,
      target: state.target,
      server: state.server,
      identity: state.identity,
    );
    VmOperationResult result;
    try {
      result = await api.pollVmOperation(handle);
    } on VmException catch (error) {
      result = error.reason == VmExceptionReason.busy
          ? state.result!
          : const VmOperationResult(outcome: VmOperationOutcome.unknown);
    } on Object {
      result = const VmOperationResult(outcome: VmOperationOutcome.unknown);
    }
    if (_current(generation)) _accept(result);
  }

  void _accept(VmOperationResult result) {
    state = VirtualMachinesState(
      result:
          result.outcome == VmOperationOutcome.unknown &&
              result.operation == null
          ? VmOperationResult(
              outcome: result.outcome,
              operation: state.result?.operation,
            )
          : result,
      target: state.target,
      server: state.server,
      identity: state.identity,
    );
    if (state.pending) {
      if (_polls++ < 60) {
        _timer = Timer(const Duration(seconds: 2), checkProgress);
      }
    } else {
      _timer?.cancel();
      if (!state.unknown) _release();
      ref.invalidate(virtualMachinesInventoryProvider);
      ref.invalidate(virtualMachineChoicesProvider);
    }
  }

  bool _current(int generation) =>
      ref.mounted &&
      generation == _generation &&
      identical(_session, ref.read(dashboardActiveSessionProvider));
  void acknowledgeAfterReconnect() {
    if (state.unknown &&
        !state.connectionCurrent &&
        ref.read(dashboardActiveSessionProvider) != null &&
        !identical(_session, ref.read(dashboardActiveSessionProvider))) {
      _release();
      _session = null;
      state = const VirtualMachinesState();
    }
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
