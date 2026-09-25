part of 'true_nas_session_repository.dart';

/// A bounded, typed adapter for stable 25.10 snapshots. Issued review objects
/// belong to one authenticated session and are invalidated by inventory reload.
abstract interface class AuthenticatedSnapshotsSession {
  SnapshotsCapabilities get snapshotsCapabilities;
  Future<List<SnapshotDataset>> loadSnapshotDatasets();
  Future<SnapshotPageResult> loadSnapshots(SnapshotQuery query);
  Future<SnapshotOperationResult> createSnapshot(SnapshotCreateRequest request);
  Future<SnapshotOperationResult> deleteSnapshot(SnapshotDeleteRequest request);
  Future<SnapshotRecoveryReview> reviewSnapshotRecovery(
    SnapshotRecoveryPlan plan,
  );
  Future<SnapshotOperationResult> applySnapshotRecovery(
    SnapshotRecoveryRequest request,
  );
}

final class SnapshotsCapabilities {
  const SnapshotsCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.canRead,
    required this.canCreate,
    required this.canDelete,
    this.canClone = false,
    this.canRollback = false,
    this.canHold = false,
    this.canRelease = false,
  });
  const SnapshotsCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      canRead = false,
      canCreate = false,
      canDelete = false,
      canClone = false,
      canRollback = false,
      canHold = false,
      canRelease = false;
  final bool connected;
  final bool versionSupported;
  final bool canRead;
  final bool canCreate;
  final bool canDelete;
  final bool canClone, canRollback, canHold, canRelease;
  bool get supported => connected && versionSupported && canRead;
  String? get blockedReason => !connected
      ? 'Connect to a server to view snapshots.'
      : !versionSupported
      ? 'The snapshot workspace requires a stable TrueNAS 25.10 release.'
      : !canRead
      ? 'Snapshot and filesystem inventory are unavailable to this account.'
      : null;
}

final class SnapshotDataset {
  const SnapshotDataset({
    required this.id,
    required this.guid,
    required this.creationSeconds,
    this.blockedReason,
    this.origin,
    this.readOnly,
    this.writtenBytes,
    this.referencedBytes,
    this.encrypted = false,
  });
  final String id;
  final String guid;
  final int creationSeconds;
  final String? blockedReason;
  final String? origin;
  final bool? readOnly;
  final int? writtenBytes, referencedBytes;
  final bool encrypted;
  bool get canCreate => blockedReason == null;
}

final class SnapshotEntry {
  SnapshotEntry({
    required this.id,
    required this.dataset,
    required this.name,
    required this.guid,
    required this.creationSeconds,
    required this.creationTxg,
    required this.usedBytes,
    required this.referencedBytes,
    required Map<String, int> holds,
    required this.userReferences,
    required List<String> clones,
    required this.deferredDestroy,
    this.clonesKnown = true,
    this.blockedReason,
  }) : holds = Map.unmodifiable(holds),
       clones = List.unmodifiable(clones);
  final String id;
  final String dataset;
  final String name;
  // Strings preserve full uint64 precision on Flutter Web.
  final String guid;
  final String creationTxg;
  final int creationSeconds;
  final int usedBytes;
  final int referencedBytes;
  final Map<String, int> holds;
  final int? userReferences;
  final List<String> clones;
  final bool clonesKnown;
  final bool? deferredDestroy;
  final String? blockedReason;
  bool get canDelete => blockedReason == null;
  DateTime get createdAt =>
      DateTime.fromMillisecondsSinceEpoch(creationSeconds * 1000, isUtc: true);
}

/// Prefix search, one exact filesystem, 25 rows per page, at most 1000 names.
/// Concurrent server changes can shift pages; deletion always rechecks identity.
final class SnapshotQuery {
  const SnapshotQuery({
    required this.dataset,
    this.namePrefix = '',
    this.page = 0,
  });
  final String dataset;
  final String namePrefix;
  final int page;
  static const pageSize = 25;
  String? get validationError =>
      !_snapshotDatasetName(dataset) ||
          namePrefix.length > 64 ||
          (namePrefix.isNotEmpty &&
              !RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.:-]*$')
                  .hasMatch(namePrefix)) ||
          page < 0 ||
          page >= 40
      ? 'Choose a filesystem and a valid snapshot name prefix.'
      : null;
  @override
  bool operator ==(Object other) =>
      other is SnapshotQuery &&
      dataset == other.dataset &&
      namePrefix == other.namePrefix &&
      page == other.page;
  @override
  int get hashCode => Object.hash(dataset, namePrefix, page);
}

final class SnapshotPageResult {
  SnapshotPageResult({
    required List<SnapshotEntry> entries,
    required this.hasMore,
  }) : entries = List.unmodifiable(entries);
  final List<SnapshotEntry> entries;
  final bool hasMore;
}

final class SnapshotCreateRequest {
  const SnapshotCreateRequest({required this.dataset, required this.name});
  final SnapshotDataset dataset;
  final String name;
  String get id => '${dataset.id}@$name';
  String? get validationError => !dataset.canCreate
      ? dataset.blockedReason
      : !_snapshotName(name) || id.length > 240
      ? 'Use 1–64 letters, digits, underscores, hyphens, dots or colons; start with a letter, digit or underscore.'
      : null;
}

final class SnapshotDeleteRequest {
  const SnapshotDeleteRequest({
    required this.snapshot,
    required this.confirmation,
  });
  final SnapshotEntry snapshot;
  final String confirmation;
  String? get validationError => !snapshot.canDelete
      ? snapshot.blockedReason
      : confirmation != snapshot.id
      ? 'Type the full snapshot identifier exactly to confirm deletion.'
      : null;
}

enum SnapshotRecoveryKind {
  clone,
  rollback,
  hold,
  release,
  recursiveCreate,
  bulkDelete,
}

