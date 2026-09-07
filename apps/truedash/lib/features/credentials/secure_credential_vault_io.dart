import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:truenas_api/truenas_api.dart';

import 'secure_credential_vault.dart';

const _maximumApiKeyLength = 16384;
const _options = SecureCredentialStorageOptions(
  androidResetOnError: false,
  androidNamespace: 'com.truedash.truedash.api-key',
  appleSynchronizable: false,
  appleThisDeviceUnlocked: true,
  macOsDataProtectionKeychain: true,
);

CredentialVault createSecureCredentialVault() => NativeSecureCredentialVault();

final class NativeSecureCredentialVault implements CredentialVault {
  NativeSecureCredentialVault({SecureCredentialStoragePort? storage})
    : _storage = storage ?? _FlutterSecureCredentialStoragePort();

  final SecureCredentialStoragePort _storage;

  @override
  Future<String?> readApiKey(String serverDisplayInput) async {
    final key = _keyFor(serverDisplayInput);
    try {
      final value = await _storage.read(key: key, options: _options);
      if (value == null) return null;
      if (value.isEmpty || value.length > _maximumApiKeyLength) {
        throw const CredentialVaultFailure(
          CredentialVaultFailureKind.unavailable,
        );
      }
      return value;
    } on CredentialVaultFailure {
      rethrow;
    } on Object {
      throw const CredentialVaultFailure(
        CredentialVaultFailureKind.unavailable,
      );
    }
  }

  @override
  Future<void> writeApiKey(String serverDisplayInput, String apiKey) async {
    final key = _keyFor(serverDisplayInput);
    if (apiKey.isEmpty || apiKey.length > _maximumApiKeyLength) {
      throw const CredentialVaultFailure(
        CredentialVaultFailureKind.invalidInput,
      );
    }
    try {
      await _storage.write(key: key, value: apiKey, options: _options);
    } on CredentialVaultFailure {
      rethrow;
    } on Object {
      throw const CredentialVaultFailure(
        CredentialVaultFailureKind.unavailable,
      );
    }
  }

  @override
  Future<void> deleteApiKey(String serverDisplayInput) async {
    final key = _keyFor(serverDisplayInput);
    try {
      await _storage.delete(key: key, options: _options);
    } on CredentialVaultFailure {
      rethrow;
    } on Object {
      throw const CredentialVaultFailure(
        CredentialVaultFailureKind.unavailable,
      );
    }
  }

  String _keyFor(String input) {
    try {
      return credentialStorageKey(input);
    } on CredentialStorageKeyFailure {
      throw const CredentialVaultFailure(
        CredentialVaultFailureKind.invalidInput,
      );
    }
  }
}

final class _FlutterSecureCredentialStoragePort
    implements SecureCredentialStoragePort {
  _FlutterSecureCredentialStoragePort()
    : _storage = const FlutterSecureStorage(
        aOptions: AndroidOptions(
          resetOnError: false,
          storageNamespace: 'com.truedash.truedash.api-key',
        ),
        iOptions: IOSOptions(
          accessibility: KeychainAccessibility.unlocked_this_device,
          synchronizable: false,
        ),
        mOptions: MacOsOptions(
          accessibility: KeychainAccessibility.unlocked_this_device,
          synchronizable: false,
          usesDataProtectionKeychain: true,
        ),
        lOptions: LinuxOptions(),
        wOptions: WindowsOptions(useBackwardCompatibility: false),
      );

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read({
    required String key,
    required SecureCredentialStorageOptions options,
  }) => _storage.read(
    key: key,
    aOptions: const AndroidOptions(
      resetOnError: false,
      storageNamespace: 'com.truedash.truedash.api-key',
    ),
    iOptions: const IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
      synchronizable: false,
    ),
    mOptions: const MacOsOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
      synchronizable: false,
      usesDataProtectionKeychain: true,
    ),
    lOptions: const LinuxOptions(),
    wOptions: const WindowsOptions(useBackwardCompatibility: false),
  );

  @override
  Future<void> write({
    required String key,
    required String value,
    required SecureCredentialStorageOptions options,
  }) => _storage.write(
    key: key,
    value: value,
    aOptions: const AndroidOptions(
      resetOnError: false,
      storageNamespace: 'com.truedash.truedash.api-key',
    ),
    iOptions: const IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
      synchronizable: false,
    ),
    mOptions: const MacOsOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
      synchronizable: false,
      usesDataProtectionKeychain: true,
    ),
    lOptions: const LinuxOptions(),
    wOptions: const WindowsOptions(useBackwardCompatibility: false),
  );

  @override
  Future<void> delete({
    required String key,
    required SecureCredentialStorageOptions options,
  }) => _storage.delete(
    key: key,
    aOptions: const AndroidOptions(
      resetOnError: false,
      storageNamespace: 'com.truedash.truedash.api-key',
    ),
    iOptions: const IOSOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
      synchronizable: false,
    ),
    mOptions: const MacOsOptions(
      accessibility: KeychainAccessibility.unlocked_this_device,
      synchronizable: false,
      usesDataProtectionKeychain: true,
    ),
    lOptions: const LinuxOptions(),
    wOptions: const WindowsOptions(useBackwardCompatibility: false),
  );
}
