import 'package:truenas_api/truenas_api.dart';

import 'secure_credential_vault_web.dart'
    if (dart.library.io) 'secure_credential_vault_io.dart'
    as platform;

export 'credential_storage_key.dart';

/// Selects native secure storage, or Web's intentionally non-persistent vault.
CredentialVault createSecureCredentialVault() =>
    platform.createSecureCredentialVault();

enum CredentialVaultFailureKind { invalidInput, unavailable, unsupported }

/// Stable public failure that never includes credential or backend details.
final class CredentialVaultFailure implements Exception {
  const CredentialVaultFailure(this.kind);

  final CredentialVaultFailureKind kind;

  @override
  String toString() => switch (kind) {
    CredentialVaultFailureKind.invalidInput => 'Credential input is invalid.',
    CredentialVaultFailureKind.unavailable =>
      'Credential storage is unavailable.',
    CredentialVaultFailureKind.unsupported =>
      'Credential persistence is unavailable on this platform.',
  };
}

/// Immutable platform policy supplied to each storage operation.
final class SecureCredentialStorageOptions {
  const SecureCredentialStorageOptions({
    required this.androidResetOnError,
    required this.androidNamespace,
    required this.appleSynchronizable,
    required this.appleThisDeviceUnlocked,
    required this.macOsDataProtectionKeychain,
  });

  final bool androidResetOnError;
  final String androidNamespace;
  final bool appleSynchronizable;
  final bool appleThisDeviceUnlocked;
  final bool macOsDataProtectionKeychain;
}

/// Narrow native backend seam. Values cross it only for the required write.
abstract interface class SecureCredentialStoragePort {
  Future<String?> read({
    required String key,
    required SecureCredentialStorageOptions options,
  });
  Future<void> write({
    required String key,
    required String value,
    required SecureCredentialStorageOptions options,
  });
  Future<void> delete({
    required String key,
    required SecureCredentialStorageOptions options,
  });
}
