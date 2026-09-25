part of 'true_nas_session_repository.dart';

/// Default-purpose SMB shares on existing, independently verified dataset roots.
abstract interface class AuthenticatedSmbSharesSession {
  SmbSharesCapabilities get smbSharesCapabilities;
  Future<SmbShareInventory> loadSmbShares();
  Future<SmbShareReview> reviewSmbShare(SmbShareRequest request);
  Future<SmbShareResult> executeSmbShare(
    SmbShareReview review,
    String confirmation,
  );
}

final class SmbSharesCapabilities {
  const SmbSharesCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.available,
    required this.canCreate,
    required this.canUpdate,
    required this.canDelete,
  });
  const SmbSharesCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      canCreate = false,
      canUpdate = false,
      canDelete = false;
  final bool connected,
      versionSupported,
      available,
      canCreate,
      canUpdate,
      canDelete;
  bool get supported => connected && versionSupported && available;
  bool allows(SmbShareAction action) =>
      supported &&
      switch (action) {
        SmbShareAction.create => canCreate,
        SmbShareAction.update => canUpdate,
        SmbShareAction.delete => canDelete,
      };
  String? get blockedReason => !connected
      ? 'Connect to inspect SMB shares.'
      : !versionSupported
      ? 'Native SMB shares require stable TrueNAS 25.10.'
      : !available
      ? 'SMB inventory reads are unavailable to this account.'
      : null;
}

enum SmbShareAction { create, update, delete }

enum SmbShareOutcome { verified, rejected, unknown }

enum SmbSharesExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  stale,
  invalid,
  dependency,
  unavailable,
}

