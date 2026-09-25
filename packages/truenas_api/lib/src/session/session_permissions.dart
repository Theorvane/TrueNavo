part of 'true_nas_session_repository.dart';

/// Native, nonrecursive permission changes on existing dataset roots only.
abstract interface class AuthenticatedPermissionsSession {
  PermissionsCapabilities get permissionsCapabilities;
  Future<List<PermissionDataset>> loadPermissionDatasets();
  Future<PermissionReview> loadPermissionReview(PermissionDataset dataset);
  Future<PermissionIdentity?> lookupPermissionIdentity(
    PermissionIdentityKind kind,
    int id,
  );
  Future<PermissionOperationResult> applyPermissions(
    PermissionApplyRequest request,
  );
  Future<PermissionOperationResult> checkPermissionOperation(
    PermissionOperationResult operation,
  );
}

final class PermissionsCapabilities {
  PermissionsCapabilities({
    required this.connected,
    required this.versionSupported,
    required Set<String> methods,
  }) : methods = Set.unmodifiable(methods);
  const PermissionsCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      methods = const {};
  final bool connected, versionSupported;
  final Set<String> methods;
  bool get supported =>
      connected &&
      versionSupported &&
      methods.containsAll({
        'pool.dataset.query',
        'filesystem.getacl',
        'filesystem.stat',
        'filesystem.statfs',
      });
  bool canCall(String method) => supported && methods.contains(method);
  String? get blockedReason => !connected
      ? 'Connect to inspect dataset permissions.'
      : !versionSupported
      ? 'Native permissions require stable TrueNAS 25.10.'
      : !supported
      ? 'Dataset and filesystem metadata permissions are required.'
      : null;
}

enum PermissionAclType { nfs4, posix1e, disabled }

enum PermissionIdentityKind { user, group }

enum PermissionOperationOutcome { pending, verified, failed, unknown }

final class PermissionDataset {
  const PermissionDataset({
    required this.id,
    required this.mountpoint,
    this.blockedReason,
  });
  final String id, mountpoint;
  final String? blockedReason;
  bool get editable => blockedReason == null;
}

final class PermissionIdentity {
  const PermissionIdentity({
    required this.kind,
    required this.id,
    required this.name,
    required this.local,
  });
  final PermissionIdentityKind kind;
  final int id;
  final String name;
  final bool local;
}

final class PermissionAce {
  PermissionAce({
    required this.tag,
    this.id,
    this.type,
    required Map<String, bool> permissions,
    Map<String, bool> flags = const {},
    this.isDefault = false,
  }) : permissions = Map.unmodifiable({
         for (final name
             in type == null ? posixPermissionNames : nfs4PermissionNames)
           name: false,
         ...permissions,
       }),
       flags = Map.unmodifiable({
         if (type != null)
           for (final name in nfs4FlagNames) name: false,
         ...flags,
       });
  final String tag;
  final int? id;
  final String? type;
  final Map<String, bool> permissions, flags;
  final bool isDefault;
  static const posixPermissionNames = ['READ', 'WRITE', 'EXECUTE'];
  static const nfs4PermissionNames = [
    'READ_DATA',
    'WRITE_DATA',
    'APPEND_DATA',
    'READ_NAMED_ATTRS',
    'WRITE_NAMED_ATTRS',
    'EXECUTE',
    'DELETE',
    'DELETE_CHILD',
    'READ_ATTRIBUTES',
    'WRITE_ATTRIBUTES',
    'READ_ACL',
    'WRITE_ACL',
    'WRITE_OWNER',
    'SYNCHRONIZE',
  ];
  static const nfs4FlagNames = [
    'FILE_INHERIT',
    'DIRECTORY_INHERIT',
    'NO_PROPAGATE_INHERIT',
    'INHERIT_ONLY',
    'INHERITED',
  ];
  Map<String, Object?> _wire(PermissionAclType kind) => {
    'tag': tag,
    'id': id ?? -1,
    'who': null,
    'perms': permissions,
    if (kind == PermissionAclType.nfs4) ...{
      'type': type,
      'flags': flags,
    } else
      'default': isDefault,
  };
}

final class PermissionReview {
  PermissionReview({
    required this.dataset,
    required this.aclType,
    required this.uid,
    required this.gid,
    required this.mode,
    required this.trivial,
    required List<PermissionAce> acl,
    Map<String, bool> aclFlags = const {},
    this.blockedReason,
  }) : acl = List.unmodifiable(acl),
       aclFlags = Map.unmodifiable(aclFlags);
  final PermissionDataset dataset;
  final PermissionAclType aclType;
  final int uid, gid;
  final String mode;
  final bool trivial;
  final List<PermissionAce> acl;
  final Map<String, bool> aclFlags;
  final String? blockedReason;
  bool get editable => dataset.editable && blockedReason == null;
  bool get canEditAcl => editable && aclType != PermissionAclType.disabled;
  bool get canEditMode =>
      editable && aclType != PermissionAclType.nfs4 && trivial;
}

