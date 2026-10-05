import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/configuration_backup/configuration_backup_file.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('truenavo.test.configuration_backup_file');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  Object? Function(MethodCall)? handler;
  setUp(() {
    calls.clear();
    handler = null;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      if (handler != null) return handler!(call);
      if (call.method == 'cancelDocument') return null;
      return _reply(
        call,
        call.method == 'chooseDocument' ? 'selected' : 'saved',
      );
    });
  });
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  AndroidConfigurationBackupFileSaver saver([bool android = true]) =>
      AndroidConfigurationBackupFileSaver(channel: channel, android: android);
  Future<ConfigurationBackupSaveOutcome> save(
    AndroidConfigurationBackupFileSaver value,
    Uint8List bytes, {
    String filename = 'truenas-configuration.db',
    bool Function()? current,
  }) => value.save(
    bytes: bytes,
    filename: filename,
    isCurrent: current ?? () => true,
  );

  test(
    'picker contains no bytes or URI and save consumes its buffer',
    () async {
      final bytes = Uint8List.fromList([1, 2, 3]);
      expect(await save(saver(), bytes), ConfigurationBackupSaveOutcome.saved);
      expect(bytes, [0, 0, 0]);
      expect((calls.first.arguments as Map).keys.toSet(), {
        'protocolVersion',
        'operationId',
        'filename',
      });
      final write = calls.singleWhere(
        (c) => c.method == 'writeSelectedDocument',
      );
      expect((write.arguments as Map).keys.toSet(), {
        'protocolVersion',
        'operationId',
        'bytes',
      });
      expect(
        (write.arguments as Map)['operationId'],
        (calls.first.arguments as Map)['operationId'],
      );
    },
  );
  test('unsupported platform never launches picker and clears bytes', () async {
    final bytes = Uint8List.fromList([1]);
    expect(
      await save(saver(false), bytes),
      ConfigurationBackupSaveOutcome.unsupported,
    );
    expect(calls, isEmpty);
    expect(bytes, [0]);
  });
  test('canonical audit report filename is accepted and consumed', () async {
    final bytes = Uint8List.fromList([0x1f, 0x8b, 0x08]);
    expect(
      await save(
        saver(),
        bytes,
        filename: '12345678-1234-4234-8234-123456789abc.csv.tar.gz',
      ),
      ConfigurationBackupSaveOutcome.saved,
    );
    expect(bytes, [0, 0, 0]);
    expect(
      (calls.first.arguments as Map)['filename'],
      '12345678-1234-4234-8234-123456789abc.csv.tar.gz',
    );
  });
  for (final invalid in [
    '../secret.db',
    'backup.db',
    'truenas-configuration.db\n',
    '12345678-1234-4234-8234-123456789abc.exe.tar.gz',
    '../12345678-1234-4234-8234-123456789abc.csv.tar.gz',
  ]) {
    test('invalid filename $invalid has zero platform calls', () async {
      final bytes = Uint8List.fromList([1]);
      expect(
        await save(saver(), bytes, filename: invalid),
        ConfigurationBackupSaveOutcome.failed,
      );
      expect(calls, isEmpty);
      expect(bytes, [0]);
    });
  }
  for (final length in [0, 16 * 1024 * 1024 + 1]) {
    test('invalid byte length $length never invokes channel', () async {
      final bytes = Uint8List(length)..fillRange(0, length, 1);
      expect(await save(saver(), bytes), ConfigurationBackupSaveOutcome.failed);
      expect(calls, isEmpty);
      expect(bytes.every((b) => b == 0), isTrue);
    });
  }
  test('already stale connection never opens picker', () async {
    final bytes = Uint8List.fromList([1]);
    expect(
      await save(saver(), bytes, current: () => false),
      ConfigurationBackupSaveOutcome.cancelled,
    );
    expect(calls, isEmpty);
    expect(bytes, [0]);
  });
  test(
    'connection change while picker open prevents all byte writes',
    () async {
      var current = true;
      handler = (call) {
        if (call.method == 'chooseDocument') {
          current = false;
          return _reply(call, 'selected');
        }
        return null;
      };
      final bytes = Uint8List.fromList([1]);
      expect(
        await save(saver(), bytes, current: () => current),
        ConfigurationBackupSaveOutcome.cancelled,
      );
      expect(calls.where((c) => c.method == 'writeSelectedDocument'), isEmpty);
      expect(bytes, [0]);
    },
  );
  test('stale provider completion is never reported saved', () async {
    var current = true;
    handler = (call) {
      if (call.method == 'writeSelectedDocument') current = false;
      return call.method == 'cancelDocument'
          ? null
          : _reply(
              call,
              call.method == 'chooseDocument' ? 'selected' : 'saved',
            );
    };
    final bytes = Uint8List.fromList([1]);
    expect(
      await save(saver(), bytes, current: () => current),
      ConfigurationBackupSaveOutcome.cancelled,
    );
    expect(bytes, [0]);
  });
  for (final response in ['cancelled', 'failed', 'malformed', 'throws']) {
    test('picker $response settles sanitized without byte handoff', () async {
      handler = (call) {
        if (call.method == 'cancelDocument') return null;
        if (response == 'throws') {
          throw PlatformException(code: 'private', message: 'synthetic-secret');
        }
        if (response == 'malformed') return {'status': 'selected'};
        return _reply(call, response);
      };
      final bytes = Uint8List.fromList([1]);
      expect(
        await save(saver(), bytes),
        response == 'cancelled'
            ? ConfigurationBackupSaveOutcome.cancelled
            : ConfigurationBackupSaveOutcome.failed,
      );
      expect(calls.where((c) => c.method == 'writeSelectedDocument'), isEmpty);
      expect(bytes, [0]);
    });
  }
  test(
    'cancelled in-flight write clears bytes and cannot complete saved',
    () async {
      final pending = Completer<Object?>();
      MethodCall? writing;
      handler = (call) {
        if (call.method == 'chooseDocument') return _reply(call, 'selected');
        if (call.method == 'writeSelectedDocument') {
          writing = call;
          return pending.future;
        }
        return null;
      };
      final instance = saver();
      final bytes = Uint8List.fromList([1]);
      final future = save(instance, bytes);
      while (writing == null) {
        await Future<void>.delayed(Duration.zero);
      }
      instance.cancel();
      pending.complete(_reply(writing!, 'saved'));
      expect(await future, ConfigurationBackupSaveOutcome.cancelled);
      expect(bytes, [0]);
    },
  );
}

Map<String, Object?> _reply(MethodCall call, String status) => {
  'protocolVersion': 1,
  'operationId': (call.arguments as Map)['operationId'],
  'status': status,
};
