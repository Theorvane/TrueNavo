import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/configuration_restore/configuration_restore_file.dart';

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  setUp(
    () => binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed),
  );
  test(
    'selection precedes read phase callback with no URI or filename',
    () async {
      final channel = _Channel();
      var reading = false;
      channel.beforeRead = () => expect(reading, isTrue);
      final picker = _picker(channel);
      final bytes = await picker.pick(
        isCurrent: () => true,
        onReadStarted: () => reading = true,
      );
      expect(bytes, [1, 2, 3]);
      expect(identical(bytes, channel.bytes), isTrue);
      expect(channel.calls.take(2).map((e) => e.method), [
        'chooseDocument',
        'readSelectedDocument',
      ]);
      for (final call in channel.calls) {
        expect((call.arguments as Map).keys.toSet(), {
          'protocolVersion',
          'operationId',
        });
      }
      bytes!.fillRange(0, bytes.length, 0);
    },
  );
  test('unsupported platform and stale session never open picker', () async {
    final channel = _Channel();
    await expectLater(
      AndroidConfigurationRestoreFilePicker(
        channel: channel,
        android: false,
      ).pick(isCurrent: () => true),
      throwsA(isA<ConfigurationRestoreFileException>()),
    );
    expect(await _picker(channel).pick(isCurrent: () => false), isNull);
    expect(channel.calls, isEmpty);
  });
  test('session change during selection prevents every file read', () async {
    var current = true;
    final channel = _Channel()..onChoose = () => current = false;
    expect(await _picker(channel).pick(isCurrent: () => current), isNull);
    expect(
      channel.calls.where((e) => e.method == 'readSelectedDocument'),
      isEmpty,
    );
  });
  test('phase callback can revoke lease before native read', () async {
    var current = true;
    final channel = _Channel();
    expect(
      await _picker(channel)
          .pick(isCurrent: () => current, onReadStarted: () => current = false),
      isNull,
    );
    expect(
      channel.calls.where((e) => e.method == 'readSelectedDocument'),
      isEmpty,
    );
  });
  test(
    'waits locally for resumed without reading in picker background',
    () async {
      var resumed = false;
      final channel = _Channel();
      final picker = AndroidConfigurationRestoreFilePicker(
        channel: channel,
        android: true,
        resumed: () => resumed,
      );
      final pending = picker.pick(isCurrent: () => true);
      await Future<void>.delayed(const Duration(milliseconds: 70));
      expect(
        channel.calls.where((e) => e.method == 'readSelectedDocument'),
        isEmpty,
      );
      resumed = true;
      final bytes = await pending;
      expect(bytes, [1, 2, 3]);
      bytes!.fillRange(0, bytes.length, 0);
    },
  );
  test('cancel foreground wait settles without a read', () async {
    final channel = _Channel();
    final picker = AndroidConfigurationRestoreFilePicker(
      channel: channel,
      android: true,
      resumed: () => false,
    );
    final pending = picker.pick(isCurrent: () => true);
    await Future<void>.delayed(Duration.zero);
    picker.cancel();
    expect(await pending, isNull);
    expect(
      channel.calls.where((e) => e.method == 'readSelectedDocument'),
      isEmpty,
    );
  });
  test('foreground wait expires after its bounded window', () async {
    final channel = _Channel();
    final picker = AndroidConfigurationRestoreFilePicker(
      channel: channel,
      android: true,
      resumed: () => false,
    );
    expect(await picker.pick(isCurrent: () => true), isNull);
    expect(
      channel.calls.where((e) => e.method == 'readSelectedDocument'),
      isEmpty,
    );
  });
  for (final fault in [
    'wrongId',
    'extra',
    'empty',
    'oversized',
    'failure',
    'throw',
  ]) {
    test(
      'malformed $fault read fails sanitized and wipes received bytes',
      () async {
        final channel = _Channel()..fault = fault;
        await expectLater(
          _picker(channel).pick(isCurrent: () => true),
          throwsA(isA<ConfigurationRestoreFileException>()),
        );
        if (fault != 'failure' && fault != 'throw') {
          expect(channel.bytes.every((v) => v == 0), isTrue);
        }
      },
    );
  }
  test('picker cancellation does not read', () async {
    final channel = _Channel()..chooseStatus = 'cancelled';
    expect(await _picker(channel).pick(isCurrent: () => true), isNull);
    expect(
      channel.calls.where((e) => e.method == 'readSelectedDocument'),
      isEmpty,
    );
  });
  test('session change during provider read discards late bytes', () async {
    var current = true;
    final channel = _Channel()..readPause = Completer<void>();
    final future = _picker(channel).pick(isCurrent: () => current);
    while (!channel.reading) {
      await Future<void>.delayed(Duration.zero);
    }
    current = false;
    channel.readPause!.complete();
    expect(await future, isNull);
    expect(channel.bytes, [0, 0, 0]);
  });
  test(
    'background after actual read begins cancels and wipes late bytes',
    () async {
      final channel = _Channel()..readPause = Completer<void>();
      final future = _picker(channel).pick(isCurrent: () => true);
      while (!channel.reading) {
        await Future<void>.delayed(Duration.zero);
      }
      binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      channel.readPause!.complete();
      expect(await future, isNull);
      expect(channel.bytes, [0, 0, 0]);
      expect(
        channel.calls.where((e) => e.method == 'cancelDocument'),
        isNotEmpty,
      );
    },
  );
}

AndroidConfigurationRestoreFilePicker _picker(_Channel channel) =>
    AndroidConfigurationRestoreFilePicker(
      channel: channel,
      android: true,
      resumed: () => true,
    );

class _Channel extends MethodChannel {
  _Channel() : super('synthetic.restore.picker');
  final calls = <MethodCall>[];
  String? fault;
  String chooseStatus = 'selected';
  void Function()? onChoose, beforeRead;
  bool reading = false;
  Completer<void>? readPause;
  Uint8List bytes = Uint8List.fromList([1, 2, 3]);
  @override
  Future<Map<K, V>?> invokeMapMethod<K, V>(
    String method, [
    dynamic arguments,
  ]) async {
    calls.add(MethodCall(method, arguments));
    final result = <String, Object?>{
      'protocolVersion': 1,
      'operationId': (arguments as Map)['operationId'],
    };
    if (method == 'chooseDocument') {
      onChoose?.call();
      result['status'] = chooseStatus;
    } else {
      reading = true;
      beforeRead?.call();
      await readPause?.future;
      if (fault == 'throw') throw StateError('synthetic-private-filename');
      if (fault == 'empty') bytes = Uint8List(0);
      if (fault == 'oversized') {
        bytes = Uint8List(10 * 1024 * 1024 + 1)
          ..fillRange(0, 10 * 1024 * 1024 + 1, 1);
      }
      result['status'] = fault == 'failure' ? 'failed' : 'read';
      if (fault != 'failure') result['bytes'] = bytes;
      if (fault == 'wrongId') result['operationId'] = 'wrong';
      if (fault == 'extra') result['private'] = true;
    }
    return Map<K, V>.from(result);
  }

  @override
  Future<T?> invokeMethod<T>(String method, [dynamic arguments]) async {
    calls.add(MethodCall(method, arguments));
    return null;
  }
}