final class PermissionApplyRequest {
  PermissionApplyRequest({
    required this.review,
    List<PermissionAce>? acl,
    this.mode,
  }) : acl = acl == null ? null : List.unmodifiable(acl);
  final PermissionReview review;
  final List<PermissionAce>? acl;
  final String? mode;
  String? get validationError {
    if (!review.editable || (acl == null) == (mode == null)) {
      return 'Choose one supported permission change.';
    }
    if (mode != null) {
      if (!review.canEditMode ||
          !RegExp(r'^[0-7]{3}$').hasMatch(mode!) ||
          mode == '000') {
        return 'Use three nonzero octal permission digits on a trivial POSIX or disabled ACL.';
      }
      return mode == review.mode ? 'Select a permission change.' : null;
    }
    if (!review.canEditAcl) {
      return 'ACL editing is unavailable for this dataset.';
    }
    final error = _permissionsAclError(review.aclType, acl!);
    if (error != null) return error;
    return _adminEqual(
          _permissionsAclKey(review.aclType, acl!),
          _permissionsAclKey(review.aclType, review.acl),
        )
        ? 'Select an ACL change.'
        : null;
  }

  String? get expectedMode =>
      mode ??
      (review.aclType == PermissionAclType.posix1e &&
              acl != null &&
              _permissionsAclError(review.aclType, acl!) == null
          ? _permissionsPosixMode(acl!)
          : null);
}

final class PermissionOperationResult {
  const PermissionOperationResult({
    required this.outcome,
    this.jobId,
    this.message,
  });
  final PermissionOperationOutcome outcome;
  final int? jobId;
  final String? message;
  bool get canCheck =>
      outcome == PermissionOperationOutcome.pending && jobId != null;
}

enum PermissionsExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  invalidInput,
  invalidResponse,
  staleSnapshot,
  busy,
  unavailable,
}

