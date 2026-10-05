import 'dart:typed_data';

import 'package:truenas_api/truenas_api.dart';

import '../features/configuration_restore/configuration_restore_file.dart';

/// Synthetic file envelope only. This is not a usable server configuration.
Uint8List _sampleEnvelope() {
  final bytes = Uint8List(512);
  bytes.setAll(0, 'SQLite format 3\u0000'.codeUnits);
  bytes[16] = 2;
  bytes[18] = 1;
  bytes[19] = 1;
  return bytes;
}

/// No connector, generated token, platform picker or upload exists in preview.
mixin ConfigurationRestorePreviewAdapter
    implements AuthenticatedConfigurationRestoreSession {
  static final _files = Expando<bool>();
  static final _inventory = ConfigurationRestoreInventory(
    endpoint: 'wss://nas-demo.example/api/current',
    hostId: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    bootId: '12345678-1234-4234-8234-123456789abc',
    currentVersion: '25.10.1',
    state: 'READY',
    fullAdmin: true,
    failoverLicensed: false,
    conflictingJob: false,
    bootPool: 'boot-pool',
    bootHealthy: true,
    environments: const [
      BootEnvironmentSnapshot(
        id: '25.10.1',
        dataset: 'boot-pool/ROOT/25.10.1',
        created: '2026-09-01T10:00:00',
        usedBytes: 4294967296,
        active: true,
        activated: true,
        keep: true,
        canActivate: true,
      ),
    ],
  );

  @override
  ConfigurationRestoreCapabilities get configurationRestoreCapabilities =>
      const ConfigurationRestoreCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        transferSupported: true,
      );

  @override
  Future<ConfigurationRestoreFile> prepareConfigurationRestore(
    Uint8List bytes,
  ) async {
    final file = ConfigurationRestoreFile.fromBytes(bytes);
    _files[file] = true;
    return file;
  }

  @override
  Future<ConfigurationRestoreInventory> loadConfigurationRestore() async =>
      _inventory;

  @override
  Future<ConfigurationRestoreReview> reviewConfigurationRestore(
    ConfigurationRestoreRequest request,
  ) async {
    if (!identical(request.inventory, _inventory) ||
        _files[request.file] != true ||
        request.validationError != null) {
      throw const ConfigurationRestoreException(
        ConfigurationRestoreExceptionReason.invalidRequest,
      );
    }
    return ConfigurationRestoreReview(
      request: request,
      endpoint: _inventory.endpoint,
      warnings: const [
        'SAMPLE ONLY. The synthetic envelope is not a usable configuration. No file picker, server connection, token or upload will occur.',
        'Real restoration replaces settings and automatically reboots TrueNAS. Keep independent access and a separate backup.',
        'Envelope inspection cannot prove correct-server ownership, database compatibility or recoverability.',
        'A missing secret seed or authorized-key files can remove existing recovery material. Acceptance is not completion.',
      ],
    );
  }

  @override
  Future<ConfigurationRestoreResult> executeConfigurationRestore(
    ConfigurationRestoreReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    review.request.file.dispose();
    return const ConfigurationRestoreResult(
      ConfigurationRestoreOutcome.rejected,
      'Sample preview: no token, configuration upload, restoration or reboot was performed.',
    );
  }
}

final class ConfigurationRestorePreviewFilePicker
    implements ConfigurationRestoreFilePicker {
  const ConfigurationRestorePreviewFilePicker();
  @override
  bool get supported => true;
  @override
  void cancel() {}
  @override
  Future<Uint8List?> pick({
    required bool Function() isCurrent,
    void Function()? onReadStarted,
  }) async {
    if (!isCurrent()) return null;
    onReadStarted?.call();
    if (!isCurrent()) return null;
    return _sampleEnvelope();
  }
}
