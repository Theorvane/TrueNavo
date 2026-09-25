part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedCloudSyncSession {
  CloudSyncCapabilities get cloudSyncCapabilities;
  Future<CloudSyncInventory> loadCloudSync();
  Future<CloudSyncReview> reviewCloudSync(CloudSyncRequest request);
  Future<CloudSyncResult> executeCloudSync(
    CloudSyncReview review,
    String confirmation,
  );
  Future<CloudSyncResult> pollCloudSync(CloudSyncJob job);
}

final class CloudSyncCapabilities {
  const CloudSyncCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.available,
    required this.canCreate,
    required this.canUpdate,
    required this.canDelete,
    required this.canRun,
  });
  const CloudSyncCapabilities.disconnected()
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
  bool allows(CloudSyncAction action) =>
      supported &&
      switch (action) {
        CloudSyncAction.create => canCreate,
        CloudSyncAction.update => canUpdate,
        CloudSyncAction.delete => canDelete,
        CloudSyncAction.run => canRun,
      };
  String? get blockedReason => !connected
      ? 'Connect to inspect cloud sync tasks.'
      : !versionSupported
      ? 'Native cloud sync requires stable TrueNAS 25.10.'
      : !available
      ? 'Task, credential-reference, dataset, path, timezone and job reads are required.'
      : null;
}

final class CloudSyncCredential {
  const CloudSyncCredential({
    required this.id,
    required this.name,
    required this.provider,
  });
  final int id;
  final String name, provider;
  bool get supported => const {'S3', 'DROPBOX'}.contains(provider);
}

final class CloudSyncDataset {
  const CloudSyncDataset({
    required this.id,
    required this.guid,
    required this.path,
    this.blockedReason,
  });
  final String id, guid, path;
  final String? blockedReason;
}

final class CloudSyncSettings {
  CloudSyncSettings({
    required this.path,
    required this.credentialId,
    this.description = '',
    this.direction = 'PUSH',
    this.transferMode = 'COPY',
    this.folder = '',
    this.bucket = '',
    this.region = '',
    this.storageClass = '',
    this.serverSideEncryption = false,
    this.dropboxChunkSize = 48,
    this.enabled = false,
    this.minute = '0',
    this.hour = '2',
    this.dom = '*',
    this.month = '*',
    this.dow = '*',
    List<String> exclude = const [],
  }) : exclude = List.unmodifiable(exclude);
  final String path,
      description,
      direction,
      transferMode,
      folder,
      bucket,
      region,
      storageClass,
      minute,
      hour,
      dom,
      month,
      dow;
  final int credentialId, dropboxChunkSize;
  final bool enabled, serverSideEncryption;
  final List<String> exclude;
  String? validate(String provider) {
    if (!_cloudPath(path) ||
        credentialId <= 0 ||
        !_cloudText(description, 256, empty: true)) {
      return 'Choose an exact local dataset and existing credential; use a short description.';
    }
    if (!{'PUSH', 'PULL'}.contains(direction) ||
        !{'COPY', 'SYNC', 'MOVE'}.contains(transferMode)) {
      return 'Choose PUSH/PULL and COPY/SYNC/MOVE.';
    }
    if (!_cloudFolder(folder) || !{'S3', 'DROPBOX'}.contains(provider)) {
      return 'Only bounded S3 and Dropbox tasks are supported; choose a non-root relative remote folder.';
    }
    if (provider == 'S3' &&
        (!RegExp(r'^[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]$').hasMatch(bucket) ||
            bucket.contains('..') ||
            bucket.contains('.-') ||
            bucket.contains('-.') ||
            !RegExp(r'^[a-z0-9-]{0,63}$').hasMatch(region) ||
            !{
              '',
              'STANDARD',
              'REDUCED_REDUNDANCY',
              'STANDARD_IA',
              'ONEZONE_IA',
              'INTELLIGENT_TIERING',
              'GLACIER',
              'GLACIER_IR',
              'DEEP_ARCHIVE',
            }.contains(storageClass))) {
      return 'Use a bounded S3 bucket, region and supported storage class.';
    }
    if (provider == 'DROPBOX' &&
        (bucket.isNotEmpty ||
            region.isNotEmpty ||
            storageClass.isNotEmpty ||
            serverSideEncryption ||
            dropboxChunkSize < 5 ||
            dropboxChunkSize >= 150)) {
      return 'Dropbox uses a folder and a 5–149 MiB chunk size, without S3 attributes.';
    }
    if (exclude.length > 64 ||
        exclude.toSet().length != exclude.length ||
        exclude.any(
          (e) =>
              !_cloudText(e, 256) ||
              e.startsWith('-') ||
              e.startsWith('+') ||
              e.contains('\\') ||
              e.split('/').any((p) => p == '..' || p == '.'),
        )) {
      return 'Use at most 64 distinct, single-line exclusion patterns without traversal or filter directives.';
    }
    return SnapshotScheduleCron(
      minute: minute,
      hour: hour,
      dom: dom,
      month: month,
      dow: dow,
    ).validationError;
  }