/// Typed plans contain exact issued objects, never user-authored RPC options.
final class SnapshotRecoveryPlan {
  SnapshotRecoveryPlan.clone({
    required SnapshotEntry snapshot,
    required SnapshotDataset parent,
    required String newName,
  }) : kind = SnapshotRecoveryKind.clone,
       snapshots = List.unmodifiable([snapshot]),
       dataset = parent,
       name = newName;
  SnapshotRecoveryPlan.rollback(SnapshotEntry snapshot)
    : kind = SnapshotRecoveryKind.rollback,
      snapshots = List.unmodifiable([snapshot]),
      dataset = null,
      name = '';
  SnapshotRecoveryPlan.hold(SnapshotEntry snapshot)
    : kind = SnapshotRecoveryKind.hold,
      snapshots = List.unmodifiable([snapshot]),
      dataset = null,
      name = '';
  SnapshotRecoveryPlan.release(SnapshotEntry snapshot)
    : kind = SnapshotRecoveryKind.release,
      snapshots = List.unmodifiable([snapshot]),
      dataset = null,
      name = '';
  const SnapshotRecoveryPlan.recursiveCreate({
    required this.dataset,
    required this.name,
  }) : kind = SnapshotRecoveryKind.recursiveCreate,
       snapshots = const [];
  SnapshotRecoveryPlan.bulkDelete(List<SnapshotEntry> selected)
    : kind = SnapshotRecoveryKind.bulkDelete,
      snapshots = List.unmodifiable(selected),
      dataset = null,
      name = '';
  final SnapshotRecoveryKind kind;
  final List<SnapshotEntry> snapshots;
  final SnapshotDataset? dataset;
  final String name;
  String get target => switch (kind) {
    SnapshotRecoveryKind.clone => '${dataset!.id}/$name',
    SnapshotRecoveryKind.recursiveCreate => '${dataset!.id}@$name',
    SnapshotRecoveryKind.bulkDelete => 'DELETE ${snapshots.length} SNAPSHOTS',
    _ => snapshots.single.id,
  };
}

final class SnapshotRecoveryReview {
  SnapshotRecoveryReview({
    required this.plan,
    required List<SnapshotEntry> snapshots,
    required List<SnapshotDataset> datasets,
    required List<SnapshotEntry> newerSnapshots,
    required List<String> warnings,
    this.blockedReason,
  }) : snapshots = List.unmodifiable(snapshots),
       datasets = List.unmodifiable(datasets),
       newerSnapshots = List.unmodifiable(newerSnapshots),
       warnings = List.unmodifiable(warnings);
  final SnapshotRecoveryPlan plan;
  final List<SnapshotEntry> snapshots, newerSnapshots;
  final List<SnapshotDataset> datasets;
  final List<String> warnings;
  final String? blockedReason;
  bool get canApply => blockedReason == null;
  bool get bookmarksInspectable => false;
  bool get requiresLossAcknowledgement => {
    SnapshotRecoveryKind.rollback,
    SnapshotRecoveryKind.release,
    SnapshotRecoveryKind.bulkDelete,
  }.contains(plan.kind);
}

final class SnapshotRecoveryRequest {
  const SnapshotRecoveryRequest({
    required this.review,
    required this.confirmation,
    this.acknowledgeDataLoss = false,
  });
  final SnapshotRecoveryReview review;
  final String confirmation;
  final bool acknowledgeDataLoss;
  String? get validationError => !review.canApply
      ? review.blockedReason
      : confirmation != review.plan.target
      ? 'Type the reviewed target exactly.'
      : review.requiresLossAcknowledgement && !acknowledgeDataLoss
      ? 'Acknowledge the exact destructive impact before continuing.'
      : null;
}

enum SnapshotOperationOutcome { verified, rejected, unknown }

final class SnapshotOperationResult {
  const SnapshotOperationResult({required this.outcome, required this.message});
  final SnapshotOperationOutcome outcome;
  final String message;
}

enum SnapshotsExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleSnapshot,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class SnapshotsException implements Exception {
  const SnapshotsException(this.reason);
  final SnapshotsExceptionReason reason;
  String get userMessage => switch (reason) {
    SnapshotsExceptionReason.notAuthenticated =>
      'The connection changed. Reconnect and reload snapshots.',
    SnapshotsExceptionReason.unsupportedVersion =>
      'Snapshots require a stable TrueNAS 25.10 release.',
    SnapshotsExceptionReason.unavailableMethod =>
      'The required snapshot method is unavailable to this account.',
    SnapshotsExceptionReason.busy => 'Another server change or an unresolved snapshot operation is in progress.',
    SnapshotsExceptionReason.staleSnapshot => 'The filesystem, snapshot or review changed. Reload and review again; nothing was sent.',
    SnapshotsExceptionReason.invalidRequest =>
      'Review a valid snapshot request before applying.',
    SnapshotsExceptionReason.invalidResponse => 'Snapshot identity or inventory could not be verified. Reload the filesystem.',
    SnapshotsExceptionReason.unavailable =>
      'Snapshot data could not be loaded. Remote details have been withheld.',
  };
  @override
  String toString() => userMessage;
}

const _snapshotProperties = [
  'guid',
  'creation',
  'createtxg',
  'used',
  'referenced',
  'userrefs',
  'clones',
  'defer_destroy',
];

final class _SessionSnapshots {
  _SessionSnapshots({
    required this.client,
    required ServerSummary summary,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherBusy,
    required this.requestTimeout,
  }) : versionSupported =
           _managementVersion(summary.version) == _ManagementVersion.v2510,
       methods = Set.unmodifiable(summary.availableMethodNames);
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent;
  final bool Function() isOtherBusy;
  final Duration requestTimeout;
  final bool versionSupported;
  final Set<String> methods;
  var _submitting = false;
  var _uncertain = false;
  var _loadingDatasets = false;
  var _loadingSnapshots = false;
  bool get isBusy => _submitting || _uncertain;
  final Set<SnapshotDataset> _datasets = {};
  final Set<SnapshotEntry> _snapshots = {};
  final Set<SnapshotRecoveryReview> _recoveryReviews = {};

