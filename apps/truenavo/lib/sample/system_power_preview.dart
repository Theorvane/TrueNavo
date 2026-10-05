// Connector-free fixtures shared by offline demo and development preview.
import 'package:truenas_api/truenas_api.dart';

/// Public synthetic identity only. No connector, power command or job checks.
mixin SystemPowerPreviewAdapter implements AuthenticatedSystemPowerSession {
  static final _inventory = SystemPowerInventory(
    endpoint: 'wss://nas-demo.example/api/current',
    hostId: '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    bootId: '12345678-1234-4234-8234-123456789abc',
    currentVersion: '25.10.1',
    state: 'READY',
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
      BootEnvironmentSnapshot(
        id: '25.10.0',
        dataset: 'boot-pool/ROOT/25.10.0',
        created: '2026-08-01T10:00:00',
        usedBytes: 3221225472,
        active: false,
        activated: false,
        keep: true,
        canActivate: true,
      ),
    ],
  );
  @override
  SystemPowerCapabilities get systemPowerCapabilities =>
      const SystemPowerCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canReboot: true,
        canShutdown: true,
      );
  @override
  Future<SystemPowerInventory> loadSystemPower() async => _inventory;
  @override
  Future<SystemPowerReview> reviewSystemPower(
    SystemPowerRequest request,
  ) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      throw const SystemPowerException(
        SystemPowerExceptionReason.invalidRequest,
      );
    }
    return SystemPowerReview(
      request: request,
      endpoint: _inventory.endpoint,
      warnings: [
        'SAMPLE ONLY. No server connection, restart, shutdown or job lookup will occur.',
        'All clients, shares, applications and virtual machines are interrupted on a real server. Coordinate downtime and independent access first.',
        if (request.action == SystemPowerAction.shutdown) 'A real shutdown leaves the machine offline. This app cannot turn it on.',
        'Acceptance and disconnection do not prove completion. No automatic reconnect, check, retry or replay is performed.',
      ],
    );
  }

  @override
  Future<SystemPowerResult> executeSystemPower(
    SystemPowerReview review,
    String confirmation,
  ) async => const SystemPowerResult(
    SystemPowerOutcome.rejected,
    'Sample preview: no restart, shutdown or server request was sent.',
  );
}
