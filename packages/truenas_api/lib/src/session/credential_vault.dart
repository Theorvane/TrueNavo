abstract interface class CredentialVault {
  Future<String?> readApiKey(String serverDisplayInput);
  Future<void> writeApiKey(String serverDisplayInput, String apiKey);
  Future<void> deleteApiKey(String serverDisplayInput);
}

final class NoopCredentialVault implements CredentialVault {
  const NoopCredentialVault();
  @override
  Future<void> deleteApiKey(String serverDisplayInput) async {}
  @override
  Future<String?> readApiKey(String serverDisplayInput) async => null;
  @override
  Future<void> writeApiKey(String serverDisplayInput, String apiKey) async {}
}

/// Test/future-adapter boundary only; no M0 UI writes to this vault.
final class InMemoryCredentialVault implements CredentialVault {
  final _keys = <String, String>{};
  @override
  Future<void> deleteApiKey(String serverDisplayInput) async =>
      _keys.remove(serverDisplayInput);
  @override
  Future<String?> readApiKey(String serverDisplayInput) async =>
      _keys[serverDisplayInput];
  @override
  Future<void> writeApiKey(String serverDisplayInput, String apiKey) async {
    _keys[serverDisplayInput] = apiKey;
  }
}
