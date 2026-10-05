import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final accountsSessionProvider = Provider<AuthenticatedAccountsSession?>((ref) {
  final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repository is AuthenticatedAccountsSession
      ? repository as AuthenticatedAccountsSession
      : null;
});
final accountsInventoryProvider = FutureProvider<AccountsInventory>((
  ref,
) async {
  final api = ref.watch(accountsSessionProvider);
  if (api == null) {
    throw const AccountsException(AccountsExceptionReason.notAuthenticated);
  }
  return api.loadAccounts();
});

final class AccountsState {
  const AccountsState({
    this.busy = false,
    this.result,
    this.message,
    this.target,
    this.server,
    this.connectionCurrent = true,
  });
  final bool busy, connectionCurrent;
  final AccountsOperationResult? result;
  final String? message, target, server;
  bool get unknown => result?.outcome == AccountsOperationOutcome.unknown;
  bool get locked => busy || unknown;
}

final accountsControllerProvider =
    NotifierProvider<AccountsController, AccountsState>(AccountsController.new);

class AccountsController extends Notifier<AccountsState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  @override
  AccountsState build() {
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (identical(_session, next)) return;
      _generation++;
      _release();
      state = state.locked
          ? AccountsState(
              connectionCurrent: false,
              target: state.target,
              server: state.server,
              result: const AccountsOperationResult(
                AccountsOperationOutcome.unknown,
              ),
            )
          : const AccountsState();
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const AccountsState();
  }

  Future<void> perform(
    AuthenticatedSession session,
    String target,
    Future<AccountsOperationResult> Function(AuthenticatedAccountsSession)
    action,
  ) async {
    if (state.locked ||
        session.endpoint == null ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final api = session.repository;
    if (api is! AuthenticatedAccountsSession) return;
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const AccountsState(
        message: 'Another server operation is in progress.',
      );
      return;
    }
    _session = session;
    final generation = ++_generation;
    state = AccountsState(busy: true, target: target, server: session.endpoint);
    AccountsOperationResult? result;
    String? message;
    var refresh = false;
    try {
      result = await action(api as AuthenticatedAccountsSession);
      refresh = true;
    } on AccountsException catch (error) {
      message = error.userMessage;
      refresh = error.reason == AccountsExceptionReason.staleSnapshot;
    } on Object {
      result = const AccountsOperationResult(AccountsOperationOutcome.unknown);
      refresh = true;
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    state = AccountsState(
      result: result,
      message: message,
      target: target,
      server: session.endpoint,
    );
    if (!state.unknown) _release();
    if (refresh) ref.invalidate(accountsInventoryProvider);
  }

  void acknowledgeAfterReconnect() {
    final session = ref.read(dashboardActiveSessionProvider);
    if (state.unknown &&
        !state.connectionCurrent &&
        session?.endpoint != null &&
        !identical(session, _session)) {
      _release();
      state = const AccountsState();
    }
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
