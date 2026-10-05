// Connector-free fixtures shared by offline demo and development preview.
import 'package:truenas_api/truenas_api.dart';

/// Connector-free sample data. There are no instance fields, so the adapter can
/// be mixed into a const preview session. Every setter is rejected locally.
mixin PermissionsPreviewAdapter implements AuthenticatedPermissionsSession {
  static const _datasets = [
    PermissionDataset(id: 'tank/media', mountpoint: '/mnt/tank/media'),
    PermissionDataset(id: 'tank/backups', mountpoint: '/mnt/tank/backups'),
    PermissionDataset(id: 'tank/archive', mountpoint: '/mnt/tank/archive'),
    PermissionDataset(
      id: 'tank/private',
      mountpoint: '/mnt/tank/private',
      blockedReason: 'Sample encrypted dataset is locked. Unlocking is not part of this editor.',
    ),
  ];
  static final _reviews = [
    PermissionReview(
      dataset: _datasets[0],
      aclType: PermissionAclType.nfs4,
      uid: 3000,
      gid: 3010,
      mode: '770',
      trivial: false,
      aclFlags: const {
        'autoinherit': false,
        'protected': false,
        'defaulted': false,
      },
      acl: [
        PermissionAce(
          tag: 'owner@',
          type: 'ALLOW',
          permissions: {
            for (final name in PermissionAce.nfs4PermissionNames) name: true,
          },
          flags: const {'FILE_INHERIT': true, 'DIRECTORY_INHERIT': true},
        ),
        PermissionAce(
          tag: 'GROUP',
          id: 3010,
          type: 'ALLOW',
          permissions: const {
            'READ_DATA': true,
            'WRITE_DATA': true,
            'APPEND_DATA': true,
            'EXECUTE': true,
            'READ_ACL': true,
          },
          flags: const {'FILE_INHERIT': true, 'DIRECTORY_INHERIT': true},
        ),
        PermissionAce(
          tag: 'everyone@',
          type: 'ALLOW',
          permissions: const {'READ_ATTRIBUTES': true, 'READ_ACL': true},
        ),
      ],
    ),
    PermissionReview(
      dataset: _datasets[1],
      aclType: PermissionAclType.posix1e,
      uid: 3001,
      gid: 3020,
      mode: '750',
      trivial: false,
      acl: [
        for (final defaults in [false, true]) ...[
          PermissionAce(
            tag: 'USER_OBJ',
            isDefault: defaults,
            permissions: const {'READ': true, 'WRITE': true, 'EXECUTE': true},
          ),
          PermissionAce(
            tag: 'GROUP_OBJ',
            isDefault: defaults,
            permissions: const {'READ': true, 'EXECUTE': true},
          ),
          PermissionAce(
            tag: 'OTHER',
            isDefault: defaults,
            permissions: const {},
          ),
        ],
      ],
    ),
    PermissionReview(
      dataset: _datasets[2],
      aclType: PermissionAclType.disabled,
      uid: 3002,
      gid: 3010,
      mode: '750',
      trivial: true,
      acl: const [],
    ),
    PermissionReview(
      dataset: _datasets[3],
      aclType: PermissionAclType.disabled,
      uid: 0,
      gid: 0,
      mode: '700',
      trivial: true,
      acl: const [],
      blockedReason:
          'Locked sample dataset: permission editing is unavailable.',
    ),
  ];
  @override
  PermissionsCapabilities get permissionsCapabilities =>
      PermissionsCapabilities(
        connected: true,
        versionSupported: true,
        methods: const {
          'pool.dataset.query',
          'filesystem.getacl',
          'filesystem.stat',
          'filesystem.statfs',
          'filesystem.setacl',
          'filesystem.setperm',
          'core.get_jobs',
          'user.query',
          'group.query',
        },
      );
  @override
  Future<List<PermissionDataset>> loadPermissionDatasets() async => _datasets;
  @override
  Future<PermissionReview> loadPermissionReview(
    PermissionDataset dataset,
  ) async {
    for (final review in _reviews) {
      if (identical(review.dataset, dataset)) return review;
    }
    throw const PermissionsException(PermissionsExceptionReason.staleSnapshot);
  }

  @override
  Future<PermissionIdentity?> lookupPermissionIdentity(
    PermissionIdentityKind kind,
    int id,
  ) async {
    final names = kind == PermissionIdentityKind.user
        ? const {3000: 'media', 3001: 'backup', 3002: 'archive'}
        : const {3010: 'media_services', 3020: 'backup_operators'};
    final name = names[id];
    return name == null
        ? null
        : PermissionIdentity(kind: kind, id: id, name: name, local: true);
  }

  @override
  Future<PermissionOperationResult> applyPermissions(
    PermissionApplyRequest request,
  ) => Future.error(
    const PermissionsException(PermissionsExceptionReason.unavailable),
  );
  @override
  Future<PermissionOperationResult> checkPermissionOperation(
    PermissionOperationResult operation,
  ) async => const PermissionOperationResult(
    outcome: PermissionOperationOutcome.unknown,
    message: 'Sample preview has no server jobs or transport. No permission change was sent.',
  );
}
