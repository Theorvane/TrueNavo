// Connector-free fixtures shared by offline demo and development preview.
import 'package:truenas_api/truenas_api.dart';

/// Stopped-service configuration sample without RPC, DNS or file operations.
mixin NfsSettingsPreviewAdapter implements AuthenticatedNfsSettingsSession {
  static final _inventory = NfsSettingsInventory(
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
    config: NfsConfigSnapshot(
      id: 1,
      settings: NfsGlobalSettings(
        serverThreads: null,
        protocols: const ['NFSV3', 'NFSV4'],
        bindAddresses: const ['192.0.2.10'],
        mountdLog: false,
        statdLockdLog: false,
      ),
      reportedServers: 8,
      managedNfsd: true,
      allowNonroot: false,
      v4Krb: false,
      v4Domain: '',
      v4KrbEnabled: false,
      keytabHasNfsSpn: false,
      rdma: false,
      userdManageGids: false,
      mountdPort: null,
      rpcstatdPort: null,
      rpclockdPort: null,
    ),
    exports: [
      NfsConfiguredExport(id: 21, enabled: false, security: const ['SYS']),
      NfsConfiguredExport(id: 22, enabled: false, security: const ['SYS']),
    ],
    serviceState: 'STOPPED',
    serviceEnabled: false,
    bindChoices: const ['192.0.2.10', '192.0.2.11'],
    directoryConfigured: false,
  );
  @override
  NfsSettingsCapabilities get nfsSettingsCapabilities =>
      const NfsSettingsCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canUpdate: true,
      );
  @override
  Future<NfsSettingsInventory> loadNfsSettings() async => _inventory;
  @override
  Future<NfsSettingsReview> reviewNfsSettings(
    NfsSettingsRequest request,
  ) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      throw const NfsSettingsException(
        NfsSettingsExceptionReason.invalidRequest,
      );
    }
    return NfsSettingsReview(
      request: request,
      endpoint: _inventory.endpoint,
      warnings: const [
        'SAMPLE ONLY. No NFS configuration, service, logging, export or network action is submitted.',
        'Real changes require the NFS service stopped. Protocol and binding changes also require no enabled exports.',
        'Automatic worker count is reported configuration, not measured load. Service startup and client access require independent verification.',
      ],
    );
  }

  @override
  Future<NfsSettingsResult> executeNfsSettings(
    NfsSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async => const NfsSettingsResult(
    NfsSettingsOutcome.rejected,
    'Sample preview: no NFS write, service change, export operation or probe was performed.',
  );
}
