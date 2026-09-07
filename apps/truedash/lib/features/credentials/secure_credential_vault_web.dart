import 'package:truenas_api/truenas_api.dart';

import 'secure_credential_vault.dart';

CredentialVault createSecureCredentialVault() =>
    const WebSecureCredentialVault();

/// Web deliberately does not retain API keys in any browser storage.
final class WebSecureCredentialVault implements CredentialVault {
  const WebSecureCredentialVault();

  @override
  Future<String?> readApiKey(String serverDisplayInput) async => null;

  @override
  Future<void> writeApiKey(String serverDisplayInput, String apiKey) async {
    throw const CredentialVaultFailure(CredentialVaultFailureKind.unsupported);
  }

  @override
  Future<void> deleteApiKey(String serverDisplayInput) async {}
}
