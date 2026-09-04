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
    required String apiKey,
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
  // Reserved injection seam for a later secure-storage slice. M0 never reads or writes it.
  // ignore: unused_field
  final CredentialVault _credentialVault;
  final JsonRpcClientFactory _clientFactory;
  JsonRpcClient? _client;
  var _nextId = 0;

  Future<ServerSummary> connect({
    required String serverInput,
    required String apiKey,
  }) async {
    final endpoint = ValidatedEndpoint.parse(serverInput);
    JsonRpcClient? client;
    try {
      final transport = await _connector.connect(endpoint.connectionUri);
      client = _clientFactory(transport);
      _client = client;
      final login = await client.call(
        'auth.login_ex',
        id: _id(),
        params: [
          <String, Object?>{'mechanism': 'API_KEY_PLAIN', 'api_key': apiKey},
        ],
      );
      _requireSuccess(login);
      final me = await client.call('auth.me', id: _id());
      final info = await client.call('system.info', id: _id());
      final methods = await client.call('core.get_methods', id: _id());
      return ServerSummary(
        originalHostInput: endpoint.originalInput,
        endpointUri: endpoint.connectionUri,
        identity: _identity(me),
        version: _version(info),
        availableMethodNames: _methods(methods),
      );
    } catch (error) {
      if (identical(_client, client)) _client = null;
      try {
        await client?.close();
      } catch (_) {
        // The connection error remains the actionable failure.
      }
      if (error is TlsHandshakeException) {
        throw const TlsCertificateException();
      }
      rethrow;
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

  Future<void> close() async {
    final client = _client;
    _client = null;
    await client?.close();
  }
}