  SnapshotsCapabilities get capabilities {
    final read =
        isCurrent() &&
        versionSupported &&
        methods.containsAll({'pool.snapshot.query', 'pool.dataset.query'});
    return SnapshotsCapabilities(
      connected: isCurrent(),
      versionSupported: versionSupported,
      canRead: read,
      canCreate: read && methods.contains('pool.snapshot.create'),
      canDelete: read && methods.contains('pool.snapshot.delete'),
      canClone: read && methods.contains('pool.snapshot.clone'),
      canRollback: read && methods.contains('pool.snapshot.rollback'),
      canHold: read && methods.contains('pool.snapshot.hold'),
      canRelease: read && methods.contains('pool.snapshot.release'),
    );
  }

  void _guard([String? method]) {
    if (!isCurrent()) {
      throw const SnapshotsException(SnapshotsExceptionReason.notAuthenticated);
    }
    if (!versionSupported) {
      throw const SnapshotsException(
        SnapshotsExceptionReason.unsupportedVersion,
      );
    }
    if (!capabilities.canRead ||
        (method != null && !methods.contains(method))) {
      throw const SnapshotsException(
        SnapshotsExceptionReason.unavailableMethod,
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

  Future<List<SnapshotDataset>> _readDatasets([String? id]) async {
    final raw = await _call('pool.dataset.query', [
      id == null
          ? [
              ['type', '=', 'FILESYSTEM'],
            ]
          : [
              ['id', '=', id],
            ],
      {
        'limit': id == null ? 1025 : 2,
        'select': [
          'id',
          'name',
          'type',
          'encrypted',
          'locked',
          'guid',
          'creation',
          'mountpoint',
          'origin',
          'readonly',
          'written',
          'referenced',
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
            'encryption',
            'keystatus',
            'origin',
            'readonly',
            'written',
            'referenced',
          ],
        },
      },
    ]);
    if (raw is! List || raw.length > (id == null ? 1024 : 1)) {
      _snapshotInvalid();
    }
    final seen = <String>{};
    final result = <SnapshotDataset>[];
    for (final value in raw) {
      if (value is! Map ||
          !_snapshotDatasetName(value['id']) ||
          value['name'] != value['id'] ||
          value['type'] != 'FILESYSTEM' ||
          value['locked'] is! bool ||
          value['encrypted'] is! bool) {
        _snapshotInvalid();
      }
      final name = value['id'] as String;
      if (!seen.add(name) || (id != null && name != id)) _snapshotInvalid();
      final guid = _snapshotUint64(_snapshotRaw(value['guid']));
      final created = _snapshotNumber(_snapshotRaw(value['creation']));
      final managed = value['managedby'];
      final managedValue = managed == null ? '' : _snapshotRaw(managed);
      result.add(
        SnapshotDataset(
          id: name,
          guid: guid,
          creationSeconds: created,
          origin: _snapshotRaw(value['origin']),
          readOnly: switch (_snapshotRaw(value['readonly'])) {
            'on' => true,
            'off' => false,
            _ => null,
          },
          writtenBytes: _snapshotOptionalNumber(value['written']),
          referencedBytes: _snapshotOptionalNumber(value['referenced']),
          encrypted: value['encrypted'] as bool,
          blockedReason: value['locked'] == true
              ? 'Unlock this filesystem in TrueNAS before creating a snapshot.'
              : _snapshotSystemDataset(name) ||
                    managedValue == null ||
                    !{'', '-'}.contains(managedValue)
              ? 'Snapshots of system or externally managed filesystems require TrueNAS.'
              : null,
        ),
      );
    }
    return result;
  }

  Future<List<SnapshotDataset>> loadDatasets() async {
    _guard();
    if (_submitting || _loadingDatasets) {
      throw const SnapshotsException(SnapshotsExceptionReason.busy);
    }
    _loadingDatasets = true;
    _datasets.clear();
    _recoveryReviews.clear();
    try {
      final rows = await _readDatasets();
      _datasets.addAll(rows);
      return List.unmodifiable(rows);
    } on SnapshotsException {
      rethrow;
    } on Object {
      throw const SnapshotsException(SnapshotsExceptionReason.unavailable);
    } finally {
      _loadingDatasets = false;
    }
  }

  Future<List<SnapshotEntry>> _readExact(String id) async {
    final raw = await _call('pool.snapshot.query', [
      [
        ['id', '=', id],
      ],
      {
        'limit': 2,
        'extra': {'holds': true, 'properties': _snapshotProperties},
      },
    ]);
    if (raw is! List || raw.length > 1) _snapshotInvalid();
    return [for (final row in raw) _parseSnapshot(row, expectedId: id)];
  }

  Future<SnapshotPageResult> load(SnapshotQuery query) async {
    _guard();
    if (query.validationError != null) {
      throw const SnapshotsException(SnapshotsExceptionReason.invalidRequest);
    }
    if (_submitting || _loadingSnapshots) {
      throw const SnapshotsException(SnapshotsExceptionReason.busy);
    }
    _loadingSnapshots = true;
    _snapshots.clear();
    _recoveryReviews.clear();
    try {
      final names = await _call('pool.snapshot.query', [
        [
          ['dataset', '=', query.dataset],
          if (query.namePrefix.isNotEmpty)
            ['name', '^', '${query.dataset}@${query.namePrefix}'],
        ],
        {
          'select': ['name'],
          'order_by': ['name'],
          'offset': query.page * SnapshotQuery.pageSize,
          'limit': SnapshotQuery.pageSize + 1,
        },
      ]);
      if (names is! List || names.length > SnapshotQuery.pageSize + 1) {
        _snapshotInvalid();
      }
      final ids = <String>[];
      for (final row in names) {
        if (row is! Map || row['name'] is! String) _snapshotInvalid();
        final id = row['name'] as String;
        final prefix = '${query.dataset}@${query.namePrefix}';
        if (!id.startsWith(prefix) || !_snapshotId(id) || ids.contains(id)) {
          _snapshotInvalid();
        }
        ids.add(id);
      }
      final entries = <SnapshotEntry>[];
      // Keep at most five exact detail requests in flight.
      final selected = ids.take(SnapshotQuery.pageSize).toList();
      for (var start = 0; start < selected.length; start += 5) {
        final rows = await Future.wait(
          selected.skip(start).take(5).map(_readExact),
        );
        for (final row in rows) {
          // Volatile inventories may lose rows; do not silently shift a review.
          if (row.length != 1) _snapshotInvalid();
          entries.add(row.single);
        }
      }
      _snapshots.addAll(entries);
      return SnapshotPageResult(
        entries: entries,
        hasMore: ids.length > SnapshotQuery.pageSize,
      );
    } on SnapshotsException {
      rethrow;
    } on Object {
      throw const SnapshotsException(SnapshotsExceptionReason.unavailable);
    } finally {
      _loadingSnapshots = false;
    }
  }

  void _start(String method, String? validationError, bool issued) {
    _guard(method);
    if (isBusy || isOtherBusy() || _loadingDatasets || _loadingSnapshots) {
      throw const SnapshotsException(SnapshotsExceptionReason.busy);
    }
    if (!issued) {
      throw const SnapshotsException(SnapshotsExceptionReason.staleSnapshot);
    }
    if (validationError != null) {
      throw const SnapshotsException(SnapshotsExceptionReason.invalidRequest);
    }
    _submitting = true;
  }

  Future<SnapshotOperationResult> create(SnapshotCreateRequest request) async {
    _start(
      'pool.snapshot.create',
      request.validationError,
      _datasets.contains(request.dataset),
    );
    var sent = false;
    try {
      final dataset = await _readDatasets(request.dataset.id);
      if (dataset.length != 1 ||
          !_sameSnapshotDataset(dataset.single, request.dataset) ||
          !dataset.single.canCreate) {
        _snapshotStale();
      }
      if ((await _readExact(request.id)).isNotEmpty) _snapshotStale();
      // An existence read is not a filesystem identity token.
      final latest = await _readDatasets(request.dataset.id);
      if (latest.length != 1 ||
          !_sameSnapshotDataset(latest.single, request.dataset)) {
        _snapshotStale();
      }
      _guard('pool.snapshot.create');
      if (isOtherBusy()) {
        throw const SnapshotsException(SnapshotsExceptionReason.busy);
      }
      sent = true;
      final raw = await _call('pool.snapshot.create', [
        {
          'dataset': request.dataset.id,
          'name': request.name,
          'recursive': false,
          'vmware_sync': false,
        },
      ]);
      // Create responses omit holds. Their immutable identity must match a
      // separate exact query before the UI can claim success.
      final receipt = _parseSnapshot(
        raw,
        expectedId: request.id,
        requireSafety: false,
      );
      final after = await _readExact(request.id);
      final parent = await _readDatasets(request.dataset.id);
      if (after.length != 1 ||
          !_sameSnapshotIdentity(receipt, after.single) ||
          parent.length != 1 ||
          !_sameSnapshotDataset(parent.single, request.dataset)) {
        return _unknown();
      }
      _datasets.clear();
      _snapshots.clear();
      _recoveryReviews.clear();
      return const SnapshotOperationResult(
        outcome: SnapshotOperationOutcome.verified,
        message: 'The new snapshot identity was read back and verified. Child datasets were not included.',
      );
    } on SnapshotsException catch (error) {
      return sent ? _unknown() : _rejected(error.userMessage);
    } on Object {
      return sent
          ? _unknown()
          : _rejected('Preflight checks failed. No snapshot was created.');
    } finally {
      _submitting = false;
    }
  }

  Future<SnapshotOperationResult> delete(SnapshotDeleteRequest request) async {
    _start(
      'pool.snapshot.delete',
      request.validationError,
      _snapshots.contains(request.snapshot),
    );
    var sent = false;
    try {
      final current = await _readExact(request.snapshot.id);
      if (current.length != 1 ||
          !_sameSnapshotIdentity(current.single, request.snapshot) ||
          !current.single.canDelete) {
        _snapshotStale();
      }
      _guard('pool.snapshot.delete');
      if (isOtherBusy()) {
        throw const SnapshotsException(SnapshotsExceptionReason.busy);
      }
      sent = true;
      final result = await _call('pool.snapshot.delete', [
        request.snapshot.id,
        {'recursive': false, 'defer': false},
      ]);
      if (result != true ||
          (await _readExact(request.snapshot.id)).isNotEmpty) {
        return _unknown();
      }
      _snapshots.clear();
      _recoveryReviews.clear();
      return const SnapshotOperationResult(
        outcome: SnapshotOperationOutcome.verified,
        message: 'The single snapshot was deleted and its absence was verified. Deletion cannot be undone.',
      );
    } on SnapshotsException catch (error) {
      return sent ? _unknown() : _rejected(error.userMessage);
    } on Object {
      return sent
          ? _unknown()
          : _rejected('Preflight checks failed. No snapshot was deleted.');
    } finally {
      _submitting = false;
    }
  }

  String _recoveryMethod(SnapshotRecoveryKind kind) =>
      'pool.snapshot.${switch (kind) {
        SnapshotRecoveryKind.recursiveCreate => 'create',
        SnapshotRecoveryKind.bulkDelete => 'delete',
        _ => kind.name,
      }}';

