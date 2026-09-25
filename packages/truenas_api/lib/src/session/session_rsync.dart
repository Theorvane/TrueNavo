part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedRsyncSession {
  RsyncCapabilities get rsyncCapabilities;
  Future<RsyncInventory> loadRsync();
  Future<RsyncReview> reviewRsync(RsyncRequest request);
  Future<RsyncResult> executeRsync(RsyncReview review, String confirmation);
  Future<RsyncResult> checkRsyncJob(RsyncJob job);
}

final class RsyncCapabilities {
  const RsyncCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.available,
    required this.canCreate,
    required this.canUpdate,
    required this.canDelete,
    required this.canRun,
  });
  const RsyncCapabilities.disconnected()
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
  bool allows(RsyncAction action) =>
      supported &&
      switch (action) {
        RsyncAction.create => canCreate,
        RsyncAction.update ||
        RsyncAction.enable ||
        RsyncAction.disable => canUpdate,
        RsyncAction.delete => canDelete,
        RsyncAction.run => canRun,
      };
  String? get blockedReason => !connected
      ? 'Connect to inspect Rsync tasks.'
      : !versionSupported
      ? 'Native Rsync requires stable TrueNAS 25.10.'
      : !available
      ? 'Task, SSH public identity, local user, dataset, path, timezone, HA and job reads are required.'
      : null;
}

final class RsyncUser {
  const RsyncUser({
    required this.id,
    required this.uid,
    required this.username,
  });
  final int id, uid;
  final String username;
}

final class RsyncConnection {
  RsyncConnection({
    required this.id,
    required this.name,
    required this.host,
    required this.port,
    required this.username,
    required this.keyPairId,
    required this.publicKeyFingerprint,
    required List<String> hostKeyFingerprints,
  }) : hostKeyFingerprints = List.unmodifiable(hostKeyFingerprints);
  final int id, port, keyPairId;
  final String name, host, username, publicKeyFingerprint;
  final List<String> hostKeyFingerprints;
  String get destination => '$username@$host:$port';
}

final class RsyncDataset {
  const RsyncDataset({
    required this.id,
    required this.guid,
    required this.path,
    this.blockedReason,
  });
  final String id, guid, path;
  final String? blockedReason;
}

final class RsyncSettings {
  const RsyncSettings({
    required this.path,
    required this.user,
    required this.connectionId,
    required this.remotePath,
    this.description = '',
    this.enabled = false,
    this.recursive = true,
    this.times = true,
    this.compress = true,
    this.delayUpdates = true,
    this.cron = const PoolScrubCron(minute: '0', hour: '2', dow: '*'),
  });
  final String path, user, remotePath, description;
  final int connectionId;
  final bool enabled, recursive, times, compress, delayUpdates;
  final PoolScrubCron cron;
  String? get validationError =>
      !_rsyncLocalPath(path) || !_rsyncUsername(user) || !_pmId(connectionId)
      ? 'Choose an exact local dataset, local non-root user and existing SSH connection.'
      : !_rsyncRemotePath(remotePath)
      ? 'Use a dedicated non-root absolute remote directory with plain path components.'
      : !_pmText(description, 120, empty: true)
      ? 'Use at most 120 plain description characters.'
      : !recursive
      ? 'Native Rsync requires recursive directory copy.'
      : cron.validationError;
  Map<String, Object?> get _wire => {
    'path': path,
    'user': user,
    'mode': 'SSH',
    'remotehost': null,
    'remoteport': null,
    'remotemodule': null,
    'ssh_credentials': connectionId,
    'remotepath': remotePath,
    'direction': 'PUSH',
    'desc': description,
    'schedule': cron._wire,
    'recursive': recursive,
    'times': times,
    'compress': compress,
    'archive': false,
    'delete': false,
    'quiet': false,
    'preserveperm': false,
    'preserveattr': false,
    'delayupdates': delayUpdates,
    'extra': <String>['--one-file-system'],
    'enabled': enabled,
  };
}

final class RsyncTask {
  const RsyncTask({
    required this.id,
    required this.description,
    required this.mode,
    required this.direction,
    required this.enabled,
    required this.locked,
    this.settings,
    this.blockedReason,
    this.lastJobState,
    this.crossFilesystemProtection = true,
  });
  final int id;
  final String description, mode, direction;
  final bool enabled, locked;
  final RsyncSettings? settings;
  final String? blockedReason;
  final String? lastJobState;
  final bool crossFilesystemProtection;
  bool get supported => settings != null && blockedReason == null && !locked;
}

final class RsyncInventory {
  RsyncInventory({
    required this.endpoint,
    required this.timezone,
    required this.failoverLicensed,
    required List<RsyncTask> tasks,
    required List<RsyncConnection> connections,
    required List<RsyncUser> users,
    required List<RsyncDataset> datasets,
    this.conflictingJob = false,
  }) : tasks = List.unmodifiable(tasks),
       connections = List.unmodifiable(connections),
       users = List.unmodifiable(users),
       datasets = List.unmodifiable(datasets);
  final String endpoint, timezone;
  final bool failoverLicensed, conflictingJob;
  final List<RsyncTask> tasks;
  final List<RsyncConnection> connections;
  final List<RsyncUser> users;
  final List<RsyncDataset> datasets;
  String? get blockedReason => failoverLicensed
      ? 'HA Rsync requires the coordinated TrueNAS workflow.'
      : conflictingJob
      ? 'Another server job is active. Wait and reload.'
      : null;
}

