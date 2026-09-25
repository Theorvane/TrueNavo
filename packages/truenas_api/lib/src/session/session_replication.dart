part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedReplicationSession {
  ReplicationCapabilities get replicationCapabilities;
  Future<ReplicationInventory> loadReplication();
  Future<ReplicationReview> reviewReplication(ReplicationRequest request);
  Future<ReplicationResult> executeReplication(
    ReplicationReview review,
    String confirmation,
  );
  Future<ReplicationResult> pollReplication(ReplicationJob job);
}

final class ReplicationCapabilities {
  const ReplicationCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.available,
    required this.canCreate,
    required this.canUpdate,
    required this.canDelete,
    required this.canRun,
  });
  const ReplicationCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      canCreate = false,
      canUpdate = false,
      canDelete = false,
      canRun = false;
  final bool connected,
      versionSupported,
      available,
      canCreate,
      canUpdate,
      canDelete,
      canRun;
  bool get supported => connected && versionSupported && available;
  bool supports(ReplicationAction action) =>
      supported &&
      switch (action) {
        ReplicationAction.create => canCreate,
        ReplicationAction.update ||
        ReplicationAction.enable ||
        ReplicationAction.disable => canUpdate,
        ReplicationAction.delete => canDelete,
        ReplicationAction.run => canRun,
      };
  String? get blockedReason => !connected
      ? 'Connect to inspect replication.'
      : !versionSupported
      ? 'Native replication requires stable TrueNAS 25.10.'
      : !available
      ? 'Replication, dataset, snapshot, filesystem-choice and job reads are required.'
      : null;
}

/// This native form deliberately represents local, single-source, manual PUSH
/// tasks only. Unsupported tasks remain visible but cannot be rewritten here.
final class ReplicationSettings {
  const ReplicationSettings({
    required this.name,
    required this.source,
    required this.destination,
    this.namingSchema = 'auto-%Y-%m-%d_%H-%M',
    this.retention = 'NONE',
    this.lifetimeValue = 2,
    this.lifetimeUnit = 'WEEK',
    this.enabled = true,
  });
  final String name, source, destination, namingSchema, retention, lifetimeUnit;
  final int lifetimeValue;
  final bool enabled;
  ReplicationSettings copyWith({
    String? name,
    String? source,
    String? destination,
    String? namingSchema,
    String? retention,
    int? lifetimeValue,
    String? lifetimeUnit,
    bool? enabled,
  }) => ReplicationSettings(
    name: name ?? this.name,
    source: source ?? this.source,
    destination: destination ?? this.destination,
    namingSchema: namingSchema ?? this.namingSchema,
    retention: retention ?? this.retention,
    lifetimeValue: lifetimeValue ?? this.lifetimeValue,
    lifetimeUnit: lifetimeUnit ?? this.lifetimeUnit,
    enabled: enabled ?? this.enabled,
  );
  String? get validationError => !_repText(name, 120) || name.trim() != name
      ? 'Use a task name of 1–120 printable characters without outer spaces.'
      : !_repDataset(source) ||
            !_repDataset(destination) ||
            _repOverlap(source, destination)
      ? 'Choose distinct, unrelated non-system source and destination datasets.'
      : !_scheduleNaming(namingSchema)
      ? 'Use a snapshot naming schema containing %Y, %m, %d, %H and %M exactly once.'
      : !{'NONE', 'SOURCE', 'CUSTOM'}.contains(retention) ||
            retention == 'CUSTOM' &&
                (lifetimeValue < 1 ||
                    lifetimeValue > 3650 ||
                    !snapshotScheduleLifetimeUnits.contains(lifetimeUnit))
      ? 'Choose a supported destination retention policy and 1–3650 units.'
      : null;
  Map<String, Object?> get _wire => {
    'name': name,
    'direction': 'PUSH',
    'transport': 'LOCAL',
    'ssh_credentials': null,
    'source_datasets': [source],
    'target_dataset': destination,
    'recursive': false,
    'exclude': <String>[],
    'properties': false,
    'properties_exclude': <String>[],
    'properties_override': <String, String>{},
    'replicate': false,
    'encryption': false,
    'periodic_snapshot_tasks': <int>[],
    'naming_schema': <String>[],
    'also_include_naming_schema': [namingSchema],
    'name_regex': null,
    'auto': false,
    'schedule': null,
    'restrict_schedule': null,
    'only_matching_schedule': false,
    'allow_from_scratch': false,
    'readonly': 'SET',
    'hold_pending_snapshots': false,
    'retention_policy': retention,
    'lifetime_value': retention == 'CUSTOM' ? lifetimeValue : null,
    'lifetime_unit': retention == 'CUSTOM' ? lifetimeUnit : null,
    'lifetimes': <Object?>[],
    'compression': null,
    'speed_limit': null,
    'large_block': true,
    'embed': false,
    'compressed': true,
    'retries': 1,
    'logging_level': null,
    'enabled': enabled,
    'sudo': false,
    'netcat_active_side': null,
    'netcat_active_side_listen_address': null,
    'netcat_active_side_port_min': null,
    'netcat_active_side_port_max': null,
    'netcat_passive_side_connect_address': null,
    'encryption_inherit': null,
    'encryption_key_format': null,
  };
}

