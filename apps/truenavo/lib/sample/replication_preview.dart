// Connector-free fixtures shared by offline demo and development preview.
import 'package:truenas_api/truenas_api.dart';

/// Immutable sample data only. This mixin owns no connector or mutable fields.
mixin ReplicationPreviewAdapter implements AuthenticatedReplicationSession {
  static const _settings = ReplicationSettings(
    name: 'Documents archive',
    source: 'tank/documents',
    destination: 'backup/documents',
    enabled: true,
  );
  static final _inventory = ReplicationInventory(
    endpoint: 'wss://nas-demo.example/api/current',
    tasks: const [
      ReplicationTask(
        id: 1,
        name: 'Documents archive',
        source: 'tank/documents',
        destination: 'backup/documents',
        transport: 'LOCAL',
        direction: 'PUSH',
        enabled: true,
        state: 'FINISHED',
        settings: _settings,
      ),
      ReplicationTask(
        id: 2,
        name: 'Remote archive',
        source: 'tank/media',
        destination: 'offsite/media',
        transport: 'SSH',
        direction: 'PUSH',
        enabled: false,
        state: 'HOLD',
        blockedReason:
            'Remote replication needs the advanced TrueNAS workflow.',
      ),
    ],
    datasets: const [
      ReplicationDataset(
        id: 'tank/documents',
        guid: 'sample-source',
        readonly: false,
      ),
      ReplicationDataset(
        id: 'tank/media',
        guid: 'sample-media',
        readonly: false,
      ),
      ReplicationDataset(
        id: 'backup/parent',
        guid: 'sample-parent',
        readonly: false,
      ),
      ReplicationDataset(
        id: 'backup/documents',
        guid: 'sample-target',
        readonly: true,
      ),
    ],
  );
  @override
  ReplicationCapabilities get replicationCapabilities =>
      const ReplicationCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canCreate: true,
        canUpdate: true,
        canDelete: true,
        canRun: true,
      );
  @override
  Future<ReplicationInventory> loadReplication() async => _inventory;
  @override
  Future<ReplicationReview> reviewReplication(
    ReplicationRequest request,
  ) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      throw const ReplicationException(
        ReplicationExceptionReason.invalidRequest,
      );
    }
    return ReplicationReview(
      request: request,
      endpoint: _inventory.endpoint,
      warnings: const [
        'SAMPLE ONLY. No task is saved, run, removed or polled by this preview.',
      ],
      sourceSnapshots: 12,
      destinationSnapshots: 8,
      createsDestination: !_inventory.datasets.any(
        (d) => d.id == request.effectiveSettings?.destination,
      ),
    );
  }

  @override
  Future<ReplicationResult> executeReplication(
    ReplicationReview review,
    String confirmation,
  ) async => const ReplicationResult(
    ReplicationOutcome.rejected,
    'Sample preview: no replication request was sent.',
  );
  @override
  Future<ReplicationResult> pollReplication(ReplicationJob job) async =>
      const ReplicationResult(
        ReplicationOutcome.rejected,
        'Sample preview: no job read was sent.',
      );
}