  Map<String, Object?> _wire(String provider) => {
    'description': description,
    'path': path,
    'credentials': credentialId,
    'direction': direction,
    'transfer_mode': transferMode,
    'enabled': enabled,
    'schedule': {
      'minute': minute,
      'hour': hour,
      'dom': dom,
      'month': month,
      'dow': dow,
    },
    'exclude': exclude,
    'attributes': {
      'folder': folder,
      if (provider == 'S3') ...{
        'bucket': bucket,
        'region': region,
        'encryption': serverSideEncryption ? 'AES256' : null,
        'storage_class': storageClass,
        'fast_list': false,
      },
      if (provider == 'DROPBOX') 'chunk_size': dropboxChunkSize,
    },
  };
}

final class CloudSyncTask {
  const CloudSyncTask({
    required this.id,
    required this.settings,
    required this.provider,
    this.state = 'IDLE',
    this.blockedReason,
  });
  final int id;
  final CloudSyncSettings settings;
  final String provider, state;
  final String? blockedReason;
}

final class CloudSyncInventory {
  CloudSyncInventory({
    required this.endpoint,
    required this.timezone,
    required List<CloudSyncTask> tasks,
    required List<CloudSyncCredential> credentials,
    required List<CloudSyncDataset> datasets,
    this.conflictingJob = false,
  }) : tasks = List.unmodifiable(tasks),
       credentials = List.unmodifiable(credentials),
       datasets = List.unmodifiable(datasets);
  final String endpoint, timezone;
  final List<CloudSyncTask> tasks;
  final List<CloudSyncCredential> credentials;
  final List<CloudSyncDataset> datasets;
  final bool conflictingJob;
}

enum CloudSyncAction { create, update, run, delete }

final class CloudSyncRequest {
  const CloudSyncRequest({
    required this.inventory,
    required this.action,
    this.task,
    this.settings,
  });
  final CloudSyncInventory inventory;
  final CloudSyncAction action;
  final CloudSyncTask? task;
  final CloudSyncSettings? settings;
  CloudSyncSettings get desired => settings ?? task!.settings;
  String get target => action == CloudSyncAction.create
      ? 'CREATE ${settings?.path ?? ""}'
      : '${action.name.toUpperCase()} #${task?.id ?? 0}';
  String? get validationError {
    if (inventory.conflictingJob) {
      return 'A cloud sync or conflicting storage job is active; wait for completion.';
    }
    if (action == CloudSyncAction.create
        ? task != null || settings == null
        : task == null || !inventory.tasks.any((t) => identical(t, task))) {
      return 'Choose an exact task from this inventory.';
    }
    if (task?.blockedReason != null) return task!.blockedReason;
    if ((action == CloudSyncAction.run || action == CloudSyncAction.delete) &&
        settings != null) {
      return 'Run and delete do not accept replacement settings.';
    }
    final desired = this.desired;
    final credential = inventory.credentials
        .where((c) => c.id == desired.credentialId)
        .singleOrNull;
    if (credential == null || !credential.supported) {
      return 'Select a supported existing credential reference.';
    }
    if (task != null &&
        (desired.path != task!.settings.path ||
            desired.credentialId != task!.settings.credentialId ||
            credential.provider != task!.provider ||
            desired.bucket != task!.settings.bucket ||
            desired.folder != task!.settings.folder ||
            desired.direction != task!.settings.direction)) {
      return 'Local path, credential, direction and remote destination are immutable here. Create a separately reviewed task to change them.';
    }
    final dataset = inventory.datasets
        .where((d) => d.path == desired.path)
        .singleOrNull;
    if (dataset == null || dataset.blockedReason != null) {
      return dataset?.blockedReason ??
          'Choose an available exact leaf dataset mountpoint.';
    }
    return desired.validate(credential.provider);
  }
}

final class CloudSyncReview {
  CloudSyncReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final CloudSyncRequest request;
  final String endpoint;
  final List<String> warnings;
  String get target => request.target;
  CloudSyncAction get action => request.action;
}

final class CloudSyncJob {
  const CloudSyncJob({
    required this.id,
    required this.taskId,
    required this.endpoint,
  });
  final int id, taskId;
  final String endpoint;
}

enum CloudSyncOutcome { succeeded, pending, failed, rejected, unknown }

final class CloudSyncResult {
  const CloudSyncResult(this.outcome, this.message, {this.job, this.percent});
  final CloudSyncOutcome outcome;
  final String message;
  final CloudSyncJob? job;
  final double? percent;
}

