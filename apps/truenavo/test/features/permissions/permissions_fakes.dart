import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/permissions/permissions_controller.dart';
import 'package:truenas_api/truenas_api.dart';

const permissionsMethods = {
  'pool.dataset.query',
  'filesystem.getacl',
  'filesystem.stat',
  'filesystem.statfs',
  'filesystem.setacl',
  'filesystem.setperm',
  'core.get_jobs',
  'user.query',
  'group.query',
};
const permissionDataset = PermissionDataset(
  id: 'tank/media',
  mountpoint: '/mnt/tank/media',
);
PermissionReview permissionReview({
  PermissionAclType type = PermissionAclType.nfs4,
  bool trivial = false,
}) => PermissionReview(
  dataset: permissionDataset,
  aclType: type,
  uid: 3000,
  gid: 3010,
  mode: '750',
  trivial: trivial,
  aclFlags: type == PermissionAclType.nfs4
      ? const {'autoinherit': false, 'protected': false, 'defaulted': false}
      : const {},
  acl: type == PermissionAclType.disabled
      ? []
      : type == PermissionAclType.nfs4
      ? [
          PermissionAce(
            tag: 'owner@',
            type: 'ALLOW',
            permissions: const {'READ_DATA': true, 'WRITE_DATA': true},
            flags: const {'FILE_INHERIT': true},
          ),
          PermissionAce(
            tag: 'GROUP',
            id: 3010,
            type: 'ALLOW',
            permissions: const {'READ_DATA': true},
          ),
          PermissionAce(
            tag: 'everyone@',
            type: 'ALLOW',
            permissions: const {'READ_ACL': true},
          ),
        ]
      : [
          PermissionAce(
            tag: 'USER_OBJ',
            permissions: const {'READ': true, 'WRITE': true, 'EXECUTE': true},
          ),
          PermissionAce(
            tag: 'GROUP_OBJ',
            permissions: const {'READ': true, 'EXECUTE': true},
          ),
          PermissionAce(tag: 'OTHER', permissions: const {}),
        ],
);
PermissionApplyRequest permissionChange(PermissionReview review) {
  if (review.aclType == PermissionAclType.disabled) {
    return PermissionApplyRequest(review: review, mode: '700');
  }
  final first = review.acl.first;
  final bit = review.aclType == PermissionAclType.nfs4 ? 'WRITE_DATA' : 'WRITE';
  return PermissionApplyRequest(
    review: review,
    acl: [
      PermissionAce(
        tag: first.tag,
        id: first.id,
        type: first.type,
        permissions: {...first.permissions, bit: !first.permissions[bit]!},
        flags: first.flags,
        isDefault: first.isDefault,
      ),
      ...review.acl.skip(1),
    ],
  );
}

class PermissionsFake
    implements SessionRepository, AuthenticatedPermissionsSession {
  PermissionsFake({this.methods = permissionsMethods, PermissionReview? review})
    : review = review ?? permissionReview();
  final Set<String> methods;
  final PermissionReview review;
  int reads = 0, reviewReads = 0, checks = 0, lookups = 0;
  final writes = <PermissionApplyRequest>[];
  Future<PermissionOperationResult> Function()? onApply;
  Future<PermissionOperationResult> Function(PermissionOperationResult)?
  onCheck;
  Future<List<PermissionDataset>> Function()? onLoad;
  Future<PermissionReview> Function(PermissionDataset)? onReview;
  Future<PermissionIdentity?> Function(PermissionIdentityKind, int)? onLookup;
  @override
  PermissionsCapabilities get permissionsCapabilities =>
      PermissionsCapabilities(
        connected: true,
        versionSupported: true,
        methods: methods,
      );
  @override
  Future<List<PermissionDataset>> loadPermissionDatasets() async {
    reads++;
    return onLoad?.call() ?? [review.dataset];
  }

  @override
  Future<PermissionReview> loadPermissionReview(
    PermissionDataset dataset,
  ) async {
    reviewReads++;
    return onReview?.call(dataset) ?? review;
  }

  @override
  Future<PermissionIdentity?> lookupPermissionIdentity(
    PermissionIdentityKind kind,
    int id,
  ) async {
    lookups++;
    return onLookup == null
        ? PermissionIdentity(
            kind: kind,
            id: id,
            name: 'Resolved local identity',
            local: true,
          )
        : onLookup!(kind, id);
  }

  @override
  Future<PermissionOperationResult> applyPermissions(
    PermissionApplyRequest request,
  ) async {
    writes.add(request);
    return onApply?.call() ??
        const PermissionOperationResult(
          outcome: PermissionOperationOutcome.verified,
        );
  }

  @override
  Future<PermissionOperationResult> checkPermissionOperation(
    PermissionOperationResult operation,
  ) async {
    checks++;
    return onCheck?.call(operation) ?? operation;
  }

  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw UnimplementedError();
}

class PermissionsHarness {
  PermissionsHarness({PermissionsFake? fake, int autoPolls = 0})
    : api = fake ?? PermissionsFake() {
    session = newSession();
    active = session;
    container = ProviderContainer(
      overrides: [
        dashboardActiveSessionProvider.overrideWith((ref) => active),
        permissionsAutoPollLimitProvider.overrideWithValue(autoPolls),
      ],
    );
  }
  final PermissionsFake api;
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  late final ProviderContainer container;
  AuthenticatedSession newSession({
    String? endpoint = 'wss://sample.example/api/current',
    PermissionsFake? fake,
  }) => AuthenticatedSession(
    profileId: 'test',
    repository: fake ?? api,
    availableMethodNames: (fake ?? api).methods,
    version: '25.10.1',
    endpoint: endpoint,
  );
  void select(AuthenticatedSession? next) {
    active = next;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  void dispose() => container.dispose();
}
