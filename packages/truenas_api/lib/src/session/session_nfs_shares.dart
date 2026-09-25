part of 'true_nas_session_repository.dart';

/// Native, bounded NFS export configuration. Never starts/stops a service.
abstract interface class AuthenticatedNfsSharesSession {
  NfsSharesCapabilities get nfsSharesCapabilities;
  Future<NfsShareInventory> loadNfsShares();
  Future<NfsShareReview> reviewNfsShare(NfsShareRequest request);
  Future<NfsShareResult> executeNfsShare(
    NfsShareReview review,
    String confirmation,
  );
}

final class NfsSharesCapabilities {
  const NfsSharesCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.available,
    required this.canCreate,
    required this.canUpdate,
    required this.canDelete,
  });
  const NfsSharesCapabilities.disconnected()
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
  bool allows(NfsShareAction action) =>
      supported &&
      switch (action) {
        NfsShareAction.create => canCreate,
        NfsShareAction.update => canUpdate,
        NfsShareAction.delete => canDelete,
      };
  String? get blockedReason => !connected
      ? 'Connect to inspect NFS shares.'
      : !versionSupported
      ? 'This workspace requires stable TrueNAS 25.10.'
      : !available
      ? 'Public NFS inventory methods are unavailable to this account.'
      : null;
}

final class NfsShareSettings {
  NfsShareSettings({
    required this.path,
    this.comment = '',
    List<String> hosts = const [],
    List<String> networks = const [],
    this.readOnly = false,
    this.enabled = true,
    this.maprootUser,
    this.maprootGroup,
    this.mapallUser,
    this.mapallGroup,
  }) : hosts = List.unmodifiable(hosts),
       networks = List.unmodifiable(networks);
  final String path, comment;
  final List<String> hosts, networks;
  final bool readOnly, enabled;
  final String? maprootUser, maprootGroup, mapallUser, mapallGroup;
  String? get validationError {
    if (!_nfsPath(path) || !_nfsText(comment, 120, empty: true)) {
      return 'Choose an existing dataset root and a comment of at most 120 characters.';
    }
    if (hosts.length > 16 ||
        networks.length > 16 ||
        hosts.toSet().length != hosts.length ||
        networks.toSet().length != networks.length ||
        hosts.any((h) => !_networkIPv4(h)) ||
        networks.any((n) => _nfsCidr(n) == null)) {
      return 'Use up to 16 unique IPv4 hosts and 16 canonical IPv4 CIDR networks. DNS, IPv6, wildcards and netgroups are not supported here.';
    }
    final ranges = networks.map((n) => _nfsCidr(n)!).toList();
    for (var i = 0; i < ranges.length; i++) {
      for (var j = i + 1; j < ranges.length; j++) {
        if (ranges[i].$1 <= ranges[j].$2 && ranges[j].$1 <= ranges[i].$2) {
          return 'Authorized networks must not overlap.';
        }
      }
    }
    if (hosts.any(
      (h) => ranges.any((n) => _nfsIp(h) >= n.$1 && _nfsIp(h) <= n.$2),
    )) {
      return 'List a client either as a host or within a network, not both.';
    }
    for (final value in [maprootUser, maprootGroup, mapallUser, mapallGroup]) {
      if (value != null && value.isNotEmpty && !_nfsIdentityName(value)) {
        return 'Mapping names must be plain local account names.';
      }
    }
    bool has(String? value) => value != null && value.isNotEmpty;
    if (has(maprootGroup) && !has(maprootUser) ||
        has(mapallGroup) && !has(mapallUser) ||
        has(maprootUser) && has(mapallUser)) {
      return 'Choose either maproot or mapall, with a user before an optional group.';
    }
    return null;
  }

  Map<String, Object?> get _wire => {
    'path': path,
    'comment': comment,
    'hosts': hosts,
    'networks': networks,
    'ro': readOnly,
    'enabled': enabled,
    'maproot_user': maprootUser,
    'maproot_group': maprootGroup,
    'mapall_user': mapallUser,
    'mapall_group': mapallGroup,
  };
}

final class NfsShare {
  const NfsShare({
    required this.id,
    required this.settings,
    this.blockedReason,
  });
  final int id;
  final NfsShareSettings settings;
  final String? blockedReason;
  bool get editable => blockedReason == null;
}

final class NfsShareDataset {
  const NfsShareDataset({
    required this.id,
    required this.guid,
    required this.path,
    this.blockedReason,
  });
  final String id, guid, path;
  final String? blockedReason;
  bool get available => blockedReason == null;
}

final class NfsShareInventory {
  NfsShareInventory({
    required List<NfsShare> shares,
    required List<NfsShareDataset> datasets,
    required this.serviceState,
    required this.serviceEnabled,
    required List<String> protocols,
    this.blockedReason,
  }) : shares = List.unmodifiable(shares),
       datasets = List.unmodifiable(datasets),
       protocols = List.unmodifiable(protocols);
  final List<NfsShare> shares;
  final List<NfsShareDataset> datasets;
  final String serviceState;
  final bool serviceEnabled;
  final List<String> protocols;
  final String? blockedReason;
}

enum NfsShareAction { create, update, delete }

