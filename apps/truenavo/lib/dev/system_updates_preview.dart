import 'package:truenas_api/truenas_api.dart';

/// Const-compatible, immutable, connector-free display fixtures.
mixin SystemUpdatesPreviewAdapter implements AuthenticatedSystemUpdatesSession {
  static final _inventory = SystemUpdateInventory(
    endpoint: 'wss://nas-demo.example/api/current',
    currentVersion: '25.10.1',
    bootPool: 'boot-pool',
    bootHealthy: true,
    failoverLicensed: false,
    conflictingJob: false,
    bootSizeBytes: 64 * 1024 * 1024 * 1024,
    bootAllocatedBytes: 16 * 1024 * 1024 * 1024,
    bootFreeBytes: 48 * 1024 * 1024 * 1024,
    checked: true,
    currentTrain: 'TrueNAS-SCALE-Goldeye',
    currentProfile: 'GENERAL',
    matchesProfile: true,
    environments: const [
      BootEnvironmentSnapshot(
        id: '25.10.1',
        dataset: 'boot-pool/ROOT/25.10.1',
        created: '2026-01-01 00:00:00',
        usedBytes: 8 * 1024 * 1024 * 1024,
        active: true,
        activated: true,
        keep: true,
        canActivate: true,
      ),
      BootEnvironmentSnapshot(
        id: '25.10.0',
        dataset: 'boot-pool/ROOT/25.10.0',
        created: '2025-10-01 00:00:00',
        usedBytes: 8 * 1024 * 1024 * 1024,
        active: false,
        activated: false,
        keep: true,
        canActivate: true,
      ),
    ],
    versions: const [
      SystemUpdateVersion(
        train: 'TrueNAS-SCALE-Goldeye',
        version: '25.10.2',
        filename: 'TrueNAS-SCALE-25.10.2.update',
        checksum: 'SYNTHETIC-NOT-A-VERIFIED-CHECKSUM',
        downloadBytes: 2 * 1024 * 1024 * 1024,
        profile: 'GENERAL',
        releaseNotes:
            'Synthetic release fixture; not an available-release claim.',
      ),
    ],
  );
  @override
  SystemUpdatesCapabilities get systemUpdatesCapabilities =>
      const SystemUpdatesCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canCheck: true,
        canDownload: true,
        canInstall: true,
      );
  @override
  Future<SystemUpdateInventory> loadSystemUpdates() async => _inventory;
  @override
  Future<SystemUpdateReview> reviewSystemUpdate(
    SystemUpdateRequest request,
  ) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      throw const SystemUpdatesException(
        SystemUpdatesExceptionReason.invalidRequest,
      );
    }
    return SystemUpdateReview(
      request: request,
      endpoint: _inventory.endpoint,
      warnings: const [
        'SAMPLE ONLY. The preview cannot check an update source, download, install, poll or reboot.',
      ],
    );
  }

  @override
  Future<SystemUpdateResult> executeSystemUpdate(
    SystemUpdateReview review,
    String confirmation,
  ) async => const SystemUpdateResult(
    SystemUpdateOutcome.rejected,
    'Sample preview: no update request was sent.',
  );
  @override
  Future<SystemUpdateResult> pollSystemUpdate(SystemUpdateJob job) async =>
      const SystemUpdateResult(
        SystemUpdateOutcome.rejected,
        'Sample preview: no job read was sent.',
      );
}