final class ReplicationDataset {
  const ReplicationDataset({
    required this.id,
    required this.guid,
    required this.readonly,
    this.blockedReason,
  });
  final String id, guid;
  final bool readonly;
  final String? blockedReason;
  bool get available => blockedReason == null;
}

final class ReplicationTask {
  const ReplicationTask({
    required this.id,
    required this.name,
    required this.source,
    required this.destination,
    required this.transport,
    required this.direction,
    required this.enabled,
    required this.state,
    this.settings,
    this.blockedReason,
  });
  final int id;
  final String name, source, destination, transport, direction, state;
  final bool enabled;
  final ReplicationSettings? settings;
  final String? blockedReason;
  bool get available => settings != null && blockedReason == null;
}

final class ReplicationInventory {
  ReplicationInventory({
    required this.endpoint,
    required List<ReplicationTask> tasks,
    required List<ReplicationDataset> datasets,
    this.conflictingJob = false,
  }) : tasks = List.unmodifiable(tasks),
       datasets = List.unmodifiable(datasets);
  final String endpoint;
  final List<ReplicationTask> tasks;
  final List<ReplicationDataset> datasets;
  final bool conflictingJob;
}

enum ReplicationAction { create, update, enable, disable, run, delete }

final class ReplicationRequest {
  const ReplicationRequest({
    required this.inventory,
    required this.action,
    this.task,
    this.settings,
  });
  final ReplicationInventory inventory;
  final ReplicationAction action;
  final ReplicationTask? task;
  final ReplicationSettings? settings;
  ReplicationSettings? get effectiveSettings => switch (action) {
    ReplicationAction.create || ReplicationAction.update => settings,
    ReplicationAction.enable => task?.settings?.copyWith(enabled: true),
    ReplicationAction.disable => task?.settings?.copyWith(enabled: false),
    _ => task?.settings,
  };
  String get target =>
      '${action.name.toUpperCase()} ${task?.name ?? settings?.name ?? ''}';
  String? get validationError {
    if (inventory.conflictingJob) {
      return 'A storage or replication job is active. Wait for its outcome first.';
    }
    if (action == ReplicationAction.create
        ? task != null || settings == null
        : task == null || !inventory.tasks.any((t) => identical(t, task))) {
      return 'Choose an exact task from the current inventory.';
    }
    if (action != ReplicationAction.create && !task!.available) {
      return task!.blockedReason ??
          'This task requires the advanced TrueNAS workflow.';
    }
    if (action != ReplicationAction.create &&
        action != ReplicationAction.update &&
        settings != null) {
      return 'This action does not accept replacement settings.';
    }
    final value = effectiveSettings;
    if (value == null || value.validationError != null) {
      return value?.validationError ??
          'Review valid local replication settings.';
    }
    if (inventory.tasks.any((t) => t.id != task?.id && t.name == value.name)) {
      return 'Another replication task uses this name.';
    }
    if (action == ReplicationAction.run && !value.enabled) {
      return 'Enable this manual task before running it.';
    }
    if (action == ReplicationAction.enable && task!.enabled ||
        action == ReplicationAction.disable && !task!.enabled) {
      return 'The task already has this enabled state.';
    }
    final source = inventory.datasets
        .where((d) => d.id == value.source)
        .firstOrNull;
    final destination = inventory.datasets
        .where((d) => d.id == value.destination)
        .firstOrNull;
    final parent = inventory.datasets
        .where(
          (d) =>
              d.id ==
              value.destination.substring(
                0,
                value.destination.lastIndexOf('/'),
              ),
        )
        .firstOrNull;
    if (source?.available != true ||
        (destination ?? parent)?.available != true) {
      return 'Source and existing destination (or its direct parent) must be available, unencrypted, non-system filesystems.';
    }
    if (destination != null && !destination.readonly) {
      return 'An existing destination must already be read-only. Protect it in TrueNAS first.';
    }
    if (inventory.datasets.any(
      (d) => d.id.startsWith('${value.destination}/'),
    )) {
      return 'Destination trees with child datasets require the advanced replication workflow.';
    }
    return null;
  }
}

final class ReplicationReview {
  ReplicationReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
    required this.sourceSnapshots,
    required this.destinationSnapshots,
    required this.createsDestination,
  }) : warnings = List.unmodifiable(warnings);
  final ReplicationRequest request;
  final String endpoint;
  final List<String> warnings;
  final int sourceSnapshots, destinationSnapshots;
  final bool createsDestination;
  String get target => request.target;
  ReplicationAction get action => request.action;
}

