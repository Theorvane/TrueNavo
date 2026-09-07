import '../endpoint/validated_endpoint.dart';
import '../protocol/json_rpc_client.dart';
import '../transport/rpc_transport.dart';
import 'authentication_exception.dart';
import 'credential_vault.dart';
import 'server_summary.dart';

typedef JsonRpcClientFactory = JsonRpcClient Function(RpcTransport transport);

abstract interface class SessionRepository {
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  });
  Future<void> close();
}

final class TrueNasSessionRepository implements SessionRepository {
  TrueNasSessionRepository({
    required RpcConnector connector,
    CredentialVault? credentialVault,
    JsonRpcClientFactory? clientFactory,
  }) : _connector = connector,
       _credentialVault = credentialVault ?? const NoopCredentialVault(),
       _clientFactory = clientFactory ?? JsonRpcClient.new;

  final RpcConnector _connector;
  final CredentialVault _credentialVault;
  final JsonRpcClientFactory _clientFactory;
  JsonRpcClient? _client;
  var _nextId = 0;

  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) async {
    final endpoint = ValidatedEndpoint.parse(serverInput);
    RpcTransport? connectedTransport;
    JsonRpcClient? client;
    try {
      connectedTransport = await _connector.connect(endpoint.connectionUri);
      client = _clientFactory(connectedTransport);
      _client = client;
      _requireCurrent(isConnectionCurrent);
      final explicitKey = apiKey?.isNotEmpty == true ? apiKey : null;
      final key =
          explicitKey ??
          await _readRememberedKey(
            endpoint.connectionUri.toString(),
            isConnectionCurrent,
          );
      _requireCurrent(isConnectionCurrent);
      if (key == null || key.isEmpty) {
        throw const CredentialUnavailableException(
          CredentialUnavailableReason.missing,
        );
      }
      final login = await client.call(
        'auth.login_ex',
        id: _id(),
        params: [
          <String, Object?>{'mechanism': 'API_KEY_PLAIN', 'api_key': key},
        ],
      );
      _requireSuccess(login);
      _requireCurrent(isConnectionCurrent);
      final me = await client.call('auth.me', id: _id());
      _requireCurrent(isConnectionCurrent);
      final info = await client.call('system.info', id: _id());
      _requireCurrent(isConnectionCurrent);
      final methods = await client.call('core.get_methods', id: _id());
      _requireCurrent(isConnectionCurrent);
      final summary = ServerSummary(
        originalHostInput: endpoint.originalInput,
        endpointUri: endpoint.connectionUri,
        identity: _identity(me),
        version: _version(info),
        availableMethodNames: _methods(methods),
      );
      if (rememberApiKey && explicitKey != null) {
        await _writeRememberedKey(
          endpoint.connectionUri.toString(),
          explicitKey,
          isConnectionCurrent,
        );
        // A successful vault write is the credential commit point. Do not let
        // a later cancellable callback report a failed connection after the
        // vault can no longer compensate the persisted replacement.
        return summary;
      }
      _requireCurrent(isConnectionCurrent);
      return summary;
    } catch (error) {
      if (identical(_client, client)) _client = null;
      try {
        if (client != null) {
          await client.close();
        } else {
          await connectedTransport?.close();
        }
      } catch (_) {
        // The connection error remains the actionable failure.
      }
      if (error is TlsHandshakeException) {
        throw const TlsCertificateException();
      }
      rethrow;
    }
  }

  Future<String?> _readRememberedKey(
    String endpointIdentifier,
    bool Function()? isConnectionCurrent,
  ) async {
    _requireCurrent(isConnectionCurrent);
    try {
      final key = await _credentialVault.readApiKey(endpointIdentifier);
      _requireCurrent(isConnectionCurrent);
      return key;
    } on CredentialUnavailableException {
      rethrow;
    } on Object {
      throw const CredentialUnavailableException(
        CredentialUnavailableReason.unavailable,
      );
    }
  }

  Future<void> _writeRememberedKey(
    String endpointIdentifier,
    String apiKey,
    bool Function()? isConnectionCurrent,
  ) async {
    _requireCurrent(isConnectionCurrent);
    try {
      await _credentialVault.writeApiKey(
        endpointIdentifier,
        apiKey,
        isCurrent: isConnectionCurrent,
      );
    } on CredentialWriteCancelledException {
      throw const CredentialUnavailableException(
        CredentialUnavailableReason.cancelled,
      );
    } on CredentialUnavailableException {
      rethrow;
    } on Object {
      throw const CredentialUnavailableException(
        CredentialUnavailableReason.unavailable,
      );
    }
  }

  void _requireCurrent(bool Function()? isConnectionCurrent) {
    final bool current;
    try {
      current = isConnectionCurrent?.call() ?? true;
    } on Object {
      throw const CredentialUnavailableException(
        CredentialUnavailableReason.cancelled,
      );
    }
    if (!current) {
      throw const CredentialUnavailableException(
        CredentialUnavailableReason.cancelled,
      );
    }
  }

  String _id() => 'm0-${++_nextId}';

  void _requireSuccess(Object? response) {
    final state = response is Map ? response['state'] : response;
    if (state == 'SUCCESS') return;
    throw AuthenticationStateException(switch (state) {
      'OTP_REQUIRED' => AuthenticationState.otpRequired,
      'AUTH_ERR' => AuthenticationState.authenticationFailed,
      'EXPIRED' => AuthenticationState.expired,
      'REDIRECT' => AuthenticationState.redirect,
      _ => AuthenticationState.unknown,
    });
  }

  String _identity(Object? value) {
    if (value is! Map) return 'unknown';
    for (final key in const ['username', 'name', 'user', 'id']) {
      final candidate = value[key];
      if (candidate is String && candidate.isNotEmpty) return candidate;
      if (candidate is num) return candidate.toString();
    }
    return 'unknown';
  }

  String _version(Object? value) {
    if (value is Map &&
        value['version'] is String &&
        (value['version'] as String).isNotEmpty) {
      return value['version'] as String;
    }
    return 'unknown';
  }

  Set<String> _methods(Object? value) {
    if (value is Map) return value.keys.whereType<String>().toSet();
    if (value is List) return value.whereType<String>().toSet();
    return const <String>{};
  }

  @override
  Future<void> close() async {
    final client = _client;
    _client = null;
    await client?.close();
  }
}