final class SmbSharesException implements Exception {
  const SmbSharesException(this.reason);
  final SmbSharesExceptionReason reason;
  String get userMessage => switch (reason) {
    SmbSharesExceptionReason.notAuthenticated =>
      'Reconnect before inspecting SMB shares.',
    SmbSharesExceptionReason.unsupportedVersion =>
      'Native SMB shares require stable TrueNAS 25.10.',
    SmbSharesExceptionReason.unavailableMethod =>
      'Required public SMB safety methods are unavailable.',
    SmbSharesExceptionReason.busy =>
      'Another change or an unresolved SMB operation is in progress.',
    SmbSharesExceptionReason.stale => 'The share, dataset, dependencies or session changed. Reload and review again.',
    SmbSharesExceptionReason.invalid =>
      'The selected SMB settings or filesystem identity could not be verified.',
    SmbSharesExceptionReason.dependency => 'Advanced share settings or service dependencies require their dedicated workflow.',
    SmbSharesExceptionReason.unavailable =>
      'SMB information could not be read safely. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

final class SmbShareSettings {
  const SmbShareSettings({
    required this.name,
    this.comment = '',
    this.readonly = false,
    this.enabled = true,
  });
  final String name, comment;
  final bool readonly, enabled;
  String? get validationError => !_smbName(name)
      ? 'Use a share name of 1–80 plain characters, without reserved names or SMB punctuation.'
      : !_smbText(comment, 512, empty: true)
      ? 'Use a single-line comment of at most 512 characters.'
      : null;
  Map<String, Object?> get _wire => {
    'name': name,
    'comment': comment,
    'readonly': readonly,
    'enabled': enabled,
  };
}

final class SmbShareEntry {
  const SmbShareEntry({
    required this.id,
    required this.name,
    required this.path,
    required this.comment,
    required this.readonly,
    required this.enabled,
    required this.purpose,
    required this.locked,
    this.blockedReason,
  });
  final int id;
  final String name, path, comment, purpose;
  final bool readonly, enabled;
  final bool? locked;
  final String? blockedReason;
  bool get editable => blockedReason == null;
  SmbShareSettings get settings => SmbShareSettings(
    name: name,
    comment: comment,
    readonly: readonly,
    enabled: enabled,
  );
}

final class SmbShareDataset {
  const SmbShareDataset({
    required this.id,
    required this.guid,
    required this.mountpoint,
    this.blockedReason,
  });
  final String id, guid, mountpoint;
  final String? blockedReason;
  bool get editable => blockedReason == null;
}

final class SmbShareInventory {
  SmbShareInventory({
    required List<SmbShareEntry> shares,
    required List<SmbShareDataset> datasets,
    required this.serviceState,
    required this.serviceEnabled,
  }) : shares = List.unmodifiable(shares),
       datasets = List.unmodifiable(datasets);
  final List<SmbShareEntry> shares;
  final List<SmbShareDataset> datasets;
  final String serviceState;
  final bool serviceEnabled;
  int get enabledCount => shares.where((s) => s.enabled).length;
  int get disabledCount => shares.length - enabledCount;
}

final class SmbShareRequest {
  const SmbShareRequest({
    required this.inventory,
    required this.action,
    this.share,
    this.dataset,
    this.settings,
  });
  final SmbShareInventory inventory;
  final SmbShareAction action;
  final SmbShareEntry? share;
  final SmbShareDataset? dataset;
  final SmbShareSettings? settings;
  String get target => share?.name ?? settings?.name ?? '';
  String? get validationError {
    if (action == SmbShareAction.create) {
      if (share != null ||
          dataset == null ||
          !dataset!.editable ||
          settings == null) {
        return 'Select an eligible existing dataset root and new share settings.';
      }
    } else if (share == null || !share!.editable || dataset != null) {
      return 'Select an eligible current SMB share.';
    }
    if (action == SmbShareAction.delete) {
      return settings == null
          ? null
          : 'Deletion does not accept replacement settings.';
    }
    if (settings == null) return 'Review explicit SMB settings.';
    if (settings!.validationError != null) return settings!.validationError;
    if (action == SmbShareAction.update && settings!.name != share!.name) {
      return 'Renaming can rewrite share-level ACL records. Use the dedicated TrueNAS share ACL workflow.';
    }
    if (inventory.shares.any(
      (s) =>
          s.id != share?.id &&
          s.name.toLowerCase() == settings!.name.toLowerCase(),
    )) {
      return 'Share names must be unique, ignoring case.';
    }
    if (action == SmbShareAction.update &&
        _adminEqual(settings!._wire, share!.settings._wire)) {
      return 'Change at least one setting before reviewing.';
    }
    return null;
  }
}

final class SmbShareReview {
  SmbShareReview({
    required this.action,
    required this.target,
    required this.identity,
    required List<String> changes,
    required List<String> warnings,
  }) : changes = List.unmodifiable(changes),
       warnings = List.unmodifiable(warnings);
  final SmbShareAction action;
  final String target, identity;
  final List<String> changes, warnings;
  String get confirmation => target;
}

final class SmbShareResult {
  const SmbShareResult(this.outcome, this.message);
  final SmbShareOutcome outcome;
  final String message;
}

const _smbShareKeys = [
  'id',
  'purpose',
  'name',
  'path',
  'enabled',
  'comment',
  'readonly',
  'browsable',
  'access_based_share_enumeration',
  'locked',
  'audit',
  'options',
];
const _smbProperties = [
  'guid',
  'creation',
  'mountpoint',
  'readonly',
  'origin',
  'encryption',
  'encryptionroot',
  'keystatus',
  'acltype',
  'xattr',
  'filesystem_count',
];
const _smbSafetyMethods = {
  'sharing.smb.query',
  'sharing.smb.presets',
  'sharing.smb.share_precheck',
  'smb.config',
  'service.query',
  'pool.dataset.query',
  'pool.dataset.attachments',
  'filesystem.stat',
  'filesystem.statfs',
  'filesystem.getacl',
  'failover.licensed',
  'sharing.nfs.query',
};

final class _SmbSnapshot {
  const _SmbSnapshot(this.inventory, this.shares, this.datasets, this.service);
  final SmbShareInventory inventory;
  final Map<int, Map<String, Object?>> shares;
  final Map<String, Map<String, Object?>> datasets;
  final Map<String, Object?> service;
  Object get fingerprint => [shares, datasets, service];
}

final class _SmbPlan {
  const _SmbPlan(
    this.request,
    this.snapshot,
    this.dataset,
    this.proof,
    this.payload,
  );
  final SmbShareRequest request;
  final _SmbSnapshot snapshot;
  final SmbShareDataset dataset;
  final Object proof;
  final Map<String, Object?> payload;
}

final class _SessionSmbShares {
  _SessionSmbShares({
    required this.client,
    required ServerSummary summary,
    required Object? metadata,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherBusy,
    required this.requestTimeout,
  }) : _version =
           _managementVersion(summary.version) == _ManagementVersion.v2510,
       _methods = Set.unmodifiable(summary.availableMethodNames),
       _safeReads = {
         for (final method in _smbSafetyMethods)
           if (_smbSync(metadata, method)) method,
       },
       _sync = {
         for (final action in SmbShareAction.values)
           if (_smbSync(metadata, 'sharing.smb.${action.name}')) action,
       };
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherBusy;
  final Duration requestTimeout;
  final bool _version;
  final Set<String> _methods;
  final Set<String> _safeReads;
  final Set<SmbShareAction> _sync;
  final _inventories = <SmbShareInventory, _SmbSnapshot>{};
  final _reviews = <SmbShareReview, _SmbPlan>{};
  bool _reading = false, _submitting = false, _unknown = false;
  bool get isBusy => _submitting || _unknown;
  SmbSharesCapabilities get capabilities {
    final safety =
        _methods.containsAll(_smbSafetyMethods) &&
        _safeReads.containsAll(_smbSafetyMethods);
    bool action(SmbShareAction a) =>
        safety &&
        _sync.contains(a) &&
        _methods.contains('sharing.smb.${a.name}');
    return SmbSharesCapabilities(
      connected: isCurrent(),
      versionSupported: _version,
      available:
          _methods.containsAll({
            'sharing.smb.query',
            'pool.dataset.query',
            'service.query',
          }) &&
          _safeReads.containsAll({
            'sharing.smb.query',
            'pool.dataset.query',
            'service.query',
          }),
      canCreate: action(SmbShareAction.create),
      canUpdate: action(SmbShareAction.update),
      canDelete: action(SmbShareAction.delete),
    );
  }

  void _guard([String? method]) {
    if (!isCurrent()) {
      throw const SmbSharesException(SmbSharesExceptionReason.notAuthenticated);
    }
    if (!_version) {
      throw const SmbSharesException(
        SmbSharesExceptionReason.unsupportedVersion,
      );
    }
    if (!capabilities.available ||
        method != null && !_methods.contains(method)) {
      throw const SmbSharesException(
        SmbSharesExceptionReason.unavailableMethod,
      );
    }
  }

  Future<Object?> _call(String method, List<Object?> args) async {
    _guard(method);
    final result = await client
        .call(method, id: nextId(), params: args)
        .timeout(requestTimeout);
    _guard(method);
    return result;
  }

  Future<T> _read<T>(Future<T> Function() operation) async {
    _guard();
    if (_reading || isBusy || isOtherBusy()) {
      throw const SmbSharesException(SmbSharesExceptionReason.busy);
    }
    _reading = true;
    try {
      return await operation();
    } on SmbSharesException {
      rethrow;
    } on Object {
      throw const SmbSharesException(SmbSharesExceptionReason.unavailable);
    } finally {
      _reading = false;
    }
  }

  Future<_SmbSnapshot> _snapshot() async {
    final rawShares = await _call('sharing.smb.query', [
      [],
      {
        'limit': 257,
        'extra': {'retrieve_locked_info': true},
      },
    ]);
    if (rawShares is! List || rawShares.length > 256) _smbInvalid();
    final shares = <int, Map<String, Object?>>{};
    final entries = <SmbShareEntry>[];
    final names = <String>{};
    for (final raw in rawShares) {
      final row = _smbMap(raw);
      if (!_smbNumber(row['id']) ||
          row['id'] == 0 ||
          !_smbText(row['name'], 80) ||
          !_smbText(row['path'], 4096) ||
          !_smbText(row['comment'], 512, empty: true) ||
          !_smbText(row['purpose'], 80) ||
          row['enabled'] is! bool ||
          row['readonly'] is! bool ||
          row['locked'] != null && row['locked'] is! bool ||
          shares.containsKey(row['id']) ||
          !names.add((row['name'] as String).toLowerCase())) {
        _smbInvalid();
      }
      shares[row['id'] as int] = row;
      entries.add(
        SmbShareEntry(
          id: row['id'] as int,
          name: row['name'] as String,
          path: row['path'] as String,
          comment: row['comment'] as String,
          readonly: row['readonly'] as bool,
          enabled: row['enabled'] as bool,
          purpose: row['purpose'] as String,
          locked: row['locked'] as bool?,
          blockedReason: _smbShareBlocked(row),
        ),
      );
    }
    final rawDatasets = await _call('pool.dataset.query', [
      [
        ['type', '=', 'FILESYSTEM'],
      ],
      {
        'limit': 257,
        'select': [
          'id',
          'type',
          'encrypted',
          'locked',
          ..._smbProperties,
          ['user_properties.managedby', 'managedby'],
        ],
        'extra': {
          'flat': true,
          'retrieve_children': false,
          'retrieve_user_props': true,
          'properties': _smbProperties,
        },
      },
    ]);
    if (rawDatasets is! List || rawDatasets.length > 256) _smbInvalid();
    final datasets = <String, Map<String, Object?>>{};
    for (final raw in rawDatasets) {
      // GUID identity uses the exact wire string, not redundant parsed numeric
      // metadata that JSON clients can round beyond 2^53. It is never submitted.
      final guidMetadata = raw is Map ? raw['guid'] : null;
      final row = _smbMap(
        raw is Map && guidMetadata is Map
            ? {
                ...raw,
                'guid': {
                  for (final e in guidMetadata.entries)
                    if (e.key != 'parsed') e.key: e.value,
                },
              }
            : raw,
      );
      if (!_smbDatasetName(row['id']) ||
          row['type'] != 'FILESYSTEM' ||
          row['encrypted'] is! bool ||
          row['locked'] is! bool ||
          datasets.containsKey(row['id'])) {
        _smbInvalid();
      }
      final guid = _smbRaw(row['guid']);
      if (guid == null ||
          !RegExp(r'^[0-9]{1,20}$').hasMatch(guid) ||
          BigInt.parse(guid) <= BigInt.zero ||
          BigInt.parse(guid) > BigInt.parse('18446744073709551615')) {
        _smbInvalid();
      }
      datasets[row['id'] as String] = row;
    }
    final choices = [
      for (final row in datasets.values)
        SmbShareDataset(
          id: row['id'] as String,
          guid: _smbRaw(row['guid'])!,
          mountpoint: row['mountpoint'] is String
              ? row['mountpoint'] as String
              : '',
          blockedReason: _smbDatasetBlocked(datasets, row['id'] as String),
        ),
    ];
    final rawService = await _call('service.query', [
      [
        ['service', '=', 'cifs'],
      ],
      {
        'limit': 2,
        'select': ['id', 'service', 'enable', 'state'],
      },
    ]);
    if (rawService is! List || rawService.length != 1) _smbInvalid();
    final service = _smbMap(rawService.single);
    if (!_smbNumber(service['id']) ||
        service['service'] != 'cifs' ||
        service['enable'] is! bool ||
        !{
          'RUNNING',
          'STOPPED',
          'CRASHED',
          'UNKNOWN',
        }.contains(service['state'])) {
      _smbInvalid();
    }
    entries.sort((a, b) => a.name.compareTo(b.name));
    choices.sort((a, b) => a.id.compareTo(b.id));
    return _SmbSnapshot(
      SmbShareInventory(
        shares: entries,
        datasets: choices,
        serviceState: service['state'] as String,
        serviceEnabled: service['enable'] as bool,
      ),
      shares,
      datasets,
      service,
    );
  }

  Future<SmbShareInventory> load() => _read(() async {
    _inventories.clear();
    _reviews.clear();
    final snapshot = await _snapshot();
    _inventories[snapshot.inventory] = snapshot;
    return snapshot.inventory;
  });
  Future<_SmbSnapshot> _fresh(SmbShareInventory inventory) async {
    final issued = _inventories[inventory];
    if (issued == null) {
      throw const SmbSharesException(SmbSharesExceptionReason.stale);
    }
    final fresh = await _snapshot();
    if (!_adminEqual(issued.fingerprint, fresh.fingerprint)) {
      throw const SmbSharesException(SmbSharesExceptionReason.stale);
    }
    return fresh;
  }

  Future<Object> _proof(SmbShareDataset dataset, SmbShareEntry? share) async {
    if (await _call('failover.licensed', []) != false) {
      throw const SmbSharesException(SmbSharesExceptionReason.dependency);
    }
    final config = _smbMap(await _call('smb.config', []));
    if (config['smb_options'] != '' ||
        config['enable_smb1'] != false ||
        config['ntlmv1_auth'] != false) {
      throw const SmbSharesException(SmbSharesExceptionReason.dependency);
    }
    final presets = _smbMap(await _call('sharing.smb.presets', []));
    if (presets['DEFAULT_SHARE'] is! Map ||
        !_smbText((presets['DEFAULT_SHARE'] as Map)['verbose_name'], 256)) {
      _smbInvalid();
    }
    if (await _call('sharing.smb.share_precheck', [{}]) != null) _smbInvalid();
    // attachments() omits disabled exports and ancestor exports.
    final nfs = await _call('sharing.nfs.query', [
      [],
      {
        'limit': 129,
        'select': ['id', 'path', 'enabled', 'aliases'],
      },
    ]);
    if (nfs is! List || nfs.length > 128) _smbInvalid();
    final nfsProof = <Object?>[];
    final nfsIds = <int>{};
    var nfsPathCount = 0;
    for (final raw in nfs) {
      final row = _smbMap(raw);
      if (!_smbNumber(row['id']) ||
          !nfsIds.add(row['id'] as int) ||
          !_smbText(row['path'], 4096) ||
          row['enabled'] is! bool ||
          !_adminEqual(row['aliases'], [])) {
        throw const SmbSharesException(SmbSharesExceptionReason.dependency);
      }
      final nfsPath = row['path'] as String;
      if (!nfsPath.startsWith('/mnt/') ||
          nfsPath.split('/').length > 17 ||
          nfsPath
              .split('/')
              .skip(1)
              .any((p) => p.isEmpty || p == '.' || p == '..') ||
          nfsPath == dataset.mountpoint ||
          nfsPath.startsWith('${dataset.mountpoint}/') ||
          dataset.mountpoint.startsWith('$nfsPath/')) {
        throw const SmbSharesException(SmbSharesExceptionReason.dependency);
      }
      var prefix = '';
      final identities = <Object?>[];
      for (final part in nfsPath.split('/').skip(1)) {
        if (++nfsPathCount > 256) {
          throw const SmbSharesException(SmbSharesExceptionReason.dependency);
        }
        prefix = '$prefix/$part';
        final stat = _smbMap(await _call('filesystem.stat', [prefix]));
        if (stat['type'] != 'DIRECTORY' ||
            stat['realpath'] != prefix ||
            ['inode', 'dev', 'mount_id'].any((k) => !_smbNumber(stat[k]))) {
          throw const SmbSharesException(SmbSharesExceptionReason.dependency);
        }
        identities.add([prefix, stat['inode'], stat['dev'], stat['mount_id']]);
      }
      nfsProof.add([row, identities]);
    }
    final rawAttachments = await _call('pool.dataset.attachments', [
      dataset.id,
    ]);
    if (rawAttachments is! List || rawAttachments.length > 32) _smbInvalid();
    final attachments = <Object?>[];
    var attachmentCount = 0;
    for (final raw in rawAttachments) {
      final row = _smbMap(raw);
      if (row['attachments'] is! List ||
          (row['attachments'] as List).length > 256 ||
          (row['attachments'] as List).any((a) => !_smbText(a, 2048))) {
        _smbInvalid();
      }
      final names = (row['attachments'] as List).cast<String>().toList()
        ..sort();
      attachmentCount += names.length;
      if (attachmentCount > 256 ||
          !_smbText(row['type'], 128) ||
          row['service'] != null && !_smbText(row['service'], 128)) {
        _smbInvalid();
      }
      if (names.toSet().length != names.length) _smbInvalid();
      if (names.isNotEmpty &&
          (row['type'] != 'SMB Share' ||
              row['service'] != 'cifs' ||
              share == null ||
              names.length != 1 ||
              names.single != share.name)) {
        throw const SmbSharesException(SmbSharesExceptionReason.dependency);
      }
      attachments.add([row['type'], row['service'], names]);
    }
    final path = dataset.mountpoint;
    final paths = <Object?>[];
    var current = '';
    for (final component in ['', ...path.split('/').skip(1)]) {
      current = component.isEmpty
          ? '/'
          : current == '/'
          ? '/$component'
          : '$current/$component';
      final raw = _smbMap(await _call('filesystem.stat', [current]));
      if (raw['type'] != 'DIRECTORY' ||
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
          ].any((k) => !_smbNumber(raw[k])) ||
          raw['attributes'] is! List ||
          (raw['attributes'] as List).length > 128 ||
          (raw['attributes'] as List).any((a) => !_smbText(a, 128))) {
        _smbInvalid();
      }
      if (current == path && raw['is_mountpoint'] != true) _smbInvalid();
      paths.add({
        for (final key in [
          'type',
          'realpath',
          'uid',
          'gid',
          'mode',
          'dev',
          'inode',
          'mount_id',
          'is_ctldir',
          'is_mountpoint',
          'acl',
          'attributes',
        ])
          key: raw[key],
      });
    }
    final mount = _smbMap(await _call('filesystem.statfs', [path]));
    if (mount['fstype'] != 'zfs' ||
        mount['source'] != dataset.id ||
        mount['dest'] != path ||
        !_smbText(mount['fsid'], 128) ||
        mount['flags'] is! List ||
        (mount['flags'] as List).length > 128 ||
        (mount['flags'] as List).any(
          (f) => !_smbText(f, 128) || (f as String).toUpperCase() == 'RO',
        )) {
      _smbInvalid();
    }
    final acl = _smbMap(await _call('filesystem.getacl', [path, false, false]));
    if (acl['path'] != path ||
        !_smbNumber(acl['uid']) ||
        !_smbNumber(acl['gid']) ||
        acl['trivial'] is! bool ||
        !{'NFS4', 'POSIX1E'}.contains(acl['acltype']) ||
        acl['acl'] is! List ||
        (acl['acl'] as List).length > 256) {
      _smbInvalid();
    }
    // Reuse the strict, source-shaped ACE parser; never submit its ACL output.
    try {
      final kind = acl['acltype'] == 'NFS4'
          ? PermissionAclType.nfs4
          : PermissionAclType.posix1e;
      final entries = [
        for (final entry in acl['acl'] as List)
          _permissionsParseAce(kind, entry),
      ];
      if (_permissionsAclError(kind, entries) != null) _smbInvalid();
      if (kind == PermissionAclType.nfs4) {
        _permissionsBoolMap(acl['aclflags'], const [
          'autoinherit',
          'protected',
          'defaulted',
        ]);
      }
      if (acl['uid'] != (paths.last as Map)['uid'] ||
          acl['gid'] != (paths.last as Map)['gid']) {
        _smbInvalid();
      }
    } on Object {
      _smbInvalid();
    }
    return {
      'config': config,
      'nfs': nfsProof,
      'presets': presets,
      'attachments': attachments,
      'paths': paths,
      'mount': {
        for (final k in ['fstype', 'source', 'dest', 'fsid', 'flags'])
          k: mount[k],
      },
      'acl': acl,
    };
  }

  Future<SmbShareReview> review(SmbShareRequest request) => _read(() async {
    if (!capabilities.allows(request.action)) {
      throw const SmbSharesException(
        SmbSharesExceptionReason.unavailableMethod,
      );
    }
    if (request.validationError != null) _smbInvalid();
    if (request.share != null &&
            !request.inventory.shares.any((s) => identical(s, request.share)) ||
        request.dataset != null &&
            !request.inventory.datasets.any(
              (d) => identical(d, request.dataset),
            )) {
      throw const SmbSharesException(SmbSharesExceptionReason.stale);
    }
    final snapshot = await _fresh(request.inventory);
    final dataset =
        request.dataset ??
        snapshot.inventory.datasets
            .where((d) => d.mountpoint == request.share!.path)
            .firstOrNull;
    if (dataset == null || !dataset.editable) {
      throw const SmbSharesException(SmbSharesExceptionReason.dependency);
    }
    if (snapshot.inventory.shares.any(
      (s) =>
          s.id != request.share?.id &&
          (s.path == dataset.mountpoint ||
              s.path.startsWith('${dataset.mountpoint}/') ||
              dataset.mountpoint.startsWith('${s.path}/')),
    )) {
      throw const SmbSharesException(SmbSharesExceptionReason.dependency);
    }
    final proof = await _proof(dataset, request.share);
    await _fresh(request.inventory);
    final payload = request.action == SmbShareAction.create
        ? <String, Object?>{
            ...request.settings!._wire,
            'path': dataset.mountpoint,
            'purpose': 'DEFAULT_SHARE',
            'options': {
              'aapl_name_mangling': false,
              'hostsallow': <String>[],
              'hostsdeny': <String>[],
            },
            'browsable': true,
            'access_based_share_enumeration': false,
            'audit': {
              'enable': false,
              'watch_list': <String>[],
              'ignore_list': <String>[],
            },
          }
        : <String, Object?>{
            if (request.settings != null)
              for (final entry in request.settings!._wire.entries)
                if (entry.value != request.share!.settings._wire[entry.key])
                  entry.key: entry.value,
          };
    final review = SmbShareReview(
      action: request.action,
      target: request.target,
      identity: '${dataset.id} · GUID ${dataset.guid} · ${dataset.mountpoint}',
      changes: [
        '${request.action.name.toUpperCase()} SMB share ${request.target}',
        'Existing filesystem root: ${dataset.mountpoint}',
        if (request.settings != null) ...[
          'Name: ${request.share?.name ?? '(new)'} → ${request.settings!.name}',
          'Comment: ${request.share?.comment ?? '(new)'} → ${request.settings!.comment}',
          'SMB read-only: ${request.share?.readonly ?? '(new)'} → ${request.settings!.readonly}',
          'Enabled: ${request.share?.enabled ?? '(new)'} → ${request.settings!.enabled}',
        ],
      ],
      warnings: [
        'This changes the SMB share configuration only. No directory, dataset, file, owner, filesystem ACL or mode is intentionally created, deleted or changed.',
        if (request.action == SmbShareAction.create) 'Without an existing name-keyed share ACL, SMB defaults to Everyone FULL access at the share layer; existing filesystem permissions still apply. Previously used names can retain a server ACL. No share ACL is read or set here. Inspect share permissions in TrueNAS before enabling if the name was previously used.',
        if (request.action != SmbShareAction.delete) 'TrueNAS reloads the SMB service configuration. Disabling forcibly disconnects clients of this share; enabled changes also reload mDNS. The service is not explicitly started by this client.',
        if (request.action == SmbShareAction.delete) 'Delete removes this SMB share configuration and its active share-level ACL, and forcibly disconnects its clients. Files and the filesystem ACL remain. Inactive share ACL records may remain on the server.',
        'Only submitted public settings and their public readback are compared. TrueNAS may normalize private legacy fields for the DEFAULT_SHARE preset; this client cannot inspect those private records.',
        'Read-only limits SMB clients only; local processes and other protocols may still write. Configured enabled counts are not active sessions or service health.',
        'Other administrators and local processes must remain idle. The public API has no atomic identity compare-and-write; a final race cannot be eliminated.',
      ],
    );
    _reviews.clear();
    _reviews[review] = _SmbPlan(request, snapshot, dataset, proof, payload);
    return review;
  });

  Future<SmbShareResult> execute(
    SmbShareReview review,
    String confirmation,
  ) async {
    _guard();
    if (_reading || isBusy || isOtherBusy()) {
      throw const SmbSharesException(SmbSharesExceptionReason.busy);
    }
    final plan = _reviews.remove(review);
    if (plan == null || confirmation != review.confirmation) {
      throw const SmbSharesException(SmbSharesExceptionReason.stale);
    }
    _submitting = true;
    var sent = false;
    try {
      final request = plan.request;
      if (!capabilities.allows(request.action)) {
        throw const SmbSharesException(
          SmbSharesExceptionReason.unavailableMethod,
        );
      }
      await _fresh(request.inventory);
      if (!_adminEqual(plan.proof, await _proof(plan.dataset, request.share))) {
        throw const SmbSharesException(SmbSharesExceptionReason.stale);
      }
      await _fresh(request.inventory);
      _guard();
      if (isOtherBusy()) {
        throw const SmbSharesException(SmbSharesExceptionReason.busy);
      }
      sent = true;
      final receipt = await _call('sharing.smb.${request.action.name}', [
        if (request.action != SmbShareAction.create) request.share!.id,
        if (request.action != SmbShareAction.delete) plan.payload,
      ]);
      final after = await _snapshot();
      int? id;
      if (request.action == SmbShareAction.delete) {
        if (receipt != true) _smbInvalid();
        id = request.share!.id;
      } else {
        final row = _smbMap(receipt);
        if (!_smbNumber(row['id']) || row['id'] == 0) _smbInvalid();
        id = row['id'] as int;
        if (request.action == SmbShareAction.update &&
                id != request.share!.id ||
            request.action == SmbShareAction.create &&
                plan.snapshot.shares.containsKey(id)) {
          _smbInvalid();
        }
        final expected = {
          ...(request.action == SmbShareAction.create
              ? plan.payload
              : plan.snapshot.shares[id]!),
          ...plan.payload,
          'id': id,
          'locked': false,
        };
        if (!_adminEqual(row, expected) ||
            !_adminEqual(after.shares[id], expected)) {
          _smbInvalid();
        }
      }
      final expectedOthers = {...plan.snapshot.shares}
        ..remove(request.share?.id);
      final actualOthers = {...after.shares}..remove(id);
      if (!_adminEqual(expectedOthers, actualOthers) ||
          request.action == SmbShareAction.delete &&
              after.shares.containsKey(id) ||
          !_adminEqual(plan.snapshot.datasets, after.datasets) ||
          !_adminEqual(plan.snapshot.service, after.service)) {
        _smbInvalid();
      }
      final selected = request.action == SmbShareAction.delete
          ? null
          : after.inventory.shares.where((s) => s.id == id).single;
      final afterProof = await _proof(plan.dataset, selected);
      final beforeMap = {...plan.proof as Map}..remove('attachments');
      final afterMap = {...afterProof as Map}..remove('attachments');
      if (!_adminEqual(beforeMap, afterMap)) _smbInvalid();
      // Close proof reads with an independent inventory read to catch intervening replacement.
      if (!_adminEqual(after.fingerprint, (await _snapshot()).fingerprint)) {
        _smbInvalid();
      }
      _inventories.clear();
      return const SmbShareResult(
        SmbShareOutcome.verified,
        'The SMB configuration change and unchanged dataset identity/permissions were verified. Client reconnection may still be required.',
      );
    } on Object catch (error) {
      if (!sent) {
        if (error is SmbSharesException) rethrow;
        throw const SmbSharesException(SmbSharesExceptionReason.unavailable);
      }
      _unknown = true;
      return const SmbShareResult(
        SmbShareOutcome.unknown,
        'The SMB change may have reached the server but could not be independently verified. Do not repeat it. Inspect the original share and reconnect.',
      );
    } finally {
      _submitting = false;
    }
  }
}

String? _smbShareBlocked(Map<String, Object?> row) {
  if (row['locked'] != false) return 'A positively unlocked share is required.';
  if (row.keys.any((k) => !_smbShareKeys.contains(k)) ||
      row.length != _smbShareKeys.length ||
      row['purpose'] != 'DEFAULT_SHARE' ||
      row['browsable'] is! bool ||
      row['access_based_share_enumeration'] is! bool ||
      !_adminEqual(row['options'], {
        'aapl_name_mangling': false,
        'hostsallow': [],
        'hostsdeny': [],
      }) ||
      !_adminEqual(row['audit'], {
        'enable': false,
        'watch_list': [],
        'ignore_list': [],
      }) ||
      !_smbName(row['name'] as String)) {
    return 'Advanced purpose, audit, host filters or unknown settings are read-only here.';
  }
  return null;
}

String? _smbDatasetBlocked(Map<String, Map<String, Object?>> rows, String id) {
  final parts = id.split('/');
  if (parts.length < 2) return 'Pool roots are not share targets here.';
  if (parts.length > 15) {
    return 'The filesystem path exceeds the bounded identity proof.';
  }
  for (var i = 1; i <= parts.length; i++) {
    final key = parts.take(i).join('/');
    final row = rows[key];
    if (row == null) return 'Every dataset ancestor must be visible.';
    if (row['encrypted'] != false ||
        row['locked'] != false ||
        _smbRaw(row['encryption']) != 'off' ||
        !{'-', 'none'}.contains(_smbRaw(row['encryptionroot'])) ||
        !{'-', 'none', 'available'}.contains(_smbRaw(row['keystatus']))) {
      return 'Encrypted or locked datasets and ancestors are protected.';
    }
    if (parts
            .take(i)
            .any(
              (p) => {
                '.system',
                'ix-apps',
                'ix-applications',
                '.ix-virt',
                'boot-pool',
                'freenas-boot',
              }.contains(p),
            ) ||
        !(row['managedby'] == null ||
            {'', '-'}.contains(_smbRaw(row['managedby'])))) {
      return 'System-managed datasets and ancestors are protected.';
    }
    if (row['mountpoint'] != '/mnt/$key' ||
        _smbRaw(row['readonly']) != 'off' ||
        !{'', '-', 'none'}.contains(_smbRaw(row['origin'])) ||
        !RegExp(r'^[1-9][0-9]{0,15}$')
            .hasMatch(_smbRaw(row['creation']) ?? '') ||
        !{'nfsv4', 'posix'}.contains(_smbRaw(row['acltype'])) ||
        !{'on', 'sa'}.contains(_smbRaw(row['xattr']))) {
      return 'A standard, writable, non-cloned dataset root is required.';
    }
  }
  if (_smbRaw(rows[id]!['filesystem_count']) != '0' ||
      rows.keys.any((key) => key.startsWith('$id/'))) {
    return 'Datasets with child filesystems require a recursive share-impact review.';
  }
  return null;
}

bool _smbSync(Object? metadata, String method) =>
    metadata is Map &&
    metadata[method] is Map &&
    (metadata[method] as Map)['job'] == false &&
    (metadata[method] as Map)['no_auth_required'] == false &&
    (metadata[method] as Map)['uploadable'] == false &&
    (metadata[method] as Map)['downloadable'] == false &&
    (metadata[method] as Map)['private'] != true &&
    (metadata[method] as Map)['_private'] != true;
Never _smbInvalid() =>
    throw const SmbSharesException(SmbSharesExceptionReason.invalid);
bool _smbNumber(Object? value) =>
    value is int && value >= 0 && value <= 9007199254740991;
bool _smbText(Object? value, int max, {bool empty = false}) =>
    value is String &&
    (empty || value.isNotEmpty) &&
    value.length <= max &&
    !value.contains(RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]'));
bool _smbName(String value) =>
    _smbText(value, 80) &&
    value.trim() == value &&
    !{'global', 'printers', 'homes'}.contains(value.toLowerCase()) &&
    !value.contains(RegExp(r'[\\/\[\]:|<>+=;,*?"$]'));
bool _smbDatasetName(Object? value) =>
    _smbText(value, 240) &&
    (value as String)
        .split('/')
        .every(
          (p) =>
              p.isNotEmpty &&
              p != '.' &&
              p != '..' &&
              RegExp(r'^[A-Za-z0-9_.: -]+$').hasMatch(p),
        );
String? _smbRaw(Object? raw) {
  final value = raw is Map
      ? raw['rawvalue'] ?? raw['value'] ?? raw['parsed']
      : raw;
  return value is String
      ? value
      : _smbNumber(value)
      ? '$value'
      : null;
}

Map<String, Object?> _smbMap(Object? raw) {
  var count = 0;
  Object? copy(Object? value, int depth) {
    if (++count > 16384 || depth > 16) _smbInvalid();
    if (value == null || value is bool) return value;
    if (value is String && value.length <= 32768) return value;
    if (value is int &&
        value >= -9007199254740991 &&
        value <= 9007199254740991) {
      return value;
    }
    if (value is List && value.length <= 512) {
      return List<Object?>.unmodifiable(value.map((v) => copy(v, depth + 1)));
    }
    if (value is Map &&
        value.length <= 256 &&
        value.keys.every((k) => _smbText(k, 256))) {
      return Map<String, Object?>.unmodifiable({
        for (final entry in value.entries)
          entry.key as String: copy(entry.value, depth + 1),
      });
    }
    _smbInvalid();
  }

  final result = copy(raw, 0);
  if (result is! Map<String, Object?>) _smbInvalid();
  return result;
}
