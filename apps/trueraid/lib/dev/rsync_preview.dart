import 'package:truenas_api/truenas_api.dart';

/// Connector-free samples. No SSH key use, transfer, probe, scan, timer or job RPC.
mixin RsyncPreviewAdapter implements AuthenticatedRsyncSession {
  static final _inventory = RsyncInventory(
    endpoint: 'wss://nas-demo.example/api/current',
    timezone: 'Asia/Seoul',
    failoverLicensed: false,
    tasks: const [
      RsyncTask(
        id: 11,
        description: 'Media copy · paused',
        mode: 'SSH',
        direction: 'PUSH',
        enabled: false,
        locked: false,
        lastJobState: 'SUCCESS',
        settings: RsyncSettings(
          path: '/mnt/tank/media',
          user: 'backup',
          connectionId: 21,
          remotePath: '/srv/backup',
          description: 'Media copy · paused',
        ),
      ),
      RsyncTask(
        id: 12,
        description: 'Documents overnight',
        mode: 'SSH',
        direction: 'PUSH',
        enabled: true,
        locked: false,
        lastJobState: 'FAILED',
        settings: RsyncSettings(
          path: '/mnt/tank/documents',
          user: 'backup',
          connectionId: 21,
          remotePath: '/srv/documents',
          description: 'Documents overnight',
          enabled: true,
        ),
      ),
      RsyncTask(
        id: 13,
        description: 'Legacy module task',
        mode: 'MODULE',
        direction: 'PULL',
        enabled: false,
        locked: false,
        blockedReason: 'Module and pull configurations remain read-only in this bounded native workflow.',
      ),
    ],
    connections: [
      RsyncConnection(
        id: 21,
        name: 'Offsite sample',
        host: 'backup.example',
        port: 22,
        username: 'replica',
        keyPairId: 31,
        publicKeyFingerprint: 'SHA256:sample-public-identity-only',
        hostKeyFingerprints: ['SHA256:sample-pinned-host-only'],
      ),
    ],
    users: const [RsyncUser(id: 41, uid: 1001, username: 'backup')],
    datasets: const [
      RsyncDataset(id: 'tank/media', guid: '101', path: '/mnt/tank/media'),
      RsyncDataset(
        id: 'tank/documents',
        guid: '102',
        path: '/mnt/tank/documents',
      ),
    ],
  );
  @override
  RsyncCapabilities get rsyncCapabilities => const RsyncCapabilities(
    connected: true,
    versionSupported: true,
    available: true,
    canCreate: true,
    canUpdate: true,
    canDelete: true,
    canRun: true,
  );
  @override
  Future<RsyncInventory> loadRsync() async => _inventory;
  @override
  Future<RsyncReview> reviewRsync(RsyncRequest request) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      throw const RsyncException(RsyncExceptionReason.invalidRequest);
    }
    return RsyncReview(
      request: request,
      endpoint: _inventory.endpoint,
      warnings: const [
        'SAMPLE ONLY. No SSH connection, transfer, remote probe, configuration write or job lookup will occur.',
        'On a real server, a PUSH transfer may overwrite destination files. Enabling a task permits future scheduled transfers; disabling or deleting it does not stop an active transfer.',
      ],
    );
  }

  @override
  Future<RsyncResult> executeRsync(
    RsyncReview review,
    String confirmation,
  ) async => const RsyncResult(
    RsyncOutcome.rejected,
    'Sample preview: no configuration or transfer request was sent.',
  );
  @override
  Future<RsyncResult> checkRsyncJob(RsyncJob job) async => const RsyncResult(
    RsyncOutcome.rejected,
    'Sample preview: no job lookup or remote request was made.',
  );
}
