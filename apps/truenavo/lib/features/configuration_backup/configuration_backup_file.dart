import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

enum ConfigurationBackupSaveOutcome { saved, cancelled, failed, unsupported }

abstract interface class ConfigurationBackupFileSaver {
  bool get supported;

  /// Consumes and clears [bytes] on every outcome. Saving may leave a partial
  /// user-selected document on failure; a document provider is not transactional.
  Future<ConfigurationBackupSaveOutcome> save({
    required Uint8List bytes,
    required String filename,
    required bool Function() isCurrent,
  });
  void cancel();
}

final configurationBackupFileSaverProvider =
    Provider<ConfigurationBackupFileSaver>((ref) {
      final saver = AndroidConfigurationBackupFileSaver();
      ref.onDispose(saver.cancel);
      return saver;
    });

bool _allowedExportFilename(String filename) {
  if (const {
    'truenas-configuration.db',
    'truenas-configuration.tar',
  }.contains(filename)) {
    return true;
  }
  return RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-'
        r'[0-9a-fA-F]{4}-[0-9a-fA-F]{12}\.(csv|json|yaml)\.tar\.gz$',
      ).stringMatch(filename) ==
      filename;
}

final class AndroidConfigurationBackupFileSaver
    implements ConfigurationBackupFileSaver {
  AndroidConfigurationBackupFileSaver({MethodChannel? channel, bool? android})
    : _channel =
          channel ??
          const MethodChannel('truenavo.configuration_backup_file.v1'),
      supported =
          android ??
          (!kIsWeb && defaultTargetPlatform == TargetPlatform.android);
  final MethodChannel _channel;
  @override
  final bool supported;
  String? _active;
  static int _sequence = 0;

  @override
  Future<ConfigurationBackupSaveOutcome> save({
    required Uint8List bytes,
    required String filename,
    required bool Function() isCurrent,
  }) async {
    String? owned;
    try {
      if (!supported) return ConfigurationBackupSaveOutcome.unsupported;
      if (_active != null ||
          bytes.isEmpty ||
          bytes.length > 16 * 1024 * 1024 ||
          !_allowedExportFilename(filename)) {
        return ConfigurationBackupSaveOutcome.failed;
      }
      if (!isCurrent()) return ConfigurationBackupSaveOutcome.cancelled;
      owned = '${DateTime.now().microsecondsSinceEpoch}-${++_sequence}';
      _active = owned;
      final args = <String, Object?>{
        'protocolVersion': 1,
        'operationId': owned,
      };
      final chosen = await _channel.invokeMapMethod<String, Object?>(
        'chooseDocument',
        {...args, 'filename': filename},
      );
      if (_active != owned || !isCurrent()) {
        return ConfigurationBackupSaveOutcome.cancelled;
      }
      if (!_response(chosen, owned)) {
        return ConfigurationBackupSaveOutcome.failed;
      }
      if (chosen!['status'] == 'cancelled') {
        return ConfigurationBackupSaveOutcome.cancelled;
      }
      if (chosen['status'] != 'selected') {
        return ConfigurationBackupSaveOutcome.failed;
      }
      // No bytes crossed the channel before this post-picker identity check.
      final result = await _channel.invokeMapMethod<String, Object?>(
        'writeSelectedDocument',
        {...args, 'bytes': bytes},
      );
      if (_active != owned || !isCurrent()) {
        return ConfigurationBackupSaveOutcome.cancelled;
      }
      if (!_response(result, owned)) {
        return ConfigurationBackupSaveOutcome.failed;
      }
      return switch (result!['status']) {
        'saved' => ConfigurationBackupSaveOutcome.saved,
        'cancelled' => ConfigurationBackupSaveOutcome.cancelled,
        _ => ConfigurationBackupSaveOutcome.failed,
      };
    } on Object {
      return ConfigurationBackupSaveOutcome.failed;
    } finally {
      bytes.fillRange(0, bytes.length, 0);
      if (owned != null) {
        if (_active == owned) _active = null;
        _discard(owned);
      }
    }
  }

  bool _response(Map<String, Object?>? response, String id) =>
      response != null &&
      response.length == 3 &&
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
    if (id != null) _discard(id);
  }
}
