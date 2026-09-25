part of 'true_nas_session_repository.dart';

/// Bounded USER/GROUP byte/object quotas, never arbitrary quota dictionaries.
abstract interface class AuthenticatedQuotasSession {
  QuotaCapabilities get quotaCapabilities;
  Future<List<QuotaDataset>> loadQuotaDatasets();
  Future<QuotaInventory> loadQuotas(QuotaDataset dataset);
  Future<QuotaIdentity> resolveQuotaIdentity(
    QuotaInventory inventory,
    QuotaKind kind,
    int id,
  );
  Future<QuotaReview> reviewQuotaChange(QuotaChange change);
  Future<QuotaResult> executeQuotaReview(
    QuotaReview review,
    String confirmation,
  );
}

enum QuotaKind {
  user,
  group;

  String get label => this == user ? 'User' : 'Group';
  String get wire => this == user ? 'USER' : 'GROUP';
}

final class QuotaCapabilities {
  const QuotaCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.available,
    required this.canSetUser,
    required this.canSetGroup,
  });
  const QuotaCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      canSetUser = false,
      canSetGroup = false;
  final bool connected, versionSupported, available, canSetUser, canSetGroup;
  bool get supported => connected && versionSupported && available;
  bool canSet(QuotaKind kind) =>
      supported && (kind == QuotaKind.user ? canSetUser : canSetGroup);
  String? get blockedReason => !connected
      ? 'Connect to a server to inspect quotas.'
      : !versionSupported
      ? 'This quota workspace requires stable TrueNAS 25.10.'
      : !available
      ? 'Dataset quota reads are unavailable to this account.'
      : null;
}

final class QuotaDataset {
  const QuotaDataset({
    required this.id,
    required this.guid,
    this.blockedReason,
  });
  final String id, guid;
  final String? blockedReason;
  bool get editable => blockedReason == null;
}

final class QuotaEntry {
  const QuotaEntry({
    required this.kind,
    required this.id,
    this.name,
    required this.byteLimit,
    required this.objectLimit,
    this.usedBytes,
    this.usedObjects,
  });
  final QuotaKind kind;
  final int id, byteLimit, objectLimit;
  final String? name;
  final int? usedBytes, usedObjects;
}

final class QuotaInventory {
  QuotaInventory({required this.dataset, required List<QuotaEntry> entries})
    : entries = List.unmodifiable(entries);
  final QuotaDataset dataset;
  final List<QuotaEntry> entries;
  QuotaEntry? entry(QuotaKind kind, int id) {
    for (final entry in entries) {
      if (entry.kind == kind && entry.id == id) return entry;
    }
    return null;
  }
}

final class QuotaIdentity {
  const QuotaIdentity({
    required this.kind,
    required this.id,
    required this.name,
    required this.source,
    required this.local,
    this.sid,
  });
  final QuotaKind kind;
  final int id;
  final String name, source;
  final bool local;
  final String? sid;
  String get displayLabel =>
      '${kind.label} $name (${kind == QuotaKind.user ? 'UID' : 'GID'} $id)';
}

final class QuotaChange {
  const QuotaChange({
    required this.inventory,
    required this.identity,
    this.byteLimit,
    this.objectLimit,
  });
  final QuotaInventory inventory;
  final QuotaIdentity identity;
  // Null means unchanged; zero explicitly removes that one limit.
  final int? byteLimit, objectLimit;
  String? get validationError {
    if (!inventory.dataset.editable) return inventory.dataset.blockedReason;
    if (!_quotaId(identity.id) || identity.id == 0) {
      return 'Resolve a non-root numeric UID or GID before reviewing a quota.';
    }
    if (byteLimit == null && objectLimit == null ||
        byteLimit != null && !_quotaNumber(byteLimit) ||
        objectLimit != null && !_quotaNumber(objectLimit)) {
      return 'Choose at least one exact nonnegative byte or object limit. Zero removes that limit.';
    }
    final current = inventory.entry(identity.kind, identity.id);
    if (byteLimit != null && byteLimit == (current?.byteLimit ?? 0) ||
        objectLimit != null && objectLimit == (current?.objectLimit ?? 0)) {
      return 'Send only limits that differ from their current values.';
    }
    return null;
  }
}

