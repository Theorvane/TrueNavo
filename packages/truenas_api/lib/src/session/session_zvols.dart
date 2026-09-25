part of 'true_nas_session_repository.dart';

/// Typed storage changes; no arbitrary dataset dictionaries cross this API.
abstract interface class AuthenticatedZvolsSession {
  ZvolCapabilities get zvolCapabilities;
  Future<ZvolInventory> loadZvols();
  Future<String> loadZvolRecommendedBlockSize(ZvolParent parent);
  Future<ZvolReview> reviewZvolCreate(ZvolCreate request);
  Future<ZvolReview> reviewZvolUpdate(ZvolUpdate request);
  Future<ZvolReview> reviewZvolDelete(ZvolEntry volume);
  Future<ZvolResult> executeZvolReview(ZvolReview review, String confirmation);
}

const zvolBlockSizes = <String, int>{
  '512B': 512,
  '1K': 1024,
  '2K': 2048,
  '4K': 4096,
  '8K': 8192,
  '16K': 16384,
  '32K': 32768,
  '64K': 65536,
  '128K': 131072,
};
const zvolCompressionChoices = ['OFF', 'LZ4', 'ZSTD'];
const zvolSyncChoices = ['STANDARD', 'ALWAYS'];
const _zvolDependencyMethods = {
  'pool.dataset.attachments',
  'vm.device.query',
  'iscsi.extent.query',
  'nvmet.namespace.query',
};

final class ZvolCapabilities {
  ZvolCapabilities({
    required this.connected,
    required this.versionSupported,
    required Set<String> methods,
  }) : methods = Set.unmodifiable(methods);
  const ZvolCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      methods = const {};
  final bool connected, versionSupported;
  final Set<String> methods;
  bool get supported =>
      connected && versionSupported && methods.contains('pool.dataset.query');
  bool canCall(String method) => supported && methods.contains(method);
  bool get canCreate =>
      canCall('pool.dataset.create') &&
      canCall('pool.dataset.recommended_zvol_blocksize') &&
      methods.containsAll(_zvolDependencyMethods);
  bool get canUpdate =>
      canCall('pool.dataset.update') &&
      methods.containsAll(_zvolDependencyMethods);
  bool get canDelete =>
      canCall('pool.dataset.delete') &&
      canCall('pool.snapshot.query') &&
      methods.containsAll(_zvolDependencyMethods);
  String? get blockedReason => !connected
      ? 'Connect to a server to manage Zvols.'
      : !versionSupported
      ? 'This workspace requires stable TrueNAS 25.10.'
      : !supported
      ? 'Dataset inventory is unavailable to this account.'
      : null;
}

final class ZvolParent {
  const ZvolParent({
    required this.id,
    required this.guid,
    required this.availableBytes,
    this.blockedReason,
  });
  final String id, guid;
  final int availableBytes;
  final String? blockedReason;
  bool get available => blockedReason == null;
}

final class ZvolEntry {
  const ZvolEntry({
    required this.id,
    required this.guid,
    required this.sizeBytes,
    required this.blockSizeBytes,
    required this.usedBytes,
    required this.referencedBytes,
    required this.reservationBytes,
    required this.refreservationBytes,
    required this.compression,
    required this.sync,
    required this.readonly,
    this.blockedReason,
  });
  final String id, guid, compression, sync;
  final int sizeBytes,
      blockSizeBytes,
      usedBytes,
      referencedBytes,
      reservationBytes,
      refreservationBytes;
  final bool readonly;
  final String? blockedReason;
  bool get editable => blockedReason == null;
  String get provisioning => refreservationBytes == 0
      ? 'Thin'
      : refreservationBytes >= sizeBytes
      ? 'Reserved'
      : 'Custom reservation';
}

final class ZvolInventory {
  ZvolInventory({
    required List<ZvolParent> parents,
    required List<ZvolEntry> volumes,
  }) : parents = List.unmodifiable(parents),
       volumes = List.unmodifiable(volumes);
  final List<ZvolParent> parents;
  final List<ZvolEntry> volumes;
}

