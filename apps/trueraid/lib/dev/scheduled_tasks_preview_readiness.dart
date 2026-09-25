import 'package:truenas_api/truenas_api.dart';

/// Synthetic, immutable readiness. This file has no connector or task runner.
final scheduledTasksPreviewReadiness = AlertSettingsInventory(
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
  services: const [],
);
