import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

final class ConfigurationRestoreFileException implements Exception {
  const ConfigurationRestoreFileException();
  @override
  String toString() =>
      'The selected configuration file could not be read safely.';
}

abstract interface class ConfigurationRestoreFilePicker {
  bool get supported;

  /// Returns owned mutable bytes, or null on cancellation. No filename or URI
  /// leaves native storage. The caller must consume or clear the returned bytes.
  Future<Uint8List?> pick({
    required bool Function() isCurrent,
    void Function()? onReadStarted,
  });
  void cancel();
}

final configurationRestoreFilePickerProvider =
    Provider<ConfigurationRestoreFilePicker>((ref) {
      final picker = AndroidConfigurationRestoreFilePicker();
      ref.onDispose(picker.cancel);
      return picker;
    });

final class AndroidConfigurationRestoreFilePicker
    implements ConfigurationRestoreFilePicker {
  AndroidConfigurationRestoreFilePicker({
    MethodChannel? channel,
    bool? android,
    bool Function()? resumed,
  }) : _channel =
           channel ??
           const MethodChannel('trueraid.configuration_restore_file.v1'),
       supported =
           android ??
           (!kIsWeb && defaultTargetPlatform == TargetPlatform.android),
       _resumed =
           resumed ??
           (() =>
               WidgetsBinding.instance.lifecycleState ==
               AppLifecycleState.resumed);
  final MethodChannel _channel;
  final bool Function() _resumed;
  @override
  final bool supported;
  String? _active;
  void Function()? _cancelWait;
  static int _sequence = 0;

  @override
  Future<Uint8List?> pick({
    required bool Function() isCurrent,
    void Function()? onReadStarted,
  }) async {
    String? owned;
    Uint8List? bytes;
    AppLifecycleListener? lifecycle;
    try {
      if (!supported || _active != null) {
        throw const ConfigurationRestoreFileException();
      }
      if (!isCurrent()) return null;
      owned = '${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';
      _active = owned;
      final args = <String, Object?>{
        'protocolVersion': 1,
        'operationId': owned,
      };
      final chosen = await _channel.invokeMapMethod<String, Object?>(
        'chooseDocument',
        args,
      );
      if (_active != owned || !isCurrent()) return null;
      if (!_response(chosen, owned, 3)) {
        throw const ConfigurationRestoreFileException();
      }
      if (chosen!['status'] == 'cancelled') return null;
      if (chosen['status'] != 'selected') {
        throw const ConfigurationRestoreFileException();
      }
      // ActivityResult may precede Flutter resumed. Wait locally, at most 2s;
      // no document bytes or network request are read while waiting.
      if (!await _waitForForeground(owned, isCurrent)) return null;
      onReadStarted?.call();
      if (_active != owned || !isCurrent() || !_resumed()) return null;
      lifecycle = AppLifecycleListener(
        onStateChange: (state) {
          if (_active == owned && state != AppLifecycleState.resumed) cancel();
        },
      );
      final result = await _channel.invokeMapMethod<String, Object?>(
        'readSelectedDocument',
        args,
      );
      final raw = result?['bytes'];
      if (raw is Uint8List) bytes = raw;
      if (_active != owned || !isCurrent() || !_resumed()) return null;
      if (_response(result, owned, 3) && result!['status'] == 'cancelled') {
        return null;
      }
      if (!_response(result, owned, 4) ||
          result!['status'] != 'read' ||
          bytes == null ||
          bytes.isEmpty ||
          bytes.length > 10 * 1024 * 1024) {
        throw const ConfigurationRestoreFileException();
      }
      final value = bytes;
      bytes = null;
      return value;
    } on Object {
      throw const ConfigurationRestoreFileException();
    } finally {
      lifecycle?.dispose();
      bytes?.fillRange(0, bytes.length, 0);
      if (owned != null) {
        if (_active == owned) _active = null;
        _discard(owned);
      }
    }
  }

  Future<bool> _waitForForeground(
    String owned,
    bool Function() isCurrent,
  ) async {
    final result = Completer<bool>();
    var ticks = 0;
    void finish(bool ready) {
      if (!result.isCompleted) result.complete(ready);
    }

    void cancelWait() => finish(false);
    _cancelWait = cancelWait;
    void inspect() {
      try {
        if (_active != owned || !isCurrent() || ++ticks > 40) {
          finish(false);
        } else if (_resumed()) {
          finish(true);
        }
      } on Object {
        finish(false);
      }
    }

    inspect();
    final timer = Timer.periodic(
      const Duration(milliseconds: 50),
      (_) => inspect(),
    );
    try {
      return await result.future;
    } finally {
      timer.cancel();
      if (identical(_cancelWait, cancelWait)) _cancelWait = null;
    }
  }

  bool _response(Map<String, Object?>? response, String id, int length) =>
      response != null &&
      response.length == length &&
      response['protocolVersion'] == 1 &&
      response['operationId'] == id &&
      response['status'] is String;
  void _discard(String id) {
    _channel
        .invokeMethod<void>('cancelDocument', {
          'protocolVersion': 1,
          'operationId': id,
        })
        .then<void>((_) {}, onError: (_, _) {});
  }

  @override
  void cancel() {
    final id = _active;
    _active = null;
    _cancelWait?.call();
    if (id != null) _discard(id);
  }
}