final class ZvolCreate {
  const ZvolCreate({
    required this.parent,
    required this.name,
    required this.sizeBytes,
    this.blockSize = '16K',
    this.thin = false,
    this.compression = 'LZ4',
    this.sync = 'STANDARD',
  });
  final ZvolParent parent;
  final String name, blockSize, compression, sync;
  final int sizeBytes;
  final bool thin;
  String get target => '${parent.id}/$name';
  String? get validationError {
    if (!parent.available) return parent.blockedReason;
    if (!RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.-]{0,62}$').hasMatch(name) ||
        name == '.' ||
        name == '..' ||
        target.length > 200 ||
        const {
          '.system',
          'ix-apps',
          'ix-applications',
          '.ix-virt',
        }.contains(name)) {
      return 'Enter a simple new child name, at most 63 characters.';
    }
    if (!_zvolSize(sizeBytes, zvolBlockSizes[blockSize])) {
      return 'Size must be positive exact bytes and a multiple of the selected block size.';
    }
    if (!zvolCompressionChoices.contains(compression) ||
        !zvolSyncChoices.contains(sync)) {
      return 'Choose a supported compression and synchronous-write policy.';
    }
    if (!_zvolCapacity(sizeBytes, parent.availableBytes, 0)) {
      return 'Volume size cannot exceed 80% of currently available parent space. Force-size is never used.';
    }
    return null;
  }
}

final class ZvolUpdate {
  const ZvolUpdate({
    required this.volume,
    this.sizeBytes,
    this.compression,
    this.sync,
    this.readonly,
  });
  final ZvolEntry volume;
  final int? sizeBytes;
  final String? compression, sync;
  final bool? readonly;
  String? get validationError {
    if (!volume.editable) return volume.blockedReason;
    if (sizeBytes == null &&
        compression == null &&
        sync == null &&
        readonly == null) {
      return 'Select at least one changed setting.';
    }
    if (sizeBytes != null &&
        (!_zvolSize(sizeBytes!, volume.blockSizeBytes) ||
            sizeBytes! <= volume.sizeBytes)) {
      return 'Zvols can only grow, in exact multiples of their existing block size.';
    }
    if (sizeBytes != null && volume.refreservationBytes > 0) {
      return 'Reserved-volume growth requires server-calculated allocation overhead. Only zero-refreservation volumes can grow here; existing reservations are never reduced.';
    }
    if (compression != null &&
            (!zvolCompressionChoices.contains(compression) ||
                compression == volume.compression) ||
        sync != null &&
            (!zvolSyncChoices.contains(sync) || sync == volume.sync) ||
        readonly == volume.readonly) {
      return 'Choose supported values that differ from the current settings.';
    }
    return null;
  }
}

enum ZvolAction { create, update, delete }

final class ZvolReview {
  ZvolReview({
    required this.action,
    required this.target,
    required this.identity,
    required List<String> changes,
    required List<String> warnings,
  }) : changes = List.unmodifiable(changes),
       warnings = List.unmodifiable(warnings);
  final ZvolAction action;
  final String target, identity;
  final List<String> changes, warnings;
}

enum ZvolOutcome { verified, rejected, unknown }

final class ZvolResult {
  const ZvolResult(this.outcome, this.message);
  final ZvolOutcome outcome;
  final String message;
}

enum ZvolExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  stale,
  invalid,
  dependency,
  unavailable,
}

final class ZvolException implements Exception {
  const ZvolException(this.reason);
  final ZvolExceptionReason reason;
  String get userMessage => switch (reason) {
    ZvolExceptionReason.notAuthenticated => 'Reconnect before managing Zvols.',
    ZvolExceptionReason.unsupportedVersion =>
      'This storage adapter requires stable TrueNAS 25.10.',
    ZvolExceptionReason.unavailableMethod =>
      'Required storage or dependency-read methods are unavailable.',
    ZvolExceptionReason.busy =>
      'Another storage operation or an unresolved change is in progress.',
    ZvolExceptionReason.stale => 'The target, parent, settings or session changed. Reload and review again.',
    ZvolExceptionReason.invalid =>
      'The request, storage identity or capacity could not be verified.',
    ZvolExceptionReason.dependency => 'Detach all VM, iSCSI, NVMe and service uses first. Deletion also requires no snapshots.',
    ZvolExceptionReason.unavailable =>
      'Storage could not be read safely. Retry the read explicitly.',
  };
}

const _zvolProperties = [
  'guid',
  'creation',
  'used',
  'referenced',
  'available',
  'volsize',
  'volblocksize',
  'reservation',
  'refreservation',
  'compression',
  'sync',
  'readonly',
  'origin',
  'mountpoint',
  'encryption',
  'encryptionroot',
  'keystatus',
  'snapdev',
];