  void _recoveryPlanGuard(SnapshotRecoveryPlan plan) {
    _guard(_recoveryMethod(plan.kind));
    if (plan.snapshots.length > 25 ||
        plan.snapshots.map((s) => s.id).toSet().length !=
            plan.snapshots.length ||
        plan.snapshots.any((s) => !_snapshots.contains(s)) ||
        plan.dataset != null && !_datasets.contains(plan.dataset)) {
      _snapshotStale();
    }
    if (plan.kind == SnapshotRecoveryKind.recursiveCreate) {
      if (plan.dataset == null ||
          !plan.dataset!.canCreate ||
          !_snapshotName(plan.name)) {
        _snapshotStale();
      }
    } else if (plan.kind == SnapshotRecoveryKind.bulkDelete) {
      if (plan.snapshots.isEmpty || plan.snapshots.any((s) => !s.canDelete)) {
        _snapshotStale();
      }
    } else {
      if (plan.snapshots.length != 1) _snapshotStale();
      if (plan.kind == SnapshotRecoveryKind.clone &&
          (plan.dataset == null ||
              !plan.dataset!.canCreate ||
              !_snapshotName(plan.name) ||
              !_snapshotDatasetName(plan.target) ||
              plan.target.split('/').first !=
                  plan.snapshots.single.dataset.split('/').first)) {
        _snapshotStale();
      }
    }
  }

