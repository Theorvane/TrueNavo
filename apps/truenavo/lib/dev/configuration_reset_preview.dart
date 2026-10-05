import 'package:truenas_api/truenas_api.dart';

/// Public synthetic readiness only. No connector, reset or power RPC exists.
mixin ConfigurationResetPreviewAdapter
    implements AuthenticatedConfigurationResetSession {
  static final _inventory = ConfigurationResetInventory(
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
  ConfigurationResetCapabilities get configurationResetCapabilities =>
      const ConfigurationResetCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
      );

  @override
  Future<ConfigurationResetInventory> loadConfigurationReset() async =>
      _inventory;

  @override
  Future<ConfigurationResetReview> reviewConfigurationReset(
    ConfigurationResetRequest request,
  ) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      throw const ConfigurationResetException(
        ConfigurationResetExceptionReason.invalidRequest,
      );
    }
    return ConfigurationResetReview(
      request: request,
      endpoint: _inventory.endpoint,
      warnings: const [
        'SAMPLE ONLY. No server connection, reset, file change or reboot occurs.',
        'Real reset replaces configuration immediately and requests a reboot. An error can follow replacement and does not prove rollback.',
        'Keep independent console access, a trusted configuration backup and recovery keys. Accounts, addresses, certificates and services may be lost.',
        'A previously staged configuration restore can supersede factory defaults on restart. This app cannot detect or clear those pending files.',
        'This is not secure erasure, a data backup, verified key recovery or proof that the next boot uses factory defaults.',
      ],
    );
  }

  @override
  Future<ConfigurationResetResult> executeConfigurationReset(
    ConfigurationResetReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => const ConfigurationResetResult(
    ConfigurationResetOutcome.rejected,
    'Sample preview: no factory reset, configuration change or reboot was performed.',
  );
}
