// Connector-free fixtures shared by offline demo and development preview.
import 'package:truenas_api/truenas_api.dart';

/// Configuration samples only: no file-service or directory connector.
mixin SmbSettingsPreviewAdapter implements AuthenticatedSmbSettingsSession {
  static final _inventory = SmbSettingsInventory(
    readiness: AlertSettingsInventory(
      endpoint: 'wss://nas-demo.example/api/current',
      hostId:
          '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
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
      services: const [],
    ),
    config: SmbConfigSnapshot(
      id: 1,
      settings: const SmbGlobalSettings(
        netbiosName: 'NAS-DEMO',
        workgroup: 'WORKGROUP',
        description: 'Sample file server',
        multichannel: true,
        encryption: SmbTransportEncryption.desired,
      ),
      aliases: const [],
      smb1Enabled: false,
      ntlmv1Enabled: false,
      appleExtensions: true,
      localMaster: true,
      syslogEnabled: false,
      debugEnabled: false,
      auxiliaryParametersPresent: false,
      serverSidKnown: true,
      defaultGuestAccount: true,
      privilegedGroupConfigured: false,
    ),
    shares: const [
      SmbConfiguredShare(id: 11, enabled: true),
      SmbConfiguredShare(id: 12, enabled: true),
      SmbConfiguredShare(id: 13, enabled: false),
    ],
    directoryConfigured: false,
    securityManaged: false,
    appleDependentShareCount: 0,
  );
  @override
  SmbSettingsCapabilities get smbSettingsCapabilities =>
      const SmbSettingsCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canUpdate: true,
      );
  @override
  Future<SmbSettingsInventory> loadSmbSettings() async => _inventory;
  @override
  Future<SmbSettingsReview> reviewSmbSettings(
    SmbSettingsRequest request,
  ) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      throw const SmbSettingsException(
        SmbSettingsExceptionReason.invalidRequest,
      );
    }
    return SmbSettingsReview(
      request: request,
      endpoint: _inventory.endpoint,
      warnings: const [
        'SAMPLE ONLY. No configuration, account database, service restart or discovery announcement is changed.',
        'Real global changes can interrupt all SMB clients. Server identity changes can affect account databases, caches and discovery.',
        'Configured share counts are not connected clients, throughput or security certification.',
      ],
    );
  }

  @override
  Future<SmbSettingsResult> executeSmbSettings(
    SmbSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => const SmbSettingsResult(
    SmbSettingsOutcome.rejected,
    'Sample preview: no SMB write, identity change or restart was performed.',
  );
}