  Future<SnapshotRecoveryReview> reviewRecovery(
    SnapshotRecoveryPlan plan,
  ) async {
    _recoveryPlanGuard(plan);
    if (_submitting || _loadingDatasets || _loadingSnapshots) {
      throw const SnapshotsException(SnapshotsExceptionReason.busy);
    }
    _loadingSnapshots = true;
    try {
      final review = await _readRecovery(plan);
      if (_recoveryReviews.length >= 32) {
        _recoveryReviews.remove(_recoveryReviews.first);
      }
      _recoveryReviews.add(review);
      return review;
    } on SnapshotsException {
      rethrow;
    } on Object {
      throw const SnapshotsException(SnapshotsExceptionReason.unavailable);
    } finally {
      _loadingSnapshots = false;
    }
  }

  Future<List<SnapshotEntry>> _recoveryInventory(String dataset) async {
    final raw = await _call('pool.snapshot.query', [
      [
        ['dataset', '=', dataset],
      ],
      {
        'select': ['name'],
        'order_by': ['name'],
        'limit': 65,
      },
    ]);
    if (raw is! List || raw.length > 64) _snapshotInvalid();
    final ids = <String>{};
    final result = <SnapshotEntry>[];
    for (final row in raw) {
      if (row is! Map ||
          row['name'] is! String ||
          !_snapshotId(row['name'] as String) ||
          !(row['name'] as String).startsWith('$dataset@') ||
          !ids.add(row['name'] as String)) {
        _snapshotInvalid();
      }
      final exact = await _readExact(row['name'] as String);
      if (exact.length != 1) _snapshotStale();
      result.add(exact.single);
    }
    return result;
  }

  Future<SnapshotRecoveryReview> _readRecovery(
    SnapshotRecoveryPlan plan,
  ) async {
    final entries = <SnapshotEntry>[];
    final datasets = <SnapshotDataset>[];
    final newer = <SnapshotEntry>[];
    String? blocked;
    final warnings = <String>[
      'Avoid concurrent changes in other clients. Name-based APIs have no atomic GUID compare-and-mutate token.',
    ];
    for (final snapshot in plan.snapshots) {
      final fresh = await _readExact(snapshot.id);
      if (fresh.length != 1 || !_sameSnapshotIdentity(snapshot, fresh.single)) {
        _snapshotStale();
      }
      entries.add(fresh.single);
      if (!_snapshotRecoverySafe(fresh.single)) blocked ??= 'Unknown holds, dependencies, deferred destruction or system ownership prevent this recovery operation.';
    }
    final datasetIds = {
      for (final s in entries) s.dataset,
      if (plan.dataset != null) plan.dataset!.id,
    };
    for (final id in datasetIds) {
      final fresh = await _readDatasets(id);
      if (fresh.length != 1 || !fresh.single.canCreate) _snapshotStale();
      if (plan.dataset?.id == id &&
          !_sameSnapshotDataset(plan.dataset!, fresh.single)) {
        _snapshotStale();
      }
      datasets.add(fresh.single);
    }
    switch (plan.kind) {
      case SnapshotRecoveryKind.clone:
        final parent = datasets.singleWhere((d) => d.id == plan.dataset!.id);
        if (datasets.any((d) => d.encrypted) || parent.readOnly != false) {
          blocked ??= 'This clone workflow needs unlocked unencrypted filesystems and a writable destination parent.';
        }
        if ((await _readDatasets(plan.target)).isNotEmpty) blocked ??= 'The clone destination already exists. No dataset will be replaced.';
        warnings.add(
          'Creates and mounts one new read-only filesystem at ${plan.target}; its origin remains dependent on the source snapshot. This is not an independent backup. No existing dataset is overwritten.',
        );
      case SnapshotRecoveryKind.rollback:
        final target = entries.single;
        final all = await _recoveryInventory(target.dataset);
        if (!all.any((s) => _sameSnapshotIdentity(s, target))) _snapshotStale();
        newer.addAll(
          all.where(
            (s) =>
                BigInt.parse(s.creationTxg) > BigInt.parse(target.creationTxg),
          ),
        );
        if (newer.isNotEmpty) blocked ??= 'Newer snapshots exist. Review and delete them separately before a non-recursive rollback; no newer snapshots, bookmarks or clones are destroyed automatically.';
        if (all.any(
          (s) =>
              s.id != target.id &&
              BigInt.parse(s.creationTxg) == BigInt.parse(target.creationTxg),
        )) {
          blocked ??= 'The latest transaction-group identity is ambiguous.';
        }
        if (datasets.single.writtenBytes == null ||
            datasets.single.referencedBytes == null ||
            datasets.single.readOnly != false) {
          blocked ??= 'Writable filesystem and written/referenced byte properties are required for rollback verification.';
        }
        warnings.addAll([
          'PERMANENT DATA LOSS: rollback replaces the current filesystem state with ${target.id}. Every change since that snapshot is lost; it does not create a backup or undo point. Stop workloads and writers first.',
          'All rollback flags remain false: no newer snapshots/bookmarks, clones, forced unmounts or child filesystems are selected for destruction.',
          'Bookmarks cannot be listed through the 25.10 public API. They are not authorized for deletion; a conflicting bookmark may make the server reject this rollback.',
        ]);
      case SnapshotRecoveryKind.hold:
        if (entries.single.userReferences != 0 ||
            entries.single.holds.isNotEmpty) {
          blocked ??= 'This workflow adds a truenas hold only when no hold currently exists.';
        }
        warnings.add(
          'Adds the TrueNAS truenas hold tag to this snapshot only. It prevents snapshot destruction; it does not copy or back up data.',
        );
      case SnapshotRecoveryKind.release:
        final target = entries.single;
        if (target.userReferences != 1 ||
            target.holds.length != 1 ||
            !target.holds.containsKey('truenas')) {
          blocked ??= 'The public release method removes ALL tags. Only a single verified truenas tag with userrefs=1 may be released here.';
        }
        warnings.add(
          'Removes the sole truenas hold from this snapshot. Retention tasks can delete it afterwards. Deferred destruction and invisible/third-party hold tags are never released here.',
        );
      case SnapshotRecoveryKind.recursiveCreate:
        final root = plan.dataset!;
        final all = await _readDatasets();
        final tree =
            all
                .where((d) => d.id == root.id || d.id.startsWith('${root.id}/'))
                .toList()
              ..sort((a, b) => a.id.compareTo(b.id));
        if (tree.isEmpty ||
            tree.length > 32 ||
            !tree.any((d) => _sameSnapshotDataset(d, root))) {
          _snapshotStale();
        }
        datasets
          ..clear()
          ..addAll(tree);
        for (final d in tree) {
          if (!d.canCreate || '${d.id}@${plan.name}'.length > 240) blocked ??= 'Every selected filesystem must support the exact proposed name.';
          if ((await _readExact('${d.id}@${plan.name}')).isNotEmpty) blocked ??= 'A proposed snapshot already exists. Nothing will be overwritten.';
        }
        warnings.add(
          'Creates a named snapshot on each of the ${tree.length} listed accessible filesystems, one at a time. This is NOT an atomic recursive snapshot: volumes, hidden/system children and unlisted filesystems are excluded. A failure can leave a partial set; nothing is retried or automatically cleaned up.',
        );
      case SnapshotRecoveryKind.bulkDelete:
        if (entries.any((s) => !s.canDelete)) blocked ??= 'Every selected snapshot must have no holds, clones or deferred destruction.';
        warnings.add(
          'PERMANENT DATA LOSS: deletes exactly ${entries.length} selected snapshots, one at a time. This is not atomic. A failure can leave a partial deletion; remaining snapshots are not retried and no child snapshots or datasets are implicitly deleted.',
        );
    }
    datasets.sort((a, b) => a.id.compareTo(b.id));
    return SnapshotRecoveryReview(
      plan: plan,
      snapshots: entries,
      datasets: datasets,
      newerSnapshots: newer,
      warnings: warnings,
      blockedReason: blocked,
    );
  }