final class ReplicationJob {
  const ReplicationJob({
    required this.id,
    required this.taskId,
    required this.taskName,
    required this.endpoint,
  });
  final int id, taskId;
  final String taskName, endpoint;
}

enum ReplicationOutcome { succeeded, pending, failed, rejected, unknown }

final class ReplicationResult {
  const ReplicationResult(this.outcome, this.message, {this.job, this.percent});
  final ReplicationOutcome outcome;
  final String message;
  final ReplicationJob? job;
  final double? percent;
}

enum ReplicationExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class ReplicationException implements Exception {
  const ReplicationException(this.reason);
  final ReplicationExceptionReason reason;
  String get userMessage => switch (reason) {
    ReplicationExceptionReason.notAuthenticated =>
      'A current authenticated connection is required.',
    ReplicationExceptionReason.unsupportedVersion =>
      'This replication adapter supports stable TrueNAS 25.10 only.',
    ReplicationExceptionReason.unavailableMethod =>
      'Required public replication methods or permissions are unavailable.',
    ReplicationExceptionReason.busy =>
      'Another server operation is pending or needs verification.',
    ReplicationExceptionReason.staleReview => 'The connection, inventory or exact review changed. Nothing was submitted.',
    ReplicationExceptionReason.invalidRequest => 'Choose supported local, manual replication settings and review the exact target.',
    ReplicationExceptionReason.invalidResponse =>
      'Replication safety information could not be validated.',
    ReplicationExceptionReason.unavailable =>
      'Replication information is unavailable. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

final class _ReplicationObservation {
  const _ReplicationObservation(this.inventory, this.fingerprint);
  final ReplicationInventory inventory;
  final String fingerprint;
}

final class _ReplicationReviewProof {
  const _ReplicationReviewProof(this.issued, this.fingerprint, this.snapshots);
  final DateTime issued;
  final String fingerprint, snapshots;
}

final class _SessionReplication {
  _SessionReplication({
    required this.client,
    required ServerSummary summary,
    required Object? metadata,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherMutationBusy,
    required this.requestTimeout,
  }) : _versionSupported =
           _managementVersion(summary.version) == _ManagementVersion.v2510,
       _endpoint = summary.endpointUri.toString(),
       _metadata = metadata is Map ? Map.of(metadata) : const {};
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherMutationBusy;
  final Duration requestTimeout;
  final bool _versionSupported;
  final String _endpoint;
  final Map _metadata;
  bool _calling = false, _uncertain = false;
  final Map<ReplicationInventory, _ReplicationObservation> _inventories = {};
  final Map<ReplicationReview, _ReplicationReviewProof> _reviews = {};
  final Set<ReplicationJob> _jobs = {};
  bool get isBusy => _calling || _uncertain || _jobs.isNotEmpty;
  static const _reads = {
    'replication.query',
    'pool.dataset.query',
    'pool.filesystem_choices',
    'pool.snapshot.query',
    'core.get_jobs',
  };
  bool _method(String name, {bool job = false, bool write = false}) {
    final row = _metadata[name];
    return row is Map &&
        row['job'] == job &&
        row['uploadable'] == false &&
        row['downloadable'] == false &&
        (row['check_pipes'] == null ||
            row['check_pipes'] == false ||
            row['check_pipes'] is List &&
                (row['check_pipes'] as List).isEmpty) &&
        row['private'] != true &&
        row['_private'] != true &&
        (!write || row['no_auth_required'] == false);
  }

  ReplicationCapabilities get capabilities => ReplicationCapabilities(
    connected: isCurrent(),
    versionSupported: _versionSupported,
    available: _reads.every(_method),
    canCreate: _method('replication.create', write: true),
    canUpdate: _method('replication.update', write: true),
    canDelete: _method('replication.delete', write: true),
    canRun: _method('replication.run', job: true, write: true),
  );
  void _guard([ReplicationAction? action]) {
    if (!isCurrent()) {
      throw const ReplicationException(
        ReplicationExceptionReason.notAuthenticated,
      );
    }
    if (!_versionSupported) {
      throw const ReplicationException(
        ReplicationExceptionReason.unsupportedVersion,
      );
    }
    if (!capabilities.supported ||
        action != null && !capabilities.supports(action)) {
      throw const ReplicationException(
        ReplicationExceptionReason.unavailableMethod,
      );
    }
  }

  Future<Object?> _call(String method, List<Object?> params) async {
    _guard();
    final result = await client
        .call(method, id: nextId(), params: params)
        .timeout(requestTimeout);
    _guard();
    return result;
  }

  Future<_ReplicationObservation> _read() async {
    final rawTasks = await _call('replication.query', [
      [],
      {'limit': 129, 'select': _repTaskSelect},
    ]);
    final rawDatasets = await _call('pool.dataset.query', [
      [],
      {
        'limit': 513,
        'select': [
          'id',
          'type',
          'guid',
          'locked',
          'encrypted',
          'readonly',
          ['user_properties.managedby', 'managedby'],
        ],
        'extra': {
          'flat': true,
          'retrieve_children': false,
          'retrieve_user_props': true,
          'properties': ['guid', 'readonly', 'encryption', 'keystatus'],
        },
      },
    ]);
    final choices = await _call('pool.filesystem_choices', const []);
    final jobs = await _call('core.get_jobs', const [
      [
        [
          'state',
          'in',
          ['WAITING', 'RUNNING'],
        ],
      ],
      {
        'limit': 129,
        'select': ['id', 'method', 'state'],
      },
    ]);
    if (rawTasks is! List ||
        rawTasks.length > 128 ||
        rawDatasets is! List ||
        rawDatasets.length > 512 ||
        choices is! List ||
        choices.length > 512 ||
        choices.any((c) => !_scheduleDatasetName(c)) ||
        choices.toSet().length != choices.length ||
        jobs is! List ||
        jobs.length > 128) {
      _repInvalid();
    }
    final datasets = <ReplicationDataset>[];
    final identities = <Map<String, Object?>>[];
    for (final row in rawDatasets) {
      if (row is! Map ||
          !_scheduleDatasetName(row['id']) ||
          !{'FILESYSTEM', 'VOLUME'}.contains(row['type']) ||
          row['locked'] is! bool ||
          row['encrypted'] is! bool) {
        _repInvalid();
      }
      final guid = _repUint64(_snapshotRaw(row['guid']));
      final readonly = _snapshotRaw(row['readonly']);
      final managed = row.containsKey('managedby')
          ? _snapshotRaw(row['managedby'])
          : '-';
      if (guid == null || !{'on', 'off'}.contains(readonly)) _repInvalid();
      final id = row['id'] as String;
      final blocked =
          !_repDataset(id) ||
              !choices.contains(id) ||
              row['type'] != 'FILESYSTEM'
          ? 'System, pool-root and non-filesystem datasets are protected.'
          : row['locked'] == true || row['encrypted'] == true
          ? 'Locked and encrypted datasets require an encryption-aware workflow.'
          : managed == null || !{'', '-'}.contains(managed)
          ? 'Externally managed datasets are protected.'
          : null;
      datasets.add(
        ReplicationDataset(
          id: id,
          guid: guid,
          readonly: readonly == 'on',
          blockedReason: blocked,
        ),
      );
      identities.add({
        'id': id,
        'guid': guid,
        'readonly': readonly,
        'blocked': blocked,
        'type': row['type'],
        'locked': row['locked'],
        'encrypted': row['encrypted'],
        'managed': managed,
      });
    }
    if (datasets.map((d) => d.id).toSet().length != datasets.length ||
        datasets.map((d) => d.guid).toSet().length != datasets.length) {
      _repInvalid();
    }
    // A managed/encrypted ancestor also protects apparently unmarked children.
    final protected = datasets
        .where((d) => d.blockedReason != null && d.id.contains('/'))
        .map((d) => d.id)
        .toList();
    protected.addAll(
      identities
          .where(
            (d) =>
                d['locked'] == true ||
                d['encrypted'] == true ||
                d['managed'] == null ||
                !{'', '-'}.contains(d['managed']),
          )
          .map((d) => d['id'] as String),
    );
    for (var index = 0; index < datasets.length; index++) {
      final row = datasets[index];
      if (protected.any((p) => row.id.startsWith('$p/'))) {
        datasets[index] = ReplicationDataset(
          id: row.id,
          guid: row.guid,
          readonly: row.readonly,
          blockedReason: 'A protected ancestor requires the advanced workflow.',
        );
      }
    }
    final tasks = rawTasks.map(_repTask).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (tasks.map((t) => t.id).toSet().length != tasks.length) _repInvalid();
    var conflict = tasks.any((t) => {'RUNNING', 'WAITING'}.contains(t.state));
    for (final row in jobs) {
      if (row is! Map ||
          !_repId(row['id']) ||
          !_repText(row['method'], 128) ||
          !{'WAITING', 'RUNNING'}.contains(row['state'])) {
        _repInvalid();
      }
      final method = row['method'] as String;
      conflict |=
          [
            'replication.',
            'pool.',
            'filesystem.',
            'cloudsync.',
            'boot.',
            'update.',
          ].any(method.startsWith) ||
          {'system.reboot', 'system.shutdown'}.contains(method);
    }
    datasets.sort((a, b) => a.id.compareTo(b.id));
    identities.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    final rows =
        rawTasks
            .map(
              (r) => Map<String, Object?>.from(r as Map)
                ..remove('task_state')
                ..remove('job'),
            )
            .toList()
          ..sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
    return _ReplicationObservation(
      ReplicationInventory(
        endpoint: _endpoint,
        tasks: tasks,
        datasets: datasets,
        conflictingJob: conflict,
      ),
      _repCanonical({
        'tasks': rows,
        'datasets': identities,
        'conflict': conflict,
      }),
    );
  }

  Future<ReplicationInventory> load() async {
    _guard();
    if (_calling) {
      throw const ReplicationException(ReplicationExceptionReason.busy);
    }
    _calling = true;
    _inventories.clear();
    _reviews.clear();
    try {
      final read = await _read();
      _inventories[read.inventory] = read;
      return read.inventory;
    } on ReplicationException {
      rethrow;
    } on Object {
      throw const ReplicationException(ReplicationExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<List<Map<String, String>>> _snapshots(
    ReplicationSettings settings,
  ) async {
    final scope = [settings.source, settings.destination];
    final rows = await _call('pool.snapshot.query', [
      [
        ['dataset', 'in', scope],
      ],
      {
        'limit': 257,
        'select': ['id', 'dataset', 'properties'],
        'extra': {
          'properties': ['guid', 'createtxg'],
        },
      },
    ]);
    if (rows is! List || rows.length > 256) _repInvalid();
    final snapshots = <Map<String, String>>[];
    for (final row in rows) {
      if (row is! Map ||
          !_repText(row['id'], 512) ||
          !scope.contains(row['dataset']) ||
          !(row['id'] as String).startsWith('${row['dataset']}@') ||
          (row['id'] as String).split('@').length != 2 ||
          row['properties'] is! Map) {
        _repInvalid();
      }
      final props = row['properties'] as Map;
      final guid = _repUint64(_snapshotRaw(props['guid']));
      final txg = _repUint64(_snapshotRaw(props['createtxg']));
      if (guid == null || txg == null) _repInvalid();
      snapshots.add({
        'id': row['id'] as String,
        'dataset': row['dataset'] as String,
        'guid': guid,
        'txg': txg,
      });
    }
    snapshots.sort((a, b) => a['id']!.compareTo(b['id']!));
    if (snapshots.map((s) => s['id']).toSet().length != snapshots.length) {
      _repInvalid();
    }
    return snapshots;
  }

  void _runSafety(
    ReplicationRequest request,
    List<Map<String, String>> snapshots,
  ) {
    if (request.action != ReplicationAction.run) return;
    final settings = request.effectiveSettings!;
    final sources = snapshots
        .where((s) => s['dataset'] == settings.source)
        .toList();
    final targets = snapshots
        .where((s) => s['dataset'] == settings.destination)
        .toList();
    final exists = request.inventory.datasets.any(
      (d) => d.id == settings.destination,
    );
    if (sources.isEmpty ||
        exists &&
            !targets.any(
              (t) => sources.any(
                (s) =>
                    s['guid'] == t['guid'] &&
                    s['id']!.split('@').last == t['id']!.split('@').last,
              ),
            )) {
      throw const ReplicationException(
        ReplicationExceptionReason.invalidRequest,
      );
    }
  }

  Future<ReplicationReview> review(ReplicationRequest request) async {
    _guard(request.action);
    if (isBusy || isOtherMutationBusy()) {
      throw const ReplicationException(ReplicationExceptionReason.busy);
    }
    final baseline = _inventories[request.inventory];
    if (baseline == null) {
      throw const ReplicationException(ReplicationExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      throw const ReplicationException(
        ReplicationExceptionReason.invalidRequest,
      );
    }
    _calling = true;
    try {
      final fresh = await _read();
      if (fresh.fingerprint != baseline.fingerprint) {
        throw const ReplicationException(
          ReplicationExceptionReason.staleReview,
        );
      }
      final settings = request.effectiveSettings!;
      final snapshots = await _snapshots(settings);
      _runSafety(request, snapshots);
      final creates = !request.inventory.datasets.any(
        (d) => d.id == settings.destination,
      );
      final result = ReplicationReview(
        request: request,
        endpoint: _endpoint,
        sourceSnapshots: snapshots
            .where((s) => s['dataset'] == settings.source)
            .length,
        destinationSnapshots: snapshots
            .where((s) => s['dataset'] == settings.destination)
            .length,
        createsDestination: creates,
        warnings: [
          'LOCAL PUSH on $_endpoint: ${settings.source} → ${settings.destination}. Only this source dataset is included; child datasets are not replicated.',
          'Manual task only: no schedule, snapshot-task binding or automatic run is created. Run requires a separate exact confirmation. Server retries are fixed to 1; the app never retries.',
          'Only snapshots matching ${settings.namingSchema} are eligible. Displayed snapshot counts are totals, not eligibility, transfer-size or recoverability proofs.',
          if (creates) 'Running may create the exact destination dataset. Its existing direct parent is identity-checked; available space and external consumers are not independently attested.',
          if (!creates) 'Running receives into the existing read-only destination. A common snapshot name and GUID are required; receive may roll back destination changes. No from-scratch overwrite is allowed.',
          'Dataset properties and encryption keys are not replicated. Destination readonly is SET after receive. Review property compatibility and recovery requirements in TrueNAS.',
          settings.retention == 'NONE'
              ? 'Destination retention NONE: this task does not apply snapshot-retention deletion.'
              : settings.retention == 'SOURCE'
              ? 'Destination retention SOURCE can delete destination snapshots absent from the source. All displayed destination snapshots are potentially affected; this is not an exact deletion preview.'
              : 'Destination retention CUSTOM can delete matching destination snapshots older than ${settings.lifetimeValue} ${settings.lifetimeUnit}. Snapshot dates and server policy determine deletion; displayed counts are not an exact expiry preview.',
          if (request.action == ReplicationAction.delete) 'Delete removes the manual replication task, not its datasets or snapshots. Its destination retention will no longer be maintained by this task.',
          'Settings, dataset GUIDs and snapshot identities are re-read before dispatch. Other clients can still change them afterwards; the API has no atomic compare-and-swap. Keep an independent verified backup.',
        ],
      );
      _reviews.clear();
      _reviews[result] = _ReplicationReviewProof(
        DateTime.now(),
        fresh.fingerprint,
        _repCanonical(snapshots),
      );
      return result;
    } on ReplicationException {
      rethrow;
    } on Object {
      throw const ReplicationException(ReplicationExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<ReplicationResult> execute(
    ReplicationReview review,
    String confirmation,
  ) async {
    _guard(review.action);
    if (isBusy || isOtherMutationBusy()) {
      throw const ReplicationException(ReplicationExceptionReason.busy);
    }
    final proof = _reviews.remove(review);
    if (proof == null ||
        !_inventories.containsKey(review.request.inventory) ||
        DateTime.now().difference(proof.issued) > const Duration(minutes: 5) ||
        confirmation != review.target ||
        review.endpoint != _endpoint) {
      throw const ReplicationException(ReplicationExceptionReason.staleReview);
    }
    if (review.request.validationError != null) {
      throw const ReplicationException(
        ReplicationExceptionReason.invalidRequest,
      );
    }
    _calling = true;
    var sent = false;
    try {
      final fresh = await _read();
      final snapshots = await _snapshots(review.request.effectiveSettings!);
      if (fresh.fingerprint != proof.fingerprint ||
          _repCanonical(snapshots) != proof.snapshots) {
        return const ReplicationResult(
          ReplicationOutcome.rejected,
          'Replication, dataset or snapshot state changed. Nothing was sent.',
        );
      }
      _runSafety(review.request, snapshots);
      if (isOtherMutationBusy()) {
        throw const ReplicationException(ReplicationExceptionReason.busy);
      }
      _guard(review.action);
      final request = review.request;
      final method = switch (request.action) {
        ReplicationAction.create => 'replication.create',
        ReplicationAction.run => 'replication.run',
        ReplicationAction.delete => 'replication.delete',
        _ => 'replication.update',
      };
      final params = switch (request.action) {
        ReplicationAction.create => <Object?>[request.effectiveSettings!._wire],
        ReplicationAction.update => <Object?>[
          request.task!.id,
          request.effectiveSettings!._wire,
        ],
        ReplicationAction.enable || ReplicationAction.disable => <Object?>[
          request.task!.id,
          {'enabled': request.action == ReplicationAction.enable},
        ],
        _ => <Object?>[request.task!.id],
      };
      sent = true;
      final result = await _call(method, params);
      _reviews.clear();
      _inventories.clear();
      if (request.action == ReplicationAction.run) {
        if (!_repId(result)) return _unknown();
        final job = ReplicationJob(
          id: result as int,
          taskId: request.task!.id,
          taskName: request.task!.name,
          endpoint: _endpoint,
        );
        _jobs.add(job);
        return ReplicationResult(
          ReplicationOutcome.pending,
          'Run accepted as an owned job. Completion is not yet verified; use Check job. No automatic polling or replay.',
          job: job,
        );
      }
      if (request.action == ReplicationAction.delete
          ? result != true
          : result is! Map ||
                !_repId(result['id']) ||
                request.action == ReplicationAction.create &&
                    request.inventory.tasks.any((t) => t.id == result['id']) ||
                request.task != null && result['id'] != request.task!.id ||
                !_repMatches(result, request.effectiveSettings!)) {
        return _unknown();
      }
      final after = await _read();
      if (request.action == ReplicationAction.delete) {
        if (after.inventory.tasks.any((t) => t.id == request.task!.id)) {
          return _unknown();
        }
      } else {
        final id = (result as Map)['id'];
        final task = after.inventory.tasks.where((t) => t.id == id).firstOrNull;
        if (task?.settings == null ||
            _repCanonical(task!.settings!._wire) !=
                _repCanonical(request.effectiveSettings!._wire)) {
          return _unknown();
        }
      }
      return const ReplicationResult(
        ReplicationOutcome.succeeded,
        'The exact task configuration was re-read and verified. No replication run was requested.',
      );
    } on JsonRpcRemoteException catch (error) {
      if (sent && !_repDenied(error)) return _unknown();
      return const ReplicationResult(
        ReplicationOutcome.rejected,
        'The request was denied or preflight was unavailable. Remote details were withheld.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const ReplicationResult(
              ReplicationOutcome.rejected,
              'Preflight could not be verified. No mutation was sent.',
            );
    } finally {
      _calling = false;
    }
  }

  ReplicationResult _unknown({ReplicationJob? job}) {
    if (job == null) _uncertain = true;
    _reviews.clear();
    _inventories.clear();
    return ReplicationResult(
      ReplicationOutcome.unknown,
      job == null
          ? 'The operation may have taken effect. Inspect the original TrueNAS server and reconnect before another change. Do not repeat this request.'
          : 'The owned job could not be verified. Its lock remains held; explicitly check this same job or inspect the original server. Nothing is replayed.',
      job: job,
    );
  }

  Future<ReplicationResult> poll(ReplicationJob job) async {
    _guard();
    if (_calling || !_jobs.contains(job) || job.endpoint != _endpoint) {
      throw const ReplicationException(ReplicationExceptionReason.staleReview);
    }
    _calling = true;
    try {
      final rows = await _call('core.get_jobs', [
        [
          ['id', '=', job.id],
        ],
        {
          'limit': 2,
          'select': [
            'id',
            'method',
            'arguments',
            'state',
            'progress',
            'result',
          ],
        },
      ]);
      if (rows is! List || rows.length != 1 || rows.single is! Map) {
        return _unknown(job: job);
      }
      final row = rows.single as Map;
      if (row['id'] is! int ||
          row['id'] != job.id ||
          row['method'] != 'replication.run' ||
          _repCanonical(row['arguments']) !=
              _repCanonical([job.taskId, true])) {
        return _unknown(job: job);
      }
      if ({'WAITING', 'RUNNING'}.contains(row['state'])) {
        final progress = row['progress'];
        final percent = progress is Map ? progress['percent'] : null;
        return ReplicationResult(
          ReplicationOutcome.pending,
          'Owned replication job is ${row['state'] == 'RUNNING' ? 'running' : 'waiting'}. Progress is server-reported.',
          job: job,
          percent:
              percent is num &&
                  percent.isFinite &&
                  percent >= 0 &&
                  percent <= 100
              ? percent.toDouble()
              : null,
        );
      }
      if (!{'SUCCESS', 'FAILED', 'ABORTED'}.contains(row['state']) ||
          row['state'] == 'SUCCESS' &&
              (!row.containsKey('result') || row['result'] != null)) {
        return _unknown(job: job);
      }
      _jobs.remove(job);
      _reviews.clear();
      _inventories.clear();
      return ReplicationResult(
        row['state'] == 'SUCCESS'
            ? ReplicationOutcome.succeeded
            : ReplicationOutcome.failed,
        row['state'] == 'SUCCESS'
            ? 'The exact owned job reported success. This does not independently verify backup integrity; perform a recovery test separately.'
            : 'The owned job stopped without success. Partial destination or retention effects may remain. No retry was requested.',
      );
    } on Object {
      return _unknown(job: job);
    } finally {
      _calling = false;
    }
  }
}

const _repTaskSelect = [
  'id',
  'name',
  'direction',
  'transport',
  ['ssh_credentials.id', 'credential_id'],
  'source_datasets',
  'target_dataset',
  'recursive',
  'exclude',
  'properties',
  'properties_exclude',
  'properties_override',
  'replicate',
  'encryption',
  'periodic_snapshot_tasks',
  'naming_schema',
  'also_include_naming_schema',
  'name_regex',
  'auto',
  'schedule',
  'restrict_schedule',
  'only_matching_schedule',
  'allow_from_scratch',
  'readonly',
  'hold_pending_snapshots',
  'retention_policy',
  'lifetime_value',
  'lifetime_unit',
  'lifetimes',
  'compression',
  'speed_limit',
  'large_block',
  'embed',
  'compressed',
  'retries',
  'logging_level',
  'enabled',
  'sudo',
  'netcat_active_side',
  'netcat_active_side_listen_address',
  'netcat_active_side_port_min',
  'netcat_active_side_port_max',
  'netcat_passive_side_connect_address',
  'encryption_inherit',
  'encryption_key_format',
  ['state.state', 'task_state'],
  ['job.id', 'last_job_id'],
  ['job.state', 'last_job_state'],
];
ReplicationTask _repTask(Object? value) {
  if (value is! Map ||
      !_repId(value['id']) ||
      !_repText(value['name'], 120) ||
      !{'PUSH', 'PULL'}.contains(value['direction']) ||
      !{'LOCAL', 'SSH', 'SSH+NETCAT'}.contains(value['transport']) ||
      value['source_datasets'] is! List ||
      (value['source_datasets'] as List).isEmpty ||
      (value['source_datasets'] as List).length > 128 ||
      (value['source_datasets'] as List).any((s) => !_scheduleDatasetName(s)) ||
      !_scheduleDatasetName(value['target_dataset']) ||
      value['enabled'] is! bool ||
      !_repText(value['task_state'], 32)) {
    _repInvalid();
  }
  final rawState = value['task_state'];
  final state =
      {
        'PENDING',
        'RUNNING',
        'WAITING',
        'HOLD',
        'FINISHED',
        'ERROR',
        'FAILED',
      }.contains(rawState)
      ? rawState as String
      : 'UNKNOWN';
  final names = value['also_include_naming_schema'];
  ReplicationSettings? settings;
  if ((value['source_datasets'] as List).length == 1 &&
      names is List &&
      names.length == 1 &&
      names.single is String &&
      {'NONE', 'SOURCE', 'CUSTOM'}.contains(value['retention_policy'])) {
    final retention = value['retention_policy'] as String;
    if (retention != 'CUSTOM' ||
        value['lifetime_value'] is int && value['lifetime_unit'] is String) {
      final candidate = ReplicationSettings(
        name: value['name'] as String,
        source: (value['source_datasets'] as List).single as String,
        destination: value['target_dataset'] as String,
        namingSchema: names.single as String,
        retention: retention,
        lifetimeValue: retention == 'CUSTOM'
            ? value['lifetime_value'] as int
            : 2,
        lifetimeUnit: retention == 'CUSTOM'
            ? value['lifetime_unit'] as String
            : 'WEEK',
        enabled: value['enabled'] as bool,
      );
      if (candidate.validationError == null && _repMatches(value, candidate)) {
        settings = candidate;
      }
    }
  }
  final activeJob = value['last_job_id'];
  final jobState = value['last_job_state'];
  if (activeJob != null && !_repId(activeJob)) _repInvalid();
  return ReplicationTask(
    id: value['id'] as int,
    name: value['name'] as String,
    source: (value['source_datasets'] as List).join(', '),
    destination: value['target_dataset'] as String,
    transport: value['transport'] as String,
    direction: value['direction'] as String,
    enabled: value['enabled'] as bool,
    state: state,
    settings: settings,
    blockedReason: settings == null
        ? 'Advanced, remote, recursive, encrypted or scheduled task: inspect in TrueNAS. Its settings are never flattened into this form.'
        : activeJob != null &&
                  !{'SUCCESS', 'FAILED', 'ABORTED'}.contains(jobState) ||
              !{'PENDING', 'FINISHED', 'ERROR', 'FAILED'}.contains(state)
        ? 'This task is active, held or has an unknown state.'
        : null,
  );
}

bool _repMatches(Map row, ReplicationSettings settings) {
  for (final entry in settings._wire.entries) {
    if (entry.key == 'ssh_credentials') {
      if (row.containsKey('credential_id')
          ? row['credential_id'] != null
          : row['ssh_credentials'] != null) {
        return false;
      }
    } else if (!row.containsKey(entry.key) ||
        _repCanonical(row[entry.key]) != _repCanonical(entry.value)) {
      return false;
    }
  }
  return true;
}

String _repCanonical(Object? value) => jsonEncode(
  value is Map
      ? {
          for (final k in value.keys.map((k) => k.toString()).toList()..sort())
            k: jsonDecode(_repCanonical(value[k])),
        }
      : value is List
      ? value.map((v) => jsonDecode(_repCanonical(v))).toList()
      : value,
);
bool _repText(Object? value, int max) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= max &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f]').hasMatch(value);
bool _repId(Object? value) =>
    value is int && value > 0 && value <= 9007199254740991;
bool _repDataset(Object? value) =>
    _scheduleDatasetName(value) &&
    (value as String).contains('/') &&
    !value
        .split('/')
        .any(
          (p) =>
              p.startsWith('.') ||
              {
                'ix-apps',
                'ix-applications',
                'ix-virt',
                'boot-pool',
                'freenas-boot',
              }.contains(p),
        );
bool _repOverlap(String a, String b) =>
    a == b || a.startsWith('$b/') || b.startsWith('$a/');
bool _repDenied(JsonRpcRemoteException error) =>
    error.data is Map &&
    (error.data as Map)['errno'] is int &&
    {1, 13}.contains((error.data as Map)['errno']);
String? _repUint64(String? value) =>
    value != null &&
        RegExp(r'^[0-9]{1,20}$').hasMatch(value) &&
        BigInt.parse(value) > BigInt.zero &&
        BigInt.parse(value) <= BigInt.parse('18446744073709551615')
    ? value
    : null;
Never _repInvalid() => throw const ReplicationException(
  ReplicationExceptionReason.invalidResponse,
);
