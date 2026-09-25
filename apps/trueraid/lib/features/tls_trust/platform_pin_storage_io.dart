import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'native_pin_storage_lock.dart';
import 'platform_pin_storage_windows.dart';
import 'raw_pin_storage.dart';

RawPinStorage createPlatformRawPinStorage() {
  if (Platform.isWindows) {
    return WindowsCredentialRawPinStorage();
  }
  if (Platform.isAndroid ||
      Platform.isIOS ||
      Platform.isMacOS ||
      Platform.isLinux) {
    return FlutterSecureRawPinStorage();
  }
  return const _UnsupportedRawPinStorage();
}

final class FlutterSecureRawPinStorage implements RawPinStorage {
  FlutterSecureRawPinStorage({NativePinStorageLock? lock})
    : _lock =
          lock ??
          NativePinStorageLock.appPrivate(getApplicationSupportDirectory),
      _storage = FlutterSecureStorage(
        aOptions: const AndroidOptions(
          resetOnError: false,
          storageNamespace: 'com.trueraid.trueraid.tls-pin',
        ),
        iOptions: const IOSOptions(
          accessibility: KeychainAccessibility.unlocked_this_device,
        ),
        mOptions: const MacOsOptions(
          accessibility: KeychainAccessibility.unlocked_this_device,
          usesDataProtectionKeychain: true,
        ),
      );
  final FlutterSecureStorage _storage;
  final NativePinStorageLock _lock;
  @override
  Future<RawPinReadResult> read(String key) => _readUnlocked(key);

  Future<RawPinReadResult> _readUnlocked(String key) async {
    try {
      final value = await _storage.read(key: key);
      return value == null
          ? const RawPinReadResult.absent()
          : RawPinReadResult.value(value);
    } on Object {
      return const RawPinReadResult.failure(RawPinStorageFailure.readFailed);
    }
  }

  @override
  Future<RawPinStorageResult> write(String key, String value) =>
      _writeUnlocked(key, value);

  Future<RawPinStorageResult> _writeUnlocked(String key, String value) async {
    try {
      await _storage.write(key: key, value: value);
      return const RawPinStorageResult.success();
    } on Object {
      return const RawPinStorageResult.failure(
        RawPinStorageFailure.writeFailed,
      );
    }
  }

  @override
  Future<RawPinStorageResult> delete(String key) => _deleteUnlocked(key);

  Future<RawPinStorageResult> _deleteUnlocked(String key) async {
    try {
      await _storage.delete(key: key);
      return const RawPinStorageResult.success();
    } on Object {
      return const RawPinStorageResult.failure(
        RawPinStorageFailure.deleteFailed,
      );
    }
  }

  @override
  Future<RawPinStorageResult> writeIfValue(
    String key,
    String? expectedValue,
    String value,
  ) async {
    try {
      return await _lock.withKeys(<String>[key], () async {
        final current = await _readUnlocked(key);
        if (current is RawPinReadFailure) {
          return RawPinStorageResult.failure(current.failure);
        }
        final actual = switch (current) {
          RawPinAbsent() => null,
          RawPinValue(:final value) => value,
          _ => null,
        };
        if (actual != expectedValue) {
          return const RawPinStorageResult.notMatched();
        }
        return _writeUnlocked(key, value);
      });
    } on NativePinStorageLockException {
      return const RawPinStorageResult.failure(
        RawPinStorageFailure.writeFailed,
      );
    }
  }

  @override
  Future<RawPinStorageResult> writeIfValues(
    String key,
    String? expectedValue,
    String guardKey,
    String expectedGuardValue,
    String value,
  ) async {
    try {
      return await _lock.withKeys(<String>[key, guardKey], () async {
        final guard = await _readUnlocked(guardKey);
        if (guard is RawPinReadFailure) {
          return RawPinStorageResult.failure(guard.failure);
        }
        if (guard is! RawPinValue || guard.value != expectedGuardValue) {
          return const RawPinStorageResult.notMatched();
        }
        final current = await _readUnlocked(key);
        if (current is RawPinReadFailure) {
          return RawPinStorageResult.failure(current.failure);
        }
        final actual = switch (current) {
          RawPinAbsent() => null,
          RawPinValue(:final value) => value,
          _ => null,
        };
        if (actual != expectedValue) {
          return const RawPinStorageResult.notMatched();
        }
        return _writeUnlocked(key, value);
      });
    } on NativePinStorageLockException {
      return const RawPinStorageResult.failure(
        RawPinStorageFailure.writeFailed,
      );
    }
  }

  @override
  Future<RawPinStorageResult> deleteIfValue(
    String key,
    String expectedValue,
  ) async {
    try {
      return await _lock.withKeys(<String>[key], () async {
        final current = await _readUnlocked(key);
        if (current is RawPinReadFailure) {
          return RawPinStorageResult.failure(current.failure);
        }
        if (current is! RawPinValue || current.value != expectedValue) {
          return const RawPinStorageResult.notMatched();
        }
        return _deleteUnlocked(key);
      });
    } on NativePinStorageLockException {
      return const RawPinStorageResult.failure(
        RawPinStorageFailure.deleteFailed,
      );
    }
  }
}

final class _UnsupportedRawPinStorage implements RawPinStorage {
  const _UnsupportedRawPinStorage();
  @override
  Future<RawPinReadResult> read(String key) async =>
      const RawPinReadResult.failure(RawPinStorageFailure.unsupportedPlatform);
  @override
  Future<RawPinStorageResult> write(String key, String value) async =>
      const RawPinStorageResult.failure(
        RawPinStorageFailure.unsupportedPlatform,
      );
  @override
  Future<RawPinStorageResult> delete(String key) async =>
      const RawPinStorageResult.failure(
        RawPinStorageFailure.unsupportedPlatform,
      );
  @override
  Future<RawPinStorageResult> writeIfValue(
    String key,
    String? expectedValue,
    String value,
  ) async => const RawPinStorageResult.failure(
    RawPinStorageFailure.unsupportedPlatform,
  );
  @override
  Future<RawPinStorageResult> writeIfValues(
    String key,
    String? expectedValue,
    String guardKey,
    String expectedGuardValue,
    String value,
  ) async => const RawPinStorageResult.failure(
    RawPinStorageFailure.unsupportedPlatform,
  );
  @override
  Future<RawPinStorageResult> deleteIfValue(
    String key,
    String expectedValue,
  ) async => const RawPinStorageResult.failure(
    RawPinStorageFailure.unsupportedPlatform,
  );
}
