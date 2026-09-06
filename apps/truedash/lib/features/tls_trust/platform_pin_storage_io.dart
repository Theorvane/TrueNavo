import 'dart:io';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';

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
  FlutterSecureRawPinStorage()
    : _storage = FlutterSecureStorage(
        aOptions: const AndroidOptions(
          resetOnError: false,
          storageNamespace: 'com.truedash.truedash.tls-pin',
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
  @override
  Future<RawPinReadResult> read(String key) async {
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
  Future<RawPinStorageResult> write(String key, String value) async {
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
  Future<RawPinStorageResult> delete(String key) async {
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
    final current = await read(key);
    if (current is RawPinReadFailure) {
      return RawPinStorageResult.failure(current.failure);
    }
    final actual = switch (current) {
      RawPinAbsent() => null,
      RawPinValue(:final value) => value,
      _ => null,
    };
    if (actual != expectedValue) return const RawPinStorageResult.notMatched();
    return write(key, value);
  }

  @override
  Future<RawPinStorageResult> writeIfValues(
    String key,
    String? expectedValue,
    String guardKey,
    String expectedGuardValue,
    String value,
  ) async {
    final guard = await read(guardKey);
    if (guard is RawPinReadFailure) {
      return RawPinStorageResult.failure(guard.failure);
    }
    if (guard is! RawPinValue || guard.value != expectedGuardValue) {
      return const RawPinStorageResult.notMatched();
    }
    return writeIfValue(key, expectedValue, value);
  }

  @override
  Future<RawPinStorageResult> deleteIfValue(
    String key,
    String expectedValue,
  ) async {
    final current = await read(key);
    if (current is RawPinReadFailure) {
      return RawPinStorageResult.failure(current.failure);
    }
    if (current is! RawPinValue || current.value != expectedValue) {
      return const RawPinStorageResult.notMatched();
    }
    return delete(key);
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
