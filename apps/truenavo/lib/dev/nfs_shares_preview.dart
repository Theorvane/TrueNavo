import 'package:truenas_api/truenas_api.dart';

/// Static presentation only; no transport, mutable instance state or writes.
mixin NfsSharesPreviewAdapter implements AuthenticatedNfsSharesSession {
  static final _inventory = NfsShareInventory(
    shares: [
      NfsShare(
        id: 1,
        settings: NfsShareSettings(
          path: '/mnt/tank/media',
          comment: 'Media library',
          networks: ['192.168.10.0/24'],
          readOnly: true,
        ),
      ),
      NfsShare(
        id: 2,
        settings: NfsShareSettings(
          path: '/mnt/tank/backups',
          comment: 'Backup clients',
          hosts: ['192.168.20.10'],
          mapallUser: 'backup',
          mapallGroup: 'backup',
        ),
      ),
      NfsShare(
        id: 3,
        settings: NfsShareSettings(
          path: '/mnt/tank/archive',
          comment: 'Offline archive',
          enabled: false,
          readOnly: true,
        ),
      ),
    ],
    datasets: const [
      NfsShareDataset(id: 'tank/media', guid: '1001', path: '/mnt/tank/media'),
      NfsShareDataset(
        id: 'tank/backups',
        guid: '1002',
        path: '/mnt/tank/backups',
      ),
      NfsShareDataset(
        id: 'tank/archive',
        guid: '1003',
        path: '/mnt/tank/archive',
      ),
      NfsShareDataset(
        id: 'tank/projects',
        guid: '1004',
        path: '/mnt/tank/projects',
      ),
    ],
    serviceState: 'RUNNING',
    serviceEnabled: true,
    protocols: ['NFSV3', 'NFSV4'],
  );
  @override
  NfsSharesCapabilities get nfsSharesCapabilities =>
      const NfsSharesCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canCreate: true,
        canUpdate: true,
        canDelete: true,
      );
  @override
  Future<NfsShareInventory> loadNfsShares() async => _inventory;
  @override
  Future<NfsShareReview> reviewNfsShare(NfsShareRequest request) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null) {
      throw const NfsSharesException(NfsSharesExceptionReason.invalid);
    }
    return NfsShareReview(
      action: request.action,
      target: request.target,
      identity: 'Connector-free sample dataset identity',
      changes: ['Sample ${request.action.name} for ${request.target}'],
      warnings: [
        'SAMPLE DATA — this preview never contacts a NAS and rejects every write.',
        'TrueNAS saves configuration and reloads NFS exports globally. Existing clients and pending I/O can be affected. Quiesce clients first.',
        'Export generation may clean manual /etc/exports.d entries or disable native ZFS sharenfs. Real operations require public safety proofs.',
        'The dataset, files, ownership and ACLs are not a deletion target. Configuration readback does not prove client access.',
      ],
    );
  }

  @override
  Future<NfsShareResult> executeNfsShare(
    NfsShareReview review,
    String confirmation,
  ) async => const NfsShareResult(
    NfsShareOutcome.rejected,
    'Preview only. No NFS request was sent.',
  );
}