final class _ZvolRow {
  _ZvolRow(
    this.raw,
    this.id,
    this.guid,
    this.filesystem,
    this.used,
    this.available,
    this.config,
    this.identity,
    this.blockedReason,
  );
  final Map raw;
  final String id, guid, config, identity;
  final bool filesystem;
  final int used, available;
  final String? blockedReason;
  String? get parent =>
      id.contains('/') ? id.substring(0, id.lastIndexOf('/')) : null;
  static _ZvolRow parse(Object? value) {
    if (value is! Map ||
        !_zvolId(value['id']) ||
        !const {'FILESYSTEM', 'VOLUME'}.contains(value['type']) ||
        value['encrypted'] is! bool ||
        value['locked'] is! bool) {
      _zvolInvalid();
    }
    final id = value['id'] as String;
    final guid = _zvolRaw(value['guid']);
    if (!RegExp(r'^[0-9]{1,20}$').hasMatch(guid) ||
        BigInt.parse(guid) > BigInt.parse('18446744073709551615') ||
        BigInt.parse(guid) == BigInt.zero) {
      _zvolInvalid();
    }
    final creation = _zvolBytes(value['creation']);
    final filesystem = value['type'] == 'FILESYSTEM';
    final readonly = _zvolRaw(value['readonly']).toUpperCase();
    if (!const {'ON', 'OFF'}.contains(readonly)) _zvolInvalid();
    final settings = <String, Object?>{};
    for (final key in [
      'readonly',
      'compression',
      'sync',
      'reservation',
      'refreservation',
      'origin',
      if (!filesystem) ...['volsize', 'volblocksize', 'snapdev'],
    ]) {
      final prop = value[key];
      if (prop is! Map ||
          prop['source'] is! String ||
          !const {
                'LOCAL',
                'DEFAULT',
                'INHERITED',
                'RECEIVED',
              }.contains(prop['source']) &&
              !(key == 'origin' && prop['source'] == 'NONE')) {
        _zvolInvalid();
      }
      final source = prop['source_info'];
      if (source != null &&
          source != '' &&
          (source is! String || !_datasetText(source, 200))) {
        _zvolInvalid();
      }
      if (prop['source'] == 'INHERITED' &&
          (source is! String || !id.startsWith('$source/'))) {
        _zvolInvalid();
      }
      settings[key] = [_zvolRaw(prop), prop['source'], source];
    }
    final managed = value['managedby'] == null
        ? ''
        : _zvolRaw(value['managedby']);
    final blocked = value['encrypted'] == true || value['locked'] == true
        ? 'Encrypted or locked storage requires its dedicated workflow.'
        : id
                  .split('/')
                  .any(
                    (s) => const {
                      '.system',
                      'ix-apps',
                      'ix-applications',
                      '.ix-virt',
                      'boot-pool',
                      'freenas-boot',
                    }.contains(s),
                  ) ||
              !const {'', '-'}.contains(managed)
        ? 'System-managed storage is not editable here.'
        : filesystem && value['mountpoint'] != '/mnt/$id'
        ? 'A standard mounted parent filesystem is required.'
        : filesystem && readonly != 'OFF'
        ? 'The parent filesystem is read-only.'
        : !filesystem && value['mountpoint'] != null
        ? 'Unexpected volume mountpoint.'
        : !filesystem &&
              !const {'', '-', 'none'}.contains(_zvolRaw(value['origin']))
        ? 'Cloned volumes require a separate dependency workflow.'
        : null;
    final identity = _appsFingerprint([
      id,
      guid,
      creation,
      value['type'],
      value['mountpoint'],
      value['encrypted'],
      value['locked'],
      managed,
    ]);
    final row = _ZvolRow(
      value,
      id,
      guid,
      filesystem,
      _zvolBytes(value['used']),
      _zvolBytes(value['available']),
      _appsFingerprint([identity, settings]),
      identity,
      blocked,
    );
    _zvolBytes(value['reservation']);
    _zvolBytes(value['refreservation']);
    _zvolBytes(value['referenced']);
    if (!filesystem) row.entry();
    return row;
  }

