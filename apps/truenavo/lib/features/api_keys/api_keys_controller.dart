import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final apiKeysSessionProvider = Provider<AuthenticatedApiKeysSession?>((ref) {
  final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repository is AuthenticatedApiKeysSession
      ? repository as AuthenticatedApiKeysSession
      : null;
});
final apiKeysInventoryProvider = FutureProvider<ApiKeyInventory>((ref) async {
  final session = ref.watch(dashboardActiveSessionProvider);
  final api = ref.watch(apiKeysSessionProvider);
  if (session?.endpoint == null || api == null) {
    throw StateError('A current API-key connection is required.');
  }
  return api.loadApiKeys();
}, retry: (_, _) => null);

/// Secret-bearing results are NEVER retained here. The one-time secret is
/// returned directly to the caller and must be discarded when no longer current.
final class ApiKeysState {
  const ApiKeysState({
    this.busy = false,
    this.result,
    this.server,
    this.connectionCurrent = true,
    this.recoveryMessage,
  });
  final bool busy, connectionCurrent;
  final ApiKeyResult? result;
  final String? server, recoveryMessage;
  bool get unknown => result?.outcome == ApiKeyOutcome.unknown;
  bool get locked => busy || unknown;
}

final apiKeysControllerProvider =
    NotifierProvider<ApiKeysController, ApiKeysState>(ApiKeysController.new);

class ApiKeysController extends Notifier<ApiKeysState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  final _used = Expando<bool>();
  @override
  ApiKeysState build() {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _release();
      if (state.locked) {
        state = ApiKeysState(
          server: state.server,
          connectionCurrent: identical(_session, next),
          result: const ApiKeyResult(
            ApiKeyOutcome.unknown,
            'The connection changed. Verify the original server and key clients before another change. No request is replayed.',
          ),
        );
        if (identical(_session, next)) _owner = _lock?.acquire();
      } else {
        _session = null;
        state = const ApiKeysState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const ApiKeysState();
  }

  Future<ApiKeyOneTimeSecret?> execute({
    required AuthenticatedSession expectedSession,
    required ApiKeyReview review,
    required String confirmation,
  }) async {
    if (state.locked || _used[review] == true) return null;
    if (expectedSession.endpoint == null ||
        confirmation != review.target ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      state = const ApiKeysState(
        result: ApiKeyResult(
          ApiKeyOutcome.rejected,
          'The exact target or connection changed. Nothing was sent.',
        ),
      );
      return null;
    }
    final api = expectedSession.repository;
    if (api is! AuthenticatedApiKeysSession) return null;
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const ApiKeysState(
        result: ApiKeyResult(
          ApiKeyOutcome.rejected,
          'Another server operation is in progress. Nothing was sent.',
        ),
      );
      return null;
    }
    _session = expectedSession;
    _used[review] = true;
    final generation = ++_generation;
    state = ApiKeysState(busy: true, server: expectedSession.endpoint);
    ApiKeyResult result;
    try {
      result = await (api as AuthenticatedApiKeysSession).executeApiKey(
        review,
        confirmation,
      );
    } on ApiKeysException catch (error) {
      result = ApiKeyResult(ApiKeyOutcome.rejected, error.userMessage);
    } on Object {
      result = const ApiKeyResult(
        ApiKeyOutcome.unknown,
        'The key change outcome could not be verified. Inspect the original server and reconnect; do not repeat it.',
      );
    }
    if (!ref.mounted ||
        generation != _generation ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      result.secret?.discard();
      return null;
    }
    // Only fixed messages and outcomes are stored; key material bypasses state.
    state = ApiKeysState(
      server: expectedSession.endpoint,
      result: result.withoutSecret,
    );
    if (!state.unknown) {
      _release();
      ref.invalidate(apiKeysInventoryProvider);
    }
    if (result.outcome != ApiKeyOutcome.succeeded) {
      result.secret?.discard();
      return null;
    }
    return result.secret;
  }

  bool get canAcknowledge {
    final current = ref.read(dashboardActiveSessionProvider);
    return state.unknown &&
        !state.connectionCurrent &&
        current?.endpoint != null &&
        current!.endpoint == state.server &&
        !identical(current, _session);
  }

  void noteSecretDiscarded(AuthenticatedSession expectedSession) {
    if (state.locked ||
        state.result?.outcome != ApiKeyOutcome.succeeded ||
        !identical(_session, expectedSession) ||
        !identical(expectedSession, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    state = ApiKeysState(
      server: state.server,
      result: const ApiKeyResult(
        ApiKeyOutcome.succeeded,
        'The server confirmed the key change. TrueNavo no longer holds its one-time value. If you did not save it, inspect the key list and plan a separate rotation; do not repeat the original request.',
      ),
    );
  }

  void acknowledgeAfterReconnect() {
    if (!canAcknowledge) return;
    _release();
    _session = null;
    state = const ApiKeysState(
      recoveryMessage: 'Prior completion remains unverified. Current keys are reloaded; the previous request was not replayed.',
    );
    ref.invalidate(apiKeysInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