  Future<SnapshotOperationResult> applyRecovery(
    SnapshotRecoveryRequest request,
  ) async {
    final review = request.review;
    final plan = review.plan;
    final method = _recoveryMethod(plan.kind);
    _start(method, request.validationError, _recoveryReviews.contains(review));
    var sent = false;
    Future<Object?> write(List<Object?> args) async {
      _guard(method);
      if (isOtherBusy()) {
        throw const SnapshotsException(SnapshotsExceptionReason.busy);
      }
      sent = true;
      return _call(method, args);
    }

    try {
      final fresh = await _readRecovery(plan);
      if (!fresh.canApply || !_sameRecovery(review, fresh)) _snapshotStale();
      _recoveryReviews.remove(review);
      switch (plan.kind) {
        case SnapshotRecoveryKind.clone:
          final result = await write([
            {
              'snapshot': plan.snapshots.single.id,
              'dataset_dst': plan.target,
              'dataset_properties': {'readonly': 'on'},
            },
          ]);
          final after = await _readDatasets(plan.target);
          final source = await _readExact(plan.snapshots.single.id);
          if (result != true ||
              after.length != 1 ||
              after.single.origin != plan.snapshots.single.id ||
              after.single.readOnly != true ||
              source.length != 1 ||
              !_sameSnapshotIdentity(source.single, review.snapshots.single) ||
              source.single.deferredDestroy != false ||
              !source.single.clonesKnown ||
              source.single.userReferences !=
                  review.snapshots.single.userReferences ||
              !_adminEqual(
                source.single.holds,
                review.snapshots.single.holds,
              ) ||
              !_adminEqual(
                source.single.clones.toSet().toList()..sort(),
                {...review.snapshots.single.clones, plan.target}.toList()
                  ..sort(),
              )) {
            return _unknown();
          }
        case SnapshotRecoveryKind.rollback:
          final result = await write([
            plan.snapshots.single.id,
            {
              'recursive': false,
              'recursive_clones': false,
              'force': false,
              'recursive_rollback': false,
            },
          ]);
          final after = await _readDatasets(plan.snapshots.single.dataset);
          final snapshots = await _recoveryInventory(
            plan.snapshots.single.dataset,
          );
          final target = snapshots
              .where((s) => s.id == plan.snapshots.single.id)
              .firstOrNull;
          if (result != null ||
              after.length != 1 ||
              !_sameSnapshotDataset(after.single, review.datasets.single) ||
              after.single.writtenBytes != 0 ||
              after.single.referencedBytes !=
                  review.snapshots.single.referencedBytes ||
              target == null ||
              !_sameSnapshotSafety(target, review.snapshots.single) ||
              snapshots.any(
                (s) =>
                    BigInt.parse(s.creationTxg) >
                    BigInt.parse(target.creationTxg),
              )) {
            return _unknown();
          }
        case SnapshotRecoveryKind.hold:
        case SnapshotRecoveryKind.release:
          final result = await write([
            plan.snapshots.single.id,
            {'recursive': false},
          ]);
          final after = await _readExact(plan.snapshots.single.id);
          if (result != null ||
              after.length != 1 ||
              !_sameSnapshotIdentity(after.single, review.snapshots.single) ||
              after.single.deferredDestroy != false ||
              !after.single.clonesKnown ||
              !_adminEqual(
                after.single.clones,
                review.snapshots.single.clones,
              )) {
            return _unknown();
          }
          final held = plan.kind == SnapshotRecoveryKind.hold;
          if (held
              ? after.single.userReferences != 1 ||
                    after.single.holds.length != 1 ||
                    !after.single.holds.containsKey('truenas')
              : after.single.userReferences != 0 ||
                    after.single.holds.isNotEmpty) {
            return _unknown();
          }
        case SnapshotRecoveryKind.recursiveCreate:
          for (final dataset in review.datasets) {
            final parent = await _readDatasets(dataset.id);
            final id = '${dataset.id}@${plan.name}';
            if (parent.length != 1 ||
                !_sameSnapshotDataset(parent.single, dataset) ||
                (await _readExact(id)).isNotEmpty) {
              _snapshotStale();
            }
            final result = await write([
              {
                'dataset': dataset.id,
                'name': plan.name,
                'recursive': false,
                'vmware_sync': false,
              },
            ]);
            final receipt = _parseSnapshot(
              result,
              expectedId: id,
              requireSafety: false,
            );
            final after = await _readExact(id);
            if (after.length != 1 ||
                !_sameSnapshotIdentity(after.single, receipt)) {
              return _unknown();
            }
          }
        case SnapshotRecoveryKind.bulkDelete:
          for (final snapshot in review.snapshots) {
            final before = await _readExact(snapshot.id);
            if (before.length != 1 ||
                !_sameSnapshotSafety(before.single, snapshot) ||
                !before.single.canDelete) {
              _snapshotStale();
            }
            final result = await write([
              snapshot.id,
              {'recursive': false, 'defer': false},
            ]);
            if (result != true || (await _readExact(snapshot.id)).isNotEmpty) {
              return _unknown();
            }
          }
      }
      // Every original filesystem must still be the exact reviewed object.
      // This does not constitute a file-by-file recovery/content audit.
      for (final dataset in review.datasets) {
        final after = await _readDatasets(dataset.id);
        if (after.length != 1 || !_sameRecoveryDataset(after.single, dataset)) {
          return _unknown();
        }
      }
      _datasets.clear();
      _snapshots.clear();
      _recoveryReviews.clear();
      return SnapshotOperationResult(
        outcome: SnapshotOperationOutcome.verified,
        message: plan.kind == SnapshotRecoveryKind.rollback
            ? 'The server acknowledged rollback. Filesystem identity, latest snapshot, zero bytes written since it and referenced bytes were read back. Individual files and application consistency were not audited.'
            : 'The ${plan.kind.name} operation and its exact bounded postconditions were read back. No command was retried.',
      );
    } on SnapshotsException catch (error) {
      return sent ? _unknown() : _rejected(error.userMessage);
    } on Object {
      return sent
          ? _unknown()
          : _rejected('Recovery preflight failed. Nothing was sent.');
    } finally {
      _submitting = false;
    }
  }

