part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedPoolMaintenanceSession {
  PoolMaintenanceCapabilities get poolMaintenanceCapabilities;
  Future<PoolMaintenanceInventory> loadPoolMaintenance();
  Future<PoolMaintenanceReview> reviewPoolMaintenance(
    PoolMaintenanceRequest request,
  );
  Future<PoolMaintenanceResult> executePoolMaintenance(
    PoolMaintenanceReview review,
    String confirmation,
  );
  Future<PoolMaintenanceResult> checkPoolMaintenanceJob(PoolMaintenanceJob job);
}

final class PoolMaintenanceCapabilities {
  const PoolMaintenanceCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.available,
    required this.canScrub,
    required this.canCreateSchedule,
    required this.canUpdateSchedule,
    required this.canDeleteSchedule,
  });
  const PoolMaintenanceCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      canScrub = false,
      canCreateSchedule = false,
      canUpdateSchedule = false,
      canDeleteSchedule = false;
  final bool connected,
      versionSupported,
      available,
      canScrub,
      canCreateSchedule,
      canUpdateSchedule,
      canDeleteSchedule;
  bool get supported => connected && versionSupported && available;
  bool allows(PoolMaintenanceAction action) =>
      supported &&
      switch (action) {
        PoolMaintenanceAction.startScrub ||
        PoolMaintenanceAction.stopScrub => canScrub,
        PoolMaintenanceAction.createSchedule => canCreateSchedule,
        PoolMaintenanceAction.updateSchedule ||
        PoolMaintenanceAction.enableSchedule ||
        PoolMaintenanceAction.disableSchedule => canUpdateSchedule,
        PoolMaintenanceAction.deleteSchedule => canDeleteSchedule,
      };
  String? get blockedReason => !connected
      ? 'Connect to inspect pool maintenance.'
      : !versionSupported
      ? 'Pool maintenance requires stable TrueNAS 25.10.'
      : !available
      ? 'Pool, scrub schedule, timezone, failover and active-job reads are required.'
      : null;
}

final class PoolMaintenanceScan {
  const PoolMaintenanceScan({
    this.function,
    this.state,
    this.startTime,
    this.endTime,
    this.pauseTime,
    this.percentage,
    this.errors,
    this.remainingSeconds,
  });
  final String? function, state;
  final DateTime? startTime, endTime, pauseTime;
  final double? percentage;
  final int? errors, remainingSeconds;
  bool get running => state == 'SCANNING';
  bool get paused => pauseTime != null;
}

final class PoolMaintenancePool {
  const PoolMaintenancePool({
    required this.id,
    required this.name,
    required this.guid,
    required this.status,
    required this.healthy,
    required this.warning,
    this.scan,
    this.expansionState,
    this.size,
    this.allocated,
    this.free,
  });
  final int id;
  final String name, guid, status;
  final bool healthy, warning;
  final PoolMaintenanceScan? scan;
  final String? expansionState;
  final int? size, allocated, free;
  bool get online => status == 'ONLINE' && healthy && !warning;
  bool get expanding => expansionState == 'SCANNING';
}

final class PoolScrubCron {
  const PoolScrubCron({
    this.minute = '0',
    this.hour = '0',
    this.dom = '*',
    this.month = '*',
    this.dow = '7',
  });
  final String minute, hour, dom, month, dow;
  String? get validationError => SnapshotScheduleCron(
    minute: minute,
    hour: hour,
    dom: dom,
    month: month,
    dow: dow,
  ).validationError;
  Map<String, Object?> get _wire => {
    'minute': minute,
    'hour': hour,
    'dom': dom,
    'month': month,
    'dow': dow,
  };
  String get expression => '$minute $hour $dom $month $dow';
}

final class PoolScrubScheduleSettings {
  const PoolScrubScheduleSettings({
    this.threshold = 35,
    this.description = '',
    this.cron = const PoolScrubCron(),
    this.enabled = true,
  });
  final int threshold;
  final String description;
  final PoolScrubCron cron;
  final bool enabled;
  String? get validationError => threshold < 0 || threshold > 3650
      ? 'Use a threshold from 0 to 3650 days.'
      : !_pmText(description, 200, empty: true)
      ? 'Use at most 200 plain description characters.'
      : cron.validationError;
  Map<String, Object?> get _wire => {
    'threshold': threshold,
    'description': description,
    'schedule': cron._wire,
    'enabled': enabled,
  };
}

final class PoolScrubSchedule {
  const PoolScrubSchedule({
    required this.id,
    required this.poolId,
    required this.poolName,
    required this.settings,
  });
  final int id, poolId;
  final String poolName;
  final PoolScrubScheduleSettings settings;
}

/// Only scrub methods have projected arguments; arbitrary job arguments are never requested.
final class PoolMaintenanceActiveJob {
  const PoolMaintenanceActiveJob({
    required this.id,
    required this.method,
    required this.state,
    this.poolId,
    this.poolName,
    this.action,
  });
  final int id;
  final String method, state;
  final int? poolId;
  final String? poolName, action;
  bool starts(PoolMaintenancePool pool) =>
      action == 'START' &&
      (method == 'pool.scrub' && poolId == pool.id ||
          method == 'pool.scrub.scrub' && poolName == pool.name);
}

