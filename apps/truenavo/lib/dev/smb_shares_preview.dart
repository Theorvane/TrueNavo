import 'package:truenas_api/truenas_api.dart';

/// Connector-free, immutable fixtures; compatible with a const repository.
mixin SmbSharesPreviewAdapter implements AuthenticatedSmbSharesSession {
  static final _inventory = SmbShareInventory(
    serviceState: 'RUNNING',
    serviceEnabled: true,
    datasets: const [
      SmbShareDataset(
        id: 'tank/design',
        guid: '2105',
        mountpoint: '/mnt/tank/design',
      ),
      SmbShareDataset(
        id: 'tank/team',
        guid: '2101',
        mountpoint: '/mnt/tank/team',
      ),
      SmbShareDataset(
        id: 'tank/archive',
        guid: '2102',
        mountpoint: '/mnt/tank/archive',
      ),
      SmbShareDataset(
        id: 'tank/projects',
        guid: '2103',
        mountpoint: '/mnt/tank/projects',
      ),
      SmbShareDataset(
        id: 'tank/private',
        guid: '2104',
        mountpoint: '/mnt/tank/private',
        blockedReason: 'Sample encrypted dataset is protected.',
      ),
    ],
    shares: const [
      SmbShareEntry(
        id: 11,
        name: 'Team documents',
        path: '/mnt/tank/team',
        comment: 'Shared workspace',
        readonly: false,
        enabled: true,
        purpose: 'DEFAULT_SHARE',
        locked: false,
      ),
      SmbShareEntry(
        id: 12,
        name: 'Archive',
        path: '/mnt/tank/archive',
        comment: 'Read-only reference files',
        readonly: true,
        enabled: true,
        purpose: 'DEFAULT_SHARE',
        locked: false,
      ),
      SmbShareEntry(
        id: 13,
        name: 'Project drop',
        path: '/mnt/tank/projects',
        comment: 'Disabled until the next project',
        readonly: false,
        enabled: false,
        purpose: 'DEFAULT_SHARE',
        locked: false,
      ),
      SmbShareEntry(
        id: 14,
        name: 'Private backup',
        path: '/mnt/tank/private',
        comment: 'Special-purpose sample',
        readonly: false,
        enabled: false,
        purpose: 'TIMEMACHINE_SHARE',
        locked: null,
        blockedReason: 'Special-purpose settings and unknown lock status are inspect-only.',
      ),
    ],
  );
  @override
  SmbSharesCapabilities get smbSharesCapabilities =>
      const SmbSharesCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
        canCreate: true,
        canUpdate: true,
        canDelete: true,
      );
  @override
  Future<SmbShareInventory> loadSmbShares() async => _inventory;
  @override
  Future<SmbShareReview> reviewSmbShare(SmbShareRequest request) async {
    if (!identical(request.inventory, _inventory) ||
        request.validationError != null ||
        request.share != null &&
            !_inventory.shares.any((s) => identical(s, request.share)) ||
        request.dataset != null &&
            !_inventory.datasets.any((d) => identical(d, request.dataset))) {
      throw const SmbSharesException(SmbSharesExceptionReason.invalid);
    }
    return SmbShareReview(
      action: request.action,
      target: request.target,
      identity:
          'Synthetic preview · ${request.dataset?.id ?? request.share?.path}',
      changes: [
        '${request.action.name}: ${request.target}',
        if (request.settings case final settings?)
          'Comment: ${settings.comment}; read-only: ${settings.readonly}; enabled: ${settings.enabled}',
      ],
      warnings: [
        'SAMPLE ONLY. This preview cannot submit SMB configuration changes.',
        'A real change can reload SMB configuration and affect existing clients. Deleting a share does not delete its dataset or files.',
      ],
    );
  }

  @override
  Future<SmbShareResult> executeSmbShare(
    SmbShareReview review,
    String confirmation,
  ) async => const SmbShareResult(
    SmbShareOutcome.rejected,
    'Sample preview: no SMB request was sent.',
  );
}