enum RsyncAction { create, update, enable, disable, delete, run }

final class RsyncRequest {
  const RsyncRequest({
    required this.inventory,
    required this.action,
    this.task,
    this.settings,
  });
  final RsyncInventory inventory;
  final RsyncAction action;
  final RsyncTask? task;
  final RsyncSettings? settings;
  RsyncSettings? get desired => settings ?? task?.settings;
  String get target =>
      '${action.name.toUpperCase()} RSYNC ${task?.id ?? 'NEW'} / ${desired?.path ?? 'unsupported'} / SSH ${desired?.connectionId ?? 0} / ${desired?.remotePath ?? 'unsupported'}';
  String? get validationError {
    if (inventory.blockedReason != null) return inventory.blockedReason;
    if (action == RsyncAction.create) {
      if (task != null ||
          settings == null ||
          settings!.enabled ||
          inventory.tasks.length >= 128) {
        return 'Create a disabled task with complete settings; at most 128 tasks are supported.';
      }
    } else if (task == null ||
        !inventory.tasks.any((t) => identical(t, task)) ||
        !task!.supported) {
      return 'Choose the exact supported task; unsupported configurations remain read-only.';
    }
    if (action == RsyncAction.update &&
        (settings == null || task!.enabled || settings!.enabled)) {
      return 'Disable the task before editing; enabling is a separate reviewed operation.';
    }
    if (!{RsyncAction.create, RsyncAction.update}.contains(action) &&
        settings != null) {
      return 'This is a separate exact task operation, not a settings update.';
    }
    if (action == RsyncAction.enable && task!.enabled ||
        action == RsyncAction.disable && !task!.enabled) {
      return 'The task already has that enabled state.';
    }
    if ({RsyncAction.delete, RsyncAction.run}.contains(action) &&
        task!.enabled) {
      return 'Disable the schedule before deleting or running this task manually.';
    }
    final value = desired;
    if (value == null || value.validationError != null) {
      return value?.validationError ?? 'Choose supported settings.';
    }
    if (!inventory.users.any((u) => u.username == value.user) ||
        !inventory.connections.any((c) => c.id == value.connectionId) ||
        !inventory.datasets.any(
          (d) => d.path == value.path && d.blockedReason == null,
        )) {
      return 'The selected user, SSH connection or dedicated local dataset is unavailable.';
    }
    if ({RsyncAction.run, RsyncAction.enable}.contains(action) &&
        task?.crossFilesystemProtection != true) {
      return 'Review an update to add the fixed one-filesystem protection before running or enabling this task.';
    }
    if (action == RsyncAction.update &&
        _pmEqual(settings!._wire, task!.settings!._wire) &&
        task!.crossFilesystemProtection) {
      return 'Change at least one supported setting.';
    }
    return null;
  }
}

final class RsyncReview {
  RsyncReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final RsyncRequest request;
  final String endpoint;
  final List<String> warnings;
  RsyncAction get action => request.action;
  String get target => request.target;
}

final class RsyncJob {
  const RsyncJob({
    required this.id,
    required this.taskId,
    required this.endpoint,
    required this.path,
    required this.connectionId,
    required this.remotePath,
  });
  final int id, taskId, connectionId;
  final String endpoint, path, remotePath;
}

enum RsyncOutcome { accepted, succeeded, rejected, unknown }

final class RsyncResult {
  const RsyncResult(this.outcome, this.message, {this.job});
  final RsyncOutcome outcome;
  final String message;
  final RsyncJob? job;
  int? get jobId => job?.id;
}

enum RsyncExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  invalidRequest,
  invalidResponse,
  staleReview,
  unavailable,
}

final class RsyncException implements Exception {
  const RsyncException(this.reason);
  final RsyncExceptionReason reason;
  String get userMessage => switch (reason) {
    RsyncExceptionReason.notAuthenticated => 'Connect before inspecting Rsync.',
    RsyncExceptionReason.unsupportedVersion =>
      'Native Rsync requires stable TrueNAS 25.10.',
    RsyncExceptionReason.unavailableMethod =>
      'Required Rsync safety methods are unavailable.',
    RsyncExceptionReason.busy =>
      'Another or uncertain operation blocks this change.',
    RsyncExceptionReason.invalidRequest =>
      'Choose the exact supported task and settings. Nothing was sent.',
    RsyncExceptionReason.invalidResponse => 'Rsync safety information could not be verified. Remote details were withheld.',
    RsyncExceptionReason.staleReview =>
      'The review expired or task identity changed. Reload and review again.',
    RsyncExceptionReason.unavailable => 'Rsync information could not be read safely. Remote details were withheld.',
  };
  @override
  String toString() => 'RsyncException(${reason.name})';
}

bool _rsyncUsername(Object? v) =>
    v is String &&
    v != 'root' &&
    RegExp(r'^[A-Za-z_][A-Za-z0-9_.-]{0,59}$').hasMatch(v);
bool _rsyncLocalPath(String path) =>
    _cloudPath(path) &&
    path.split('/').where((p) => p.isNotEmpty).length >= 3 &&
    path.length <= 255;
bool _rsyncRemotePath(String path) =>
    path.length <= 255 &&
    RegExp(r'^/[A-Za-z0-9_-][A-Za-z0-9_.-]*(?:/[A-Za-z0-9_-][A-Za-z0-9_.-]*)+$')
        .hasMatch(path) &&
    !path.split('/').any((p) => p == '.' || p == '..') &&
    !{
      'bin',
      'boot',
      'dev',
      'etc',
      'lib',
      'lib64',
      'proc',
      'root',
      'run',
      'sbin',
      'sys',
      'tmp',
      'usr',
      'var',
    }.contains(path.split('/')[1]);

