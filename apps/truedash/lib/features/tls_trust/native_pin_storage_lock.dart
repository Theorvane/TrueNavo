import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';

/// An OS-released, per-key lock for secure-store compare-and-mutate actions.
///
/// The lock files live in this application's support directory, contain no
/// data, and use only a SHA-256 digest of the secure-store key as their name.
/// A process death releases the advisory locks held by its file descriptors.
final class NativePinStorageLock {
  NativePinStorageLock._(this._directoryProvider);

  factory NativePinStorageLock.appPrivate(
    Future<Directory> Function() directoryProvider,
  ) => NativePinStorageLock._(directoryProvider);

  /// Injectable only so the process-level lock contract can use a temp app
  /// directory without requiring a platform channel.
  factory NativePinStorageLock.forDirectory(Directory directory) =>
      NativePinStorageLock._(() async => directory);

  final Future<Directory> Function() _directoryProvider;

  Future<T> withKeys<T>(
    Iterable<String> keys,
    Future<T> Function() action,
  ) async {
    final hashes =
        keys
            .map((key) => sha256.convert(utf8.encode(key)).toString())
            .toSet()
            .toList()
          ..sort();
    if (hashes.isEmpty) {
      throw ArgumentError.value(keys, 'keys', 'must not be empty');
    }

    final support = await _directoryProvider();
    final directory = Directory(
      '${support.path}${Platform.pathSeparator}tls-pin-locks',
    );
    try {
      await directory.create(recursive: true);
    } on Object {
      throw const NativePinStorageLockException();
    }

    final files = <RandomAccessFile>[];
    try {
      for (final hash in hashes) {
        final file = File(
          '${directory.path}${Platform.pathSeparator}$hash.lock',
        );
        final handle = await file.open(mode: FileMode.append);
        files.add(handle);
        await handle.lock(FileLock.blockingExclusive);
      }
      return await action();
    } on NativePinStorageLockException {
      rethrow;
    } on Object {
      throw const NativePinStorageLockException();
    } finally {
      for (final file in files.reversed) {
        try {
          await file.unlock();
        } on Object {
          // Closing still releases the advisory lock on every supported OS.
        }
        try {
          await file.close();
        } on Object {
          // The caller receives the original operation/lock failure.
        }
      }
    }
  }
}

final class NativePinStorageLockException implements Exception {
  const NativePinStorageLockException();
}