final class PoolMaintenanceInventory {
  PoolMaintenanceInventory({
    required this.endpoint,
    required List<PoolMaintenancePool> pools,
    required List<PoolScrubSchedule> schedules,
    required this.timezone,
    required this.failoverLicensed,
    List<PoolMaintenanceActiveJob> jobs = const [],
  }) : pools = List.unmodifiable(pools),
       schedules = List.unmodifiable(schedules),
       jobs = List.unmodifiable(jobs);
  final String endpoint, timezone;
  final bool failoverLicensed;
  final List<PoolMaintenancePool> pools;
  final List<PoolScrubSchedule> schedules;
  final List<PoolMaintenanceActiveJob> jobs;
  String? get blockedReason => failoverLicensed
      ? 'HA/failover pool maintenance is outside this native workflow.'
      : null;
}

enum PoolMaintenanceAction {
  startScrub,
  stopScrub,
  createSchedule,
  updateSchedule,
  deleteSchedule,
  enableSchedule,
  disableSchedule,
}

final class PoolMaintenanceRequest {
  const PoolMaintenanceRequest({
    required this.inventory,
    required this.action,
    required this.pool,
    this.schedule,
    this.settings,
  });
  final PoolMaintenanceInventory inventory;
  final PoolMaintenanceAction action;
  final PoolMaintenancePool pool;
  final PoolScrubSchedule? schedule;
  final PoolScrubScheduleSettings? settings;
  bool get manual =>
      action == PoolMaintenanceAction.startScrub ||
      action == PoolMaintenanceAction.stopScrub;
  String get target =>
      '${switch (action) {
        PoolMaintenanceAction.startScrub => 'START SCRUB',
        PoolMaintenanceAction.stopScrub => 'STOP SCRUB',
        PoolMaintenanceAction.createSchedule => 'CREATE SCRUB SCHEDULE',
        PoolMaintenanceAction.updateSchedule => 'UPDATE SCRUB SCHEDULE',
        PoolMaintenanceAction.deleteSchedule => 'DELETE SCRUB SCHEDULE',
        PoolMaintenanceAction.enableSchedule => 'ENABLE SCRUB SCHEDULE',
        PoolMaintenanceAction.disableSchedule => 'DISABLE SCRUB SCHEDULE',
      }} ${pool.id} / ${pool.name} / ${pool.guid}${schedule == null ? '' : ' / ${schedule!.id}'}${action == PoolMaintenanceAction.stopScrub ? ' / ${pool.scan?.startTime?.toUtc().toIso8601String() ?? 'unknown'}' : ''}';
  String? get validationError {
    if (!inventory.pools.any((p) => identical(p, pool))) {
      return 'Choose the exact issued pool.';
    }
    if (inventory.blockedReason != null) return inventory.blockedReason;
    if (!pool.online || pool.expanding) {
      return 'Only healthy ONLINE pools without expansion are supported.';
    }
    if (inventory.pools.any(
      (p) =>
          p.expanding ||
          p.scan?.running == true &&
              (action != PoolMaintenanceAction.stopScrub || p.id != pool.id),
    )) {
      return 'Wait for other scrub, resilver or expansion work to stop, then reload.';
    }
    if (inventory.jobs.any(
      (j) => action != PoolMaintenanceAction.stopScrub || !j.starts(pool),
    )) {
      return 'Another server operation is active. Wait and reload.';
    }
    if (manual) {
      if (schedule != null || settings != null) {
        return 'Manual scrub is separate from schedule changes.';
      }
      if (action == PoolMaintenanceAction.startScrub &&
          pool.scan?.running == true) {
        return 'A scan is already active. Pause/resume is not supported here.';
      }
      if (action == PoolMaintenanceAction.stopScrub &&
          (pool.scan?.running != true ||
              pool.scan?.function != 'SCRUB' ||
              pool.scan?.startTime == null)) {
        return 'Only the exact identified active scrub can be stopped; resilver is never stopped.';
      }
    } else {
      if (pool.scan?.running == true) {
        return 'Schedule changes wait for the current scan to end.';
      }
      if (action == PoolMaintenanceAction.createSchedule) {
        if (schedule != null ||
            inventory.schedules.any((s) => s.poolId == pool.id) ||
            inventory.schedules.length >= 64) {
          return 'Only one schedule per pool is allowed, with at most 64 schedules.';
        }
      } else if (schedule == null ||
          !inventory.schedules.any((s) => identical(s, schedule)) ||
          schedule!.poolId != pool.id ||
          schedule!.poolName != pool.name) {
        return 'Choose the exact issued schedule for this pool.';
      }
      if (action == PoolMaintenanceAction.createSchedule ||
          action == PoolMaintenanceAction.updateSchedule) {
        if (settings == null) return 'Provide the schedule settings.';
        if (settings!.validationError != null) return settings!.validationError;
        if (action == PoolMaintenanceAction.updateSchedule &&
            _pmEqual(settings!._wire, schedule!.settings._wire)) {
          return 'Change at least one schedule setting.';
        }
      } else if (settings != null) {
        return 'Enable, disable and delete are separate exact operations.';
      }
      if (action == PoolMaintenanceAction.enableSchedule &&
              schedule!.settings.enabled ||
          action == PoolMaintenanceAction.disableSchedule &&
              !schedule!.settings.enabled) {
        return 'The schedule already has that enabled state.';
      }
    }
    return null;
  }
}

/// Public construction supports connector-free previews, but execute accepts only issued instances.
final class PoolMaintenanceReview {
  PoolMaintenanceReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final PoolMaintenanceRequest request;
  final String endpoint;
  final List<String> warnings;
  PoolMaintenanceAction get action => request.action;
  String get target => request.target;
}

enum PoolMaintenanceOutcome { accepted, succeeded, rejected, unknown }