const _rsyncReads = {
  'rsynctask.query',
  'keychaincredential.query',
  'user.query',
  'pool.dataset.query',
  'filesystem.stat',
  'filesystem.statfs',
  'system.general.config',
  'failover.licensed',
  'core.get_jobs',
};
const _rsyncTaskSelect = [
  'id',
  'path',
  'user',
  'mode',
  'remotehost',
  'remoteport',
  'remotemodule',
  'ssh_credentials.id',
  'ssh_credentials.type',
  'remotepath',
  'direction',
  'desc',
  'schedule',
  'recursive',
  'times',
  'compress',
  'archive',
  'delete',
  'quiet',
  'preserveperm',
  'preserveattr',
  'delayupdates',
  'extra',
  'enabled',
  'locked',
  'job.state',
];

final class _RsyncSnapshot {
  const _RsyncSnapshot(this.inventory, this.proof, this.jobIds);
  final RsyncInventory inventory;
  final String proof;
  final Set<int> jobIds;
}

final class _RsyncLease {
  const _RsyncLease(this.created, this.snapshot, this.pathProof);
  final DateTime created;
  final _RsyncSnapshot snapshot;
  final String pathProof;
}

final class _SessionRsync {
  _SessionRsync({
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
  final Map<RsyncInventory, _RsyncSnapshot> _inventories = {};
  final Map<RsyncReview, _RsyncLease> _reviews = {};
  final Map<RsyncJob, _RsyncLease> _jobs = {};
  final Set<int> _issuedJobIds = {};
  bool get isBusy => _calling || _uncertain || _jobs.isNotEmpty;
  bool _method(String name, {bool job = false}) {
    final m = _metadata[name];
    return m is Map &&
        m['job'] == job &&
        m['uploadable'] == false &&
        m['downloadable'] == false &&
        m['no_auth_required'] == false &&
        m['private'] != true &&
        m['_private'] != true;
  }

  RsyncCapabilities get capabilities => RsyncCapabilities(
    connected: isCurrent(),
    versionSupported: _version,
    available: _rsyncReads.every((m) => _method(m)),
    canCreate: _method('rsynctask.create'),
    canUpdate: _method('rsynctask.update'),
    canDelete: _method('rsynctask.delete'),
    canRun: _method('rsynctask.run', job: true),
  );
  void _guard([RsyncAction? a]) {
    if (!isCurrent()) {
      throw const RsyncException(RsyncExceptionReason.notAuthenticated);
    }
    if (!_version) {
      throw const RsyncException(RsyncExceptionReason.unsupportedVersion);
    }
    if (!capabilities.supported || a != null && !capabilities.allows(a)) {
      throw const RsyncException(RsyncExceptionReason.unavailableMethod);
    }
  }

  Future<Object?> _call(String method, List<Object?> args) async {
    _guard();
    final value = await client
        .call(method, id: nextId(), params: args)
        .timeout(requestTimeout);
    _guard();
    return value;
  }

  Future<_RsyncSnapshot> _read() async {
    final pairsRaw = await _call('keychaincredential.query', const [
      [
        ['type', '=', 'SSH_KEY_PAIR'],
      ],
      {
        'limit': 65,
        'select': ['id', 'type', 'attributes.public_key'],
      },
    ]);
    if (pairsRaw is! List || pairsRaw.length > 64) _rsyncInvalid();
    final pairs = <int, String>{};
    for (final row in pairsRaw) {
      if (row is! Map ||
          !_pmId(row['id']) ||
          row['type'] != 'SSH_KEY_PAIR' ||
          row['attributes'] is! Map ||
          row['attributes']['public_key'] is! String) {
        _rsyncInvalid();
      }
      final fingerprint = sshPublicKeyFingerprint(
        row['attributes']['public_key'] as String,
      );
      if (fingerprint == null || pairs.containsKey(row['id'])) _rsyncInvalid();
      pairs[row['id'] as int] = fingerprint;
    }
    // The private_key field is an INTEGER reference only after this exact type
    // filter; it is never projected for SSH_KEY_PAIR rows where it is secret.
    final connectionsRaw = await _call('keychaincredential.query', const [
      [
        ['type', '=', 'SSH_CREDENTIALS'],
      ],
      {
        'limit': 65,
        'select': [
          'id',
          'name',
          'type',
          'attributes.host',
          'attributes.port',
          'attributes.username',
          'attributes.private_key',
          'attributes.remote_host_key',
          'attributes.connect_timeout',
        ],
      },
    ]);
    if (connectionsRaw is! List || connectionsRaw.length > 64) _rsyncInvalid();
    final connections = <RsyncConnection>[];
    final connectionIds = <int>{};
    for (final row in connectionsRaw) {
      if (row is! Map ||
          !_pmId(row['id']) ||
          !connectionIds.add(row['id'] as int) ||
          row['type'] != 'SSH_CREDENTIALS' ||
          !_pmText(row['name'], 255) ||
          row['attributes'] is! Map) {
        _rsyncInvalid();
      }
      final a = row['attributes'] as Map;
      if (a['host'] is! String ||
          a['username'] is! String ||
          a['port'] is! int ||
          !_pmId(a['private_key']) ||
          a['remote_host_key'] is! String ||
          a['connect_timeout'] is! int) {
        _rsyncInvalid();
      }
      final keys = _sshHostKeys(a['remote_host_key'] as String);
      if (keys == null) _rsyncInvalid();
      final settings = SshConnectionSettings(
        host: a['host'] as String,
        port: a['port'] as int,
        username: a['username'] as String,
        keyPairId: a['private_key'] as int,
        remoteHostKey: keys.join('\n'),
        connectTimeout: a['connect_timeout'] as int,
      );
      if (settings.validationError != null) _rsyncInvalid();
      // Root remote login and unsupported account syntaxes are intentionally
      // not admitted to this transfer workflow even when present in keychain.
      if (!_rsyncUsername(settings.username) ||
          !pairs.containsKey(settings.keyPairId)) {
        continue;
      }
      connections.add(
        RsyncConnection(
          id: row['id'] as int,
          name: row['name'] as String,
          host: settings.host,
          port: settings.port,
          username: settings.username,
          keyPairId: settings.keyPairId,
          publicKeyFingerprint: pairs[settings.keyPairId]!,
          hostKeyFingerprints: settings.hostKeyFingerprints,
        ),
      );
    }
    connections.sort((a, b) => a.id.compareTo(b.id));
    final usersRaw = await _call('user.query', const [
      [
        ['local', '=', true],
        ['builtin', '=', false],
        ['uid', '>', 0],
        ['locked', '=', false],
      ],
      {
        'limit': 513,
        'select': ['id', 'uid', 'username', 'local', 'builtin', 'locked'],
      },
    ]);
    if (usersRaw is! List || usersRaw.length > 512) _rsyncInvalid();
    final users = <RsyncUser>[];
    for (final row in usersRaw) {
      if (row is! Map ||
          !_pmId(row['id']) ||
          !_pmId(row['uid']) ||
          row['local'] != true ||
          row['builtin'] != false ||
          row['locked'] != false ||
          !_rsyncUsername(row['username'])) {
        _rsyncInvalid();
      }
      users.add(
        RsyncUser(
          id: row['id'] as int,
          uid: row['uid'] as int,
          username: row['username'] as String,
        ),
      );
    }
    if (users.map((u) => u.id).toSet().length != users.length ||
        users.map((u) => u.uid).toSet().length != users.length ||
        users.map((u) => u.username).toSet().length != users.length) {
      _rsyncInvalid();
    }
    users.sort((a, b) => a.id.compareTo(b.id));
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
    if (datasetsRaw is! List || datasetsRaw.length > 512) _rsyncInvalid();
    final datasets = <RsyncDataset>[];
    final datasetProof = <Object?>[];
    for (final row in datasetsRaw) {
      if (row is! Map ||
          !_scheduleDatasetName(row['id']) ||
          !{'FILESYSTEM', 'VOLUME'}.contains(row['type'])) {
        _rsyncInvalid();
      }
      if (row['type'] != 'FILESYSTEM') continue;
      final id = row['id'] as String,
          guid = _cloudProperty(row['guid']),
          path = row['mountpoint'],
          mounted = _cloudProperty(row['mounted']),
          readonly = _cloudProperty(row['readonly']);
      if (!RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(guid) ||
          BigInt.parse(guid) > BigInt.parse('18446744073709551615') ||
          path != null && path is! String ||
          row['locked'] is! bool ||
          row['key_loaded'] != null && row['key_loaded'] is! bool) {
        _rsyncInvalid();
      }
      final blocked =
          !id.contains('/') ||
              id
                  .split('/')
                  .any(
                    (p) =>
                        p.startsWith('.') ||
                        {'ix-apps', 'ix-applications'}.contains(p),
                  )
          ? 'Pool roots and system datasets are not supported.'
          : path != '/mnt/$id' ||
                mounted != 'yes' ||
                readonly != 'off' ||
                row['locked'] != false ||
                row['key_loaded'] == false
          ? 'Use a mounted, unlocked, writable dataset at its normal mountpoint.'
          : datasetsRaw.any(
              (d) =>
                  d is Map &&
                  d['id'] is String &&
                  (d['id'] as String).startsWith('$id/'),
            )
          ? 'Nested datasets are outside this bounded directory transfer.'
          : null;
      datasets.add(
        RsyncDataset(
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
      _rsyncInvalid();
    }
    datasets.sort((a, b) => a.id.compareTo(b.id));
    datasetProof.sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)));
    final tasksRaw = await _call('rsynctask.query', const [
      [],
      {'limit': 129, 'select': _rsyncTaskSelect},
    ]);
    if (tasksRaw is! List || tasksRaw.length > 128) _rsyncInvalid();
    final tasks =
        tasksRaw
            .map((raw) => _rsyncTask(raw, connections, users, datasets))
            .toList()
          ..sort((a, b) => a.id.compareTo(b.id));
    if (tasks.map((t) => t.id).toSet().length != tasks.length) _rsyncInvalid();
    final config = await _call('system.general.config', const []),
        ha = await _call('failover.licensed', const []);
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
    if (config is! Map ||
        !_pmText(config['timezone'], 64) ||
        !RegExp(r'^[A-Za-z0-9_+/:\-]+$')
            .hasMatch(config['timezone'] as String) ||
        ha is! bool ||
        jobs is! List ||
        jobs.length > 128) {
      _rsyncInvalid();
    }
    final jobIds = <int>{};
    for (final row in jobs) {
      if (row is! Map ||
          !_pmId(row['id']) ||
          !jobIds.add(row['id'] as int) ||
          !_diskMethod(row['method']) ||
          !{'WAITING', 'RUNNING'}.contains(row['state'])) {
        _rsyncInvalid();
      }
    }
    final inv = RsyncInventory(
      endpoint: _endpoint,
      timezone: config['timezone'] as String,
      failoverLicensed: ha,
      tasks: tasks,
      connections: connections,
      users: users,
      datasets: datasets,
      conflictingJob: jobs.isNotEmpty,
    );
    final proof = jsonEncode([
      _endpoint,
      inv.timezone,
      ha,
      tasks.map(_rsyncTaskProof).toList(),
      connections.map(_rsyncConnectionProof).toList(),
      users.map((u) => [u.id, u.uid, u.username]).toList(),
      datasetProof,
    ]);
    return _RsyncSnapshot(inv, proof, jobIds);
  }

  Future<RsyncInventory> load() async {
    _guard();
    if (_calling) throw const RsyncException(RsyncExceptionReason.busy);
    _calling = true;
    _inventories.clear();
    _reviews.clear();
    try {
      final s = await _read();
      _inventories[s.inventory] = s;
      return s.inventory;
    } on RsyncException {
      rethrow;
    } on Object {
      throw const RsyncException(RsyncExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<String> _pathProof(RsyncRequest r) async {
    final paths = {
      r.desired!.path,
      if (r.task?.settings != null) r.task!.settings!.path,
    }.toList()..sort();
    final proof = <Object?>[];
    for (final target in paths) {
      final dataset = r.inventory.datasets
          .where((d) => d.path == target && d.blockedReason == null)
          .toList();
      if (dataset.length != 1) _rsyncInvalid();
      var path = '';
      for (final part in [
        '',
        ...target.split('/').where((p) => p.isNotEmpty),
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
            path == target && stat['is_mountpoint'] != true) {
          _rsyncInvalid();
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
      final fs = await _call('filesystem.statfs', [target]);
      if (fs is! Map ||
          fs['fstype'] != 'zfs' ||
          fs['source'] != dataset.single.id ||
          fs['dest'] != target ||
          !_pmText(fs['fsid'], 128) ||
          fs['flags'] is! List ||
          (fs['flags'] as List).any((f) => f is! String) ||
          (fs['flags'] as List).contains('RDONLY')) {
        _rsyncInvalid();
      }
      proof.add([
        fs['fstype'],
        fs['source'],
        fs['dest'],
        fs['fsid'],
        fs['flags'],
      ]);
    }
    return jsonEncode(proof);
  }

  Future<RsyncReview> review(RsyncRequest request) async {
    _guard(request.action);
    if (isBusy || isOtherMutationBusy()) {
      throw const RsyncException(RsyncExceptionReason.busy);
    }
    if (request.action == RsyncAction.run && _issuedJobIds.length >= 64) {
      throw const RsyncException(RsyncExceptionReason.invalidRequest);
    }
    final baseline = _inventories[request.inventory];
    if (baseline == null) {
      throw const RsyncException(RsyncExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      throw const RsyncException(RsyncExceptionReason.invalidRequest);
    }
    _calling = true;
    _reviews.clear();
    try {
      final fresh = await _read();
      if (fresh.proof != baseline.proof ||
          fresh.inventory.blockedReason != null) {
        throw const RsyncException(RsyncExceptionReason.staleReview);
      }
      final path = await _pathProof(request);
      final c = request.inventory.connections.singleWhere(
        (c) => c.id == request.desired!.connectionId,
      );
      final result = RsyncReview(
        request: request,
        endpoint: _endpoint,
        warnings: [
          'This targets $_endpoint and the exact local path ${request.desired!.path} as user ${request.desired!.user}, pushing over SSH to ${c.destination}:${request.desired!.remotePath}. Never use it without permission to read the source and modify that remote destination.',
          'PUSH can overwrite existing destination files even though deletion, archive, arbitrary extra options and permission/extended-attribute preservation are disabled. No remote data, path, permissions, key ownership or free-space check is performed by this app.',
          'The fixed --one-file-system option prevents ordinary cross-device recursion. It does not exclude same-device bind mounts or prove absence of mounted content; review the selected source tree before authorizing transfer. The app never accepts arbitrary extra options.',
          'The source path has no trailing slash and is not rewritten. If the remote destination already exists as a directory, it receives the source directory. If the destination is absent, the resulting layout may differ. The app does not verify remote destination existence or layout. Ordinary recursive mode does not preserve symlinks like archive mode.',
          'Existing SSH keypair public identity and host-key fingerprints are rechecked; this is not proof that the private key is present, unchanged or usable. Remote trust must already have been independently established. No host-key scan, automatic pairing, known_hosts update or remote validation is requested.',
          ...c.hostKeyFingerprints.map(
            (f) => 'Existing trusted host-key fingerprint: $f',
          ),
          if (request.action == RsyncAction.create ||
              request.action == RsyncAction.update ||
              request.action == RsyncAction.enable ||
              request.action == RsyncAction.disable)
            'Every edit explicitly sends validate_rpath:false and ssh_keyscan:false. TrueNAS still validates local user/path and imports its existing private key locally. It then changes the task and restarts cron; failures can occur after those changes.',
          if (request.action == RsyncAction.enable)
            'Enabling authorizes future remote SSH connections and destination writes on schedule in ${request.inventory.timezone}. It can run soon after cron restarts. There is no additional app confirmation for each scheduled occurrence.',
          if (request.action == RsyncAction.disable ||
              request.action == RsyncAction.delete)
            'This changes the task configuration only. It does not cancel any transfer already started; all visible active jobs must be absent before submission.',
          if (request.action == RsyncAction.run) 'This explicitly authorizes one remote SSH transfer now, despite the schedule being disabled. The source runs a shell command under the selected local user; native host/account/path and option allowlists are mandatory. No timeout from the SSH connection configuration is promised for this transfer.',
          'A successful job is only a server-reported outcome: source disappearance and deletion-limit return codes can count as success, and the server can skip a locked dataset. Full transfer, consistency and integrity are not independently verified. No job logs, errors or command output are returned to the app.',
          'All paths, references, public identities, HA status and visible jobs are rechecked before submission, but external changes and source file content can still race. There is no snapshot, atomic compare-and-swap or remote overwrite preview.',
          'Accepted runs hold the shared write lock until an explicit Check job verifies the original handle. There is no automatic polling or retry. Any post-submission uncertainty leaves a sticky lock requiring inspection of the original server and reconnect recovery.',
        ],
      );
      _reviews[result] = _RsyncLease(DateTime.now(), baseline, path);
      return result;
    } on RsyncException {
      rethrow;
    } on Object {
      throw const RsyncException(RsyncExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<RsyncResult> execute(RsyncReview review, String confirmation) async {
    _guard(review.action);
    if (isBusy || isOtherMutationBusy()) {
      throw const RsyncException(RsyncExceptionReason.busy);
    }
    final lease = _reviews.remove(review);
    if (lease == null ||
        DateTime.now().difference(lease.created) > const Duration(minutes: 5) ||
        confirmation != review.target ||
        review.endpoint != _endpoint ||
        !_inventories.containsKey(review.request.inventory)) {
      throw const RsyncException(RsyncExceptionReason.staleReview);
    }
    final r = review.request;
    if (r.validationError != null) {
      throw const RsyncException(RsyncExceptionReason.invalidRequest);
    }
    _calling = true;
    var sent = false;
    try {
      final before = await _read();
      if (before.proof != lease.snapshot.proof ||
          before.inventory.blockedReason != null ||
          await _pathProof(r) != lease.pathProof) {
        return const RsyncResult(
          RsyncOutcome.rejected,
          'Task, path, account, SSH trust or safety state changed. Nothing was sent.',
        );
      }
      if (isOtherMutationBusy()) {
        return const RsyncResult(
          RsyncOutcome.rejected,
          'Another operation became active. Nothing was sent.',
        );
      }
      _guard(r.action);
      sent = true;
      if (r.action == RsyncAction.run) {
        final receipt = await _call('rsynctask.run', [r.task!.id]);
        if (!_pmId(receipt) ||
            before.jobIds.contains(receipt) ||
            !_issuedJobIds.add(receipt as int)) {
          return _unknown();
        }
        final job = RsyncJob(
          id: receipt,
          taskId: r.task!.id,
          endpoint: _endpoint,
          path: r.desired!.path,
          connectionId: r.desired!.connectionId,
          remotePath: r.desired!.remotePath,
        );
        _jobs[job] = lease;
        _reviews.clear();
        _inventories.clear();
        return await _check(job);
      }
      final method = r.action == RsyncAction.create
          ? 'rsynctask.create'
          : r.action == RsyncAction.delete
          ? 'rsynctask.delete'
          : 'rsynctask.update';
      final payload = r.action == RsyncAction.create
          ? [
              {
                ...r.desired!._wire,
                'validate_rpath': false,
                'ssh_keyscan': false,
              },
            ]
          : r.action == RsyncAction.delete
          ? [r.task!.id]
          : [
              r.task!.id,
              {
                if (r.action == RsyncAction.update)
                  ...r.settings!._wire
                else
                  'enabled': r.action == RsyncAction.enable,
                'validate_rpath': false,
                'ssh_keyscan': false,
              },
            ];
      final receipt = await _call(method, payload);
      int? changedId;
      final desired = _rsyncDesired(r);
      if (r.action == RsyncAction.delete) {
        if (receipt != true) return _unknown();
      } else {
        final task = _rsyncTask(
          receipt,
          before.inventory.connections,
          before.inventory.users,
          before.inventory.datasets,
        );
        if (!task.supported ||
            task.crossFilesystemProtection != _rsyncExpectedProtection(r) ||
            task.settings == null ||
            !_pmEqual(task.settings!._wire, desired._wire) ||
            r.action != RsyncAction.create && task.id != r.task!.id) {
          return _unknown();
        }
        changedId = task.id;
      }
      final after = await _read();
      if (after.inventory.blockedReason != null ||
          await _pathProof(r) != lease.pathProof ||
          !_rsyncVerifyMutation(before, after, r, changedId)) {
        return _unknown();
      }
      _reviews.clear();
      _inventories.clear();
      return const RsyncResult(
        RsyncOutcome.succeeded,
        'The exact stored task change was verified. No immediate run, remote validation or host-key scan was requested. An enabled schedule can start future transfers without another app confirmation.',
      );
    } on Object {
      return sent
          ? _unknown()
          : const RsyncResult(
              RsyncOutcome.rejected,
              'The final safety read failed. No task change or transfer was sent.',
            );
    } finally {
      _calling = false;
    }
  }

  RsyncResult _unknown({RsyncJob? job}) {
    _uncertain = true;
    _reviews.clear();
    _inventories.clear();
    return RsyncResult(
      RsyncOutcome.unknown,
      'The task change or transfer may have taken effect. Its exact outcome is unverified and the write lock remains held. Inspect the original server before reconnecting; never repeat this request.',
      job: job,
    );
  }

  Future<RsyncResult> check(RsyncJob job) async {
    _guard();
    if (_calling || !_jobs.containsKey(job) || job.endpoint != _endpoint) {
      throw const RsyncException(RsyncExceptionReason.staleReview);
    }
    _calling = true;
    try {
      return await _check(job);
    } on Object {
      return _unknown(job: job);
    } finally {
      _calling = false;
    }
  }

  Future<RsyncResult> _check(RsyncJob job) async {
    final lease = _jobs[job]!;
    final rows = await _call('core.get_jobs', [
      [
        ['id', '=', job.id],
        ['method', '=', 'rsynctask.run'],
      ],
      {
        'limit': 2,
        'select': ['id', 'method', 'arguments', 'state', 'result'],
      },
    ]);
    if (rows is! List || rows.length != 1 || rows.single is! Map) {
      return _unknown(job: job);
    }
    final row = rows.single as Map;
    if (row['id'] != job.id ||
        row['method'] != 'rsynctask.run' ||
        !_pmEqual(row['arguments'], [job.taskId]) ||
        !{
          'WAITING',
          'RUNNING',
          'SUCCESS',
          'FAILED',
          'ABORTED',
        }.contains(row['state']) ||
        !row.containsKey('result') ||
        row['result'] != null) {
      return _unknown(job: job);
    }
    final after = await _read();
    final original = lease.snapshot.inventory.tasks.singleWhere(
      (t) => t.id == job.taskId,
    );
    final r = RsyncRequest(
      inventory: lease.snapshot.inventory,
      action: RsyncAction.run,
      task: original,
    );
    if (after.proof != lease.snapshot.proof ||
        after.inventory.failoverLicensed ||
        after.jobIds.any((id) => id != job.id) ||
        await _pathProof(r) != lease.pathProof) {
      return _unknown(job: job);
    }
    if (_uncertain || {'FAILED', 'ABORTED'}.contains(row['state'])) {
      return _unknown(job: job);
    }
    if ({'WAITING', 'RUNNING'}.contains(row['state'])) {
      return RsyncResult(
        RsyncOutcome.accepted,
        'The exact owned Rsync job is ${row['state'] == 'WAITING' ? 'waiting' : 'running'}. This is not transfer completion. Use Check job explicitly; no request is replayed.',
        job: job,
      );
    }
    _jobs.remove(job);
    _reviews.clear();
    _inventories.clear();
    return const RsyncResult(
      RsyncOutcome.succeeded,
      'The exact Rsync job reported success. This does not prove a complete, consistent transfer: vanished files or deletion-limit outcomes may count as success. Remote data and integrity were not independently checked.',
    );
  }
}

Never _rsyncInvalid() =>
    throw const RsyncException(RsyncExceptionReason.invalidResponse);
RsyncSettings _rsyncDesired(RsyncRequest r) {
  final s = r.desired!;
  return RsyncSettings(
    path: s.path,
    user: s.user,
    connectionId: s.connectionId,
    remotePath: s.remotePath,
    description: s.description,
    enabled: r.action == RsyncAction.enable
        ? true
        : r.action == RsyncAction.disable
        ? false
        : s.enabled,
    recursive: s.recursive,
    times: s.times,
    compress: s.compress,
    delayUpdates: s.delayUpdates,
    cron: s.cron,
  );
}

Object _rsyncConnectionProof(RsyncConnection c) => [
  c.id,
  c.name,
  c.host,
  c.port,
  c.username,
  c.keyPairId,
  c.publicKeyFingerprint,
  c.hostKeyFingerprints,
];
Object _rsyncTaskProof(RsyncTask t) => [
  t.id,
  t.description,
  t.mode,
  t.direction,
  t.enabled,
  t.locked,
  t.blockedReason,
  t.settings?._wire,
  t.crossFilesystemProtection,
];
RsyncTask _rsyncTask(
  Object? raw,
  List<RsyncConnection> connections,
  List<RsyncUser> users,
  List<RsyncDataset> datasets,
) {
  if (raw is! Map ||
      !_rsyncTaskSelect
          .map((s) => s.split('.').first)
          .toSet()
          .every(raw.containsKey) ||
      raw['job'] != null && raw['job'] is! Map ||
      !_pmId(raw['id']) ||
      !_pmText(raw['desc'], 120, empty: true) ||
      !{'SSH', 'MODULE'}.contains(raw['mode']) ||
      !{'PUSH', 'PULL'}.contains(raw['direction']) ||
      const [
        'recursive',
        'times',
        'compress',
        'archive',
        'delete',
        'quiet',
        'preserveperm',
        'preserveattr',
        'delayupdates',
        'enabled',
        'locked',
      ].any((k) => raw[k] is! bool) ||
      raw['extra'] is! List ||
      (raw['extra'] as List).length > 128) {
    _rsyncInvalid();
  }
  final recorded = raw['job'];
  final last =
      recorded is Map &&
          {
            'WAITING',
            'RUNNING',
            'SUCCESS',
            'FAILED',
            'ABORTED',
          }.contains(recorded['state'])
      ? recorded['state'] as String
      : null;
  RsyncSettings? settings;
  String? blocked;
  final ref = raw['ssh_credentials'];
  if (raw['mode'] != 'SSH' ||
      raw['direction'] != 'PUSH' ||
      raw['archive'] != false ||
      raw['delete'] != false ||
      raw['quiet'] != false ||
      raw['preserveperm'] != false ||
      raw['preserveattr'] != false ||
      ((raw['extra'] as List).isNotEmpty &&
          !_pmEqual(raw['extra'], ['--one-file-system'])) ||
      raw['remotehost'] != null ||
      raw['remoteport'] != null ||
      raw['remotemodule'] != null ||
      ref is! Map ||
      !_pmId(ref['id']) ||
      ref['type'] != 'SSH_CREDENTIALS') {
    blocked = 'Only bounded SSH-keychain PUSH directory copies without archive, deletion, quiet mode or arbitrary extra options can be changed here.';
  } else if (raw['path'] is! String ||
      raw['user'] is! String ||
      raw['remotepath'] is! String ||
      raw['schedule'] is! Map) {
    _rsyncInvalid();
  } else {
    final c = raw['schedule'] as Map;
    if (c.length != 5 ||
        !const [
          'minute',
          'hour',
          'dom',
          'month',
          'dow',
        ].every((k) => c[k] is String)) {
      _rsyncInvalid();
    }
    final candidate = RsyncSettings(
      path: raw['path'] as String,
      user: raw['user'] as String,
      connectionId: ref['id'] as int,
      remotePath: raw['remotepath'] as String,
      description: raw['desc'] as String,
      enabled: raw['enabled'] as bool,
      recursive: raw['recursive'] as bool,
      times: raw['times'] as bool,
      compress: raw['compress'] as bool,
      delayUpdates: raw['delayupdates'] as bool,
      cron: PoolScrubCron(
        minute: c['minute'] as String,
        hour: c['hour'] as String,
        dom: c['dom'] as String,
        month: c['month'] as String,
        dow: c['dow'] as String,
      ),
    );
    blocked = candidate.validationError != null
        ? 'The stored task uses unsupported path, account or schedule syntax. Raw unsupported details are withheld.'
        : !connections.any((s) => s.id == candidate.connectionId) ||
              !users.any((u) => u.username == candidate.user) ||
              !datasets.any(
                (d) => d.path == candidate.path && d.blockedReason == null,
              )
        ? 'The required SSH public identity, local user or dedicated dataset is unavailable.'
        : raw['locked'] == true
        ? 'The task path is in a locked dataset; locked does not mean a running job.'
        : null;
    if (blocked == null) settings = candidate;
  }
  return RsyncTask(
    id: raw['id'] as int,
    description: raw['desc'] as String,
    mode: raw['mode'] as String,
    direction: raw['direction'] as String,
    enabled: raw['enabled'] as bool,
    locked: raw['locked'] as bool,
    settings: settings,
    blockedReason: blocked,
    lastJobState: last,
    crossFilesystemProtection: _pmEqual(raw['extra'], ['--one-file-system']),
  );
}

bool _rsyncVerifyMutation(
  _RsyncSnapshot before,
  _RsyncSnapshot after,
  RsyncRequest r,
  int? id,
) {
  final a = before.inventory, b = after.inventory;
  if (_rsyncReferenceProof(before) != _rsyncReferenceProof(after) ||
      a.endpoint != b.endpoint ||
      a.timezone != b.timezone ||
      b.failoverLicensed ||
      !_pmEqual(
        a.connections.map(_rsyncConnectionProof).toList(),
        b.connections.map(_rsyncConnectionProof).toList(),
      ) ||
      !_pmEqual(
        a.users.map((u) => [u.id, u.uid, u.username]).toList(),
        b.users.map((u) => [u.id, u.uid, u.username]).toList(),
      ) ||
      !_pmEqual(
        a.datasets.map((d) => [d.id, d.guid, d.path, d.blockedReason]).toList(),
        b.datasets.map((d) => [d.id, d.guid, d.path, d.blockedReason]).toList(),
      )) {
    return false;
  }
  final expectedCount =
      a.tasks.length +
      (r.action == RsyncAction.create
          ? 1
          : r.action == RsyncAction.delete
          ? -1
          : 0);
  if (b.tasks.length != expectedCount) return false;
  if (r.action == RsyncAction.create && a.tasks.any((t) => t.id == id)) {
    return false;
  }
  for (final old in a.tasks) {
    if (old.id == r.task?.id) continue;
    if (!b.tasks.any(
      (t) => _pmEqual(_rsyncTaskProof(t), _rsyncTaskProof(old)),
    )) {
      return false;
    }
  }
  if (r.action == RsyncAction.delete) {
    return !b.tasks.any((t) => t.id == r.task!.id);
  }
  return b.tasks.any(
    (t) =>
        t.id == id &&
        t.supported &&
        t.crossFilesystemProtection == _rsyncExpectedProtection(r) &&
        _pmEqual(t.settings!._wire, _rsyncDesired(r)._wire),
  );
}

bool _rsyncExpectedProtection(RsyncRequest r) =>
    r.action == RsyncAction.disable ? r.task!.crossFilesystemProtection : true;
String _rsyncReferenceProof(_RsyncSnapshot value) {
  final proof = jsonDecode(value.proof) as List;
  proof[3] = null;
  return jsonEncode(proof);
}
