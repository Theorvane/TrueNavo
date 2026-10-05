import 'dart:async';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:truenas_api/truenas_api.dart';

import 'secure_credential_vault.dart';

const _maximumApiKeyLength = 16384;
const _options = SecureCredentialStorageOptions(
  androidResetOnError: false,
  androidNamespace: 'com.truenavo.truenavo.api-key',
  appleSynchronizable: false,
  appleThisDeviceUnlocked: true,
  macOsDataProtectionKeychain: true,
);

CredentialVault createSecureCredentialVault() => NativeSecureCredentialVault();

final class NativeSecureCredentialVault implements CredentialVault {
  NativeSecureCredentialVault({SecureCredentialStoragePort? storage})
    : _storage = storage ?? _FlutterSecureCredentialStoragePort();

  final SecureCredentialStoragePort _storage;
  Future<void> _operationTail = Future<void>.value();

  @override
  Future<String?> readApiKey(String endpointIdentifier) {
    final key = _keyFor(endpointIdentifier);
    return _serialize(() async {
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
    });
  }

  @override
  Future<void> writeApiKey(
    String endpointIdentifier,
    String apiKey, {
    bool Function()? isCurrent,
  }) async {
    final key = _keyFor(endpointIdentifier);
    if (apiKey.isEmpty || apiKey.length > _maximumApiKeyLength) {
      throw const CredentialVaultFailure(
        CredentialVaultFailureKind.invalidInput,
      );
    }
    return _serialize(() async {
      _requireCurrent(isCurrent);
      try {
        // Keep the snapshot within the native adapter: callers never read a
        // remembered key when an explicit key is being used.
        final previous = await _storage.read(key: key, options: _options);
        _requireCurrent(isCurrent);
        await _storage.write(key: key, value: apiKey, options: _options);
        try {
          _requireCurrent(isCurrent);
          return;
        } on CredentialWriteCancelledException {
          await _restorePrevious(key, previous);
          rethrow;
        }
      } on CredentialWriteCancelledException {
        rethrow;
      } on CredentialVaultFailure {
        rethrow;
      } on Object {
        throw const CredentialVaultFailure(
          CredentialVaultFailureKind.unavailable,
        );
      }
    });
  }

  Future<void> _restorePrevious(String key, String? previous) async {
    try {
      if (previous == null) {
        await _storage.delete(key: key, options: _options);
      } else {
        await _storage.write(key: key, value: previous, options: _options);
      }
    } on Object {
      throw const CredentialVaultFailure(
        CredentialVaultFailureKind.unavailable,
      );
    }
  }

  Future<T> _serialize<T>(FutureOr<T> Function() operation) {
    final Future<T> result = _operationTail.then<T>((_) => operation());
    _operationTail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stackTrace) {},
    );
    return result;
  }

  void _requireCurrent(bool Function()? isCurrent) {
    final bool current;
    try {
      current = isCurrent?.call() ?? true;
    } on Object {
      throw const CredentialWriteCancelledException();
    }
    if (!current) {
      throw const CredentialWriteCancelledException();
    }
  }

  @override
  Future<void> deleteApiKey(String endpointIdentifier) {
    final key = _keyFor(endpointIdentifier);
    return _serialize(() async {
      try {
        await _storage.delete(key: key, options: _options);
      } on CredentialVaultFailure {
        rethrow;
      } on Object {
        throw const CredentialVaultFailure(
          CredentialVaultFailureKind.unavailable,
        );
      }
    });
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
          storageNamespace: 'com.truenavo.truenavo.api-key',
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
      storageNamespace: 'com.truenavo.truenavo.api-key',
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
      storageNamespace: 'com.truenavo.truenavo.api-key',
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
      storageNamespace: 'com.truenavo.truenavo.api-key',
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