  ZvolParent parentView() => ZvolParent(
    id: id,
    guid: guid,
    availableBytes: available,
    blockedReason: blockedReason,
  );
  ZvolEntry entry({String? parentBlock}) {
    final size = _zvolBytes(raw['volsize']),
        block = _zvolBytes(raw['volblocksize']);
    if (!_zvolSize(size, block) || !zvolBlockSizes.values.contains(block)) {
      _zvolInvalid();
    }
    return ZvolEntry(
      id: id,
      guid: guid,
      sizeBytes: size,
      blockSizeBytes: block,
      usedBytes: used,
      referencedBytes: _zvolBytes(raw['referenced']),
      reservationBytes: _zvolBytes(raw['reservation']),
      refreservationBytes: _zvolBytes(raw['refreservation']),
      compression: _zvolRaw(raw['compression']).toUpperCase(),
      sync: _zvolRaw(raw['sync']).toUpperCase(),
      readonly: _zvolRaw(raw['readonly']).toUpperCase() == 'ON',
      blockedReason: blockedReason ?? parentBlock,
    );
  }
}

final class _ZvolPlan {
  _ZvolPlan(
    this.action,
    this.target,
    this.rows,
    this.arguments, {
    this.create,
    this.update,
    this.recommended,
  });
  final ZvolAction action;
  final String target;
  final Map<String, _ZvolRow> rows;
  final List<Object?> arguments;
  final ZvolCreate? create;
  final ZvolUpdate? update;
  final String? recommended;
  String get method => switch (action) {
    ZvolAction.create => 'pool.dataset.create',
    ZvolAction.update => 'pool.dataset.update',
    ZvolAction.delete => 'pool.dataset.delete',
  };
}