final class NfsShareRequest {
  const NfsShareRequest({
    required this.inventory,
    required this.action,
    this.share,
    this.settings,
  });
  final NfsShareInventory inventory;
  final NfsShareAction action;
  final NfsShare? share;
  final NfsShareSettings? settings;
  String get target => action == NfsShareAction.create
      ? settings?.path ?? ''
      : 'NFS #${share?.id}: ${share?.settings.path}';
  String? get validationError {
    if (inventory.blockedReason != null) return inventory.blockedReason;
    if (action == NfsShareAction.create &&
            (share != null || settings == null) ||
        action != NfsShareAction.create &&
            (share == null ||
                !inventory.shares.any((s) => identical(s, share))) ||
        action == NfsShareAction.update && settings == null ||
        action == NfsShareAction.delete && settings != null) {
      return 'Reload and select an exact NFS share action.';
    }
    if (share?.blockedReason != null) return share!.blockedReason;
    final desired = settings ?? share!.settings;
    if (desired.validationError != null) return desired.validationError;
    if (!inventory.datasets.any((d) => d.available && d.path == desired.path)) {
      return 'Only verified existing, unencrypted unmanaged dataset roots are available.';
    }
    if (action == NfsShareAction.update &&
        desired.path != share!.settings.path) {
      return 'Moving an existing export is not supported. Its original path is retained.';
    }
    if (action == NfsShareAction.update &&
        _adminEqual(desired._wire, share!.settings._wire)) {
      return 'Change at least one setting before review.';
    }
    if (action == NfsShareAction.create &&
        inventory.shares.any((s) => s.settings.path == desired.path)) {
      return 'A share already uses this dataset root.';
    }
    return null;
  }
}

final class NfsShareReview {
  NfsShareReview({
    required this.action,
    required this.target,
    required this.identity,
    required List<String> changes,
    required List<String> warnings,
  }) : changes = List.unmodifiable(changes),
       warnings = List.unmodifiable(warnings);
  final NfsShareAction action;
  final String target, identity;
  final List<String> changes, warnings;
}

enum NfsShareOutcome { verified, rejected, unknown }

final class NfsShareResult {
  const NfsShareResult(this.outcome, this.message);
  final NfsShareOutcome outcome;
  final String message;
}

enum NfsSharesExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  stale,
  invalid,
  unavailable,
}

