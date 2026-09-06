import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/tls_trust/native_pin_storage_lock.dart';
import 'package:truedash/features/tls_trust/platform_pin_storage_io.dart';
import 'package:truedash/features/tls_trust/platform_pin_storage_windows.dart';
import 'package:truedash/features/tls_trust/raw_pin_storage.dart';

void main() {
  NativePinStorageLock unavailableSupportDirectoryLock() =>
      NativePinStorageLock.appPrivate(
        () async => throw FileSystemException('support directory unavailable'),
      );

  test('maps support directory failures to the lock exception', () async {
    final lock = unavailableSupportDirectoryLock();

    await expectLater(
      lock.withKeys(<String>['key'], () async {}),
      throwsA(isA<NativePinStorageLockException>()),
    );
  });

  group('conditional native storage with an unavailable support directory', () {
    test('FlutterSecure write returns writeFailed', () async {
      final storage = FlutterSecureRawPinStorage(
        lock: unavailableSupportDirectoryLock(),
      );

      expect(
        await storage.writeIfValue('key', null, 'value'),
        const RawPinStorageResult.failure(RawPinStorageFailure.writeFailed),
      );
    });

    test('FlutterSecure delete returns deleteFailed', () async {
      final storage = FlutterSecureRawPinStorage(
        lock: unavailableSupportDirectoryLock(),
      );

      expect(
        await storage.deleteIfValue('key', 'value'),
        const RawPinStorageResult.failure(RawPinStorageFailure.deleteFailed),
      );
    });

    test('Windows Credential Manager write returns writeFailed', () async {
      final storage = WindowsCredentialRawPinStorage(
        lock: unavailableSupportDirectoryLock(),
      );

      expect(
        await storage.writeIfValue('key', null, 'value'),
        const RawPinStorageResult.failure(RawPinStorageFailure.writeFailed),
      );
    });

    test('Windows Credential Manager delete returns deleteFailed', () async {
      final storage = WindowsCredentialRawPinStorage(
        lock: unavailableSupportDirectoryLock(),
      );

      expect(
        await storage.deleteIfValue('key', 'value'),
        const RawPinStorageResult.failure(RawPinStorageFailure.deleteFailed),
      );
    });
  });

  test(
    'separate Dart processes cannot interleave a guarded read and mutation',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'truedash-pin-lock-',
      );
      final fixture = 'test/fixtures/pin_storage_lock_process.dart';
      final dart = _dartExecutable();
      try {
        final first = await Process.start(dart, <String>[
          'run',
          fixture,
          directory.path,
          'first',
        ]);
        await _waitFor(
          File('${directory.path}${Platform.pathSeparator}first-entered'),
        );
        final second = await Process.start(dart, <String>[
          'run',
          fixture,
          directory.path,
          'second',
        ]);

        await Future<void>.delayed(const Duration(milliseconds: 150));
        expect(
          await File('${directory.path}${Platform.pathSeparator}second-mutated')
              .exists(),
          isFalse,
        );

        await File('${directory.path}${Platform.pathSeparator}release')
            .create();
        expect(await first.exitCode, 0);
        expect(await second.exitCode, 0);
        expect(
          await File('${directory.path}${Platform.pathSeparator}guarded-state')
              .readAsString(),
          'first-mutated',
        );
        expect(
          await File('${directory.path}${Platform.pathSeparator}second-mutated')
              .exists(),
          isTrue,
        );
      } finally {
        await directory.delete(recursive: true);
      }
    },
  );
}

String _dartExecutable() {
  var directory = File(Platform.resolvedExecutable).parent;
  while (directory.parent.path != directory.path) {
    if (directory.path.endsWith(
      '${Platform.pathSeparator}bin${Platform.pathSeparator}cache',
    )) {
      final dart = File(
        '${directory.path}${Platform.pathSeparator}dart-sdk'
        '${Platform.pathSeparator}bin${Platform.pathSeparator}dart',
      );
      if (dart.existsSync()) return dart.path;
    }
    directory = directory.parent;
  }
  throw StateError('Unable to locate the Flutter-bundled Dart executable.');
}

Future<void> _waitFor(File file) async {
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (!await file.exists()) {
    if (DateTime.now().isAfter(deadline)) {
      fail('timed out waiting for ${file.path}');
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
  }
}