final class PermissionsException implements Exception {
  const PermissionsException(this.reason);
  final PermissionsExceptionReason reason;
  String get userMessage => switch (reason) {
    PermissionsExceptionReason.notAuthenticated =>
      'Reconnect before inspecting permissions.',
    PermissionsExceptionReason.unsupportedVersion =>
      'Native permissions require stable TrueNAS 25.10.',
    PermissionsExceptionReason.unavailableMethod =>
      'The required filesystem or identity permission is unavailable.',
    PermissionsExceptionReason.invalidInput => 'Review the ACL entries, ownership-preserving scope and permission limits.',
    PermissionsExceptionReason.invalidResponse =>
      'The filesystem response could not be verified safely.',
    PermissionsExceptionReason.staleSnapshot =>
      'The dataset, path or ACL changed. Reload and review again.',
    PermissionsExceptionReason.busy =>
      'Another server operation or uncertain permission change is in progress.',
    PermissionsExceptionReason.unavailable =>
      'Permissions could not be read. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

final class _SessionPermissions {
  _SessionPermissions({
    required this.client,
    required ServerSummary summary,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherBusy,
    required this.requestTimeout,
  }) : methods = Set.unmodifiable(summary.availableMethodNames),
       versionSupported =
           _managementVersion(summary.version) == _ManagementVersion.v2510;
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherBusy;
  final Duration requestTimeout;
  final Set<String> methods;
  final bool versionSupported;
  final String _requestNonce = List.generate(
    4,
    (_) => math.Random.secure().nextInt(2147483647).toRadixString(16),
  ).join('-');
  bool _reading = false, _writing = false, _polling = false, _uncertain = false;
  PermissionOperationResult? _active;
  final _datasets = <PermissionDataset, _PermissionDatasetRow>{};
  final _reviews = <PermissionReview, _PermissionObservation>{};
  final _jobs = <PermissionOperationResult, _PermissionPlan>{};
  bool get isBusy => _writing || _active != null || _uncertain;
  PermissionsCapabilities get capabilities => PermissionsCapabilities(
    connected: isCurrent(),
    versionSupported: versionSupported,
    methods: methods,
  );
  void _guard([String? method]) {
    if (!isCurrent()) {
      throw const PermissionsException(
        PermissionsExceptionReason.notAuthenticated,
      );
    }
    if (!versionSupported) {
      throw const PermissionsException(
        PermissionsExceptionReason.unsupportedVersion,
      );
    }
    if (!capabilities.supported ||
        method != null && !methods.contains(method)) {
      throw const PermissionsException(
        PermissionsExceptionReason.unavailableMethod,
      );
    }
  }

  Future<Object?> _call(
    String method,
    List<Object?> args, {
    String? requestId,
  }) async {
    _guard(method);
    final result = await client
        .call(method, id: requestId ?? nextId(), params: args)
        .timeout(requestTimeout);
    _guard();
    return result;
  }

  Future<List<_PermissionDatasetRow>> _rows([String? id]) async {
    final raw = await _call('pool.dataset.query', [
      id == null
          ? [
              ['type', '=', 'FILESYSTEM'],
            ]
          : [
              ['id', '=', id],
            ],
      {
        'limit': id == null ? 513 : 2,
        'select': [
          'id',
          'name',
          'type',
          'mountpoint',
          'locked',
          'encrypted',
          'guid',
          'creation',
          'readonly',
          'acltype',
          'aclmode',
          ['user_properties.managedby', 'managedby'],
        ],
        'extra': {
          'flat': true,
          'retrieve_children': false,
          'retrieve_user_props': true,
          'properties': [
            'guid',
            'creation',
            'mountpoint',
            'readonly',
            'acltype',
            'aclmode',
            'encryption',
            'keystatus',
          ],
        },
      },
    ]);
    if (raw is! List || raw.length > (id == null ? 512 : 1)) {
      _permissionsInvalid();
    }
    final rows = raw.map(_PermissionDatasetRow.parse).toList();
    if (rows.map((r) => r.dataset.id).toSet().length != rows.length ||
        id != null && rows.any((r) => r.dataset.id != id)) {
      _permissionsInvalid();
    }
    return rows;
  }

  Future<List<PermissionDataset>> datasets() async {
    _guard();
    if (_reading || _writing || _polling) {
      throw const PermissionsException(PermissionsExceptionReason.busy);
    }
    _reading = true;
    try {
      final rows = await _rows();
      _datasets.clear();
      _reviews.clear();
      for (final row in rows) {
        _datasets[row.dataset] = row;
      }
      return List.unmodifiable(rows.map((r) => r.dataset));
    } on PermissionsException {
      rethrow;
    } on Object {
      throw const PermissionsException(PermissionsExceptionReason.unavailable);
    } finally {
      _reading = false;
    }
  }

  Future<PermissionReview> review(PermissionDataset dataset) async {
    _guard();
    if (_reading || _writing || _polling) {
      throw const PermissionsException(PermissionsExceptionReason.busy);
    }
    final issued = _datasets[dataset];
    if (issued == null) {
      throw const PermissionsException(
        PermissionsExceptionReason.staleSnapshot,
      );
    }
    _reading = true;
    try {
      final rows = await _rows(dataset.id);
      if (rows.length != 1 ||
          !_adminEqual(rows.single.identity, issued.identity)) {
        throw const PermissionsException(
          PermissionsExceptionReason.staleSnapshot,
        );
      }
      final observation = await _observe(rows.single, dataset: dataset);
      _reviews[observation.review] = observation;
      return observation.review;
    } on PermissionsException {
      rethrow;
    } on Object {
      throw const PermissionsException(PermissionsExceptionReason.unavailable);
    } finally {
      _reading = false;
    }
  }

  Future<PermissionIdentity?> lookup(
    PermissionIdentityKind kind,
    int id,
  ) async {
    _guard();
    if (_reading || _writing || _polling) {
      throw const PermissionsException(PermissionsExceptionReason.busy);
    }
    _reading = true;
    try {
      return await _lookup(kind, id);
    } on PermissionsException {
      rethrow;
    } on Object {
      throw const PermissionsException(PermissionsExceptionReason.unavailable);
    } finally {
      _reading = false;
    }
  }

  Future<PermissionIdentity?> _lookup(
    PermissionIdentityKind kind,
    int id,
  ) async {
    if (!_permissionsId(id)) {
      throw const PermissionsException(PermissionsExceptionReason.invalidInput);
    }
    final user = kind == PermissionIdentityKind.user;
    final key = user ? 'uid' : 'gid', name = user ? 'username' : 'name';
    final raw = await _call(user ? 'user.query' : 'group.query', [
      [
        [key, '=', id],
      ],
      {
        'select': [key, name, 'local'],
        'limit': 2,
      },
    ]);
    if (raw is! List || raw.length > 1) _permissionsInvalid();
    if (raw.isEmpty) return null;
    final row = raw.single;
    if (row is! Map ||
        row[key] != id ||
        !_permissionsText(row[name], 256) ||
        row['local'] is! bool) {
      _permissionsInvalid();
    }
    return PermissionIdentity(
      kind: kind,
      id: id,
      name: row[name] as String,
      local: row['local'] as bool,
    );
  }

  Future<List<Map<String, Object?>>> _pathProof(String path) async {
    if (!_permissionsPath(path)) {
      throw const PermissionsException(PermissionsExceptionReason.invalidInput);
    }
    final parts = path.split('/').where((p) => p.isNotEmpty).toList();
    final result = <Map<String, Object?>>[];
    var current = '';
    for (final component in ['', ...parts]) {
      current = component.isEmpty
          ? '/'
          : current == '/'
          ? '/$component'
          : '$current/$component';
      final raw = await _call('filesystem.stat', [current]);
      if (raw is! Map ||
          raw['type'] != 'DIRECTORY' ||
          raw['realpath'] != current ||
          raw['is_ctldir'] != false ||
          raw['is_mountpoint'] is! bool ||
          raw['acl'] is! bool ||
          [
            'uid',
            'gid',
            'mode',
            'dev',
            'inode',
            'mount_id',
          ].any((k) => !_permissionsNumber(raw[k])) ||
          raw['attributes'] is! List ||
          (raw['attributes'] as List).any((a) => !_permissionsText(a, 64))) {
        _permissionsInvalid();
      }
      result.add({
        'path': current,
        for (final field in [
          'uid',
          'gid',
          'mode',
          'dev',
          'inode',
          'mount_id',
          'acl',
          'is_mountpoint',
          'attributes',
        ])
          field: raw[field],
      });
    }
    return result;
  }

  Future<Map<String, Object?>> _mountProof(_PermissionDatasetRow row) async {
    final raw = await _call('filesystem.statfs', [row.dataset.mountpoint]);
    if (raw is! Map ||
        raw['fstype'] != 'zfs' ||
        raw['source'] != row.dataset.id ||
        raw['dest'] != row.dataset.mountpoint ||
        !_permissionsText(raw['fsid'], 64) ||
        raw['flags'] is! List ||
        (raw['flags'] as List).length > 128 ||
        (raw['flags'] as List).any((f) => !_permissionsText(f, 128))) {
      _permissionsInvalid();
    }
    return {
      for (final key in ['fstype', 'source', 'dest', 'fsid', 'flags'])
        key: raw[key],
    };
  }

  Future<_PermissionObservation> _observe(
    _PermissionDatasetRow row, {
    PermissionDataset? dataset,
  }) async {
    final paths = await _pathProof(row.dataset.mountpoint);
    final mount = await _mountProof(row);
    final raw = await _call('filesystem.getacl', [
      row.dataset.mountpoint,
      false,
      false,
    ]);
    if (raw is! Map ||
        raw['path'] != row.dataset.mountpoint ||
        !_permissionsId(raw['uid']) ||
        !_permissionsId(raw['gid']) ||
        raw['trivial'] is! bool) {
      _permissionsInvalid();
    }
    final kind = switch (raw['acltype']) {
      'NFS4' => PermissionAclType.nfs4,
      'POSIX1E' => PermissionAclType.posix1e,
      'DISABLED' => PermissionAclType.disabled,
      _ => null,
    };
    if (kind == null || row.aclType != kind) _permissionsInvalid();
    final acl = <PermissionAce>[];
    if (kind == PermissionAclType.disabled) {
      if (raw['acl'] != null || raw['trivial'] != true) _permissionsInvalid();
    } else {
      if (raw['acl'] is! List || (raw['acl'] as List).length > 128) {
        _permissionsInvalid();
      }
      for (final entry in raw['acl'] as List) {
        acl.add(_permissionsParseAce(kind, entry));
      }
      if (_permissionsAclError(kind, acl) != null) _permissionsInvalid();
    }
    final flags = kind == PermissionAclType.nfs4
        ? _permissionsBoolMap(raw['aclflags'], const [
            'autoinherit',
            'protected',
            'defaulted',
          ])
        : <String, bool>{};
    final target = paths.last;
    if (target['uid'] != raw['uid'] ||
        target['gid'] != raw['gid'] ||
        target['is_mountpoint'] != true) {
      _permissionsInvalid();
    }
    final bits = (target['mode'] as int) & 4095;
    final reason =
        row.dataset.blockedReason ??
        (bits > 511
            ? 'Special mode bits are protected because the server invokes chown even when ownership is unchanged.'
            : flags.values.any((v) => v)
            ? 'This NFSv4 ACL has protected, inherited-policy or defaulted flags that this server would reset.'
            : (target['attributes'] as List).any(
                (a) => a == 'IMMUTABLE' || a == 'APPEND',
              )
            ? 'Immutable or append-only dataset roots cannot be edited here.'
            : (mount['flags'] as List).any(
                (f) => (f as String).toUpperCase() == 'RO',
              )
            ? 'This dataset is mounted read-only.'
            : null);
    final value = PermissionReview(
      dataset: dataset ?? row.dataset,
      aclType: kind,
      uid: raw['uid'] as int,
      gid: raw['gid'] as int,
      mode: bits.toRadixString(8).padLeft(3, '0'),
      trivial: raw['trivial'] as bool,
      acl: acl,
      aclFlags: flags,
      blockedReason: reason,
    );
    if (kind == PermissionAclType.posix1e &&
        (_permissionsPosixMode(acl) !=
                (bits & 511).toRadixString(8).padLeft(3, '0') ||
            value.trivial != (acl.length == 3))) {
      _permissionsInvalid();
    }
    return _PermissionObservation(row, value, paths, mount);
  }

  Future<PermissionOperationResult> apply(
    PermissionApplyRequest request,
  ) async {
    _guard();
    if (isBusy || _reading || _polling || isOtherBusy()) {
      throw const PermissionsException(PermissionsExceptionReason.busy);
    }
    final issued = _reviews[request.review];
    if (issued == null) {
      throw const PermissionsException(
        PermissionsExceptionReason.staleSnapshot,
      );
    }
    if (request.validationError != null) {
      throw const PermissionsException(PermissionsExceptionReason.invalidInput);
    }
    final method = request.acl == null
        ? 'filesystem.setperm'
        : 'filesystem.setacl';
    _guard(method);
    _guard('core.get_jobs');
    _writing = true;
    var dispatched = false;
    try {
      final rows = await _rows(request.review.dataset.id);
      if (rows.length != 1 ||
          !_adminEqual(rows.single.identity, issued.row.identity)) {
        throw const PermissionsException(
          PermissionsExceptionReason.staleSnapshot,
        );
      }
      var fresh = await _observe(rows.single);
      if (!_adminEqual(fresh.fingerprint, issued.fingerprint)) {
        throw const PermissionsException(
          PermissionsExceptionReason.staleSnapshot,
        );
      }
      final oldNamed = request.review.acl
          .where((a) => a.tag == 'USER' || a.tag == 'GROUP')
          .map((a) => '${a.tag}:${a.id}')
          .toSet();
      for (final ace in request.acl ?? <PermissionAce>[]) {
        if ((ace.tag == 'USER' || ace.tag == 'GROUP') &&
            !oldNamed.contains('${ace.tag}:${ace.id}')) {
          if (await _lookup(
                ace.tag == 'USER'
                    ? PermissionIdentityKind.user
                    : PermissionIdentityKind.group,
                ace.id!,
              ) ==
              null) {
            throw const PermissionsException(
              PermissionsExceptionReason.invalidInput,
            );
          }
        }
      }
      // Recheck after identity lookup, immediately before the single dispatch.
      final latestRows = await _rows(request.review.dataset.id);
      if (latestRows.length != 1 ||
          !_adminEqual(latestRows.single.identity, issued.row.identity)) {
        throw const PermissionsException(
          PermissionsExceptionReason.staleSnapshot,
        );
      }
      fresh = await _observe(latestRows.single);
      if (!_adminEqual(fresh.fingerprint, issued.fingerprint)) {
        throw const PermissionsException(
          PermissionsExceptionReason.staleSnapshot,
        );
      }
      final payload = <String, Object?>{
        'path': request.review.dataset.mountpoint,
        'uid': request.acl == null ? null : -1,
        'gid': request.acl == null ? null : -1,
        'user': null,
        'group': null,
        if (request.acl == null)
          'mode': request.mode
        else ...{
          'acltype': _permissionsWireType(request.review.aclType),
          'dacl': request.acl!
              .map((a) => a._wire(request.review.aclType))
              .toList(),
          'nfs41_flags': {
            'autoinherit': false,
            'protected': false,
            'defaulted': false,
          },
        },
        'options': {
          'recursive': false,
          'traverse': false,
          'stripacl': false,
          if (request.acl != null) ...{
            'canonicalize': false,
            'validate_effective_acl': true,
          },
        },
      };
      _guard(method);
      if (isOtherBusy()) {
        throw const PermissionsException(PermissionsExceptionReason.busy);
      }
      dispatched = true;
      final requestId = 'permissions-$_requestNonce-${nextId()}';
      final raw = await _call(method, [payload], requestId: requestId);
      if (!_permissionsNumber(raw) || raw == 0) return _unknown();
      final result = PermissionOperationResult(
        outcome: PermissionOperationOutcome.pending,
        jobId: raw as int,
      );
      _active = result;
      _jobs[result] = _PermissionPlan(issued, request, method, [
        payload,
      ], requestId);
      _reviews.clear();
      return result;
    } on Object catch (error) {
      if (dispatched) return _unknown();
      if (error is PermissionsException) rethrow;
      throw const PermissionsException(PermissionsExceptionReason.unavailable);
    } finally {
      _writing = false;
    }
  }

  Future<PermissionOperationResult> check(
    PermissionOperationResult operation,
  ) async {
    _guard();
    if (_reading || _writing || _polling || isOtherBusy()) {
      throw const PermissionsException(PermissionsExceptionReason.busy);
    }
    final plan = _jobs[operation];
    if (plan == null || !identical(operation, _active) || _uncertain) {
      throw const PermissionsException(
        PermissionsExceptionReason.staleSnapshot,
      );
    }
    _polling = true;
    try {
      final raw = await _call('core.get_jobs', [
        [
          ['id', '=', operation.jobId],
        ],
        {
          'select': ['id', 'method', 'state', 'arguments', 'message_ids'],
          'limit': 2,
        },
      ]);
      if (raw is! List || raw.length != 1 || raw.single is! Map) {
        return _unknown();
      }
      final job = raw.single as Map;
      final messageIds = job['message_ids'];
      if (job['id'] != operation.jobId ||
          job['method'] != plan.method ||
          messageIds is! List ||
          messageIds.isEmpty ||
          messageIds.length > 32 ||
          !messageIds.contains(plan.requestId) ||
          !_adminEqual(job['arguments'], plan.args)) {
        return _unknown();
      }
      if (job['state'] == 'WAITING' || job['state'] == 'RUNNING') {
        return operation;
      }
      if (job['state'] != 'SUCCESS') return _unknown();
      final rows = await _rows(plan.before.row.dataset.id);
      if (rows.length != 1 ||
          !_adminEqual(rows.single.identity, plan.before.row.identity)) {
        return _unknown();
      }
      final after = await _observe(rows.single);
      if (!_permissionsVerified(plan, after)) return _unknown();
      _jobs.remove(operation);
      _active = null;
      _datasets.clear();
      _reviews.clear();
      return const PermissionOperationResult(
        outcome: PermissionOperationOutcome.verified,
      );
    } on Object {
      return _unknown();
    } finally {
      _polling = false;
    }
  }

  PermissionOperationResult _unknown() {
    _uncertain = true;
    _active = null;
    _jobs.clear();
    _reviews.clear();
    return const PermissionOperationResult(
      outcome: PermissionOperationOutcome.unknown,
      message: 'The permission change may have partially applied. Inspect the original dataset before reconnecting; do not repeat it automatically.',
    );
  }
}

final class _PermissionDatasetRow {
  const _PermissionDatasetRow(this.dataset, this.aclType, this.identity);
  final PermissionDataset dataset;
  final PermissionAclType aclType;
  final Map<String, Object?> identity;
  static _PermissionDatasetRow parse(Object? raw) {
    if (raw is! Map ||
        !_permissionsDatasetName(raw['id']) ||
        raw['name'] != raw['id'] ||
        raw['type'] != 'FILESYSTEM' ||
        raw['locked'] is! bool ||
        raw['encrypted'] is! bool ||
        raw['mountpoint'] != null &&
            !_permissionsText(raw['mountpoint'], 4096)) {
      _permissionsInvalid();
    }
    final id = raw['id'] as String, path = raw['mountpoint'] as String? ?? '';
    final guid = _permissionsRaw(raw['guid']),
        created = _permissionsRaw(raw['creation']),
        managed = raw.containsKey('managedby')
            ? _permissionsRaw(raw['managedby'])
            : '-';
    if (guid == null ||
        !RegExp(r'^[0-9]{1,20}$').hasMatch(guid) ||
        BigInt.parse(guid) > BigInt.parse('18446744073709551615') ||
        created == null ||
        !RegExp(r'^[0-9]{1,16}$').hasMatch(created)) {
      _permissionsInvalid();
    }
    final kind = switch (_permissionsRaw(raw['acltype'])?.toLowerCase()) {
      'nfsv4' || 'nfs4' => PermissionAclType.nfs4,
      'posix' || 'posixacl' => PermissionAclType.posix1e,
      'off' => PermissionAclType.disabled,
      _ => null,
    };
    if (kind == null) _permissionsInvalid();
    final readonly = _permissionsRaw(raw['readonly'])?.toLowerCase();
    final reason = !id.contains('/')
        ? 'Pool-root permission editing is not supported.'
        : id
              .split('/')
              .any(
                (p) =>
                    p.startsWith('.') ||
                    {
                      'ix-apps',
                      'ix-applications',
                      'ix-virt',
                      'ix-system',
                    }.contains(p),
              )
        ? 'System-managed dataset permissions are protected.'
        : raw['locked'] == true
        ? 'Unlock this dataset before editing permissions.'
        : managed == null || !{'', '-'}.contains(managed)
        ? 'Externally managed dataset permissions are protected.'
        : readonly != 'off'
        ? 'Read-only or unverified dataset state prevents editing.'
        : path != '/mnt/$id' || !_permissionsPath(path)
        ? 'Only standard existing dataset-root mountpoints are supported.'
        : null;
    final dataset = PermissionDataset(
      id: id,
      mountpoint: path,
      blockedReason: reason,
    );
    return _PermissionDatasetRow(dataset, kind, {
      'id': id,
      'mountpoint': path,
      'guid': guid,
      'creation': created,
      'locked': raw['locked'],
      'encrypted': raw['encrypted'],
      'managedby': managed,
      'readonly': readonly,
      'acltype': _permissionsWireType(kind),
      'aclmode': _permissionsRaw(raw['aclmode']),
    });
  }
}

final class _PermissionObservation {
  const _PermissionObservation(this.row, this.review, this.paths, this.mount);
  final _PermissionDatasetRow row;
  final PermissionReview review;
  final List<Map<String, Object?>> paths;
  final Map<String, Object?> mount;
  Object get fingerprint => [
    row.identity,
    paths,
    mount,
    review.uid,
    review.gid,
    review.mode,
    review.trivial,
    review.aclFlags,
    _permissionsAclKey(review.aclType, review.acl),
    review.blockedReason,
  ];
}

final class _PermissionPlan {
  const _PermissionPlan(
    this.before,
    this.request,
    this.method,
    this.args,
    this.requestId,
  );
  final _PermissionObservation before;
  final PermissionApplyRequest request;
  final String method;
  final List<Object?> args;
  final String requestId;
}

bool _permissionsVerified(_PermissionPlan plan, _PermissionObservation after) {
  final before = plan.before;
  if (!after.review.editable ||
      !_adminEqual(before.mount, after.mount) ||
      before.paths.length != after.paths.length ||
      before.review.uid != after.review.uid ||
      before.review.gid != after.review.gid ||
      before.review.aclType != after.review.aclType ||
      !_adminEqual(before.review.aclFlags, after.review.aclFlags)) {
    return false;
  }
  for (var i = 0; i < before.paths.length; i++) {
    if (i < before.paths.length - 1) {
      if (!_adminEqual(before.paths[i], after.paths[i])) return false;
    } else {
      for (final key in before.paths[i].keys.where(
        (k) => k != 'mode' && k != 'acl',
      )) {
        if (!_adminEqual(before.paths[i][key], after.paths[i][key])) {
          return false;
        }
      }
    }
  }
  if (plan.request.expectedMode != null &&
      after.review.mode != plan.request.expectedMode) {
    return false;
  }
  if (plan.request.acl != null) {
    return _adminEqual(
      _permissionsAclKey(after.review.aclType, plan.request.acl!),
      _permissionsAclKey(after.review.aclType, after.review.acl),
    );
  }
  if (!after.review.trivial) return false;
  return after.review.aclType == PermissionAclType.disabled
      ? after.review.acl.isEmpty
      : after.review.acl.length == 3 &&
            _permissionsPosixMode(after.review.acl) == plan.request.mode;
}

Never _permissionsInvalid() => throw const PermissionsException(
  PermissionsExceptionReason.invalidResponse,
);
bool _permissionsNumber(Object? value) =>
    value is int && value >= 0 && value <= 9007199254740991;
bool _permissionsId(Object? value) =>
    value is int && value >= 0 && value <= 2147483647;
bool _permissionsText(Object? value, int maximum) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= maximum &&
    !value.contains(RegExp(r'[\x00-\x1f\x7f]'));
bool _permissionsDatasetName(Object? value) =>
    _permissionsText(value, 240) &&
    !(value as String).contains('@') &&
    value
        .split('/')
        .every(
          (p) =>
              p.isNotEmpty &&
              p != '.' &&
              p != '..' &&
              RegExp(r'^[A-Za-z0-9_.: -]+$').hasMatch(p),
        );
bool _permissionsPath(String path) =>
    path.startsWith('/mnt/') &&
    path.length <= 4096 &&
    path.split('/').length <= 17 &&
    path
        .split('/')
        .skip(1)
        .every((p) => p.isNotEmpty && p != '.' && p != '..') &&
    !path.contains(RegExp(r'[\x00-\x1f\x7f]'));
String? _permissionsRaw(Object? raw) {
  final value = raw is Map
      ? raw['rawvalue'] ?? raw['value'] ?? raw['parsed']
      : raw;
  return value is String
      ? value
      : value is int && _permissionsNumber(value)
      ? '$value'
      : null;
}

String _permissionsWireType(PermissionAclType kind) => switch (kind) {
  PermissionAclType.nfs4 => 'NFS4',
  PermissionAclType.posix1e => 'POSIX1E',
  PermissionAclType.disabled => 'DISABLED',
};
Map<String, bool> _permissionsBoolMap(Object? raw, List<String> keys) {
  if (raw is! Map ||
      raw.length != keys.length ||
      raw.keys.any((k) => !keys.contains(k)) ||
      raw.values.any((v) => v is! bool)) {
    _permissionsInvalid();
  }
  return Map<String, bool>.from(raw);
}

PermissionAce _permissionsParseAce(PermissionAclType kind, Object? raw) {
  final nfs = kind == PermissionAclType.nfs4;
  if (raw is! Map ||
      raw.keys.any(
        (k) =>
            !(nfs
                    ? {'tag', 'id', 'who', 'type', 'perms', 'flags'}
                    : {'tag', 'id', 'who', 'perms', 'default'})
                .contains(k),
      ) ||
      raw['who'] != null ||
      raw['tag'] is! String ||
      !(raw['id'] == null || raw['id'] == -1 || _permissionsId(raw['id'])) ||
      nfs && raw['type'] is! String ||
      !nfs && raw['default'] is! bool) {
    _permissionsInvalid();
  }
  return PermissionAce(
    tag: raw['tag'] as String,
    id: raw['id'] == -1 ? null : raw['id'] as int?,
    type: nfs ? raw['type'] as String : null,
    permissions: _permissionsBoolMap(
      raw['perms'],
      nfs
          ? PermissionAce.nfs4PermissionNames
          : PermissionAce.posixPermissionNames,
    ),
    flags: nfs
        ? _permissionsBoolMap(raw['flags'], PermissionAce.nfs4FlagNames)
        : const {},
    isDefault: nfs ? false : raw['default'] as bool,
  );
}

String? _permissionsAclError(PermissionAclType kind, List<PermissionAce> acl) {
  if (kind == PermissionAclType.disabled || acl.isEmpty || acl.length > 128) {
    return 'Provide one to 128 supported ACL entries.';
  }
  final nfs = kind == PermissionAclType.nfs4, seen = <String>{};
  for (final ace in acl) {
    final named = ace.tag == 'USER' || ace.tag == 'GROUP';
    if (!(nfs
                ? {'owner@', 'group@', 'everyone@', 'USER', 'GROUP'}
                : {'USER_OBJ', 'GROUP_OBJ', 'OTHER', 'MASK', 'USER', 'GROUP'})
            .contains(ace.tag) ||
        (named ? !_permissionsId(ace.id) : ace.id != null && ace.id != -1)) {
      return 'Use a valid principal tag and numeric UID or GID.';
    }
    final names = nfs
        ? PermissionAce.nfs4PermissionNames
        : PermissionAce.posixPermissionNames;
    if (ace.permissions.length != names.length ||
        ace.permissions.keys.any((k) => !names.contains(k))) {
      return 'Unknown permission bits cannot be ignored.';
    }
    if (nfs) {
      if (!{'ALLOW', 'DENY'}.contains(ace.type) ||
          !named && ace.type == 'DENY' ||
          ace.isDefault ||
          ace.flags.length != PermissionAce.nfs4FlagNames.length ||
          ace.flags.keys.any((k) => !PermissionAce.nfs4FlagNames.contains(k))) {
        return 'Use supported NFSv4 entry types and inheritance flags.';
      }
      if ((ace.flags['INHERIT_ONLY'] == true ||
              ace.flags['NO_PROPAGATE_INHERIT'] == true) &&
          ace.flags['FILE_INHERIT'] != true &&
          ace.flags['DIRECTORY_INHERIT'] != true) {
        return 'Inherit-only and no-propagate flags require file or directory inheritance.';
      }
    } else {
      if (ace.type != null ||
          ace.flags.isNotEmpty ||
          !seen.add('${ace.isDefault}:${ace.tag}:${ace.id ?? -1}')) {
        return 'POSIX entries must not have NFSv4 fields or duplicate principals.';
      }
    }
  }
  if (!nfs) {
    for (final defaults in [false, true]) {
      final entries = acl.where((a) => a.isDefault == defaults).toList();
      if (defaults && entries.isEmpty) continue;
      if ([
        'USER_OBJ',
        'GROUP_OBJ',
        'OTHER',
      ].any((tag) => entries.where((a) => a.tag == tag).length != 1)) {
        return 'Each POSIX access/default list requires owner, owning group and other entries.';
      }
      if (entries.any((a) => a.tag == 'USER' || a.tag == 'GROUP') &&
          entries.where((a) => a.tag == 'MASK').length != 1) {
        return 'Named POSIX principals require an explicit matching mask.';
      }
    }
  }
  return null;
}

Object _permissionsAclKey(PermissionAclType kind, List<PermissionAce> acl) {
  final entries = acl.map((a) => a._wire(kind)).toList();
  if (kind == PermissionAclType.posix1e) {
    entries.sort(
      (a, b) => '${a['default']}:${a['tag']}:${a['id']}'.compareTo(
        '${b['default']}:${b['tag']}:${b['id']}',
      ),
    );
  }
  return entries;
}

String _permissionsPosixMode(List<PermissionAce> acl) {
  final access = acl.where((a) => !a.isDefault).toList();
  int digit(String tag) {
    final p = access.firstWhere((a) => a.tag == tag).permissions;
    return (p['READ'] == true ? 4 : 0) +
        (p['WRITE'] == true ? 2 : 0) +
        (p['EXECUTE'] == true ? 1 : 0);
  }

  return '${digit('USER_OBJ')}${digit(access.any((a) => a.tag == 'MASK') ? 'MASK' : 'GROUP_OBJ')}${digit('OTHER')}';
}