final class NfsSharesException implements Exception {
  const NfsSharesException(this.reason);
  final NfsSharesExceptionReason reason;
  String get userMessage => switch (reason) {
    NfsSharesExceptionReason.notAuthenticated =>
      'Reconnect before inspecting NFS shares.',
    NfsSharesExceptionReason.unsupportedVersion =>
      'NFS management requires stable TrueNAS 25.10.',
    NfsSharesExceptionReason.unavailableMethod =>
      'Required public NFS configuration or safety methods are unavailable.',
    NfsSharesExceptionReason.busy =>
      'Another change or an unresolved NFS operation is in progress.',
    NfsSharesExceptionReason.stale => 'The selected share, dataset, dependency, identity or connection changed. Reload and review again.',
    NfsSharesExceptionReason.invalid =>
      'The NFS settings or required safety proofs could not be verified.',
    NfsSharesExceptionReason.unavailable =>
      'NFS information could not be read safely. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

const _nfsReads = {'sharing.nfs.query', 'nfs.config', 'service.query'};
const _nfsProofMethods = {
  'pool.dataset.query',
  'pool.dataset.attachments',
  'filesystem.stat',
  'filesystem.statfs',
  'filesystem.listdir',
  'failover.licensed',
  'user.get_user_obj',
  'group.get_group_obj',
};
const _nfsDatasetProperties = [
  'guid',
  'creation',
  'readonly',
  'origin',
  'encryption',
  'encryptionroot',
  'keystatus',
  'acltype',
  'aclmode',
  'sharenfs',
];
const _nfsShareFields = {
  'id',
  'path',
  'aliases',
  'comment',
  'networks',
  'hosts',
  'ro',
  'maproot_user',
  'maproot_group',
  'mapall_user',
  'mapall_group',
  'security',
  'enabled',
  'locked',
  'expose_snapshots',
};

const _nfsConfigFields = {
  'id',
  'servers',
  'allow_nonroot',
  'protocols',
  'v4_krb',
  'v4_domain',
  'bindip',
  'mountd_port',
  'rpcstatd_port',
  'rpclockd_port',
  'mountd_log',
  'statd_lockd_log',
  'v4_krb_enabled',
  'userd_manage_gids',
  'keytab_has_nfs_spn',
  'managed_nfsd',
  'rdma',
};

final class _NfsSnapshot {
  const _NfsSnapshot(
    this.inventory,
    this.rawShares,
    this.rows,
    this.environment,
  );
  final NfsShareInventory inventory;
  final List<Map<String, Object?>> rawShares;
  final Map<String, Map<String, Object?>> rows;
  final Object environment;
  Object get fingerprint => [rawShares, rows, environment];
}

final class _NfsPlan {
  const _NfsPlan(this.request, this.snapshot, this.proof, this.payload);
  final NfsShareRequest request;
  final _NfsSnapshot snapshot;
  final Object proof;
  final Map<String, Object?> payload;
}

final class _SessionNfsShares {
  _SessionNfsShares({
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
       _public = {
         for (final name in summary.availableMethodNames)
           if (_nfsPublic(metadata, name)) name,
       };
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherBusy;
  final Duration requestTimeout;
  final bool _version;
  final Set<String> _methods, _public;
  final _issued = <NfsShareInventory, _NfsSnapshot>{};
  final _reviews = <NfsShareReview, _NfsPlan>{};
  bool _reading = false, _sending = false, _unknown = false;
  bool get isBusy => _sending || _unknown;
  NfsSharesCapabilities get capabilities {
    final proof = _public.containsAll(_nfsProofMethods);
    return NfsSharesCapabilities(
      connected: isCurrent(),
      versionSupported: _version,
      available: _public.containsAll(_nfsReads),
      canCreate: proof && _public.contains('sharing.nfs.create'),
      canUpdate: proof && _public.contains('sharing.nfs.update'),
      canDelete: proof && _public.contains('sharing.nfs.delete'),
    );
  }

  void _guard([String? method]) {
    if (!isCurrent()) {
      throw const NfsSharesException(NfsSharesExceptionReason.notAuthenticated);
    }
    if (!_version) {
      throw const NfsSharesException(
        NfsSharesExceptionReason.unsupportedVersion,
      );
    }
    if (!capabilities.available ||
        method != null &&
            (!_public.contains(method) || !_methods.contains(method))) {
      throw const NfsSharesException(
        NfsSharesExceptionReason.unavailableMethod,
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

  Future<T> _read<T>(Future<T> Function() action) async {
    _guard();
    if (_reading || isBusy || isOtherBusy()) {
      throw const NfsSharesException(NfsSharesExceptionReason.busy);
    }
    _reading = true;
    try {
      return await action();
    } on NfsSharesException {
      rethrow;
    } on Object {
      throw const NfsSharesException(NfsSharesExceptionReason.unavailable);
    } finally {
      _reading = false;
    }
  }

  Future<NfsShareInventory> load() => _read(() async {
    _issued.clear();
    _reviews.clear();
    final snapshot = await _snapshot(tolerateProofFailure: true);
    _issued[snapshot.inventory] = snapshot;
    return snapshot.inventory;
  });
  Future<_NfsSnapshot> _snapshot({bool tolerateProofFailure = false}) async {
    final raw = await _call('sharing.nfs.query', [
      [],
      {
        'limit': 257,
        'extra': {'retrieve_locked_info': true},
      },
    ]);
    if (raw is! List || raw.length > 256) _nfsInvalid();
    final ids = <int>{};
    final rawShares = <Map<String, Object?>>[];
    final shares = <NfsShare>[];
    for (final value in raw) {
      if (value is! Map ||
          value.keys.any((k) => !_nfsShareFields.contains(k)) ||
          !_nfsNumber(value['id']) ||
          (value['id'] as int) <= 0 ||
          !ids.add(value['id'] as int)) {
        _nfsInvalid();
      }
      for (final key in _nfsShareFields) {
        if (!value.containsKey(key)) _nfsInvalid();
      }
      for (final key in ['ro', 'enabled', 'expose_snapshots']) {
        if (value[key] is! bool) _nfsInvalid();
      }
      if (value['locked'] != null && value['locked'] is! bool) _nfsInvalid();
      for (final key in [
        'maproot_user',
        'maproot_group',
        'mapall_user',
        'mapall_group',
      ]) {
        if (value[key] != null && !_nfsText(value[key], 120, empty: true)) {
          _nfsInvalid();
        }
      }
      if (!_nfsText(value['path'], 512) ||
          !_nfsText(value['comment'], 120, empty: true)) {
        _nfsInvalid();
      }
      final hosts = _nfsStrings(value['hosts'], 256),
          networks = _nfsStrings(value['networks'], 256),
          aliases = _nfsStrings(value['aliases'], 256),
          security = _nfsStrings(value['security'], 4);
      final settings = NfsShareSettings(
        path: value['path'] as String,
        comment: value['comment'] as String,
        hosts: hosts,
        networks: networks,
        readOnly: value['ro'] as bool,
        enabled: value['enabled'] as bool,
        maprootUser: value['maproot_user'] as String?,
        maprootGroup: value['maproot_group'] as String?,
        mapallUser: value['mapall_user'] as String?,
        mapallGroup: value['mapall_group'] as String?,
      );
      final reason = value['locked'] != false
          ? 'Locked exports or an unknown lock state cannot be managed here.'
          : aliases.isNotEmpty
          ? 'Legacy aliases would be reset by TrueNAS; this export is read-only here.'
          : value['expose_snapshots'] == true
          ? 'Enterprise snapshot exposure is not supported here.'
          : security.isNotEmpty && !_adminEqual(security, ['SYS'])
          ? 'Kerberos/security variants need a dedicated workflow.'
          : settings.validationError;
      shares.add(
        NfsShare(
          id: value['id'] as int,
          settings: settings,
          blockedReason: reason,
        ),
      );
      rawShares.add({
        for (final key in _nfsShareFields) key: _nfsFreeze(value[key]),
      });
    }
    rawShares.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
    shares.sort((a, b) => a.id.compareTo(b.id));
    final config = await _call('nfs.config', []);
    if (config is! Map ||
        config.keys.toSet().difference(_nfsConfigFields).isNotEmpty ||
        !_nfsConfigFields.every(config.containsKey) ||
        !_nfsId(config['id']) ||
        config['servers'] != null &&
            (!_nfsId(config['servers']) ||
                (config['servers'] as int) < 1 ||
                (config['servers'] as int) > 256) ||
        !_nfsText(config['v4_domain'], 256, empty: true) ||
        [
          'allow_nonroot',
          'v4_krb',
          'mountd_log',
          'statd_lockd_log',
          'v4_krb_enabled',
          'userd_manage_gids',
          'keytab_has_nfs_spn',
          'managed_nfsd',
          'rdma',
        ].any((k) => config[k] is! bool) ||
        ['mountd_port', 'rpcstatd_port', 'rpclockd_port'].any(
          (k) =>
              config[k] != null &&
              (!_nfsId(config[k]) ||
                  (config[k] as int) < 1 ||
                  (config[k] as int) > 65535),
        )) {
      _nfsInvalid();
    }
    _nfsStrings(config['bindip'], 128);
    final protocols = _nfsStrings(config['protocols'], 2);
    if (protocols.isEmpty ||
        protocols.any((p) => !{'NFSV3', 'NFSV4'}.contains(p))) {
      _nfsInvalid();
    }
    final services = await _call('service.query', [
      [
        ['service', '=', 'nfs'],
      ],
      {
        'limit': 2,
        'select': ['id', 'service', 'state', 'enable'],
      },
    ]);
    if (services is! List || services.length != 1 || services.single is! Map) {
      _nfsInvalid();
    }
    final service = services.single as Map;
    if (service['service'] != 'nfs' ||
        !_nfsNumber(service['id']) ||
        service['enable'] is! bool ||
        !{
          'RUNNING',
          'STOPPED',
          'CRASHED',
          'UNKNOWN',
        }.contains(service['state'])) {
      _nfsInvalid();
    }
    final rows = <String, Map<String, Object?>>{};
    final datasets = <NfsShareDataset>[];
    String? blocked;
    Object? exports, licensed;
    if (_public.containsAll(_nfsProofMethods)) {
      try {
        final ds = await _call('pool.dataset.query', [
          [
            ['type', '=', 'FILESYSTEM'],
          ],
          {
            'limit': 257,
            'select': [
              'id',
              'type',
              'mountpoint',
              'encrypted',
              'locked',
              ..._nfsDatasetProperties,
              ['user_properties.managedby', 'managedby'],
            ],
            'extra': {
              'flat': true,
              'retrieve_children': false,
              'retrieve_user_props': true,
              'properties': _nfsDatasetProperties,
            },
          },
        ]);
        if (ds is! List || ds.length > 256) _nfsInvalid();
        for (final value in ds) {
          if (value is! Map ||
              !_quotaPath(value['id']) ||
              value['type'] != 'FILESYSTEM' ||
              value['encrypted'] is! bool ||
              value['locked'] is! bool ||
              value['mountpoint'] != null &&
                  !_nfsText(value['mountpoint'], 512)) {
            _nfsInvalid();
          }
          final id = value['id'] as String;
          if (rows.containsKey(id)) _nfsInvalid();
          final row = <String, Object?>{
            'id': id,
            'mountpoint': value['mountpoint'],
            'encrypted': value['encrypted'],
            'locked': value['locked'],
            'managedby': value['managedby'] == null
                ? '-'
                : _nfsRaw(value['managedby']),
          };
          for (final p in _nfsDatasetProperties) {
            row[p] = _nfsRaw(value[p]);
          }
          final guid = row['guid'] as String;
          if (!RegExp(r'^[0-9]{1,20}$').hasMatch(guid) ||
              BigInt.parse(guid) <= BigInt.zero ||
              BigInt.parse(guid) > BigInt.parse('18446744073709551615') ||
              !RegExp(r'^[0-9]{1,16}$').hasMatch(row['creation'] as String) ||
              BigInt.parse(row['creation'] as String) <= BigInt.zero) {
            _nfsInvalid();
          }
          rows[id] = Map.unmodifiable(row);
        }
        for (final row in rows.values) {
          final id = row['id'] as String;
          String? reason = !id.contains('/')
              ? 'Pool roots are protected.'
              : null;
          final parts = id.split('/');
          for (var i = 1; i <= parts.length; i++) {
            final a = rows[parts.take(i).join('/')];
            if (a == null) {
              reason = 'Every filesystem ancestor must be visible.';
              break;
            }
            if (parts[i - 1].startsWith('.') ||
                {
                  'ix-apps',
                  'ix-applications',
                  'ix-virt',
                  'ix-system',
                }.contains(parts[i - 1]) ||
                !{'', '-'}.contains(a['managedby'])) {
              reason = 'System or externally managed datasets are protected.';
            }
            if (a['encrypted'] != false ||
                a['locked'] != false ||
                a['encryption'] != 'off' ||
                !{'', '-', 'none'}.contains(a['encryptionroot']) ||
                !{'', '-', 'none'}.contains(a['origin'])) {
              reason = 'Encrypted, locked or cloned dataset ancestry is not supported.';
            }
            if (a['mountpoint'] != '/mnt/${a['id']}' ||
                a['readonly'] != 'off' ||
                !{'', 'off', '-'}.contains(a['sharenfs'])) {
              reason = 'Dataset mount, readonly or native ZFS export properties are not supported.';
            }
          }
          datasets.add(
            NfsShareDataset(
              id: id,
              guid: row['guid'] as String,
              path: row['mountpoint'] as String? ?? '',
              blockedReason: reason,
            ),
          );
        }
        licensed = await _call('failover.licensed', []);
        if (licensed is! bool) _nfsInvalid();
        if (licensed) {
          blocked = 'HA NFS service transitions require a dedicated workflow.';
        }
        final exportPaths = <Object?>[];
        Map? exportStat;
        for (final exportPath in ['/', '/etc', '/etc/exports.d']) {
          final stat = await _call('filesystem.stat', [exportPath]);
          if (stat is! Map ||
              stat['type'] != 'DIRECTORY' ||
              stat['realpath'] != exportPath ||
              ['inode', 'dev', 'mount_id'].any((k) => !_nfsNumber(stat[k]))) {
            _nfsInvalid();
          }
          exportPaths.add([
            exportPath,
            stat['type'],
            stat['realpath'],
            stat['inode'],
            stat['dev'],
            stat['mount_id'],
            _nfsStrings(stat['attributes'], 32),
          ]);
          exportStat = stat;
        }
        final entries = await _call('filesystem.listdir', [
          '/etc/exports.d',
          [],
          {
            'limit': 1,
            'select': ['name', 'path', 'type'],
          },
        ]);
        if (exportStat == null || entries is! List || entries.length > 1) {
          _nfsInvalid();
        }
        final attrs = _nfsStrings(exportStat['attributes'], 32);
        exports = [exportPaths, entries.isEmpty];
        if (exportStat['type'] != 'DIRECTORY' ||
            exportStat['realpath'] != '/etc/exports.d' ||
            !attrs.contains('IMMUTABLE') ||
            entries.isNotEmpty) {
          blocked = 'NFS export generation can remove manual /etc/exports.d entries and disable ZFS sharenfs. Changes are blocked until the standard empty immutable directory is verified.';
        }
      } on Object {
        if (!tolerateProofFailure) rethrow;
        _guard();
        rows.clear();
        datasets.clear();
        blocked = 'NFS inventory was read, but dataset, dependency or export-directory safety proofs were denied or invalid. Changes are unavailable; no mutation was sent.';
      }
    } else {
      blocked = 'Required public path, dependency or local-identity proofs are unavailable. Inventory is read-only.';
    }
    if (config['v4_krb'] == true ||
        config['v4_krb_enabled'] == true ||
        config['keytab_has_nfs_spn'] == true ||
        config['rdma'] == true) {
      blocked = 'Kerberos-enforced or RDMA NFS configuration requires a dedicated workflow.';
    }
    if (datasets.isNotEmpty) {
      for (var i = 0; i < shares.length; i++) {
        final s = shares[i];
        if (s.editable &&
            !datasets.any((d) => d.available && d.path == s.settings.path)) {
          shares[i] = NfsShare(
            id: s.id,
            settings: s.settings,
            blockedReason: 'This export is not on an admitted existing unencrypted unmanaged dataset root.',
          );
        }
      }
    }
    if (shares.any((s) => !s.editable)) blocked ??= 'At least one existing export uses unsupported settings. Global export reload is blocked until every export can be reviewed.';
    datasets.sort((a, b) => a.id.compareTo(b.id));
    final inventory = NfsShareInventory(
      shares: shares,
      datasets: datasets,
      serviceState: service['state'] as String,
      serviceEnabled: service['enable'] as bool,
      protocols: protocols,
      blockedReason: blocked,
    );
    return _NfsSnapshot(
      inventory,
      List.unmodifiable(rawShares),
      Map.unmodifiable(rows),
      _nfsFreeze([config, service, licensed, exports])!,
    );
  }

  Future<_NfsSnapshot> _fresh(NfsShareInventory inventory) async {
    final old = _issued[inventory];
    if (old == null) {
      throw const NfsSharesException(NfsSharesExceptionReason.stale);
    }
    final fresh = await _snapshot();
    if (!_adminEqual(old.fingerprint, fresh.fingerprint) ||
        fresh.inventory.blockedReason != null) {
      throw const NfsSharesException(NfsSharesExceptionReason.stale);
    }
    return fresh;
  }

  Future<Object> _proof(
    _NfsSnapshot snapshot,
    NfsShareSettings settings, {
    List<NfsShare>? attachmentShares,
  }) async {
    final dataset = snapshot.inventory.datasets
        .where((d) => d.available && d.path == settings.path)
        .singleOrNull;
    if (dataset == null) _nfsInvalid();
    final paths = <Object?>[];
    var path = '';
    for (final p in [
      '',
      ...settings.path.split('/').where((p) => p.isNotEmpty),
    ]) {
      path = p.isEmpty
          ? '/'
          : path == '/'
          ? '/$p'
          : '$path/$p';
      final stat = await _call('filesystem.stat', [path]);
      if (stat is! Map ||
          stat['type'] != 'DIRECTORY' ||
          stat['realpath'] != path ||
          stat['is_ctldir'] != false ||
          stat['is_mountpoint'] is! bool ||
          stat['acl'] is! bool ||
          [
            'uid',
            'gid',
            'mode',
            'dev',
            'inode',
            'mount_id',
          ].any((k) => !_nfsNumber(stat[k]))) {
        _nfsInvalid();
      }
      if (path == settings.path && stat['is_mountpoint'] != true) _nfsInvalid();
      paths.add({
        for (final key in [
          'realpath',
          'type',
          'uid',
          'gid',
          'mode',
          'dev',
          'inode',
          'mount_id',
          'acl',
          'is_mountpoint',
        ])
          key: stat[key],
        'attributes': _nfsStrings(stat['attributes'], 32),
      });
    }
    final mount = await _call('filesystem.statfs', [settings.path]);
    if (mount is! Map ||
        mount['fstype'] != 'zfs' ||
        mount['source'] != dataset.id ||
        mount['dest'] != settings.path ||
        !_nfsText(mount['fsid'], 128)) {
      _nfsInvalid();
    }
    final flags = _nfsStrings(mount['flags'], 128);
    final attachments = await _call('pool.dataset.attachments', [dataset.id]);
    if (attachments is! List || attachments.length > 32) _nfsInvalid();
    final dependencies = <Object?>[];
    var count = 0;
    for (final a in attachments) {
      if (a is! Map ||
          !_nfsText(a['type'], 128) ||
          a['service'] != null && !_nfsText(a['service'], 128)) {
        _nfsInvalid();
      }
      final names = _nfsStrings(a['attachments'], 256);
      count += names.length;
      if (count > 256) _nfsInvalid();
      dependencies.add([a['type'], a['service'], names]);
    }
    final expectedNfs = [
      for (final share in attachmentShares ?? snapshot.inventory.shares)
        if (share.settings.enabled &&
            (share.settings.path == settings.path ||
                share.settings.path.startsWith('${settings.path}/')))
          share.settings.path,
    ]..sort();
    final nfsGroups = dependencies
        .where((row) => (row as List)[0] == 'NFS Share')
        .toList();
    if (nfsGroups.length > 1 ||
        nfsGroups.isNotEmpty && (nfsGroups.single as List)[1] != 'nfs') {
      _nfsInvalid();
    }
    final actualNfs =
        nfsGroups.isEmpty
              ? <String>[]
              : List<String>.from((nfsGroups.single as List)[2] as List)
          ..sort();
    if (!_adminEqual(expectedNfs, actualNfs)) _nfsInvalid();
    final identities = <Object?>[];
    // A reload regenerates every export, so prove mappings for every export,
    // including the old mapping and the requested replacement before dispatch.
    final mappings = [
      ...snapshot.inventory.shares.map((s) => s.settings),
      settings,
    ];
    final lookedUp = <String>{};
    for (final s in mappings) {
      for (final key in [
        'maproot_user',
        'maproot_group',
        'mapall_user',
        'mapall_group',
      ]) {
        final name = s._wire[key] as String?;
        if (name == null || name.isEmpty || !lookedUp.add('$key:$name')) {
          continue;
        }
        if (!_nfsIdentityName(name)) _nfsInvalid();
        final user = key.endsWith('_user');
        final result = await _call(
          user ? 'user.get_user_obj' : 'group.get_group_obj',
          [
            {
              user ? 'username' : 'groupname': name,
              'sid_info': true,
              if (user) 'get_groups': false,
            },
          ],
        );
        final prefix = user ? 'pw' : 'gr';
        if (result is! Map ||
            result['${prefix}_name'] != name ||
            result['source'] != 'LOCAL' ||
            result['local'] != true ||
            !_nfsId(result['${prefix}_${user ? 'uid' : 'gid'}']) ||
            result['${prefix}_${user ? 'uid' : 'gid'}'] == 0 ||
            user && !_nfsId(result['pw_gid']) ||
            !result.containsKey('sid') ||
            result['sid'] != null && !_nfsSid(result['sid'])) {
          _nfsInvalid();
        }
        identities.add([
          key,
          name,
          result['${prefix}_${user ? 'uid' : 'gid'}'],
          if (user) result['pw_gid'],
          result['source'],
          result['local'],
          result['sid'],
        ]);
      }
    }
    return _nfsFreeze([
      paths,
      [mount['fstype'], mount['source'], mount['dest'], mount['fsid'], flags],
      dependencies,
      identities,
    ])!;
  }

  Future<NfsShareReview> review(NfsShareRequest request) => _read(() async {
    _reviews.clear();
    if (!capabilities.allows(request.action)) {
      throw const NfsSharesException(
        NfsSharesExceptionReason.unavailableMethod,
      );
    }
    if (request.validationError != null) _nfsInvalid();
    final desired = request.settings ?? request.share!.settings;
    final fresh = await _fresh(request.inventory);
    final proof = await _proof(fresh, desired);
    await _fresh(request.inventory);
    final payload = <String, Object?>{};
    if (request.action == NfsShareAction.create) {
      payload.addAll(desired._wire);
      payload.addAll({
        'aliases': <String>[],
        'security': ['SYS'],
        'expose_snapshots': false,
      });
    }
    if (request.action == NfsShareAction.update) {
      for (final entry in desired._wire.entries) {
        if (!_adminEqual(
          entry.value,
          request.share!.settings._wire[entry.key],
        )) {
          payload[entry.key] = entry.value;
        }
      }
    }
    final dataset = fresh.inventory.datasets.firstWhere(
      (d) => d.path == desired.path,
    );
    final review = NfsShareReview(
      action: request.action,
      target: request.target,
      identity: '${dataset.id} · GUID ${dataset.guid}',
      changes: request.action == NfsShareAction.delete
          ? [
              'Delete export #${request.share!.id} for ${desired.path}. The dataset and files are not deleted.',
            ]
          : [
              for (final e in payload.entries)
                if (!{
                  'aliases',
                  'security',
                  'expose_snapshots',
                }.contains(e.key))
                  '${e.key}: ${request.action == NfsShareAction.create ? 'new' : _nfsDisplay(request.share!.settings._wire[e.key])} → ${_nfsDisplay(e.value)}',
            ],
      warnings: [
        'TrueNAS saves this configuration and reloads NFS exports globally. Other exports and existing clients can be affected. No service start, stop, forced disconnect or ownership/ACL rewrite is requested.',
        'Quiesce clients and flush pending writes first. Restricting, disabling or deleting an export can reject existing client access and pending I/O; connected-client completion is not proven.',
        'TrueNAS export generation can remove manual /etc/exports.d files and disable their ZFS sharenfs properties. This review requires that directory to be empty and immutable, and selected dataset ancestry to have sharenfs off.',
        if (desired.hosts.isEmpty && desired.networks.isEmpty)
          'Both client lists are empty: all clients are authorized by this export. AUTH_SYS is not encryption or strong client authentication.'
        else
          'Authorized IPv4 hosts and networks are alternatives (OR), not intersecting conditions. AUTH_SYS trusts client-supplied identity.',
        if (desired.mapallUser?.isNotEmpty == true)
          'Mapall maps every client user to ${desired.mapallUser}; ordinary client identities no longer select the file owner identity.'
        else if (desired.maprootUser?.isNotEmpty == true)
          'Maproot maps client root to ${desired.maprootUser}. Only local nonzero account IDs are admitted.',
        if (fresh.inventory.serviceState != 'RUNNING')
          'NFS is ${fresh.inventory.serviceState}. Saving configuration does not start the service or verify client access.',
        'No atomic compare-and-swap API exists. Keep other administrators idle until this single-use operation finishes. Readback verifies configuration, not export connectivity or durability of client writes.',
      ],
    );
    _reviews[review] = _NfsPlan(
      request,
      fresh,
      proof,
      Map.unmodifiable(payload),
    );
    return review;
  });
  Future<NfsShareResult> execute(
    NfsShareReview review,
    String confirmation,
  ) async {
    _guard();
    if (_reading || isBusy || isOtherBusy()) {
      throw const NfsSharesException(NfsSharesExceptionReason.busy);
    }
    final plan = _reviews.remove(review);
    if (plan == null || confirmation != review.target) {
      throw const NfsSharesException(NfsSharesExceptionReason.stale);
    }
    _sending = true;
    var sent = false;
    try {
      final request = plan.request,
          desired = plan.request.settings ?? plan.request.share!.settings;
      if (!capabilities.allows(request.action)) {
        throw const NfsSharesException(
          NfsSharesExceptionReason.unavailableMethod,
        );
      }
      final before = await _fresh(request.inventory);
      if (!_adminEqual(await _proof(before, desired), plan.proof)) {
        throw const NfsSharesException(NfsSharesExceptionReason.stale);
      }
      await _fresh(request.inventory);
      if (isOtherBusy()) {
        throw const NfsSharesException(NfsSharesExceptionReason.busy);
      }
      final method = 'sharing.nfs.${request.action.name}';
      _guard(method);
      sent = true;
      final receipt = await _call(method, switch (request.action) {
        NfsShareAction.create => [plan.payload],
        NfsShareAction.update => [request.share!.id, plan.payload],
        NfsShareAction.delete => [request.share!.id],
      });
      final expected = [
        for (final row in before.rawShares) Map<String, Object?>.from(row),
      ];
      if (request.action == NfsShareAction.delete) {
        if (receipt != true) return _uncertain();
        expected.removeWhere((r) => r['id'] == request.share!.id);
      } else if (request.action == NfsShareAction.update) {
        if (receipt is! Map || receipt['id'] != request.share!.id) {
          return _uncertain();
        }
        expected
            .firstWhere((r) => r['id'] == request.share!.id)
            .addAll(plan.payload);
        if (!_adminEqual(
          receipt,
          expected.firstWhere((r) => r['id'] == request.share!.id),
        )) {
          return _uncertain();
        }
      } else {
        if (receipt is! Map ||
            !_nfsNumber(receipt['id']) ||
            (receipt['id'] as int) <= 0 ||
            expected.any((r) => r['id'] == receipt['id'])) {
          return _uncertain();
        }
        expected.add({'id': receipt['id'], ...plan.payload, 'locked': false});
        if (!_adminEqual(receipt, expected.last)) return _uncertain();
      }
      expected.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
      final after = await _snapshot();
      if (!_adminEqual(expected, after.rawShares) ||
          !_adminEqual(before.rows, after.rows) ||
          !_adminEqual(before.environment, after.environment)) {
        return _uncertain();
      }
      // Attachments intentionally change for create/delete; compare exact path
      // identity independently, and verify all mapping identities again.
      // Re-read the same union of original and desired mappings, even when a
      // mapping was removed by this operation. Never substitute fresh IDs.
      final afterProof = await _proof(
        before,
        desired,
        attachmentShares: after.inventory.shares,
      );
      final oldProof = plan.proof as List, newProof = afterProof as List;
      if (!_adminEqual(oldProof[0], newProof[0]) ||
          !_adminEqual(oldProof[1], newProof[1]) ||
          !_adminEqual(oldProof[3], newProof[3]) ||
          !_nfsDependenciesMatch(
            oldProof[2] as List,
            newProof[2] as List,
            request,
          )) {
        return _uncertain();
      }
      final finalState = await _snapshot();
      if (!_adminEqual(after.fingerprint, finalState.fingerprint)) {
        return _uncertain();
      }
      _issued.clear();
      _reviews.clear();
      return const NfsShareResult(
        NfsShareOutcome.verified,
        'The exact NFS export configuration was independently read back. Client connectivity, pending writes and service health were not proven.',
      );
    } on Object {
      return sent
          ? _uncertain()
          : const NfsShareResult(
              NfsShareOutcome.rejected,
              'Preflight changed or could not be verified. No NFS mutation was sent; reload and review again.',
            );
    } finally {
      _sending = false;
    }
  }

  NfsShareResult _uncertain() {
    _unknown = true;
    _issued.clear();
    _reviews.clear();
    return const NfsShareResult(
      NfsShareOutcome.unknown,
      'NFS configuration or export reload may have changed. Inspect the original server and clients, then reconnect. Do not retry or replay this request.',
    );
  }
}

bool _nfsPublic(Object? metadata, String name) {
  if (metadata is! Map || metadata[name] is! Map) return false;
  final m = metadata[name] as Map;
  return m['job'] == false &&
      m['no_auth_required'] == false &&
      m['uploadable'] == false &&
      m['downloadable'] == false &&
      m['private'] != true &&
      m['_private'] != true;
}

bool _nfsText(Object? value, int max, {bool empty = false}) =>
    value is String &&
    (empty || value.isNotEmpty) &&
    value.length <= max &&
    !RegExp(r'[\x00-\x1f\x7f\u200b-\u200f\u202a-\u202e\u2066-\u2069\ufeff]')
        .hasMatch(value);
bool _nfsPath(String value) =>
    _nfsText(value, 512) &&
    value.startsWith('/mnt/') &&
    RegExp(r'^/mnt/[A-Za-z0-9_][A-Za-z0-9_./ -]*$').hasMatch(value) &&
    !value.endsWith('/') &&
    !value.contains('//') &&
    !value.split('/').any((p) => p == '.' || p == '..' || p == '.zfs');
bool _nfsIdentityName(String value) =>
    RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]{0,63}\$?$').hasMatch(value);
bool _nfsNumber(Object? value) =>
    value is int && value >= 0 && value <= 9007199254740991;
bool _nfsId(Object? value) => value is int && value >= 0 && value < 4294967295;
bool _nfsSid(Object? value) {
  if (value is! String ||
      !RegExp(r'^S-1-[0-9]{1,15}(?:-[0-9]{1,10}){1,15}$').hasMatch(value)) {
    return false;
  }
  final parts = value.split('-').skip(2).map(BigInt.parse).toList();
  return parts.first <= BigInt.parse('281474976710655') &&
      parts.skip(1).every((n) => n <= BigInt.parse('4294967295'));
}

int _nfsIp(String value) =>
    value.split('.').map(int.parse).fold(0, (n, v) => n * 256 + v);
(int, int)? _nfsCidr(String value) {
  final parts = value.split('/');
  if (parts.length != 2 ||
      !_networkIPv4(parts[0]) ||
      !RegExp(r'^(?:[1-9]|[12][0-9]|3[0-2])$').hasMatch(parts[1])) {
    return null;
  }
  final prefix = int.parse(parts[1]), ip = _nfsIp(parts[0]);
  final size = math.pow(2, 32 - prefix).toInt();
  if (ip % size != 0 || ip + size - 1 >= 3758096384) return null;
  return (ip, ip + size - 1);
}

List<String> _nfsStrings(Object? value, int max) {
  if (value is! List ||
      value.length > max ||
      value.any((s) => !_nfsText(s, 512)) ||
      value.toSet().length != value.length) {
    _nfsInvalid();
  }
  return List.unmodifiable(value.cast<String>());
}

String _nfsRaw(Object? value) {
  if (value is! Map || !_nfsText(value['rawvalue'], 2048, empty: true)) {
    _nfsInvalid();
  }
  return value['rawvalue'] as String;
}

Object? _nfsFreeze(Object? value, [int depth = 0]) {
  if (depth > 12) _nfsInvalid();
  if (value == null || value is bool || value is num && value.isFinite) {
    return value;
  }
  if (value is String && _nfsText(value, 4096, empty: true)) return value;
  if (value is List && value.length <= 1024) {
    return List<Object?>.unmodifiable(
      value.map((v) => _nfsFreeze(v, depth + 1)),
    );
  }
  if (value is Map &&
      value.length <= 128 &&
      value.keys.every((k) => _nfsText(k, 128))) {
    return Map<String, Object?>.unmodifiable({
      for (final entry in value.entries)
        (entry.key as String): _nfsFreeze(entry.value, depth + 1),
    });
  }
  _nfsInvalid();
}

String _nfsDisplay(Object? value) => value == null
    ? 'None'
    : value is List
    ? (value.isEmpty ? 'None' : value.join(', '))
    : value.toString();
Never _nfsInvalid() =>
    throw const NfsSharesException(NfsSharesExceptionReason.invalid);

bool _nfsDependenciesMatch(List before, List after, NfsShareRequest request) {
  // Only the exact enabled NFS path entry may appear/disappear. Every other
  // service attachment remains identical. The delegate label is NFS Share.
  List<Object?> withoutNfs(List rows) => [
    for (final row in rows)
      if ((row as List)[0] != 'NFS Share') row,
  ];
  if (!_adminEqual(withoutNfs(before), withoutNfs(after))) return false;
  List<String>? nfs(List rows) {
    final matches = rows.where((r) => (r as List)[0] == 'NFS Share').toList();
    if (matches.isEmpty) return [];
    if (matches.length != 1 || (matches.single as List)[1] != 'nfs') {
      return null;
    }
    return List<String>.from((matches.single as List)[2] as List);
  }

  final old = nfs(before), actual = nfs(after);
  if (old == null || actual == null) return false;
  final expected = List<String>.from(old),
      s = request.settings ?? request.share!.settings;
  final previouslyEnabled =
      request.action != NfsShareAction.create &&
      request.share!.settings.enabled;
  final nowEnabled = request.action != NfsShareAction.delete && s.enabled;
  if (previouslyEnabled && !nowEnabled) {
    if (!expected.remove(s.path)) return false;
  }
  if (!previouslyEnabled && nowEnabled) {
    if (expected.contains(s.path)) return false;
    expected.add(s.path);
  }
  expected.sort();
  actual.sort();
  return _adminEqual(expected, actual);
}
