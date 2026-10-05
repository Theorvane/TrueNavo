// Connector-free fixtures shared by offline demo and development preview.
import 'dart:typed_data';

import 'package:truenas_api/truenas_api.dart';

import '../features/configuration_backup/configuration_backup_file.dart';

/// Synthetic public metadata only: no backup, token, file bytes or transport.
mixin ConfigurationBackupPreviewAdapter
    implements AuthenticatedConfigurationBackupSession {
  static const _inventory = ConfigurationBackupInventory(
    endpoint: 'wss://nas-demo.example/api/current',
    hostId: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    currentVersion: '25.10.1',
    state: 'READY',
    fullAdmin: true,
    failoverLicensed: false,
    conflictingJob: false,
  );

  @override
  ConfigurationBackupCapabilities get configurationBackupCapabilities =>
      const ConfigurationBackupCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        transferSupported: true,
      );

  @override
  Future<ConfigurationBackupInventory> loadConfigurationBackup() async =>
      _inventory;

  @override
  Future<ConfigurationBackupReview> reviewConfigurationBackup(
    ConfigurationBackupRequest request,
  ) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      throw const ConfigurationBackupException(
        ConfigurationBackupExceptionReason.invalidRequest,
      );
    }
    return ConfigurationBackupReview(
      request: request,
      endpoint: _inventory.endpoint,
      warnings: [
        'SAMPLE ONLY. No server connection, download, file picker or file creation will occur.',
        'Real configuration files contain sensitive server settings even without the password secret seed. Protect every exported copy.',
        if (request.includeSecretSeed) 'The secret seed permits decryption of stored server credentials. The backup is not password-encrypted by this app.',
        if (!request.includeSecretSeed) 'Without the secret seed, encrypted credentials may not be recoverable.',
        'Pool data is not included. This is not a separate or complete encryption-key export: the database may contain stored dataset keys and other secrets. Keep independent recovery material; restoration is unverified.',
      ],
    );
  }

  @override
  Future<ConfigurationBackupResult> executeConfigurationBackup(
    ConfigurationBackupReview review,
    String confirmation,
  ) async => const ConfigurationBackupResult(
    ConfigurationBackupOutcome.rejected,
    'Sample preview: no configuration download or file save was performed.',
  );
}

/// Even a faulty sample caller cannot launch a platform picker or write a file.
final class ConfigurationBackupPreviewFileSaver
    implements ConfigurationBackupFileSaver {
  const ConfigurationBackupPreviewFileSaver();
  @override
  bool get supported => true;
  @override
  void cancel() {}
  @override
  Future<ConfigurationBackupSaveOutcome> save({
    required Uint8List bytes,
    required String filename,
    required bool Function() isCurrent,
  }) async {
    bytes.fillRange(0, bytes.length, 0);
    return ConfigurationBackupSaveOutcome.cancelled;
  }
}