  SnapshotOperationResult _unknown() {
    _uncertain = true;
    _datasets.clear();
    _snapshots.clear();
    _recoveryReviews.clear();
    return const SnapshotOperationResult(
      outcome: SnapshotOperationOutcome.unknown,
      message: 'The snapshot operation may have applied, but its outcome is unknown. No command was retried. Inspect the original server in TrueNAS and reconnect before making more changes.',
    );
  }

  SnapshotOperationResult _rejected(String message) => SnapshotOperationResult(
    outcome: SnapshotOperationOutcome.rejected,
    message: message,
  );
}

bool _sameSnapshotDataset(SnapshotDataset a, SnapshotDataset b) =>
    a.id == b.id &&
    a.guid == b.guid &&
    a.creationSeconds == b.creationSeconds &&
    a.blockedReason == b.blockedReason;
bool _sameSnapshotIdentity(SnapshotEntry a, SnapshotEntry b) =>
    a.id == b.id &&
    a.dataset == b.dataset &&
    a.guid == b.guid &&
    a.creationSeconds == b.creationSeconds &&
    a.creationTxg == b.creationTxg;

bool _snapshotRecoverySafe(SnapshotEntry s) =>
    !_snapshotSystemDataset(s.dataset) &&
    s.deferredDestroy == false &&
    s.clonesKnown &&
    s.userReferences != null &&
    s.userReferences == s.holds.length;
bool _sameSnapshotSafety(SnapshotEntry a, SnapshotEntry b) =>
    _sameSnapshotIdentity(a, b) &&
    a.userReferences == b.userReferences &&
    a.deferredDestroy == b.deferredDestroy &&
    a.clonesKnown == b.clonesKnown &&
    _adminEqual(a.holds, b.holds) &&
    _adminEqual(a.clones, b.clones);
bool _sameRecovery(SnapshotRecoveryReview a, SnapshotRecoveryReview b) =>
    a.snapshots.length == b.snapshots.length &&
    a.datasets.length == b.datasets.length &&
    a.newerSnapshots.length == b.newerSnapshots.length &&
    Iterable.generate(a.snapshots.length)
        .every((i) => _sameSnapshotSafety(a.snapshots[i], b.snapshots[i])) &&
    Iterable.generate(a.datasets.length)
        .every((i) => _sameRecoveryDataset(a.datasets[i], b.datasets[i])) &&
    Iterable.generate(a.newerSnapshots.length).every(
      (i) => _sameSnapshotSafety(a.newerSnapshots[i], b.newerSnapshots[i]),
    );