final class PoolMaintenanceJob {
  const PoolMaintenanceJob({
    required this.id,
    required this.poolId,
    required this.endpoint,
    required this.poolName,
    required this.poolGuid,
    required this.action,
  });
  final int id, poolId;
  final String endpoint, poolName, poolGuid;
  final PoolMaintenanceAction action;
}

final class PoolMaintenanceResult {
  const PoolMaintenanceResult(this.outcome, this.message, {this.job});
  final PoolMaintenanceOutcome outcome;
  final String message;
  final PoolMaintenanceJob? job;
  int? get jobId => job?.id;
}

enum PoolMaintenanceExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  invalidRequest,
  invalidResponse,
  staleReview,
  unavailable,
}

final class PoolMaintenanceException implements Exception {
  const PoolMaintenanceException(this.reason);
  final PoolMaintenanceExceptionReason reason;
  String get userMessage => switch (reason) {
    PoolMaintenanceExceptionReason.notAuthenticated =>
      'Connect before inspecting pool maintenance.',
    PoolMaintenanceExceptionReason.unsupportedVersion =>
      'This workflow requires stable TrueNAS 25.10.',
    PoolMaintenanceExceptionReason.unavailableMethod =>
      'Required pool maintenance methods are unavailable.',
    PoolMaintenanceExceptionReason.busy =>
      'Another or uncertain operation blocks this change.',
    PoolMaintenanceExceptionReason.invalidRequest =>
      'Check the exact pool, scan and schedule. Nothing was sent.',
    PoolMaintenanceExceptionReason.invalidResponse => 'Pool maintenance identity could not be verified. Remote details were withheld.',
    PoolMaintenanceExceptionReason.staleReview => 'The review expired or pool maintenance changed. Reload and review again.',
    PoolMaintenanceExceptionReason.unavailable => 'Pool maintenance could not be read safely. Remote details were withheld.',
  };
  @override
  String toString() => 'PoolMaintenanceException(${reason.name})';
}

bool _pmText(Object? value, int max, {bool empty = false}) =>
    value is String &&
    value.length <= max &&
    (empty || value.isNotEmpty) &&
    value.trim() == value &&
    !RegExp(r'[\x00-\x1f\x7f-\x9f\u202a-\u202e\u2066-\u2069]').hasMatch(value);
bool _pmEqual(Object? a, Object? b) => jsonEncode(a) == jsonEncode(b);

