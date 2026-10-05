import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final cloudCredentialsSessionProvider =
    Provider<AuthenticatedCloudCredentialsSession?>((ref) {
      final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
      return repository is AuthenticatedCloudCredentialsSession
          ? repository as AuthenticatedCloudCredentialsSession
          : null;
    });
final cloudCredentialsInventoryProvider =
    FutureProvider<CloudCredentialInventory>((ref) async {
      final session = ref.watch(dashboardActiveSessionProvider),
          api = ref.watch(cloudCredentialsSessionProvider);
      if (session?.endpoint == null || api == null) {
        throw StateError('A current credential connection is required.');
      }
      return api.loadCloudCredentials();
    }, retry: (_, _) => null);

final class CloudCredentialsState {
  const CloudCredentialsState({
    this.busy = false,
    this.result,
    this.server,
    this.target,
    this.connectionCurrent = true,
  });
  final bool busy, connectionCurrent;
  final CloudCredentialResult? result;
  final String? server, target;
  bool get unknown => result?.outcome == CloudCredentialOutcome.unknown;
  bool get locked => busy || unknown;
}

final cloudCredentialsControllerProvider =
    NotifierProvider<CloudCredentialsController, CloudCredentialsState>(
      CloudCredentialsController.new,
    );

class CloudCredentialsController extends Notifier<CloudCredentialsState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  int _generation = 0;
  final _used = Expando<bool>();
  @override
  CloudCredentialsState build() {
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      _generation++;
      _release();
      if (state.locked) {
        state = CloudCredentialsState(
          server: state.server,
          target: state.target,
          connectionCurrent: identical(_session, next),
          result: const CloudCredentialResult(
            CloudCredentialOutcome.unknown,
            'The connection changed. Inspect the original server. No credential input is replayed.',
          ),
        );
        if (identical(_session, next)) _owner = _lock?.acquire();
      } else {
        _session = null;
        state = const CloudCredentialsState();
      }
    });
    ref.onDispose(() {
      _generation++;
      _release();
    });
    return const CloudCredentialsState();
  }

  Future<void> execute({
    required AuthenticatedSession expectedSession,
    required CloudCredentialReview review,
    required String confirmation,
    CloudCredentialWriteOnlyInput? input,
  }) async {
    try {
      if (state.locked || _used[review] == true) return;
      if (expectedSession.endpoint == null ||
          confirmation != review.target ||
          review.endpoint != expectedSession.endpoint ||
          review.request.inventory.endpoint != expectedSession.endpoint ||
          !identical(
            expectedSession,
            ref.read(dashboardActiveSessionProvider),
          )) {
        state = const CloudCredentialsState(
          result: CloudCredentialResult(
            CloudCredentialOutcome.rejected,
            'The exact target or connection changed. Nothing was sent.',
          ),
        );
        return;
      }
      final api = expectedSession.repository;
      if (api is! AuthenticatedCloudCredentialsSession) return;
      _lock = ref.read(serverOperationLockProvider);
      _owner = _lock!.acquire();
      if (_owner == null) {
        state = const CloudCredentialsState(
          result: CloudCredentialResult(
            CloudCredentialOutcome.rejected,
            'Another operation is pending or unverified. Nothing was sent.',
          ),
        );
        return;
      }
      _session = expectedSession;
      _used[review] = true;
      final generation = ++_generation;
      state = CloudCredentialsState(
        busy: true,
        server: expectedSession.endpoint,
        target: review.target,
      );
      CloudCredentialResult result;
      try {
        result = await (api as AuthenticatedCloudCredentialsSession)
            .executeCloudCredential(review, confirmation, input: input);
      } on CloudCredentialsException catch (e) {
        result = CloudCredentialResult(
          CloudCredentialOutcome.rejected,
          e.userMessage,
        );
      } on Object {
        result = const CloudCredentialResult(
          CloudCredentialOutcome.unknown,
          'The outcome could not be verified. Inspect the original server before reconnecting. Do not repeat the request.',
        );
      }
      if (!ref.mounted ||
          generation != _generation ||
          !identical(
            expectedSession,
            ref.read(dashboardActiveSessionProvider),
          )) {
        return;
      }
      state = CloudCredentialsState(
        server: state.server,
        target: state.target,
        result: result,
      );
      if (!state.locked) {
        _release();
        ref.invalidate(cloudCredentialsInventoryProvider);
      }
    } finally {
      input?.dispose();
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
    state = const CloudCredentialsState(
      result: CloudCredentialResult(
        CloudCredentialOutcome.rejected,
        'Prior effects remain unverified. Information is reloaded without replaying the credential change.',
      ),
    );
    ref.invalidate(cloudCredentialsInventoryProvider);
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