final class QuotaReview {
  QuotaReview({
    required this.dataset,
    required this.identity,
    required this.confirmation,
    required List<String> changes,
    required List<String> warnings,
  }) : changes = List.unmodifiable(changes),
       warnings = List.unmodifiable(warnings);
  final QuotaDataset dataset;
  final QuotaIdentity identity;
  final String confirmation;
  final List<String> changes, warnings;
  String get target => dataset.id;
}

enum QuotaOutcome { verified, rejected, unknown }

final class QuotaResult {
  const QuotaResult(this.outcome, this.message);
  final QuotaOutcome outcome;
  final String message;
}

enum QuotaExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  stale,
  invalid,
  dependency,
  unavailable,
}

final class QuotaException implements Exception {
  const QuotaException(this.reason);
  final QuotaExceptionReason reason;
  String get userMessage => switch (reason) {
    QuotaExceptionReason.notAuthenticated =>
      'Reconnect before inspecting quotas.',
    QuotaExceptionReason.unsupportedVersion =>
      'Quotas require stable TrueNAS 25.10.',
    QuotaExceptionReason.unavailableMethod =>
      'Required quota or identity/dependency methods are unavailable.',
    QuotaExceptionReason.busy =>
      'Another server change or an unresolved quota operation is in progress.',
    QuotaExceptionReason.stale => 'The dataset, identity, quota settings or session changed. Reload and review again.',
    QuotaExceptionReason.invalid =>
      'Quota values, identity or dataset safety could not be verified.',
    QuotaExceptionReason.dependency =>
      'Dataset service dependencies changed or could not be verified.',
    QuotaExceptionReason.unavailable => 'Quota information could not be read safely. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

const _quotaProperties = [
  'guid',
  'creation',
  'mountpoint',
  'readonly',
  'quota',
  'refquota',
  'reservation',
  'refreservation',
  'origin',
  'encryption',
  'encryptionroot',
  'keystatus',
];

final class _QuotaDatasetRow {
  const _QuotaDatasetRow(this.id, this.guid, this.fingerprint, this.blocked);
  final String id, guid, fingerprint;
  final String? blocked;
  static _QuotaDatasetRow parse(Object? raw) {
    if (raw is! Map ||
        !_quotaPath(raw['id']) ||
        raw['type'] != 'FILESYSTEM' ||
        raw['encrypted'] is! bool ||
        raw['locked'] is! bool) {
      _quotaInvalid();
    }
    final id = raw['id'] as String;
    final guid = _quotaRaw(raw['guid']);
    if (!RegExp(r'^[0-9]{1,20}$').hasMatch(guid) ||
        BigInt.parse(guid) <= BigInt.zero ||
        BigInt.parse(guid) > BigInt.parse('18446744073709551615')) {
      _quotaInvalid();
    }
    final creation = _quotaRawNumber(raw['creation']);
    final readonly = _quotaRaw(raw['readonly']);
    if (!{'on', 'off'}.contains(readonly)) _quotaInvalid();
    final settings = <Object?>[];
    for (final key in [
      'readonly',
      'quota',
      'refquota',
      'reservation',
      'refreservation',
      'origin',
    ]) {
      final prop = raw[key];
      if (prop is! Map ||
          !{
                'LOCAL',
                'DEFAULT',
                'INHERITED',
                'RECEIVED',
              }.contains(prop['source']) &&
              !(key == 'origin' && prop['source'] == 'NONE')) {
        _quotaInvalid();
      }
      final info = prop['source_info'];
      if (info != null && info != '' && !_quotaText(info, 200)) _quotaInvalid();
      if (prop['source'] == 'INHERITED' &&
          (info is! String || !id.startsWith('$info/'))) {
        _quotaInvalid();
      }
      settings.add([key, _quotaRaw(prop), prop['source'], info]);
      if (key != 'readonly' && key != 'origin') _quotaRawNumber(prop);
    }
    final managed = raw['managedby'] == null ? '' : _quotaRaw(raw['managedby']);
    final origin = _quotaRaw(raw['origin']);
    final blocked = raw['encrypted'] == true || raw['locked'] == true
        ? 'Encrypted or locked datasets are outside this quota workflow.'
        : id
                  .split('/')
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
              !{'', '-'}.contains(managed)
        ? 'System-managed datasets are not editable here.'
        : raw['mountpoint'] != '/mnt/$id'
        ? 'A standard mounted filesystem root is required.'
        : readonly != 'off'
        ? 'Read-only filesystem roots are not editable here.'
        : !{'', '-', 'none'}.contains(origin)
        ? 'Cloned filesystems require their dedicated dependency workflow.'
        : null;
    return _QuotaDatasetRow(
      id,
      guid,
      jsonEncode([
        id,
        guid,
        creation,
        raw['type'],
        raw['mountpoint'],
        raw['encrypted'],
        raw['locked'],
        managed,
        settings,
      ]),
      blocked,
    );
  }
}

final class _QuotaSnapshot {
  const _QuotaSnapshot(this.rows, this.entries);
  final Map<String, _QuotaDatasetRow> rows;
  final List<QuotaEntry> entries;
}

final class _QuotaIdentityLease {
  const _QuotaIdentityLease(this.inventory, this.fingerprint);
  final QuotaInventory inventory;
  final String fingerprint;
}

final class _QuotaPlan {
  const _QuotaPlan(
    this.change,
    this.snapshot,
    this.identity,
    this.dependencies,
  );
  final QuotaChange change;
  final _QuotaSnapshot snapshot;
  final String identity, dependencies;
}

final class _SessionQuotas {
  _SessionQuotas({
    required this.client,
    required ServerSummary summary,
    required Object? metadata,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherBusy,
    required this.requestTimeout,
  }) : _versionSupported =
           _managementVersion(summary.version) == _ManagementVersion.v2510,
       _methods = Set.unmodifiable(summary.availableMethodNames),
       _synchronousSet =
           metadata is Map &&
           metadata['pool.dataset.set_quota'] is Map &&
           (metadata['pool.dataset.set_quota'] as Map)['job'] == false &&
           (metadata['pool.dataset.set_quota'] as Map)['no_auth_required'] ==
               false &&
           (metadata['pool.dataset.set_quota'] as Map)['uploadable'] == false &&
           (metadata['pool.dataset.set_quota'] as Map)['downloadable'] ==
               false &&
           (metadata['pool.dataset.set_quota'] as Map)['private'] != true &&
           (metadata['pool.dataset.set_quota'] as Map)['_private'] != true;
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherBusy;
  final Duration requestTimeout;
  final bool _versionSupported, _synchronousSet;
  final Set<String> _methods;
  final _datasets = <QuotaDataset, Map<String, _QuotaDatasetRow>>{};
  final _inventories = <QuotaInventory, _QuotaSnapshot>{};
  final _identities = <QuotaIdentity, _QuotaIdentityLease>{};
  final _reviews = <QuotaReview, _QuotaPlan>{};
  bool _reading = false, _submitting = false, _unknown = false;
  bool get isBusy => _submitting || _unknown;
  QuotaCapabilities get capabilities {
    final set =
        _synchronousSet &&
        _methods.containsAll({
          'pool.dataset.set_quota',
          'pool.dataset.attachments',
        });
    return QuotaCapabilities(
      connected: isCurrent(),
      versionSupported: _versionSupported,
      available: _methods.containsAll({
        'pool.dataset.query',
        'pool.dataset.get_quota',
      }),
      canSetUser: set && _methods.contains('user.get_user_obj'),
      canSetGroup: set && _methods.contains('group.get_group_obj'),
    );
  }

  void _guard([String? method]) {
    if (!isCurrent()) {
      throw const QuotaException(QuotaExceptionReason.notAuthenticated);
    }
    if (!_versionSupported) {
      throw const QuotaException(QuotaExceptionReason.unsupportedVersion);
    }
    if (!capabilities.available ||
        method != null && !_methods.contains(method)) {
      throw const QuotaException(QuotaExceptionReason.unavailableMethod);
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
    _guard();
    if (_reading || _submitting || isOtherBusy()) {
      throw const QuotaException(QuotaExceptionReason.busy);
    }
    _reading = true;
    try {
      return await action();
    } on QuotaException {
      rethrow;
    } on Object {
      throw const QuotaException(QuotaExceptionReason.unavailable);
    } finally {
      _reading = false;
    }
  }

  Future<Map<String, _QuotaDatasetRow>> _rows() async {
    final raw = await _call('pool.dataset.query', [
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
          ..._quotaProperties,
          ['user_properties.managedby', 'managedby'],
        ],
        'extra': {
          'flat': true,
          'retrieve_children': false,
          'retrieve_user_props': true,
          'properties': _quotaProperties,
        },
      },
    ]);
    if (raw is! List || raw.length > 256) _quotaInvalid();
    final rows = <String, _QuotaDatasetRow>{};
    for (final value in raw) {
      final row = _QuotaDatasetRow.parse(value);
      if (rows.containsKey(row.id)) _quotaInvalid();
      rows[row.id] = row;
    }
    return rows;
  }

  String? _blocked(Map<String, _QuotaDatasetRow> rows, String id) {
    final parts = id.split('/');
    for (var i = 1; i <= parts.length; i++) {
      final row = rows[parts.take(i).join('/')];
      if (row == null) return 'Every filesystem ancestor must be visible.';
      if (row.blocked != null) return row.blocked;
    }
    return null;
  }

  bool _sameRows(
    Map<String, _QuotaDatasetRow> a,
    Map<String, _QuotaDatasetRow> b,
    String id,
  ) {
    final parts = id.split('/');
    for (var i = 1; i <= parts.length; i++) {
      final name = parts.take(i).join('/');
      if (a[name] == null ||
          b[name] == null ||
          a[name]!.fingerprint != b[name]!.fingerprint) {
        return false;
      }
    }
    return _blocked(b, id) == null;
  }

  Future<List<QuotaDataset>> datasets() => _read(() async {
    _datasets.clear();
    _inventories.clear();
    _identities.clear();
    _reviews.clear();
    final rows = await _rows();
    final result = [
      for (final row in rows.values)
        QuotaDataset(
          id: row.id,
          guid: row.guid,
          blockedReason: _blocked(rows, row.id),
        ),
    ]..sort((a, b) => a.id.compareTo(b.id));
    for (final dataset in result) {
      _datasets[dataset] = rows;
    }
    return List.unmodifiable(result);
  });
  Future<List<QuotaEntry>> _entries(String dataset) async {
    final entries = <QuotaEntry>[];
    for (final kind in QuotaKind.values) {
      // No select: omitted quota fields have meaning and must stay omitted.
      final raw = await _call('pool.dataset.get_quota', [
        dataset,
        kind.wire,
        [],
        {'limit': 513},
      ]);
      if (raw is! List || raw.length > 512) _quotaInvalid();
      final ids = <int>{};
      for (final row in raw) {
        if (row is! Map ||
            row['quota_type'] != kind.wire ||
            !_quotaId(row['id']) ||
            !ids.add(row['id'] as int) ||
            !row.containsKey('name') ||
            row['name'] != null && !_quotaText(row['name'], 512)) {
          _quotaInvalid();
        }
        int? value(String key) {
          if (!row.containsKey(key)) return null;
          if (!_quotaNumber(row[key])) _quotaInvalid();
          return row[key] as int;
        }

        entries.add(
          QuotaEntry(
            kind: kind,
            id: row['id'] as int,
            name: row['name'] as String?,
            byteLimit: value('quota') ?? 0,
            objectLimit: value('obj_quota') ?? 0,
            usedBytes: value('used_bytes'),
            usedObjects: value('obj_used'),
          ),
        );
      }
    }
    entries.sort(
      (a, b) => a.kind == b.kind
          ? a.id.compareTo(b.id)
          : a.kind.index.compareTo(b.kind.index),
    );
    return List.unmodifiable(entries);
  }

  Future<QuotaInventory> load(QuotaDataset dataset) => _read(() async {
    final baseline = _datasets[dataset];
    if (baseline == null) {
      throw const QuotaException(QuotaExceptionReason.stale);
    }
    final rows = await _rows();
    if (!_sameRows(baseline, rows, dataset.id)) {
      throw const QuotaException(QuotaExceptionReason.stale);
    }
    final entries = await _entries(dataset.id);
    final after = await _rows();
    if (!_sameRows(rows, after, dataset.id)) {
      throw const QuotaException(QuotaExceptionReason.stale);
    }
    _inventories.clear();
    _identities.clear();
    _reviews.clear();
    final inventory = QuotaInventory(dataset: dataset, entries: entries);
    _inventories[inventory] = _QuotaSnapshot(after, entries);
    return inventory;
  });
  Future<_QuotaSnapshot> _fresh(QuotaInventory inventory) async {
    final old = _inventories[inventory];
    if (old == null) throw const QuotaException(QuotaExceptionReason.stale);
    final rows = await _rows();
    if (!_sameRows(old.rows, rows, inventory.dataset.id)) {
      throw const QuotaException(QuotaExceptionReason.stale);
    }
    final entries = await _entries(inventory.dataset.id);
    if (_quotaLimits(old.entries) != _quotaLimits(entries)) {
      throw const QuotaException(QuotaExceptionReason.stale);
    }
    final after = await _rows();
    if (!_sameRows(rows, after, inventory.dataset.id)) {
      throw const QuotaException(QuotaExceptionReason.stale);
    }
    return _QuotaSnapshot(after, entries);
  }

  Future<(QuotaIdentity, String)> _identity(QuotaKind kind, int id) async {
    if (!_quotaId(id) || id == 0) _quotaInvalid();
    final user = kind == QuotaKind.user;
    final raw = await _call(
      user ? 'user.get_user_obj' : 'group.get_group_obj',
      [
        {
          user ? 'uid' : 'gid': id,
          'sid_info': true,
          if (user) 'get_groups': false,
        },
      ],
    );
    final prefix = user ? 'pw' : 'gr';
    if (raw is! Map ||
        !_quotaId(raw['${prefix}_${user ? 'uid' : 'gid'}']) ||
        raw['${prefix}_${user ? 'uid' : 'gid'}'] != id ||
        !_quotaText(raw['${prefix}_name'], 512) ||
        !{'LOCAL', 'ACTIVEDIRECTORY', 'LDAP'}.contains(raw['source']) ||
        raw['local'] is! bool ||
        raw['local'] != (raw['source'] == 'LOCAL') ||
        !raw.containsKey('sid') ||
        raw['sid'] != null && !_quotaText(raw['sid'], 256) ||
        user && !_quotaId(raw['pw_gid'])) {
      _quotaInvalid();
    }
    final identity = QuotaIdentity(
      kind: kind,
      id: id,
      name: raw['${prefix}_name'] as String,
      source: raw['source'] as String,
      local: raw['local'] as bool,
      sid: raw['sid'] as String?,
    );
    return (
      identity,
      jsonEncode([
        kind.wire,
        id,
        identity.name,
        identity.source,
        identity.local,
        identity.sid,
        if (user) raw['pw_gid'],
      ]),
    );
  }

  Future<QuotaIdentity> resolve(
    QuotaInventory inventory,
    QuotaKind kind,
    int id,
  ) => _read(() async {
    await _fresh(inventory);
    final (identity, fingerprint) = await _identity(kind, id);
    if (_identities.length >= 32) _identities.remove(_identities.keys.first);
    _identities[identity] = _QuotaIdentityLease(inventory, fingerprint);
    return identity;
  });
  Future<(String, int)> _attachments(String dataset) async {
    final raw = await _call('pool.dataset.attachments', [dataset]);
    if (raw is! List || raw.length > 32) {
      throw const QuotaException(QuotaExceptionReason.dependency);
    }
    final normalized = <String>[];
    var count = 0;
    for (final row in raw) {
      if (row is! Map ||
          !_quotaText(row['type'], 128) ||
          row['service'] != null && !_quotaText(row['service'], 128) ||
          row['attachments'] is! List) {
        throw const QuotaException(QuotaExceptionReason.dependency);
      }
      final attachments = row['attachments'] as List;
      count += attachments.length;
      if (count > 512 || attachments.any((a) => !_quotaText(a, 2048))) {
        throw const QuotaException(QuotaExceptionReason.dependency);
      }
      final names = attachments.cast<String>().toList()..sort();
      if (names.toSet().length != names.length) {
        throw const QuotaException(QuotaExceptionReason.dependency);
      }
      normalized.add(jsonEncode([row['type'], row['service'], names]));
    }
    normalized.sort();
    if (normalized.toSet().length != normalized.length) {
      throw const QuotaException(QuotaExceptionReason.dependency);
    }
    return (jsonEncode(normalized), count);
  }

  Future<QuotaReview> review(QuotaChange change) => _read(() async {
    if (!capabilities.canSet(change.identity.kind)) {
      throw const QuotaException(QuotaExceptionReason.unavailableMethod);
    }
    if (change.validationError != null) _quotaInvalid();
    final lease = _identities[change.identity];
    if (lease == null || !identical(lease.inventory, change.inventory)) {
      throw const QuotaException(QuotaExceptionReason.stale);
    }
    final snapshot = await _fresh(change.inventory);
    final (_, identity) = await _identity(
      change.identity.kind,
      change.identity.id,
    );
    if (identity != lease.fingerprint) {
      throw const QuotaException(QuotaExceptionReason.stale);
    }
    final (dependencies, count) = await _attachments(
      change.inventory.dataset.id,
    );
    final current = change.inventory.entry(
      change.identity.kind,
      change.identity.id,
    );
    String limit(int value, String unit) =>
        value == 0 ? 'Unlimited (remove this limit)' : '$value $unit';
    final review = QuotaReview(
      dataset: change.inventory.dataset,
      identity: change.identity,
      confirmation:
          '${change.inventory.dataset.id} ${change.identity.kind.wire} ${change.identity.id}',
      changes: [
        if (change.byteLimit != null)
          'Bytes: ${limit(current?.byteLimit ?? 0, 'bytes')} → ${limit(change.byteLimit!, 'bytes')}',
        if (change.objectLimit != null)
          'Objects: ${limit(current?.objectLimit ?? 0, 'objects')} → ${limit(change.objectLimit!, 'objects')}',
      ],
      warnings: [
        'Limits apply to ownership on this dataset only, not recursively to child datasets. No files, owners, ACLs, shares or accounts are changed.',
        'A finite limit can reject new writes or object creation, including for connected clients. Lowering below current usage does not delete existing data.',
        if (change.byteLimit != null &&
                change.byteLimit! > 0 &&
                current?.usedBytes == null ||
            change.objectLimit != null &&
                change.objectLimit! > 0 &&
                current?.usedObjects == null)
          'Relevant usage is not reported. Enforcement may immediately reject new writes or object creation.',
        if (change.byteLimit != null &&
                change.byteLimit! > 0 &&
                current?.usedBytes != null &&
                change.byteLimit! < current!.usedBytes! ||
            change.objectLimit != null &&
                change.objectLimit! > 0 &&
                current?.usedObjects != null &&
                change.objectLimit! < current!.usedObjects!)
          'A selected limit is below the currently reported usage; new writes or object creation can fail immediately.',
        'Reported usage can lag. Byte and object limits are separate; zero removes only the selected limit and does not reserve space.',
        '$count enabled service attachments were reported. Existing and unreported/disabled consumers may be affected; no service is stopped.',
        'The public API has no atomic identity/limit comparison. Keep other administrators idle during this single-use review.',
      ],
    );
    _reviews.clear();
    _reviews[review] = _QuotaPlan(change, snapshot, identity, dependencies);
    return review;
  });
  Future<QuotaResult> execute(QuotaReview review, String confirmation) async {
    _guard();
    if (_reading || isBusy || isOtherBusy()) {
      throw const QuotaException(QuotaExceptionReason.busy);
    }
    final plan = _reviews.remove(review);
    if (plan == null || confirmation != review.confirmation) {
      throw const QuotaException(QuotaExceptionReason.stale);
    }
    _submitting = true;
    var sent = false;
    try {
      final change = plan.change;
      if (!capabilities.canSet(change.identity.kind)) {
        throw const QuotaException(QuotaExceptionReason.unavailableMethod);
      }
      await _fresh(change.inventory);
      final (_, identity) = await _identity(
        change.identity.kind,
        change.identity.id,
      );
      if (identity != plan.identity) {
        throw const QuotaException(QuotaExceptionReason.stale);
      }
      if ((await _attachments(review.target)).$1 != plan.dependencies) {
        throw const QuotaException(QuotaExceptionReason.dependency);
      }
      // Recheck the complete quota-limit map and dataset after dependency reads.
      final before = await _fresh(change.inventory);
      final (_, lastIdentity) = await _identity(
        change.identity.kind,
        change.identity.id,
      );
      if (lastIdentity != plan.identity) {
        throw const QuotaException(QuotaExceptionReason.stale);
      }
      final lastRows = await _rows();
      if (!_sameRows(before.rows, lastRows, review.target)) {
        throw const QuotaException(QuotaExceptionReason.stale);
      }
      if (isOtherBusy()) throw const QuotaException(QuotaExceptionReason.busy);
      final quotas = [
        if (change.byteLimit != null)
          {
            'quota_type': change.identity.kind.wire,
            'id': '${change.identity.id}',
            'quota_value': change.byteLimit,
          },
        if (change.objectLimit != null)
          {
            'quota_type': '${change.identity.kind.wire}OBJ',
            'id': '${change.identity.id}',
            'quota_value': change.objectLimit,
          },
      ];
      _guard('pool.dataset.set_quota');
      sent = true;
      final receipt = await _call('pool.dataset.set_quota', [
        review.target,
        quotas,
      ]);
      if (receipt != null) return _uncertain();
      final after = await _rows();
      final entries = await _entries(review.target);
      final (_, afterIdentity) = await _identity(
        change.identity.kind,
        change.identity.id,
      );
      final afterDependencies = (await _attachments(review.target)).$1;
      final finalRows = await _rows();
      if (!_sameRows(before.rows, after, review.target) ||
          afterIdentity != plan.identity ||
          !_sameRows(before.rows, finalRows, review.target) ||
          afterDependencies != plan.dependencies ||
          _quotaLimits(entries) != _quotaLimits(_expected(plan))) {
        return _uncertain();
      }
      _inventories.clear();
      _identities.clear();
      _reviews.clear();
      return const QuotaResult(
        QuotaOutcome.verified,
        'The exact quota limits were independently read back. No guest data or filesystem expansion was performed.',
      );
    } on Object {
      return sent
          ? _uncertain()
          : const QuotaResult(
              QuotaOutcome.rejected,
              'Preflight changed or could not be verified. No quota mutation was sent; reload and review again.',
            );
    } finally {
      _submitting = false;
    }
  }

  List<QuotaEntry> _expected(_QuotaPlan plan) {
    final c = plan.change;
    final current = c.inventory.entry(c.identity.kind, c.identity.id);
    return [
      for (final e in plan.snapshot.entries)
        if (e.kind != c.identity.kind || e.id != c.identity.id) e,
      QuotaEntry(
        kind: c.identity.kind,
        id: c.identity.id,
        byteLimit: c.byteLimit ?? current?.byteLimit ?? 0,
        objectLimit: c.objectLimit ?? current?.objectLimit ?? 0,
      ),
    ];
  }

  QuotaResult _uncertain() {
    _unknown = true;
    _inventories.clear();
    _identities.clear();
    _reviews.clear();
    return const QuotaResult(
      QuotaOutcome.unknown,
      'Quota limits may have changed. Inspect the original server and reconnect; do not retry or replay this review.',
    );
  }
}

String _quotaLimits(List<QuotaEntry> entries) {
  final rows = [
    for (final e in entries)
      if (e.byteLimit != 0 || e.objectLimit != 0)
        '${e.kind.wire}:${e.id}:${e.byteLimit}:${e.objectLimit}',
  ]..sort();
  return jsonEncode(rows);
}

bool _quotaNumber(Object? value) =>
    value is int && value >= 0 && value <= 9007199254740991;
bool _quotaId(Object? value) =>
    value is int && value >= 0 && value < 4294967295;
bool _quotaText(Object? value, int max) => _datasetText(value, max);
bool _quotaPath(Object? value) =>
    _quotaText(value, 200) &&
    RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.:/ -]*$').hasMatch(value as String) &&
    !value.contains('//') &&
    !value.endsWith('/') &&
    !value.split('/').any((p) => p == '.' || p == '..');
String _quotaRaw(Object? value) {
  if (value is! Map ||
      value['rawvalue'] is! String ||
      (value['rawvalue'] as String).length > 2048) {
    _quotaInvalid();
  }
  return value['rawvalue'] as String;
}

int _quotaRawNumber(Object? value) {
  final raw = _quotaRaw(value);
  if (!RegExp(r'^[0-9]+$').hasMatch(raw)) _quotaInvalid();
  final result = int.tryParse(raw);
  if (!_quotaNumber(result)) _quotaInvalid();
  return result!;
}

Never _quotaInvalid() =>
    throw const QuotaException(QuotaExceptionReason.invalid);
