import 'package:truenas_api/truenas_api.dart';

/// Connector-free presentation fixture. No network, credential or live writes.
mixin CloudSyncPreviewAdapter implements AuthenticatedCloudSyncSession {
  static final inventory = CloudSyncInventory(
    endpoint: 'wss://nas-demo.example/api/current',
    timezone: 'Asia/Seoul',
    credentials: const [
      CloudSyncCredential(id: 1, name: 'Archive S3', provider: 'S3'),
      CloudSyncCredential(id: 2, name: 'Design Dropbox', provider: 'DROPBOX'),
    ],
    datasets: const [
      CloudSyncDataset(
        id: 'tank/documents',
        guid: '1001',
        path: '/mnt/tank/documents',
      ),
      CloudSyncDataset(
        id: 'tank/design',
        guid: '1002',
        path: '/mnt/tank/design',
      ),
      CloudSyncDataset(
        id: 'tank/archive',
        guid: '1003',
        path: '/mnt/tank/archive',
      ),
    ],
    tasks: [
      CloudSyncTask(
        id: 1,
        settings: CloudSyncSettings(
          path: '/mnt/tank/documents',
          credentialId: 1,
          description: 'Documents archive',
          bucket: 'sample-archive',
          folder: 'documents',
          enabled: true,
        ),
        provider: 'S3',
        state: 'SUCCESS',
      ),
      CloudSyncTask(
        id: 2,
        settings: CloudSyncSettings(
          path: '/mnt/tank/design',
          credentialId: 2,
          description: 'Design intake',
          direction: 'PULL',
          folder: 'design',
        ),
        provider: 'DROPBOX',
      ),
      CloudSyncTask(
        id: 3,
        settings: CloudSyncSettings(
          path: '/mnt/tank/archive',
          credentialId: 1,
          description: 'Encrypted archive',
          bucket: 'sample-archive',
          folder: 'vault',
        ),
        provider: 'S3',
        blockedReason: 'Encrypted task: manage in TrueNAS.',
      ),
    ],
  );
  @override
  CloudSyncCapabilities get cloudSyncCapabilities =>
      const CloudSyncCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canCreate: true,
        canUpdate: true,
        canDelete: true,
        canRun: true,
      );
  @override
  Future<CloudSyncInventory> loadCloudSync() async => inventory;
  @override
  Future<CloudSyncReview> reviewCloudSync(CloudSyncRequest request) async {
    if (!identical(request.inventory, inventory) ||
        request.validationError != null) {
      throw const CloudSyncException(CloudSyncExceptionReason.invalidRequest);
    }
    return CloudSyncReview(
      request: request,
      endpoint: inventory.endpoint,
      warnings: [
        'SAMPLE DATA — this preview never contacts a NAS and rejects every write.',
        '${request.desired.direction} ${request.desired.transferMode}: COPY can overwrite files, SYNC deletes destination-only files and MOVE deletes source files.',
        'PULL writes NAS data. Verify a separate backup and quiesce clients.',
        'Keep the local tree quiescent and independently ensure there are no nested or bind mounts. A leaf dataset does not prove its subtree is isolated.',
        'Saving may contact the cloud and restart cron. Enabled schedules may run automatically.',
        'Credential secrets and remote contents are not inspected. No cloud listing, verification or dry run is automatic.',
      ],
    );
  }

  @override
  Future<CloudSyncResult> executeCloudSync(
    CloudSyncReview review,
    String confirmation,
  ) async => const CloudSyncResult(
    CloudSyncOutcome.rejected,
    'Preview only. No cloud sync request was sent.',
  );
  @override
  Future<CloudSyncResult> pollCloudSync(CloudSyncJob job) async =>
      const CloudSyncResult(
        CloudSyncOutcome.rejected,
        'Preview only. No cloud sync job was queried.',
      );
}