enum CloudSyncExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class CloudSyncException implements Exception {
  const CloudSyncException(this.reason);
  final CloudSyncExceptionReason reason;
  String get userMessage => switch (reason) {
    CloudSyncExceptionReason.notAuthenticated =>
      'Connect again before using cloud sync.',
    CloudSyncExceptionReason.unsupportedVersion =>
      'Native cloud sync requires stable TrueNAS 25.10.',
    CloudSyncExceptionReason.unavailableMethod =>
      'Required public cloud sync methods are unavailable.',
    CloudSyncExceptionReason.busy =>
      'Another operation is active or its outcome is unknown.',
    CloudSyncExceptionReason.staleReview =>
      'The issued task review expired or changed. Reload and review again.',
    CloudSyncExceptionReason.invalidRequest =>
      'Choose a supported cloud sync task and exact settings.',
    CloudSyncExceptionReason.invalidResponse =>
      'Cloud sync safety information could not be validated.',
    CloudSyncExceptionReason.unavailable =>
      'Cloud sync information is unavailable. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

const _cloudReads = {
  'cloudsync.query',
  'cloudsync.credentials.query',
  'pool.dataset.query',
  'filesystem.stat',
  'filesystem.statfs',
  'system.general.config',
  'core.get_jobs',
};
const _cloudTaskSelect = [
  'id',
  'description',
  'path',
  'credentials.id',
  'credentials.name',
  'credentials.provider.type',
  'direction',
  'transfer_mode',
  'enabled',
  'schedule',
  'exclude',
  'attributes',
  'pre_script',
  'post_script',
  'args',
  'snapshot',
  'include',
  'encryption',
  'filename_encryption',
  'follow_symlinks',
  'create_empty_src_dirs',
  'bwlimit',
  'transfers',
  'locked',
  'job.id',
  'job.state',
];

final class _CloudSnapshot {
  const _CloudSnapshot(this.inventory, this.fingerprint);
  final CloudSyncInventory inventory;
  final String fingerprint;
}

final class _CloudLease {
  const _CloudLease(this.snapshot, this.proof, this.created);
  final _CloudSnapshot snapshot;
  final String proof;
  final DateTime created;
}

final class _SessionCloudSync {
  _SessionCloudSync({
    required this.client,
    required ServerSummary summary,
    required Object? metadata,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherMutationBusy,
    required this.requestTimeout,
  }) : _version =
           _managementVersion(summary.version) == _ManagementVersion.v2510,
       _endpoint = summary.endpointUri.toString(),
       _metadata = metadata is Map ? Map.of(metadata) : const {};
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherMutationBusy;
  final Duration requestTimeout;
  final bool _version;
  final String _endpoint;
  final Map _metadata;
  bool _calling = false, _uncertain = false;
  final Map<CloudSyncInventory, _CloudSnapshot> _inventories = {};
  final Map<CloudSyncReview, _CloudLease> _reviews = {};
  final Set<CloudSyncJob> _jobs = {};
  bool get isBusy => _calling || _uncertain || _jobs.isNotEmpty;
  bool _method(String name, {bool job = false}) {
    final m = _metadata[name];
    return m is Map &&
        m['job'] == job &&
        m['uploadable'] == false &&
        m['downloadable'] == false &&
        m['private'] != true &&
        m['_private'] != true &&
        m['no_auth_required'] == false;
  }

  CloudSyncCapabilities get capabilities => CloudSyncCapabilities(
    connected: isCurrent(),
    versionSupported: _version,
    available: _cloudReads.every(_method),
    canCreate: _method('cloudsync.create'),
    canUpdate: _method('cloudsync.update'),
    canDelete: _method('cloudsync.delete'),
    canRun: _method('cloudsync.sync', job: true),
  );
  void _guard([CloudSyncAction? action]) {
    if (!isCurrent()) {
      throw const CloudSyncException(CloudSyncExceptionReason.notAuthenticated);
    }
    if (!_version) {
      throw const CloudSyncException(
        CloudSyncExceptionReason.unsupportedVersion,
      );
    }
    if (!capabilities.supported ||
        action != null && !capabilities.allows(action)) {
      throw const CloudSyncException(
        CloudSyncExceptionReason.unavailableMethod,
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

  Future<_CloudSnapshot> _read() async {
    final credentialsRaw = await _call('cloudsync.credentials.query', const [
      [],
      {
        'limit': 129,
        'select': ['id', 'name', 'provider.type'],
      },
    ]);
    final tasksRaw = await _call('cloudsync.query', const [
      [],
      {'limit': 257, 'select': _cloudTaskSelect},
    ]);
    final datasetsRaw = await _call('pool.dataset.query', const [
      [],
      {
        'limit': 513,
        'extra': {
          'flat': true,
          'retrieve_children': false,
          'properties': ['guid', 'mounted', 'readonly'],
        },
        'select': [
          'id',
          'type',
          'guid',
          'mountpoint',
          'mounted',
          'locked',
          'readonly',
          'key_loaded',
        ],
      },
    ]);
    final config = await _call('system.general.config', const []);
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
    if (credentialsRaw is! List ||
        credentialsRaw.length > 128 ||
        tasksRaw is! List ||
        tasksRaw.length > 256 ||
        datasetsRaw is! List ||
        datasetsRaw.length > 512 ||
        config is! Map ||
        !_cloudText(config['timezone'], 96) ||
        jobs is! List ||
        jobs.length > 128) {
      _cloudInvalid();
    }
    final credentials = <CloudSyncCredential>[];
    for (final row in credentialsRaw) {
      if (row is! Map ||
          !_cloudId(row['id']) ||
          !_cloudText(row['name'], 100) ||
          row['provider'] is! Map ||
          !_cloudText(row['provider']['type'], 64)) {
        _cloudInvalid();
      }
      credentials.add(
        CloudSyncCredential(
          id: row['id'] as int,
          name: row['name'] as String,
          provider: row['provider']['type'] as String,
        ),
      );
    }
    if (credentials.map((c) => c.id).toSet().length != credentials.length) {
      _cloudInvalid();
    }
    credentials.sort((a, b) => a.id.compareTo(b.id));
    final datasets = <CloudSyncDataset>[];
    final datasetProof = <Object?>[];
    for (final row in datasetsRaw) {
      if (row is! Map ||
          !_cloudText(row['id'], 256) ||
          !{'FILESYSTEM', 'VOLUME'}.contains(row['type'])) {
        _cloudInvalid();
      }
      if (row['type'] != 'FILESYSTEM') continue;
      final id = row['id'] as String;
      final guid = _cloudProperty(row['guid']);
      if (!RegExp(r'^[0-9]{1,20}$').hasMatch(guid) ||
          BigInt.parse(guid) <= BigInt.zero ||
          BigInt.parse(guid) > BigInt.parse('18446744073709551615')) {
        _cloudInvalid();
      }
      final path = row['mountpoint'];
      final mounted = _cloudProperty(row['mounted']);
      final readonly = _cloudProperty(row['readonly']);
      if (path != null && path is! String ||
          row['locked'] is! bool ||
          row['key_loaded'] != null && row['key_loaded'] is! bool) {
        _cloudInvalid();
      }
      final blocked =
          !id.contains('/') ||
              id
                  .split('/')
                  .any(
                    (p) =>
                        p.startsWith('.') ||
                        p == 'ix-apps' ||
                        p == 'ix-applications',
                  )
          ? 'Pool roots and system datasets are not supported.'
          : path != '/mnt/$id' ||
                mounted != 'yes' ||
                row['locked'] != false ||
                row['key_loaded'] == false ||
                readonly != 'off'
          ? 'Dataset must use its normal mountpoint and be mounted, unlocked and writable.'
          : datasetsRaw.any(
              (d) =>
                  d is Map &&
                  d['id'] is String &&
                  (d['id'] as String).startsWith('$id/'),
            )
          ? 'Nested datasets require the TrueNAS workflow.'
          : null;
      datasets.add(
        CloudSyncDataset(
          id: id,
          guid: guid,
          path: path is String ? path : '',
          blockedReason: blocked,
        ),
      );
      datasetProof.add([
        id,
        guid,
        path,
        mounted,
        readonly,
        row['locked'],
        row['key_loaded'],
      ]);
    }
    if (datasets.map((d) => d.id).toSet().length != datasets.length) {
      _cloudInvalid();
    }
    datasets.sort((a, b) => a.id.compareTo(b.id));
    final tasks = <CloudSyncTask>[];
    for (final row in tasksRaw) {
      tasks.add(_cloudTask(row, credentials));
    }
    if (tasks.map((t) => t.id).toSet().length != tasks.length) _cloudInvalid();
    tasks.sort((a, b) => a.id.compareTo(b.id));
    var conflict = false;
    for (final row in jobs) {
      if (row is! Map ||
          !_cloudId(row['id']) ||
          !_cloudText(row['method'], 128) ||
          !{'WAITING', 'RUNNING'}.contains(row['state'])) {
        _cloudInvalid();
      }
      final method = row['method'] as String;
      conflict |=
          method.startsWith('cloudsync.') ||
          method.startsWith('cloud_backup.') ||
          method.startsWith('replication.') ||
          method.startsWith('pool.') ||
          method.startsWith('filesystem.') ||
          method.startsWith('update.') ||
          method.startsWith('system.');
    }
    final inventory = CloudSyncInventory(
      endpoint: _endpoint,
      timezone: config['timezone'] as String,
      tasks: tasks,
      credentials: credentials,
      datasets: datasets,
      conflictingJob: conflict,
    );
    datasetProof.sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
    return _CloudSnapshot(
      inventory,
      jsonEncode([
        credentials.map((c) => [c.id, c.name, c.provider]).toList(),
        tasks
            .map(
              (t) => [
                t.id,
                t.settings._wire(t.provider),
                t.provider,
                t.blockedReason,
              ],
            )
            .toList(),
        datasetProof,
        config['timezone'],
        conflict,
      ]),
    );
  }

  Future<CloudSyncInventory> load() async {
    _guard();
    if (_calling) throw const CloudSyncException(CloudSyncExceptionReason.busy);
    _calling = true;
    _reviews.clear();
    _inventories.clear();
    try {
      final snapshot = await _read();
      _inventories[snapshot.inventory] = snapshot;
      return snapshot.inventory;
    } on CloudSyncException {
      rethrow;
    } on Object {
      throw const CloudSyncException(CloudSyncExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<String> _proof(CloudSyncRequest request) async {
    final settings = request.desired;
    final dataset = request.inventory.datasets.singleWhere(
      (d) => d.path == settings.path,
    );
    final proof = <Object?>[];
    var path = '';
    for (final part in [
      '',
      ...settings.path.split('/').where((p) => p.isNotEmpty),
    ]) {
      path = part.isEmpty
          ? '/'
          : path == '/'
          ? '/$part'
          : '$path/$part';
      final stat = await _call('filesystem.stat', [path]);
      if (stat is! Map ||
          stat['type'] != 'DIRECTORY' ||
          stat['realpath'] != path ||
          stat['is_ctldir'] != false ||
          stat['is_mountpoint'] is! bool ||
          [
            'dev',
            'inode',
            'mount_id',
            'mode',
            'uid',
            'gid',
          ].any((k) => stat[k] is! int || (stat[k] as int) < 0) ||
          path == settings.path && stat['is_mountpoint'] != true) {
        _cloudInvalid();
      }
      proof.add([
        for (final k in [
          'realpath',
          'type',
          'dev',
          'inode',
          'mount_id',
          'mode',
          'uid',
          'gid',
          'is_mountpoint',
        ])
          stat[k],
      ]);
    }
    final fs = await _call('filesystem.statfs', [settings.path]);
    if (fs is! Map ||
        fs['fstype'] != 'zfs' ||
        fs['source'] != dataset.id ||
        fs['dest'] != settings.path ||
        !_cloudText(fs['fsid'], 128) ||
        fs['flags'] is! List ||
        (fs['flags'] as List).any((f) => f is! String) ||
        (fs['flags'] as List).contains('RDONLY')) {
      _cloudInvalid();
    }
    proof.add([
      fs['fstype'],
      fs['source'],
      fs['dest'],
      fs['fsid'],
      fs['flags'],
    ]);
    return jsonEncode(proof);
  }

  Future<CloudSyncReview> review(CloudSyncRequest request) async {
    _guard(request.action);
    if (isBusy || isOtherMutationBusy()) {
      throw const CloudSyncException(CloudSyncExceptionReason.busy);
    }
    final baseline = _inventories[request.inventory];
    if (baseline == null) {
      throw const CloudSyncException(CloudSyncExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      throw const CloudSyncException(CloudSyncExceptionReason.invalidRequest);
    }
    _calling = true;
    _reviews.clear();
    try {
      final fresh = await _read();
      if (fresh.fingerprint != baseline.fingerprint) {
        throw const CloudSyncException(CloudSyncExceptionReason.staleReview);
      }
      final proof = await _proof(request);
      if ((await _read()).fingerprint != baseline.fingerprint) {
        throw const CloudSyncException(CloudSyncExceptionReason.staleReview);
      }
      final s = request.desired;
      final review = CloudSyncReview(
        request: request,
        endpoint: _endpoint,
        warnings: [
          'Authenticated endpoint: $_endpoint. Local path: ${s.path}. Existing credential #${s.credentialId}; its secret and remote endpoint are not read or displayed.',
          '${s.direction} ${s.transferMode}: ${s.direction == 'PUSH' ? 'local → cloud' : 'cloud → local'}; remote ${s.bucket.isEmpty ? '' : '${s.bucket}/'}${s.folder}. Credential rotation, remote contents, permissions, quotas and object versions are not attested here.',
          'COPY can overwrite destination files; it is not an append-only backup. ${s.transferMode == 'SYNC'
              ? 'SYNC also deletes destination files absent from the source.'
              : s.transferMode == 'MOVE'
              ? 'MOVE removes source files after transfer.'
              : 'Existing destination-only files are retained.'}',
          if (s.direction == 'PULL') 'PULL writes NAS data. Verify an independent backup and quiesce clients before enabling or running it.',
          'Exclusions use rclone filter semantics, not a proven deletion boundary. Review excluded paths and both endpoints in TrueNAS before SYNC or MOVE.',
          'Schedule timezone: ${request.inventory.timezone}. ${s.enabled ? 'Enabled tasks can run automatically at the next matching time.' : 'The task is disabled for scheduled runs; Run now can still execute it.'}',
          'Saving can contact the cloud provider for validation and restarts cron. Deleting aborts the task if it starts concurrently and removes its schedule, not its stored files.',
          'Only exact leaf datasets and bounded unencrypted S3/Dropbox tasks are supported. No credential creation, scripts, arbitrary flags, restore, snapshots, symlink traversal, remote listing or automatic dry run is performed.',
          'A leaf dataset and root filesystem identity do not prove that its subtree has no bind mounts or other nested mounts. Keep the local file tree quiescent and independently ensure it contains no nested mounts; rclone can traverse ordinary subdirectories. File contents and mount changes after preflight are not attested.',
          'Task, dataset GUID and path identity are rechecked, but TrueNAS offers no atomic compare-and-swap. Another administrator or scheduler can still act after preflight; failures may have partial effects.',
        ],
      );
      _reviews[review] = _CloudLease(baseline, proof, DateTime.now());
      return review;
    } on CloudSyncException {
      rethrow;
    } on Object {
      throw const CloudSyncException(CloudSyncExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<CloudSyncResult> execute(
    CloudSyncReview review,
    String confirmation,
  ) async {
    _guard(review.action);
    if (isBusy || isOtherMutationBusy()) {
      throw const CloudSyncException(CloudSyncExceptionReason.busy);
    }
    final lease = _reviews.remove(review);
    if (lease == null ||
        DateTime.now().difference(lease.created) > const Duration(minutes: 5) ||
        confirmation != review.target ||
        review.endpoint != _endpoint ||
        !_inventories.containsKey(review.request.inventory)) {
      throw const CloudSyncException(CloudSyncExceptionReason.staleReview);
    }
    final request = review.request;
    if (request.validationError != null) {
      throw const CloudSyncException(CloudSyncExceptionReason.invalidRequest);
    }
    _calling = true;
    var sent = false;
    try {
      if ((await _read()).fingerprint != lease.snapshot.fingerprint ||
          await _proof(request) != lease.proof ||
          (await _read()).fingerprint != lease.snapshot.fingerprint) {
        return const CloudSyncResult(
          CloudSyncOutcome.rejected,
          'Task, credential reference or local path changed. Nothing was submitted.',
        );
      }
      _guard(request.action);
      if (isOtherMutationBusy()) {
        return const CloudSyncResult(
          CloudSyncOutcome.rejected,
          'Another operation started. Nothing was submitted.',
        );
      }
      final provider = request.inventory.credentials
          .singleWhere((c) => c.id == request.desired.credentialId)
          .provider;
      final method = switch (request.action) {
        CloudSyncAction.create => 'cloudsync.create',
        CloudSyncAction.update => 'cloudsync.update',
        CloudSyncAction.run => 'cloudsync.sync',
        CloudSyncAction.delete => 'cloudsync.delete',
      };
      final payload = request.desired._wire(provider);
      if (request.action == CloudSyncAction.update) {
        final old = request.task!.settings._wire(provider);
        payload.removeWhere((k, v) => _adminEqual(v, old[k]));
        if (payload.isEmpty) {
          return const CloudSyncResult(
            CloudSyncOutcome.rejected,
            'No configuration changed. Nothing was submitted.',
          );
        }
      }
      final params = <Object?>[
        if (request.task != null) request.task!.id,
        if (request.action == CloudSyncAction.create ||
            request.action == CloudSyncAction.update)
          payload,
        if (request.action == CloudSyncAction.run) {'dry_run': false},
      ];
      sent = true;
      final receipt = await _call(method, params);
      _inventories.clear();
      _reviews.clear();
      if (request.action == CloudSyncAction.run) {
        if (!_cloudId(receipt)) return _unknown();
        final job = CloudSyncJob(
          id: receipt as int,
          taskId: request.task!.id,
          endpoint: _endpoint,
        );
        _jobs.add(job);
        return CloudSyncResult(
          CloudSyncOutcome.pending,
          'The server accepted this task job. Check this exact job; do not run it again.',
          job: job,
        );
      }
      if (request.action == CloudSyncAction.delete) {
        if (receipt != true) return _unknown();
      } else {
        final task = _cloudTask(receipt, request.inventory.credentials);
        if (task.blockedReason != null ||
            !_adminEqual(
              task.settings._wire(provider),
              request.desired._wire(provider),
            ) ||
            request.task != null && task.id != request.task!.id) {
          return _unknown();
        }
      }
      return const CloudSyncResult(
        CloudSyncOutcome.succeeded,
        'TrueNAS confirmed the configuration operation. This does not verify remote files or future scheduled runs.',
      );
    } on JsonRpcRemoteException catch (error) {
      if (sent &&
          error.data is Map &&
          (error.data as Map)['errno'] is int &&
          {1, 13}.contains((error.data as Map)['errno'])) {
        return const CloudSyncResult(
          CloudSyncOutcome.rejected,
          'TrueNAS denied permission. Remote details were withheld.',
        );
      }
      if (sent) return _unknown();
      return const CloudSyncResult(
        CloudSyncOutcome.rejected,
        'Preflight failed. Nothing was submitted.',
      );
    } on Object {
      if (sent) return _unknown();
      return const CloudSyncResult(
        CloudSyncOutcome.rejected,
        'Preflight failed. Nothing was submitted.',
      );
    } finally {
      _calling = false;
    }
  }

  CloudSyncResult _unknown({CloudSyncJob? job}) {
    if (job == null) _uncertain = true;
    _reviews.clear();
    _inventories.clear();
    return CloudSyncResult(
      CloudSyncOutcome.unknown,
      job == null
          ? 'The operation may have taken effect. Inspect the original server and reconnect before further changes. Do not repeat it.'
          : 'This exact job could not be verified. Its lock remains held; check its progress again or inspect the original server.',
      job: job,
    );
  }

  Future<CloudSyncResult> poll(CloudSyncJob job) async {
    _guard();
    if (_calling || !_jobs.contains(job) || job.endpoint != _endpoint) {
      throw const CloudSyncException(CloudSyncExceptionReason.staleReview);
    }
    _calling = true;
    try {
      final raw = await _call('core.get_jobs', [
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
            'progress.percent',
            'result',
          ],
        },
      ]);
      if (raw is! List || raw.length != 1 || raw.single is! Map) {
        return _unknown(job: job);
      }
      final row = raw.single as Map;
      final arguments = row['arguments'];
      if (row['id'] is! int ||
          row['id'] != job.id ||
          row['method'] != 'cloudsync.sync' ||
          arguments is! List ||
          arguments.length != 2 ||
          arguments[0] is! int ||
          arguments[0] != job.taskId ||
          arguments[1] is! Map ||
          (arguments[1] as Map).length != 1 ||
          (arguments[1] as Map)['dry_run'] != false) {
        return _unknown(job: job);
      }
      if ({'WAITING', 'RUNNING'}.contains(row['state'])) {
        final progress = row['progress'];
        if (progress is! Map) return _unknown(job: job);
        final percent = progress['percent'];
        if (percent != null &&
            (percent is! num ||
                !percent.isFinite ||
                percent < 0 ||
                percent > 100)) {
          return _unknown(job: job);
        }
        return CloudSyncResult(
          CloudSyncOutcome.pending,
          'The owned cloud sync job is ${row['state']}.',
          job: job,
          percent: percent is num ? percent.toDouble() : null,
        );
      }
      if (!{'SUCCESS', 'FAILED', 'ABORTED'}.contains(row['state']) ||
          row['state'] == 'SUCCESS' &&
              (!row.containsKey('result') || row['result'] != null)) {
        return _unknown(job: job);
      }
      _jobs.remove(job);
      return CloudSyncResult(
        row['state'] == 'SUCCESS'
            ? CloudSyncOutcome.succeeded
            : CloudSyncOutcome.failed,
        row['state'] == 'SUCCESS'
            ? 'TrueNAS reports this cloud sync job completed. Remote file integrity was not independently verified.'
            : 'TrueNAS reports this job failed or was aborted. Partial transfers or deletions may remain; inspect both endpoints.',
      );
    } on Object {
      return _unknown(job: job);
    } finally {
      _calling = false;
    }
  }
}

CloudSyncTask _cloudTask(Object? raw, List<CloudSyncCredential> credentials) {
  if (raw is! Map ||
      !_cloudId(raw['id']) ||
      !_cloudText(raw['description'], 256, empty: true) ||
      !_cloudText(raw['path'], 512) ||
      raw['credentials'] is! Map ||
      raw['attributes'] is! Map ||
      raw['schedule'] is! Map ||
      raw['enabled'] is! bool ||
      raw['locked'] is! bool) {
    _cloudInvalid();
  }
  final credential = raw['credentials'] as Map;
  final existing = credentials
      .where((c) => c.id == credential['id'])
      .singleOrNull;
  if (existing == null ||
      credential['name'] != existing.name ||
      credential['provider'] is! Map ||
      credential['provider']['type'] != existing.provider) {
    _cloudInvalid();
  }
  final a = raw['attributes'] as Map, c = raw['schedule'] as Map;
  String str(Map map, String k, {String fallback = ''}) {
    final v = map[k];
    if (v == null) return fallback;
    if (v is! String || !_cloudText(v, 512, empty: true)) _cloudInvalid();
    return v;
  }

  if (!{'PUSH', 'PULL'}.contains(raw['direction']) ||
      !{'COPY', 'SYNC', 'MOVE'}.contains(raw['transfer_mode']) ||
      raw['exclude'] is! List ||
      (raw['exclude'] as List).any((e) => e is! String) ||
      raw['transfers'] != null && raw['transfers'] is! int) {
    _cloudInvalid();
  }
  var advanced = !existing.supported || raw['locked'] != false;
  advanced |=
      c.length != 5 ||
      !c.keys.toSet().containsAll({'minute', 'hour', 'dom', 'month', 'dow'});
  for (final k in [
    'snapshot',
    'encryption',
    'filename_encryption',
    'follow_symlinks',
    'create_empty_src_dirs',
  ]) {
    if (raw[k] is! bool) _cloudInvalid();
    advanced |= raw[k] != false;
  }
  for (final k in ['pre_script', 'post_script', 'args']) {
    if (raw[k] is! String) _cloudInvalid();
    advanced |= (raw[k] as String).isNotEmpty;
  }
  for (final k in ['include', 'bwlimit']) {
    if (raw[k] is! List) _cloudInvalid();
    advanced |= (raw[k] as List).isNotEmpty;
  }
  advanced |= raw['transfers'] != null;
  final allowed = existing.provider == 'S3'
      ? {
          'folder',
          'bucket',
          'region',
          'encryption',
          'storage_class',
          'fast_list',
        }
      : {'folder', 'chunk_size'};
  advanced |=
      a.keys.any((k) => !allowed.contains(k)) ||
      a['fast_list'] == true ||
      a['encryption'] != null &&
          a['encryption'] != '' &&
          a['encryption'] != 'AES256';
  if (a.containsKey('fast_list') && a['fast_list'] is! bool ||
      a.containsKey('chunk_size') && a['chunk_size'] is! int) {
    _cloudInvalid();
  }
  final settings = CloudSyncSettings(
    path: raw['path'] as String,
    credentialId: existing.id,
    description: raw['description'] as String,
    direction: raw['direction'] as String,
    transferMode: raw['transfer_mode'] as String,
    enabled: raw['enabled'] as bool,
    folder: str(a, 'folder'),
    bucket: str(a, 'bucket'),
    region: str(a, 'region'),
    storageClass: str(a, 'storage_class'),
    serverSideEncryption: a['encryption'] == 'AES256',
    dropboxChunkSize: a['chunk_size'] is int ? a['chunk_size'] as int : 48,
    minute: str(c, 'minute'),
    hour: str(c, 'hour'),
    dom: str(c, 'dom'),
    month: str(c, 'month'),
    dow: str(c, 'dow'),
    exclude: List<String>.from(raw['exclude'] as List),
  );
  var state = 'IDLE';
  final job = raw['job'];
  if (job != null) {
    if (job is! Map ||
        !_cloudId(job['id']) ||
        !{
          'WAITING',
          'RUNNING',
          'SUCCESS',
          'FAILED',
          'ABORTED',
        }.contains(job['state'])) {
      _cloudInvalid();
    }
    state = job['state'] as String;
    advanced |= {'WAITING', 'RUNNING'}.contains(state);
  }
  return CloudSyncTask(
    id: raw['id'] as int,
    settings: settings,
    provider: existing.provider,
    state: state,
    blockedReason: advanced
        ? 'This task uses locked, active or advanced settings. Manage it in TrueNAS.'
        : settings.validate(existing.provider),
  );
}

String _cloudProperty(Object? value) {
  if (value is String) return value;
  if (value is Map) {
    final v = value['value'];
    if (v is String) return v;
  }
  return '';
}

bool _cloudId(Object? v) => v is int && v > 0 && v <= 9007199254740991;
bool _cloudText(Object? v, int max, {bool empty = false}) =>
    v is String &&
    (empty || v.isNotEmpty) &&
    v.length <= max &&
    !RegExp(r'[\x00-\x1f\x7f]').hasMatch(v);
bool _cloudPath(String v) =>
    _cloudText(v, 512) &&
    v.split('/').length >= 4 &&
    v.startsWith('/mnt/') &&
    !v.endsWith('/') &&
    !v.contains('//') &&
    !v.contains('\\') &&
    v
        .split('/')
        .skip(1)
        .every(
          (p) => p.isNotEmpty && p != '.' && p != '..' && !p.startsWith('.'),
        );
bool _cloudFolder(String v) =>
    _cloudText(v, 256) &&
    !v.startsWith('/') &&
    !v.endsWith('/') &&
    !v.contains('//') &&
    !v.contains('\\') &&
    v
        .split('/')
        .every(
          (p) => p.isNotEmpty && p != '.' && p != '..' && !p.startsWith('-'),
        );
Never _cloudInvalid() =>
    throw const CloudSyncException(CloudSyncExceptionReason.invalidResponse);
