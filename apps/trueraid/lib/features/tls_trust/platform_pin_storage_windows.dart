import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';
import 'package:path_provider/path_provider.dart';
import 'package:win32/win32.dart'
    show
        CREDENTIAL,
        CRED_PERSIST_LOCAL_MACHINE,
        CRED_TYPE_GENERIC,
        CredDelete,
        CredFree,
        CredRead,
        CredWrite,
        ERROR_NOT_FOUND,
        PCWSTR,
        PWSTR;

import 'native_pin_storage_lock.dart';
import 'raw_pin_storage.dart';

/// Classifies the documented Credential Manager status values without loading
/// a Windows DLL, so this fail-closed policy is unit-testable on every host.
final class WindowsCredentialStatus {
  const WindowsCredentialStatus._();

  static RawPinReadResult read({
    required bool succeeded,
    required int errorCode,
  }) => succeeded
      ? throw ArgumentError('Only failed CredReadW calls have an error status.')
      : errorCode == ERROR_NOT_FOUND
      ? const RawPinReadResult.absent()
      : const RawPinReadResult.failure(RawPinStorageFailure.readFailed);

  static RawPinStorageResult delete({
    required bool succeeded,
    required int errorCode,
  }) => succeeded || errorCode == ERROR_NOT_FOUND
      ? const RawPinStorageResult.success()
      : const RawPinStorageResult.failure(RawPinStorageFailure.deleteFailed);
}

/// Direct app-owned Credential Manager backend; it has no plugin dependency.
final class WindowsCredentialRawPinStorage implements RawPinStorage {
  WindowsCredentialRawPinStorage({NativePinStorageLock? lock})
    : _lock =
          lock ??
          NativePinStorageLock.appPrivate(getApplicationSupportDirectory);

  static const _maxTargetChars = 256;
  static const _maxCredentialBytes = 2560;
  final NativePinStorageLock _lock;

  String targetForKey(String key) =>
      'com.trueraid.tls-pin.v1.${sha256.convert(utf8.encode(key))}';

  bool _validTarget(String target) =>
      target.length <= _maxTargetChars &&
      RegExp(r'^com\.trueraid\.tls-pin\.v1\.[0-9a-f]{64}$').hasMatch(target);

  @override
  Future<RawPinReadResult> read(String key) => _readUnlocked(key);

  Future<RawPinReadResult> _readUnlocked(String key) async {
    final target = targetForKey(key);
    if (!_validTarget(target)) {
      return const RawPinReadResult.failure(RawPinStorageFailure.readFailed);
    }
    final out = calloc<Pointer<CREDENTIAL>>();
    final name = target.toNativeUtf16();
    try {
      // The win32 binding primes GetLastError before CredReadW and captures it
      // immediately after the failed native call, before Dart can clobber it.
      final result = CredRead(PCWSTR(name), CRED_TYPE_GENERIC, out);
      if (!result.value) {
        return WindowsCredentialStatus.read(
          succeeded: false,
          errorCode: result.error,
        );
      }
      final credential = out.value.ref;
      final size = credential.CredentialBlobSize;
      if (size == 0 ||
          size > _maxCredentialBytes ||
          credential.CredentialBlob == nullptr) {
        return const RawPinReadResult.failure(RawPinStorageFailure.readFailed);
      }
      return RawPinReadResult.value(
        utf8.decode(
          credential.CredentialBlob.asTypedList(size),
          allowMalformed: false,
        ),
      );
    } on Object {
      return const RawPinReadResult.failure(RawPinStorageFailure.readFailed);
    } finally {
      if (out.value != nullptr) CredFree(out.value);
      calloc.free(name);
      calloc.free(out);
    }
  }

  @override
  Future<RawPinStorageResult> write(String key, String value) =>
      _writeUnlocked(key, value);

  Future<RawPinStorageResult> _writeUnlocked(String key, String value) async {
    final target = targetForKey(key);
    final bytes = Uint8List.fromList(utf8.encode(value));
    if (!_validTarget(target) ||
        bytes.isEmpty ||
        bytes.length > _maxCredentialBytes) {
      return const RawPinStorageResult.failure(
        RawPinStorageFailure.writeFailed,
      );
    }
    // CREDENTIAL is the win32 package's generated CREDENTIALW definition.
    // Its FILETIME field preserves the native 4-byte alignment on Win32 and
    // Win64 (52 and 80 bytes respectively), unlike a bare Uint64 field.
    final credential = calloc<CREDENTIAL>();
    final name = target.toNativeUtf16();
    final blob = calloc<Uint8>(bytes.length);
    blob.asTypedList(bytes.length).setAll(0, bytes);
    try {
      credential.ref.Type = CRED_TYPE_GENERIC;
      credential.ref.TargetName = PWSTR(name);
      credential.ref.CredentialBlobSize = bytes.length;
      credential.ref.CredentialBlob = blob;
      credential.ref.Persist = CRED_PERSIST_LOCAL_MACHINE;
      return CredWrite(credential, 0).value
          ? const RawPinStorageResult.success()
          : const RawPinStorageResult.failure(RawPinStorageFailure.writeFailed);
    } on Object {
      return const RawPinStorageResult.failure(
        RawPinStorageFailure.writeFailed,
      );
    } finally {
      blob.asTypedList(bytes.length).fillRange(0, bytes.length, 0);
      calloc.free(blob);
      calloc.free(name);
      calloc.free(credential);
    }
  }

  @override
  Future<RawPinStorageResult> delete(String key) => _deleteUnlocked(key);

  Future<RawPinStorageResult> _deleteUnlocked(String key) async {
    final target = targetForKey(key);
    if (!_validTarget(target)) {
      return const RawPinStorageResult.failure(
        RawPinStorageFailure.deleteFailed,
      );
    }
    final name = target.toNativeUtf16();
    try {
      final result = CredDelete(PCWSTR(name), CRED_TYPE_GENERIC);
      return WindowsCredentialStatus.delete(
        succeeded: result.value,
        errorCode: result.error,
      );
    } on Object {
      return const RawPinStorageResult.failure(
        RawPinStorageFailure.deleteFailed,
      );
    } finally {
      calloc.free(name);
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
