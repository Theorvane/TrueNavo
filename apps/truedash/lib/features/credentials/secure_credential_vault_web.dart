import 'package:truenas_api/truenas_api.dart';

import 'secure_credential_vault.dart';

CredentialVault createSecureCredentialVault() =>
    const WebSecureCredentialVault();

/// Web deliberately does not retain API keys in any browser storage.
final class WebSecureCredentialVault implements CredentialVault {
  const WebSecureCredentialVault();

  @override
  Future<String?> readApiKey(String endpointIdentifier) async => null;

  @override
  Future<void> writeApiKey(
    String endpointIdentifier,
    String apiKey, {
    bool Function()? isCurrent,
  }) async {
    throw const CredentialVaultFailure(CredentialVaultFailureKind.unsupported);
  }

  @override
  Future<void> deleteApiKey(String endpointIdentifier) async {}
}