final class _SessionZvols {
  _SessionZvols({
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
  final Set<String> methods;
  final bool versionSupported;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherBusy;
  final Duration requestTimeout;
  var _loading = false, _submitting = false, _unknown = false;
  bool get isBusy => _submitting || _unknown;
  final Map<Object, Map<String, _ZvolRow>> _inventoryHandles = {};
  final Map<ZvolReview, _ZvolPlan> _reviews = {};
  ZvolCapabilities get capabilities => ZvolCapabilities(
    connected: isCurrent(),
    versionSupported: versionSupported,
    methods: methods,
  );
  void _guard(String method) {
    if (!isCurrent()) {
      throw const ZvolException(ZvolExceptionReason.notAuthenticated);
    }
    if (!versionSupported) {
      throw const ZvolException(ZvolExceptionReason.unsupportedVersion);
    }
    if (!methods.contains(method)) {
      throw const ZvolException(ZvolExceptionReason.unavailableMethod);
    }
  }

  Future<Object?> _call(String method, List<Object?> params) async {
    _guard(method);
    final result = await client
        .call(method, id: nextId(), params: params)
        .timeout(requestTimeout);
    _guard(method);
    return result;
  }

  Future<T> _read<T>(Future<T> Function() action) async {
    _guard('pool.dataset.query');
    if (_loading || _submitting) {
      throw const ZvolException(ZvolExceptionReason.busy);
    }
    _loading = true;
    try {
      return await action();
    } on ZvolException {
      rethrow;
    } on Object {
      throw const ZvolException(ZvolExceptionReason.unavailable);
    } finally {
      _loading = false;
    }
  }

  Future<Map<String, _ZvolRow>> _rows() async {
    final raw = await _call('pool.dataset.query', [
      [
        [
          'type',
          'in',
          ['FILESYSTEM', 'VOLUME'],
        ],
      ],
      {
        'limit': 1025,
        'select': [
          'id',
          'type',
          'encrypted',
          'locked',
          ..._zvolProperties,
          ['user_properties.managedby', 'managedby'],
        ],
        'extra': {
          'flat': true,
          'retrieve_children': false,
          'retrieve_user_props': true,
          'properties': _zvolProperties,
        },
      },
    ]);
    if (raw is! List || raw.length > 1024) _zvolInvalid();
    final rows = <String, _ZvolRow>{};
    for (final item in raw) {
      final row = _ZvolRow.parse(item);
      if (rows.containsKey(row.id)) _zvolInvalid();
      rows[row.id] = row;
    }
    return rows;
  }

  String? _parentsBlock(Map<String, _ZvolRow> rows, String id) {
    final parts = id.split('/');
    for (var i = 1; i < parts.length; i++) {
      final row = rows[parts.take(i).join('/')];
      if (row == null || !row.filesystem) {
        return 'All parent filesystem identities must be visible.';
      }
      if (row.blockedReason != null) return row.blockedReason;
    }
    return null;
  }

  Future<ZvolInventory> inventory() => _read(() async {
    final rows = await _rows();
    _inventoryHandles.clear();
    _reviews.clear();
    final parents = <ZvolParent>[], volumes = <ZvolEntry>[];
    for (final row in rows.values) {
      if (row.filesystem) {
        final item = ZvolParent(
          id: row.id,
          guid: row.guid,
          availableBytes: row.available,
          blockedReason: row.blockedReason ?? _parentsBlock(rows, row.id),
        );
        parents.add(item);
        _inventoryHandles[item] = rows;
      } else {
        final item = row.entry(parentBlock: _parentsBlock(rows, row.id));
        volumes.add(item);
        _inventoryHandles[item] = rows;
      }
    }
    parents.sort((a, b) => a.id.compareTo(b.id));
    volumes.sort((a, b) => a.id.compareTo(b.id));
    return ZvolInventory(parents: parents, volumes: volumes);
  });
  bool _same(
    Map<String, _ZvolRow> a,
    Map<String, _ZvolRow> b,
    String target, {
    bool includeTarget = true,
  }) {
    final parts = target.split('/');
    for (var i = 1; i <= parts.length; i++) {
      if (i == parts.length && !includeTarget) continue;
      final id = parts.take(i).join('/');
      if (a[id]?.config != b[id]?.config || a[id] == null && b[id] == null) {
        return false;
      }
    }
    return true;
  }

  Future<Map<String, _ZvolRow>> _fresh(
    Object handle,
    String target, {
    bool create = false,
  }) async {
    final baseline = _inventoryHandles[handle];
    if (baseline == null) throw const ZvolException(ZvolExceptionReason.stale);
    final rows = await _rows();
    if (!_same(baseline, rows, target, includeTarget: !create) ||
        create && rows.containsKey(target)) {
      throw const ZvolException(ZvolExceptionReason.stale);
    }
    if (_parentsBlock(rows, target) != null) {
      throw const ZvolException(ZvolExceptionReason.invalid);
    }
    return rows;
  }

  Future<void> _dependencies(
    String id, {
    required bool exists,
    bool deleting = false,
  }) async {
    for (final method in _zvolDependencyMethods) {
      _guard(method);
    }
    if (exists) {
      final attachments = await _call('pool.dataset.attachments', [id]);
      if (attachments is! List || attachments.isNotEmpty) {
        throw const ZvolException(ZvolExceptionReason.dependency);
      }
    }
    final paths = {
      '/dev/zvol/$id',
      '/dev/zvol/${id.replaceAll(' ', '+')}',
      'zvol/$id',
      'zvol/${id.replaceAll(' ', '+')}',
    };
    for (final method in [
      'vm.device.query',
      'iscsi.extent.query',
      'nvmet.namespace.query',
    ]) {
      final vm = method == 'vm.device.query';
      final raw = await _call(method, [
        vm
            ? [
                [
                  'attributes.dtype',
                  'in',
                  ['DISK', 'RAW'],
                ],
              ]
            : [],
        {
          'limit': 1025,
          'select': vm
              ? ['id', 'attributes']
              : method == 'iscsi.extent.query'
              ? ['id', 'type', 'disk', 'path']
              : ['id', 'device_type', 'device_path'],
        },
      ]);
      if (raw is! List || raw.length > 1024) _zvolInvalid();
      final ids = <int>{};
      for (final item in raw) {
        if (item is! Map ||
            !_zvolInt(item['id']) ||
            !ids.add(item['id'] as int)) {
          _zvolInvalid();
        }
        Object? path;
        if (vm) {
          if (item['attributes'] is! Map ||
              !const {
                'DISK',
                'RAW',
              }.contains((item['attributes'] as Map)['dtype'])) {
            _zvolInvalid();
          }
          path = (item['attributes'] as Map)['path'];
        } else if (method == 'iscsi.extent.query') {
          if (!const {'DISK', 'FILE'}.contains(item['type'])) _zvolInvalid();
          path = item[item['type'] == 'DISK' ? 'disk' : 'path'];
        } else {
          if (!const {'ZVOL', 'FILE'}.contains(item['device_type'])) {
            _zvolInvalid();
          }
          path = item['device_path'];
        }
        if (!_datasetText(path, 2048)) _zvolInvalid();
        if (paths.contains(path)) {
          throw const ZvolException(ZvolExceptionReason.dependency);
        }
      }
    }
    if (deleting) {
      final raw = await _call('pool.snapshot.query', [
        [
          ['dataset', '=', id],
        ],
        {
          'limit': 1,
          'select': ['id'],
        },
      ]);
      if (raw is! List || raw.isNotEmpty) {
        throw const ZvolException(ZvolExceptionReason.dependency);
      }
    }
  }

  Future<String> _recommend(String parent) async {
    final raw = await _call('pool.dataset.recommended_zvol_blocksize', [
      parent.split('/').first,
    ]);
    if (raw is! String || !zvolBlockSizes.containsKey(raw)) _zvolInvalid();
    return raw;
  }

  Future<String> recommend(ZvolParent parent) => _read(() async {
    final rows = await _fresh(parent, parent.id);
    final row = rows[parent.id]!;
    if (!row.filesystem || row.blockedReason != null) _zvolInvalid();
    return _recommend(parent.id);
  });

  ZvolReview _issue(
    _ZvolPlan plan,
    List<String> changes,
    List<String> warnings,
  ) {
    final review = ZvolReview(
      action: plan.action,
      target: plan.target,
      identity: plan.action == ZvolAction.create
          ? 'New volume; parent GUID ${plan.rows[plan.create!.parent.id]!.guid}'
          : plan.rows[plan.target]!.guid,
      changes: changes,
      warnings: [
        ...warnings,
        'This is a single-use review. Do not edit this storage from another client concurrently; the public API has no atomic compare-and-change token.',
      ],
    );
    if (_reviews.length >= 32) _reviews.remove(_reviews.keys.first);
    _reviews[review] = plan;
    return review;
  }

  Future<ZvolReview> reviewCreate(ZvolCreate request) => _read(() async {
    if (!capabilities.canCreate) {
      throw const ZvolException(ZvolExceptionReason.unavailableMethod);
    }
    if (request.validationError != null) _zvolInvalid();
    final rows = await _fresh(request.parent, request.target, create: true);
    final fresh = rows[request.parent.id]!;
    if (fresh.blockedReason != null ||
        !_zvolCapacity(request.sizeBytes, fresh.available, 0)) {
      _zvolInvalid();
    }
    final recommended = await _recommend(request.parent.id);
    // Keep below-recommendation special topologies out of this bounded wizard.
    if (zvolBlockSizes[request.blockSize]! < zvolBlockSizes[recommended]!) {
      _zvolInvalid();
    }
    await _dependencies(request.target, exists: false);
    final args = <Object?>[
      {
        'name': request.target,
        'type': 'VOLUME',
        'volsize': request.sizeBytes,
        'volblocksize': request.blockSize,
        'sparse': request.thin,
        'compression': request.compression,
        'sync': request.sync,
        'readonly': 'OFF',
        'snapdev': 'HIDDEN',
        'share_type': 'GENERIC',
        'force_size': false,
        'create_ancestors': false,
        'encryption': false,
        'inherit_encryption': true,
      },
    ];
    return _issue(
      _ZvolPlan(
        ZvolAction.create,
        request.target,
        rows,
        args,
        create: request,
        recommended: recommended,
      ),
      [
        'Logical size: ${request.sizeBytes} bytes',
        'Block size: ${request.blockSize}; server recommendation: $recommended',
        'Provisioning: ${request.thin ? 'thin, no full reservation' : 'reserved, with server-calculated metadata overhead'}',
        'Compression: ${request.compression}; sync: ${request.sync}',
        'New volume is writable; snapshots remain hidden.',
      ],
      [
        'Creates only a block device, not a filesystem, share, VM or partition.',
        if (request.thin) 'Thin provisioning does not reserve the logical size. Pool exhaustion can fail guest writes and cause data loss.',
        'Block size cannot be changed later without recreating the volume. No forced oversizing or new encryption keys are requested.',
      ],
    );
  });
  Future<ZvolReview> reviewUpdate(ZvolUpdate request) => _read(() async {
    if (!capabilities.canUpdate) {
      throw const ZvolException(ZvolExceptionReason.unavailableMethod);
    }
    if (request.validationError != null) _zvolInvalid();
    final rows = await _fresh(request.volume, request.volume.id);
    final row = rows[request.volume.id]!;
    final patch = _updatePatch(request, row, rows[row.parent]!);
    await _dependencies(row.id, exists: true);
    return _issue(
      _ZvolPlan(ZvolAction.update, row.id, rows, [
        row.id,
        patch,
      ], update: request),
      [
        for (final e in patch.entries)
          '${e.key}: ${_zvolRaw(row.raw[e.key])} → ${e.value}',
      ],
      [
        'All configured VM, iSCSI, NVMe and service attachments must be removed first, including disabled consumers.',
        if (request.sizeBytes != null) 'Only the block device grows. Guest partition/filesystem expansion is a separate operation. Shrinking is never requested.',
        if (request.readonly == true) 'Enables read-only storage. Future writes fail until this is reversed.',
        if (request.readonly == false) 'Enables writes to this volume.',
        'Unselected settings, existing data, snapshots, encryption and block size are preserved.',
      ],
    );
  });
  Map<String, Object?> _updatePatch(
    ZvolUpdate request,
    _ZvolRow row,
    _ZvolRow parent,
  ) {
    if (row.blockedReason != null || parent.blockedReason != null) {
      _zvolInvalid();
    }
    final patch = <String, Object?>{};
    if (request.sizeBytes != null) {
      if (!_zvolCapacity(request.sizeBytes!, parent.available, row.used)) {
        _zvolInvalid();
      }
      patch['volsize'] = request.sizeBytes;
      if (request.volume.refreservationBytes != 0) _zvolInvalid();
    }
    if (request.compression != null) patch['compression'] = request.compression;
    if (request.sync != null) patch['sync'] = request.sync;
    if (request.readonly != null) {
      patch['readonly'] = request.readonly! ? 'ON' : 'OFF';
    }
    return patch;
  }

  Future<ZvolReview> reviewDelete(ZvolEntry volume) => _read(() async {
    if (!capabilities.canDelete) {
      throw const ZvolException(ZvolExceptionReason.unavailableMethod);
    }
    if (!volume.editable) _zvolInvalid();
    final rows = await _fresh(volume, volume.id);
    if (rows[volume.id]!.blockedReason != null) _zvolInvalid();
    await _dependencies(volume.id, exists: true, deleting: true);
    return _issue(
      _ZvolPlan(ZvolAction.delete, volume.id, rows, [
        volume.id,
        {'recursive': false, 'force': false},
      ]),
      [
        'Permanently destroy ${volume.id}',
        'Logical device size: ${volume.sizeBytes} bytes',
        'No snapshots or configured consumers are permitted.',
      ],
      [
        'All data in this virtual disk is permanently lost. Backups and recovery are not performed by this operation.',
        'TrueNAS deletion can remove newly attached service definitions if another administrator races this review. Keep all other clients idle; no force or recursive flags are used.',
      ],
    );
  });
  Future<ZvolResult> execute(ZvolReview review, String confirmation) async {
    _guard('pool.dataset.query');
    if (isBusy || _loading || isOtherBusy()) {
      throw const ZvolException(ZvolExceptionReason.busy);
    }
    final plan = _reviews.remove(review);
    if (plan == null || confirmation != review.target) {
      throw const ZvolException(ZvolExceptionReason.stale);
    }
    _submitting = true;
    var sent = false;
    try {
      _guard(plan.method);
      var rows = await _rows();
      final creating = plan.action == ZvolAction.create;
      if (!_same(plan.rows, rows, plan.target, includeTarget: !creating) ||
          creating && rows.containsKey(plan.target) ||
          _parentsBlock(rows, plan.target) != null) {
        throw const ZvolException(ZvolExceptionReason.stale);
      }
      if (creating) {
        final r = plan.create!;
        if (!_zvolCapacity(r.sizeBytes, rows[r.parent.id]!.available, 0) ||
            await _recommend(r.parent.id) != plan.recommended) {
          throw const ZvolException(ZvolExceptionReason.stale);
        }
      } else if (plan.update != null) {
        _updatePatch(
          plan.update!,
          rows[plan.target]!,
          rows[rows[plan.target]!.parent]!,
        );
      }
      await _dependencies(
        plan.target,
        exists: !creating,
        deleting: plan.action == ZvolAction.delete,
      );
      final latest = await _rows();
      if (!_same(rows, latest, plan.target, includeTarget: !creating) ||
          creating && latest.containsKey(plan.target)) {
        throw const ZvolException(ZvolExceptionReason.stale);
      }
      rows = latest;
      if (creating &&
          !_zvolCapacity(
            plan.create!.sizeBytes,
            rows[plan.create!.parent.id]!.available,
            0,
          )) {
        _zvolInvalid();
      }
      if (plan.update != null) {
        _updatePatch(
          plan.update!,
          rows[plan.target]!,
          rows[rows[plan.target]!.parent]!,
        );
      }
      _guard(plan.method);
      if (isOtherBusy()) throw const ZvolException(ZvolExceptionReason.busy);
      sent = true;
      final receipt = await _call(plan.method, plan.arguments);
      final after = await _rows();
      if (!_same(rows, after, plan.target, includeTarget: false)) {
        return _uncertain();
      }
      final actual = after[plan.target];
      if (plan.action == ZvolAction.delete) {
        if (receipt != true || actual != null) return _uncertain();
      } else {
        if (receipt is! Map ||
            receipt['id'] != plan.target ||
            actual == null ||
            actual.filesystem ||
            receipt['type'] != 'VOLUME' ||
            (receipt.containsKey('guid') &&
                _zvolRaw(receipt['guid']) != actual.guid) ||
            actual.blockedReason != null) {
          return _uncertain();
        }
        if (creating) {
          final r = plan.create!, v = actual.entry();
          if (v.sizeBytes != r.sizeBytes ||
              v.blockSizeBytes != zvolBlockSizes[r.blockSize] ||
              v.compression != r.compression ||
              v.sync != r.sync ||
              v.readonly ||
              _zvolRaw(actual.raw['snapdev']).toUpperCase() != 'HIDDEN' ||
              (r.thin
                  ? v.refreservationBytes != 0
                  : v.refreservationBytes < v.sizeBytes)) {
            return _uncertain();
          }
        } else {
          final original = rows[plan.target]!;
          if (actual.identity != original.identity) return _uncertain();
          final patch = plan.arguments[1] as Map;
          for (final key in [
            'volsize',
            'volblocksize',
            'reservation',
            'refreservation',
            'compression',
            'sync',
            'readonly',
            'origin',
            'snapdev',
          ]) {
            if (patch.containsKey(key)) {
              if (_zvolRaw(actual.raw[key]).toUpperCase() !=
                  patch[key].toString().toUpperCase()) {
                return _uncertain();
              }
            } else if (!_adminEqual(original.raw[key], actual.raw[key])) {
              return _uncertain();
            }
          }
        }
      }
      _inventoryHandles.clear();
      _reviews.clear();
      return const ZvolResult(
        ZvolOutcome.verified,
        'The requested storage result was independently read back.',
      );
    } on Object {
      return sent
          ? _uncertain()
          : const ZvolResult(
              ZvolOutcome.rejected,
              'Preflight failed or storage changed. No mutation was sent; reload and review again.',
            );
    } finally {
      _submitting = false;
    }
  }

  ZvolResult _uncertain() {
    _unknown = true;
    _reviews.clear();
    _inventoryHandles.clear();
    return const ZvolResult(
      ZvolOutcome.unknown,
      'Storage may have changed, but the result could not be verified. Do not retry. Inspect the original server and reconnect.',
    );
  }
}

Never _zvolInvalid() => throw const ZvolException(ZvolExceptionReason.invalid);
bool _zvolInt(Object? value) =>
    value is int && value >= 0 && value <= 9007199254740991;
bool _zvolSize(int size, int? block) =>
    _zvolInt(size) &&
    size > 0 &&
    block != null &&
    block > 0 &&
    size % block == 0;
bool _zvolCapacity(int size, int available, int used) =>
    BigInt.from(size) * BigInt.from(5) <=
    (BigInt.from(available) + BigInt.from(used)) * BigInt.from(4);
bool _zvolId(Object? value) =>
    _datasetText(value, 200) &&
    RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.:/ -]*$').hasMatch(value as String) &&
    !value.contains('//') &&
    !value.endsWith('/') &&
    !value.split('/').any((p) => p == '.' || p == '..');
String _zvolRaw(Object? value) {
  if (value is! Map ||
      value['rawvalue'] is! String ||
      (value['rawvalue'] as String).length > 2048) {
    _zvolInvalid();
  }
  return value['rawvalue'] as String;
}

int _zvolBytes(Object? value) {
  final result = int.tryParse(_zvolRaw(value));
  if (!_zvolInt(result)) _zvolInvalid();
  return result!;
}