bool _sameRecoveryDataset(SnapshotDataset a, SnapshotDataset b) =>
    _sameSnapshotDataset(a, b) &&
    a.readOnly == b.readOnly &&
    a.encrypted == b.encrypted &&
    a.origin == b.origin;

int? _snapshotOptionalNumber(Object? value) {
  final raw = _snapshotRaw(value);
  return raw == null ? null : _snapshotNumber(raw);
}

SnapshotEntry _parseSnapshot(
  Object? raw, {
  required String expectedId,
  bool requireSafety = true,
}) {
  if (raw is! Map ||
      raw['id'] != expectedId ||
      raw['name'] != expectedId ||
      !_snapshotId(expectedId) ||
      raw['type'] != 'SNAPSHOT' ||
      raw['dataset'] != expectedId.split('@').first ||
      raw['snapshot_name'] != expectedId.split('@').last ||
      raw['pool'] != expectedId.split('/').first.split('@').first ||
      raw['properties'] is! Map) {
    _snapshotInvalid();
  }
  final properties = raw['properties'] as Map;
  final guid = _snapshotUint64(_snapshotRaw(properties['guid']));
  final txg = _snapshotUint64(raw['createtxg']);
  final propertyTxg = _snapshotRaw(properties['createtxg']);
  if (propertyTxg != null && propertyTxg != txg) _snapshotInvalid();
  final created = _snapshotNumber(_snapshotRaw(properties['creation']));
  if (created > 253402300799) _snapshotInvalid();
  final used = _snapshotNumber(_snapshotRaw(properties['used']));
  final referenced = _snapshotNumber(_snapshotRaw(properties['referenced']));
  final holds = <String, int>{};
  var safetyKnown = raw['holds'] is Map;
  if (raw['holds'] case final Map tags) {
    if (tags.length > 128) _snapshotInvalid();
    for (final entry in tags.entries) {
      if (!_snapshotText(entry.key, 256) ||
          entry.value is! int ||
          (entry.value as int) < 0) {
        _snapshotInvalid();
      }
      holds[entry.key as String] = entry.value as int;
    }
  }
  final userrefsRaw = _snapshotRaw(properties['userrefs']);
  final userrefs = userrefsRaw == null ? null : _snapshotNumber(userrefsRaw);
  final clonesRaw = _snapshotRaw(properties['clones']);
  final clones = <String>[];
  if (clonesRaw != null && clonesRaw != '-') {
    for (final clone in clonesRaw.split(',')) {
      if (!_snapshotDatasetName(clone) || clones.length >= 128) {
        _snapshotInvalid();
      }
      clones.add(clone);
    }
  }
  final deferRaw = _snapshotRaw(properties['defer_destroy']);
  final deferred = switch (deferRaw) {
    'off' => false,
    'on' => true,
    _ => null,
  };
  safetyKnown =
      safetyKnown && userrefs != null && clonesRaw != null && deferred != null;
  final dataset = raw['dataset'] as String;
  return SnapshotEntry(
    id: expectedId,
    dataset: dataset,
    name: raw['snapshot_name'] as String,
    guid: guid,
    creationSeconds: created,
    creationTxg: txg,
    usedBytes: used,
    referencedBytes: referenced,
    holds: holds,
    userReferences: userrefs,
    clones: clones,
    clonesKnown: clonesRaw != null,
    deferredDestroy: deferred,
    blockedReason: !requireSafety || !safetyKnown
        ? 'Holds, clone dependencies or deferred destruction could not be fully verified. Use TrueNAS.'
        : holds.isNotEmpty || userrefs != 0
        ? 'This snapshot has holds and cannot be deleted here.'
        : clones.isNotEmpty
        ? 'This snapshot has dependent clones and cannot be deleted here.'
        : deferred == true
        ? 'This snapshot is already marked for deferred destruction.'
        : _snapshotSystemDataset(dataset)
        ? 'System or application snapshots require TrueNAS.'
        : null,
  );
}

String? _snapshotRaw(Object? value) =>
    value is Map && value['rawvalue'] is String
    ? value['rawvalue'] as String
    : null;
String _snapshotUint64(Object? value) {
  if (value is! String ||
      !RegExp(r'^[0-9]{1,20}$').hasMatch(value) ||
      BigInt.parse(value) > BigInt.parse('18446744073709551615')) {
    _snapshotInvalid();
  }
  return value;
}

int _snapshotNumber(Object? raw) {
  if (raw is! String || !RegExp(r'^[0-9]{1,16}$').hasMatch(raw)) {
    _snapshotInvalid();
  }
  final value = int.tryParse(raw);
  if (value == null || value > 9007199254740991) _snapshotInvalid();
  return value;
}

bool _snapshotText(Object? value, int limit) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= limit &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(value);
bool _snapshotDatasetName(Object? value) =>
    _snapshotText(value, 200) &&
    RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_./ :\-]*$').hasMatch(value as String) &&
    !value.endsWith('/') &&
    !value.contains('//') &&
    !value.split('/').any((part) => part == '.' || part == '..');
bool _snapshotName(String value) =>
    value.length <= 64 &&
    RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.:-]*$').hasMatch(value);
bool _snapshotId(String value) =>
    value.length <= 240 &&
    value.split('@').length == 2 &&
    _snapshotDatasetName(value.split('@').first) &&
    _snapshotName(value.split('@').last);
bool _snapshotSystemDataset(String value) => value
    .split('/')
    .any(
      (part) =>
          part.startsWith('.') ||
          {
            'ix-applications',
            'ix-apps',
            'boot-pool',
            'freenas-boot',
          }.contains(part),
    );
Never _snapshotInvalid() =>
    throw const SnapshotsException(SnapshotsExceptionReason.invalidResponse);
Never _snapshotStale() =>
    throw const SnapshotsException(SnapshotsExceptionReason.staleSnapshot);
