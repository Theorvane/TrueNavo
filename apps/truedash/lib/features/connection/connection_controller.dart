import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import 'connection_state.dart';

final rpcConnectorProvider = Provider<RpcConnector>(
  (ref) => const WebSocketRpcConnector(),
);

final credentialVaultProvider = Provider<CredentialVault>(
  (ref) => const NoopCredentialVault(),
);

typedef SessionRepositoryFactory = SessionRepository Function({
  required RpcConnector connector,
  required CredentialVault credentialVault,
});

final sessionRepositoryFactoryProvider = Provider<SessionRepositoryFactory>(
  (ref) =>
      ({required connector, required credentialVault}) =>
          TrueNasSessionRepository(
            connector: connector,
            credentialVault: credentialVault,
          ),
);

final sessionRepositoryProvider = Provider<SessionRepository>(
  (ref) => ref.watch(sessionRepositoryFactoryProvider)(
    connector: ref.watch(rpcConnectorProvider),
    credentialVault: ref.watch(credentialVaultProvider),
  ),
);

final connectionControllerProvider =
    NotifierProvider<ConnectionController, ConnectionState>(
      ConnectionController.new,
    );

final class ConnectionController extends Notifier<ConnectionState> {
  late SessionRepository _repository;

  @override
  ConnectionState build() {
    _repository = ref.watch(sessionRepositoryProvider);
    ref.onDispose(() => unawaited(_repository.close()));
    return const ConnectionIdle();
  }

  Future<void> connect({
    required String serverInput,
    required String apiKey,
  }) async {
    if (state is ConnectionInProgress) return;
    state = const ConnectionInProgress();
    try {
      final summary = await _repository.connect(
        serverInput: serverInput,
        apiKey: apiKey,
      );
      state = ConnectionSucceeded(summary);
    } on EndpointValidationException catch (error) {
      state = ConnectionFailed(error.message);
    } on TlsCertificateException catch (error) {
      state = ConnectionFailed(error.userMessage);
    } on AuthenticationStateException catch (error) {
      state = ConnectionFailed(error.userMessage);
    } on JsonRpcRemoteException {
      state = const ConnectionFailed(
        'The server returned an RPC error. Check access and try again.',
      );
    } on JsonRpcProtocolException {
      state = const ConnectionFailed(
        'The server sent an invalid RPC response.',
      );
    } on RpcTransportClosedException {
      state = const ConnectionFailed(
        'The secure connection closed before setup finished.',
      );
    } catch (_) {
      state = const ConnectionFailed(
        'Unable to reach the server over a secure connection.',
      );
    }
  }
}
