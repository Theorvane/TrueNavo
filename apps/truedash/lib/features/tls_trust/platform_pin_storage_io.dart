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
}