final class _SessionPoolMaintenance {
  _SessionPoolMaintenance({
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
  final Set<PoolMaintenanceInventory> _inventories = {};
  final Map<PoolMaintenanceReview, DateTime> _reviews = {};
  final Map<PoolMaintenanceJob, PoolMaintenanceInventory> _jobs = {};
  final Map<PoolMaintenanceJob, DateTime> _scanStarts = {};
  bool get isBusy => _calling || _uncertain || _jobs.isNotEmpty;
  bool _method(String name, {bool job = false}) {
    final row = _metadata[name];
    return row is Map &&
        row['job'] == job &&
        row['uploadable'] == false &&
        row['downloadable'] == false &&
        row['private'] != true &&
        row['_private'] != true &&
        row['no_auth_required'] == false;
  }

  PoolMaintenanceCapabilities get capabilities => PoolMaintenanceCapabilities(
    connected: isCurrent(),
    versionSupported: _version,
    available: const [
      'pool.query',
      'pool.scrub.query',
      'core.get_jobs',
      'system.general.config',
      'failover.licensed',
    ].every((m) => _method(m)),
    canScrub: _method('pool.scrub.scrub', job: true),
    canCreateSchedule: _method('pool.scrub.create'),
    canUpdateSchedule: _method('pool.scrub.update'),
    canDeleteSchedule: _method('pool.scrub.delete'),
  );
  void _guard([PoolMaintenanceAction? action]) {
    if (!isCurrent()) {
      throw const PoolMaintenanceException(
        PoolMaintenanceExceptionReason.notAuthenticated,
      );
    }
    if (!_version) {
      throw const PoolMaintenanceException(
        PoolMaintenanceExceptionReason.unsupportedVersion,
      );
    }
    if (!capabilities.supported ||
        action != null && !capabilities.allows(action)) {
      throw const PoolMaintenanceException(
        PoolMaintenanceExceptionReason.unavailableMethod,
      );
    }
  }

  void _writeGuard(PoolMaintenanceRequest r) {
    _guard(r.action);
    if (_calling ||
        _uncertain ||
        isOtherMutationBusy() ||
        _jobs.isNotEmpty &&
            (r.action != PoolMaintenanceAction.stopScrub ||
                _jobs.keys.any(
                  (j) =>
                      j.action != PoolMaintenanceAction.startScrub ||
                      j.poolId != r.pool.id ||
                      j.poolGuid != r.pool.guid ||
                      _scanStarts[j] == null ||
                      _scanStarts[j] != r.pool.scan?.startTime,
                ))) {
      throw const PoolMaintenanceException(PoolMaintenanceExceptionReason.busy);
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

  Future<PoolMaintenanceInventory> _read() async {
    final raw = await _call('pool.query', const [
      [],
      {
        'limit': 65,
        'select': [
          'id',
          'name',
          'guid',
          'status',
          'healthy',
          'warning',
          'scan',
          'expand',
          'size',
          'allocated',
          'free',
        ],
      },
    ]);
    if (raw is! List || raw.length > 64) _pmInvalid();
    final pools = raw.map(_pmPool).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (pools.map((p) => p.id).toSet().length != pools.length ||
        pools.map((p) => p.guid).toSet().length != pools.length ||
        pools.map((p) => p.name).toSet().length != pools.length) {
      _pmInvalid();
    }
    final tasks = await _call('pool.scrub.query', const [
      [],
      {
        'limit': 65,
        'select': [
          'id',
          'pool',
          'pool_name',
          'threshold',
          'description',
          'schedule',
          'enabled',
        ],
      },
    ]);
    if (tasks is! List || tasks.length > 64) _pmInvalid();
    final schedules = tasks.map(_pmSchedule).toList()
      ..sort((a, b) => a.id.compareTo(b.id));
    if (schedules.map((s) => s.id).toSet().length != schedules.length ||
        schedules.map((s) => s.poolId).toSet().length != schedules.length ||
        schedules.any(
          (s) => !pools.any((p) => p.id == s.poolId && p.name == s.poolName),
        )) {
      _pmInvalid();
    }
    final general = await _call('system.general.config', const []);
    final ha = await _call('failover.licensed', const []);
    if (general is! Map ||
        !_pmText(general['timezone'], 64) ||
        !RegExp(r'^[A-Za-z0-9_+/:\-]+$')
            .hasMatch(general['timezone'] as String) ||
        ha is! bool) {
      _pmInvalid();
    }
    final rawJobs = await _call('core.get_jobs', const [
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
    if (rawJobs is! List || rawJobs.length > 128) _pmInvalid();
    final jobs = <PoolMaintenanceActiveJob>[];
    for (final row in rawJobs) {
      if (row is! Map ||
          !_pmId(row['id']) ||
          !_pmText(row['method'], 128) ||
          !RegExp(r'^[a-z][a-z0-9_.]{0,127}$')
              .hasMatch(row['method'] as String) ||
          !{'WAITING', 'RUNNING'}.contains(row['state'])) {
        _pmInvalid();
      }
      final method = row['method'] as String;
      int? poolId;
      String? poolName, action;
      if ({'pool.scrub', 'pool.scrub.scrub'}.contains(method)) {
        // Never request arbitrary job arguments: they may contain secrets.
        final detail = await _call('core.get_jobs', [
          [
            ['id', '=', row['id']],
            ['method', '=', method],
          ],
          {
            'limit': 2,
            'select': ['id', 'method', 'state', 'arguments'],
          },
        ]);
        if (detail is! List || detail.length != 1 || detail.single is! Map) {
          _pmInvalid();
        }
        final d = detail.single as Map;
        if (d['id'] != row['id'] ||
            d['method'] != method ||
            !{'WAITING', 'RUNNING'}.contains(d['state'])) {
          _pmInvalid();
        }
        final args = d['arguments'];
        if (args is! List ||
            !(args.length == 2 ||
                method == 'pool.scrub.scrub' && args.length == 1) ||
            args.length == 2 && !{'START', 'STOP', 'PAUSE'}.contains(args[1])) {
          _pmInvalid();
        }
        if (method == 'pool.scrub') {
          if (!_pmId(args[0])) _pmInvalid();
          poolId = args[0] as int;
        } else {
          if (!_pmName(args[0])) _pmInvalid();
          poolName = args[0] as String;
        }
        // Internal cron/legacy callers may omit the documented START default.
        action = args.length == 1 ? 'START' : args[1] as String;
      }
      jobs.add(
        PoolMaintenanceActiveJob(
          id: row['id'] as int,
          method: method,
          state: row['state'] as String,
          poolId: poolId,
          poolName: poolName,
          action: action,
        ),
      );
    }
    if (jobs.map((j) => j.id).toSet().length != jobs.length) _pmInvalid();
    jobs.sort((a, b) => a.id.compareTo(b.id));
    return PoolMaintenanceInventory(
      endpoint: _endpoint,
      pools: pools,
      schedules: schedules,
      timezone: general['timezone'] as String,
      failoverLicensed: ha,
      jobs: jobs,
    );
  }

  Future<PoolMaintenanceInventory> load() async {
    _guard();
    if (_calling) {
      throw const PoolMaintenanceException(PoolMaintenanceExceptionReason.busy);
    }
    _calling = true;
    _inventories.clear();
    _reviews.clear();
    try {
      final value = await _read();
      _inventories.add(value);
      return value;
    } on PoolMaintenanceException {
      rethrow;
    } on Object {
      throw const PoolMaintenanceException(
        PoolMaintenanceExceptionReason.unavailable,
      );
    } finally {
      _calling = false;
    }
  }

  Future<PoolMaintenanceReview> review(PoolMaintenanceRequest request) async {
    _writeGuard(request);
    if (!_inventories.contains(request.inventory)) {
      throw const PoolMaintenanceException(
        PoolMaintenanceExceptionReason.staleReview,
      );
    }
    if (request.validationError != null) {
      throw const PoolMaintenanceException(
        PoolMaintenanceExceptionReason.invalidRequest,
      );
    }
    _calling = true;
    try {
      final fresh = await _read();
      if (!_pmSameInventory(fresh, request.inventory)) {
        throw const PoolMaintenanceException(
          PoolMaintenanceExceptionReason.staleReview,
        );
      }
      final value = PoolMaintenanceReview(
        request: request,
        endpoint: _endpoint,
        warnings: [
          'Only the reviewed pool ID, name and GUID on $_endpoint are targeted. External changes can race after the final read; there is no atomic compare-and-swap.',
          if (request.manual) 'Scrub commands are asynchronous jobs. Accepted means the exact job was observed, not that a scrub finished or data integrity was proved. Use Check job explicitly; the app never polls or retries automatically.',
          if (request.action == PoolMaintenanceAction.startScrub) 'Starting a scrub reads stored data and may repair corruption using available ZFS redundancy. It can create substantial disk load and reduce performance. It is not a backup.',
          if (request.action == PoolMaintenanceAction.stopScrub) 'STOP cancels the identified active scrub, including a paused scrub. It is not pause, does not stop resilver and does not alter the schedule. The scan start time is rechecked; second-resolution identity is not an atomic ZFS scan token.',
          if (!request.manual) 'This changes one scrub schedule and restarts the server cron service. Other scheduled services may be affected by that restart. A datastore change can precede a cron error, so any post-submission error is uncertain.',
          if (!request.manual)
            'Cron checks run in the server timezone ${request.inventory.timezone}. Threshold is the minimum days between eligible scrubs; a cron occurrence does not promise a scrub will start. Disabled or deleted schedules do not cancel a running scrub.',
          if (request.action == PoolMaintenanceAction.deleteSchedule) 'This permanently removes the scrub schedule, not the pool or its data. No topology, disk, encryption or pool export operation is authorized.',
          'HA systems and unhealthy/offline pools are excluded. Other active server jobs and scans block changes; only matching START scrub jobs are allowed when stopping the exact current scrub.',
          'Unknown outcomes hold the shared write lock. Inspect the original server before reconnecting and acknowledging recovery; never repeat a request to discover its result.',
        ],
      );
      _reviews.clear();
      _reviews[value] = DateTime.now();
      return value;
    } on PoolMaintenanceException {
      rethrow;
    } on Object {
      throw const PoolMaintenanceException(
        PoolMaintenanceExceptionReason.unavailable,
      );
    } finally {
      _calling = false;
    }
  }

  Future<PoolMaintenanceResult> execute(
    PoolMaintenanceReview review,
    String confirmation,
  ) async {
    _writeGuard(review.request);
    final issued = _reviews.remove(review);
    if (issued == null ||
        DateTime.now().difference(issued) > const Duration(minutes: 5) ||
        confirmation != review.target ||
        review.endpoint != _endpoint ||
        !_inventories.contains(review.request.inventory)) {
      throw const PoolMaintenanceException(
        PoolMaintenanceExceptionReason.staleReview,
      );
    }
    final r = review.request;
    if (r.validationError != null) {
      throw const PoolMaintenanceException(
        PoolMaintenanceExceptionReason.invalidRequest,
      );
    }
    _calling = true;
    var dispatched = false;
    try {
      final before = await _read();
      if (!_pmSameInventory(before, r.inventory)) {
        return const PoolMaintenanceResult(
          PoolMaintenanceOutcome.rejected,
          'Pool, scan, schedules, timezone or active jobs changed. Nothing was sent.',
        );
      }
      if (isOtherMutationBusy()) {
        return const PoolMaintenanceResult(
          PoolMaintenanceOutcome.rejected,
          'Another operation became active. Nothing was sent.',
        );
      }
      _guard(r.action);
      dispatched = true;
      if (r.manual) {
        final receipt = await _call('pool.scrub.scrub', [
          r.pool.name,
          r.action == PoolMaintenanceAction.startScrub ? 'START' : 'STOP',
        ]);
        if (!_pmId(receipt) ||
            _jobs.keys.any((j) => j.id == receipt) ||
            before.jobs.any((j) => j.id == receipt)) {
          return _unknown();
        }
        final job = PoolMaintenanceJob(
          id: receipt as int,
          poolId: r.pool.id,
          endpoint: _endpoint,
          poolName: r.pool.name,
          poolGuid: r.pool.guid,
          action: r.action,
        );
        _jobs[job] = before;
        _inventories.clear();
        _reviews.clear();
        return await _check(job);
      }
      final payload = _pmPayload(r);
      final method = switch (r.action) {
        PoolMaintenanceAction.createSchedule => 'pool.scrub.create',
        PoolMaintenanceAction.deleteSchedule => 'pool.scrub.delete',
        _ => 'pool.scrub.update',
      };
      final receipt = await _call(method, payload);
      int? createdId;
      if (r.action == PoolMaintenanceAction.deleteSchedule) {
        if (receipt != true) return _unknown();
      } else {
        final task = _pmSchedule(receipt);
        if (task.poolId != r.pool.id ||
            task.poolName != r.pool.name ||
            (r.action != PoolMaintenanceAction.createSchedule &&
                task.id != r.schedule!.id) ||
            !_pmEqual(task.settings._wire, _pmDesired(r)._wire)) {
          return _unknown();
        }
        createdId = task.id;
      }
      final after = await _read();
      if (!_pmVerifySchedule(before, after, r, createdId)) return _unknown();
      _reviews.clear();
      _inventories.clear();
      return const PoolMaintenanceResult(
        PoolMaintenanceOutcome.succeeded,
        'The exact scrub schedule change was verified. No manual scrub was requested; schedule eligibility and future execution remain server-controlled.',
      );
    } on Object {
      return dispatched
          ? _unknown()
          : const PoolMaintenanceResult(
              PoolMaintenanceOutcome.rejected,
              'The final read could not be verified. No pool maintenance change was sent.',
            );
    } finally {
      _calling = false;
    }
  }

  PoolMaintenanceResult _unknown({PoolMaintenanceJob? job}) {
    _uncertain = true;
    _inventories.clear();
    _reviews.clear();
    return PoolMaintenanceResult(
      PoolMaintenanceOutcome.unknown,
      'The operation may have taken effect, but its exact outcome could not be verified. The write lock remains held. Inspect the original server before reconnecting; do not repeat the request.',
      job: job,
    );
  }

  Future<PoolMaintenanceResult> check(PoolMaintenanceJob job) async {
    _guard();
    if (_calling || !_jobs.containsKey(job) || job.endpoint != _endpoint) {
      throw const PoolMaintenanceException(
        PoolMaintenanceExceptionReason.staleReview,
      );
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

  Future<Map> _jobRow(PoolMaintenanceJob job) async {
    final rows = await _call('core.get_jobs', [
      [
        ['id', '=', job.id],
        ['method', '=', 'pool.scrub.scrub'],
      ],
      {
        'limit': 2,
        'select': ['id', 'method', 'arguments', 'state', 'result'],
      },
    ]);
    if (rows is! List || rows.length != 1 || rows.single is! Map) _pmInvalid();
    final row = rows.single as Map;
    if (row['id'] != job.id ||
        row['method'] != 'pool.scrub.scrub' ||
        !_pmEqual(row['arguments'], [
          job.poolName,
          job.action == PoolMaintenanceAction.startScrub ? 'START' : 'STOP',
        ]) ||
        !{
          'WAITING',
          'RUNNING',
          'SUCCESS',
          'FAILED',
          'ABORTED',
        }.contains(row['state']) ||
        !row.containsKey('result') ||
        row['result'] != null) {
      _pmInvalid();
    }
    return row;
  }

  Future<PoolMaintenanceResult> _check(PoolMaintenanceJob job) async {
    final before = _jobs[job]!;
    final row = await _jobRow(job);
    final after = await _read();
    final pools = after.pools
        .where(
          (p) =>
              p.id == job.poolId &&
              p.guid == job.poolGuid &&
              p.name == job.poolName,
        )
        .toList();
    if (pools.length != 1 ||
        after.failoverLicensed ||
        after.timezone != before.timezone ||
        !_pmEqual(
          before.schedules.map(_pmScheduleWire).toList(),
          after.schedules.map(_pmScheduleWire).toList(),
        ) ||
        !_pmSamePools(before.pools, after.pools, ignoreScanId: job.poolId)) {
      return _unknown(job: job);
    }
    final pool = pools.single,
        old = before.pools.singleWhere((p) => p.id == job.poolId);
    final scan = pool.scan;
    final observedStart = _scanStarts[job];
    if (observedStart != null && scan?.startTime != observedStart) {
      return _unknown(job: job);
    }
    final running = {'WAITING', 'RUNNING'}.contains(row['state']);
    if (row['state'] == 'FAILED' ||
        row['state'] == 'ABORTED' ||
        row['state'] == 'SUCCESS' && row['result'] != null) {
      return _unknown(job: job);
    }
    if (job.action == PoolMaintenanceAction.stopScrub) {
      if (scan?.function != 'SCRUB' || scan?.startTime != old.scan?.startTime) {
        return _unknown(job: job);
      }
      if (running) {
        if (!{'SCANNING', 'CANCELED', 'FINISHED'}.contains(scan?.state)) {
          return _unknown(job: job);
        }
      } else if (scan?.state != 'CANCELED') {
        return _unknown(job: job);
      }
    } else {
      // A waiting job may not yet have changed the scan. Never call it complete.
      if (!running ||
          !_pmEqual(_pmScanIdentity(scan), _pmScanIdentity(old.scan))) {
        if (scan?.function != 'SCRUB' ||
            scan?.startTime == null ||
            scan!.startTime == old.scan?.startTime ||
            !{'SCANNING', 'FINISHED', 'CANCELED'}.contains(scan.state)) {
          return _unknown(job: job);
        }
      }
      if (!running && scan?.running == true && scan?.paused != true) {
        return _unknown(job: job);
      }
      if (scan?.function == 'SCRUB' &&
          scan?.startTime != null &&
          scan!.startTime != old.scan?.startTime) {
        _scanStarts[job] = scan.startTime!;
      }
    }
    // A later successful read cannot undo an earlier uncertain mutation.
    if (_uncertain) return _unknown(job: job);
    if (running) {
      return PoolMaintenanceResult(
        PoolMaintenanceOutcome.accepted,
        'The exact scrub job is ${row['state'] == 'WAITING' ? 'waiting' : 'running'}. This is not completion or an integrity guarantee. Use Check job explicitly.',
        job: job,
      );
    }
    // STOP replaces the visible START handle. Retain its lock until every
    // earlier owned START on that pool has also reached a verified terminal job.
    final older = _jobs.keys
        .where(
          (j) =>
              !identical(j, job) &&
              j.poolId == job.poolId &&
              j.poolGuid == job.poolGuid,
        )
        .toList();
    if (job.action == PoolMaintenanceAction.stopScrub) {
      for (final previous in older) {
        final prior = await _jobRow(previous);
        if ({'WAITING', 'RUNNING'}.contains(prior['state'])) {
          return PoolMaintenanceResult(
            PoolMaintenanceOutcome.accepted,
            'The STOP job ended; the earlier owned START job has not yet ended. Use Check job again explicitly. No request is replayed.',
            job: job,
          );
        }
        if (prior['state'] != 'SUCCESS' || prior['result'] != null) {
          return _unknown(job: job);
        }
      }
      for (final previous in older) {
        _jobs.remove(previous);
        _scanStarts.remove(previous);
      }
    }
    _jobs.remove(job);
    _scanStarts.remove(job);
    _reviews.clear();
    _inventories.clear();
    if (_uncertain) return _unknown(job: job);
    return PoolMaintenanceResult(
      PoolMaintenanceOutcome.succeeded,
      scan?.paused == true
          ? 'The owned START job ended because the scrub is paused. The scrub is not complete. Reload to inspect it; pause/resume is not supported here.'
          : scan?.state == 'FINISHED'
          ? 'The owned scrub job ended and the current scan reports FINISHED. This is not a backup or independent proof of data integrity.'
          : 'The owned scrub job ended and the identified scan reports CANCELED. No schedule was changed.',
    );
  }
}

Never _pmInvalid() => throw const PoolMaintenanceException(
  PoolMaintenanceExceptionReason.invalidResponse,
);
bool _pmId(Object? v) => v is int && v > 0 && v <= 9007199254740991;
bool _pmName(Object? v) =>
    _pmText(v, 120) &&
    RegExp(r'^[A-Za-z][A-Za-z0-9_.:\-]*$').hasMatch(v as String) &&
    !{'boot-pool', 'freenas-boot'}.contains(v);
int? _pmCount(Object? v) {
  if (v == null) return null;
  if (v is! int || v < 0 || v > 9007199254740991) _pmInvalid();
  return v;
}

DateTime? _pmDate(Object? v) {
  try {
    return _apiKeyDate(v, nullable: true, naiveUtc: true);
  } on Object {
    _pmInvalid();
  }
}

PoolMaintenanceScan? _pmScan(Object? raw) {
  if (raw == null) return null;
  if (raw is! Map ||
      !const [
        'function',
        'state',
        'start_time',
        'end_time',
        'pause',
        'percentage',
        'errors',
        'total_secs_left',
      ].every(raw.containsKey)) {
    _pmInvalid();
  }
  if (!{null, 'NONE', 'SCRUB', 'RESILVER'}.contains(raw['function']) ||
      !{
        null,
        'NONE',
        'SCANNING',
        'FINISHED',
        'CANCELED',
      }.contains(raw['state'])) {
    _pmInvalid();
  }
  final start = _pmDate(raw['start_time']),
      end = _pmDate(raw['end_time']),
      pause = _pmDate(raw['pause']);
  final percent = raw['percentage'];
  if (percent != null &&
      (percent is! num || !percent.isFinite || percent < 0 || percent > 100)) {
    _pmInvalid();
  }
  if (raw['state'] == 'SCANNING' &&
          (!{'SCRUB', 'RESILVER'}.contains(raw['function']) ||
              start == null ||
              start.millisecondsSinceEpoch <= 0 ||
              end != null) ||
      pause != null &&
          (raw['state'] != 'SCANNING' ||
              raw['function'] != 'SCRUB' ||
              start == null ||
              pause.isBefore(start))) {
    _pmInvalid();
  }
  return PoolMaintenanceScan(
    function: raw['function'] as String?,
    state: raw['state'] as String?,
    startTime: start,
    endTime: end,
    pauseTime: pause,
    percentage: (percent as num?)?.toDouble(),
    errors: _pmCount(raw['errors']),
    remainingSeconds: _pmCount(raw['total_secs_left']),
  );
}

PoolMaintenancePool _pmPool(Object? raw) {
  if (raw is! Map ||
      !_pmId(raw['id']) ||
      !_pmName(raw['name']) ||
      !_pmText(raw['guid'], 20) ||
      !RegExp(r'^[1-9][0-9]{0,19}$').hasMatch(raw['guid'] as String) ||
      !{
        'ONLINE',
        'DEGRADED',
        'FAULTED',
        'OFFLINE',
        'UNAVAIL',
        'SUSPENDED',
        'REMOVED',
      }.contains(raw['status']) ||
      raw['healthy'] is! bool ||
      raw['warning'] is! bool ||
      !const [
        'scan',
        'expand',
        'size',
        'allocated',
        'free',
      ].every(raw.containsKey)) {
    _pmInvalid();
  }
  final expand = raw['expand'];
  if (expand != null &&
      (expand is! Map ||
          !expand.containsKey('state') ||
          !{
            null,
            'NONE',
            'SCANNING',
            'FINISHED',
            'CANCELED',
          }.contains(expand['state']))) {
    _pmInvalid();
  }
  final size = _pmCount(raw['size']),
      allocated = _pmCount(raw['allocated']),
      free = _pmCount(raw['free']);
  if (size != null &&
      (allocated != null && allocated > size || free != null && free > size)) {
    _pmInvalid();
  }
  return PoolMaintenancePool(
    id: raw['id'] as int,
    name: raw['name'] as String,
    guid: raw['guid'] as String,
    status: raw['status'] as String,
    healthy: raw['healthy'] as bool,
    warning: raw['warning'] as bool,
    scan: _pmScan(raw['scan']),
    expansionState: expand is Map ? expand['state'] as String? : null,
    size: size,
    allocated: allocated,
    free: free,
  );
}

PoolScrubSchedule _pmSchedule(Object? raw) {
  if (raw is! Map ||
      !_pmId(raw['id']) ||
      !_pmId(raw['pool']) ||
      !_pmName(raw['pool_name']) ||
      raw['threshold'] is! int ||
      !_pmText(raw['description'], 200, empty: true) ||
      raw['enabled'] is! bool ||
      raw['schedule'] is! Map) {
    _pmInvalid();
  }
  final c = raw['schedule'] as Map;
  if (c.length != 5 ||
      !const [
        'minute',
        'hour',
        'dom',
        'month',
        'dow',
      ].every((k) => c[k] is String)) {
    _pmInvalid();
  }
  final settings = PoolScrubScheduleSettings(
    threshold: raw['threshold'] as int,
    description: raw['description'] as String,
    enabled: raw['enabled'] as bool,
    cron: PoolScrubCron(
      minute: c['minute'] as String,
      hour: c['hour'] as String,
      dom: c['dom'] as String,
      month: c['month'] as String,
      dow: c['dow'] as String,
    ),
  );
  if (settings.validationError != null) _pmInvalid();
  return PoolScrubSchedule(
    id: raw['id'] as int,
    poolId: raw['pool'] as int,
    poolName: raw['pool_name'] as String,
    settings: settings,
  );
}

Object? _pmScanIdentity(PoolMaintenanceScan? s) => s == null
    ? null
    : [
        s.function,
        s.state,
        s.startTime?.toUtc().toIso8601String(),
        s.endTime?.toUtc().toIso8601String(),
        s.pauseTime?.toUtc().toIso8601String(),
      ];
Object _pmPoolIdentity(PoolMaintenancePool p, {bool ignoreScan = false}) => [
  p.id,
  p.name,
  p.guid,
  p.status,
  p.healthy,
  p.warning,
  p.expansionState,
  if (!ignoreScan) _pmScanIdentity(p.scan),
];
Object _pmScheduleWire(PoolScrubSchedule s) => [
  s.id,
  s.poolId,
  s.poolName,
  s.settings._wire,
];
Object _pmJobIdentity(PoolMaintenanceActiveJob j) => [
  j.id,
  j.method,
  j.poolId,
  j.poolName,
  j.action,
];
bool _pmSamePools(
  List<PoolMaintenancePool> a,
  List<PoolMaintenancePool> b, {
  int? ignoreScanId,
}) => _pmEqual(
  a.map((p) => _pmPoolIdentity(p, ignoreScan: p.id == ignoreScanId)).toList(),
  b.map((p) => _pmPoolIdentity(p, ignoreScan: p.id == ignoreScanId)).toList(),
);
bool _pmSameInventory(PoolMaintenanceInventory a, PoolMaintenanceInventory b) =>
    a.endpoint == b.endpoint &&
    a.timezone == b.timezone &&
    a.failoverLicensed == b.failoverLicensed &&
    _pmSamePools(a.pools, b.pools) &&
    _pmEqual(
      a.schedules.map(_pmScheduleWire).toList(),
      b.schedules.map(_pmScheduleWire).toList(),
    ) &&
    _pmEqual(
      a.jobs.map(_pmJobIdentity).toList(),
      b.jobs.map(_pmJobIdentity).toList(),
    );
PoolScrubScheduleSettings _pmDesired(PoolMaintenanceRequest r) =>
    r.settings ??
    PoolScrubScheduleSettings(
      threshold: r.schedule!.settings.threshold,
      description: r.schedule!.settings.description,
      cron: r.schedule!.settings.cron,
      enabled: r.action == PoolMaintenanceAction.enableSchedule
          ? true
          : r.action == PoolMaintenanceAction.disableSchedule
          ? false
          : r.schedule!.settings.enabled,
    );
List<Object?> _pmPayload(PoolMaintenanceRequest r) => switch (r.action) {
  PoolMaintenanceAction.createSchedule => [
    {'pool': r.pool.id, ...r.settings!._wire},
  ],
  PoolMaintenanceAction.deleteSchedule => [r.schedule!.id],
  PoolMaintenanceAction.enableSchedule => [
    r.schedule!.id,
    {'enabled': true},
  ],
  PoolMaintenanceAction.disableSchedule => [
    r.schedule!.id,
    {'enabled': false},
  ],
  _ => [r.schedule!.id, r.settings!._wire],
};
bool _pmVerifySchedule(
  PoolMaintenanceInventory before,
  PoolMaintenanceInventory after,
  PoolMaintenanceRequest r,
  int? createdId,
) {
  if (before.endpoint != after.endpoint ||
      before.timezone != after.timezone ||
      after.failoverLicensed ||
      after.jobs.isNotEmpty ||
      !_pmSamePools(before.pools, after.pools)) {
    return false;
  }
  final old = before.schedules, newTasks = after.schedules;
  if (r.action == PoolMaintenanceAction.createSchedule &&
      (newTasks.length != old.length + 1 ||
          old.any((s) => s.id == createdId))) {
    return false;
  }
  if (r.action == PoolMaintenanceAction.deleteSchedule &&
      (newTasks.length != old.length - 1 ||
          newTasks.any((s) => s.id == r.schedule!.id))) {
    return false;
  }
  if (r.action != PoolMaintenanceAction.createSchedule &&
      r.action != PoolMaintenanceAction.deleteSchedule &&
      newTasks.length != old.length) {
    return false;
  }
  for (final s in old) {
    if (s.id == r.schedule?.id) continue;
    if (!newTasks.any(
      (n) => _pmEqual(_pmScheduleWire(s), _pmScheduleWire(n)),
    )) {
      return false;
    }
  }
  if (r.action == PoolMaintenanceAction.deleteSchedule) return true;
  return newTasks.any(
    (s) =>
        s.id == createdId &&
        s.poolId == r.pool.id &&
        s.poolName == r.pool.name &&
        _pmEqual(s.settings._wire, _pmDesired(r)._wire),
  );
}
