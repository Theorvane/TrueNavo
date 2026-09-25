part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedSnapshotSchedulesSession {
  SnapshotSchedulesCapabilities get snapshotSchedulesCapabilities;
  Future<SnapshotScheduleInventory> loadSnapshotSchedules();
  Future<SnapshotScheduleReview> reviewSnapshotSchedule(
    SnapshotScheduleRequest request,
  );
  Future<SnapshotScheduleResult> executeSnapshotSchedule(
    SnapshotScheduleReview review,
    String confirmation,
  );
}

const snapshotScheduleLifetimeUnits = ['HOUR', 'DAY', 'WEEK', 'MONTH', 'YEAR'];
const _scheduleSafetyMethods = {
  'pool.snapshottask.query',
  'pool.dataset.query',
  'pool.filesystem_choices',
  'pool.snapshot.query',
  'replication.query',
  'vmware.query',
  'system.general.config',
};

final class SnapshotSchedulesCapabilities {
  SnapshotSchedulesCapabilities({
    required this.connected,
    required this.versionSupported,
    required Set<String> methods,
  }) : methods = Set.unmodifiable(methods);
  const SnapshotSchedulesCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      methods = const {};
  final bool connected, versionSupported;
  final Set<String> methods;
  bool get supported =>
      connected &&
      versionSupported &&
      methods.containsAll({
        'pool.snapshottask.query',
        'pool.dataset.query',
        'pool.filesystem_choices',
        'system.general.config',
      });
  bool canCall(String method) => supported && methods.contains(method);
  bool get _safe => supported && methods.containsAll(_scheduleSafetyMethods);
  bool get canCreate => _safe && methods.contains('pool.snapshottask.create');
  bool get canUpdate =>
      _safe &&
      methods.containsAll({
        'pool.snapshottask.update',
        'pool.snapshottask.update_will_change_retention_for',
        'pool.snapshottask.delete_will_change_retention_for',
      });
  bool get canDelete =>
      _safe &&
      methods.containsAll({
        'pool.snapshottask.delete',
        'pool.snapshottask.delete_will_change_retention_for',
      });
  bool get canRun => _safe && methods.contains('pool.snapshottask.run');
  String? get blockedReason => !connected
      ? 'Connect to inspect snapshot schedules.'
      : !versionSupported
      ? 'Snapshot schedules require stable TrueNAS 25.10.'
      : !supported
      ? 'Schedule, dataset, choice and timezone reads are required.'
      : null;
}

final class SnapshotScheduleCron {
  const SnapshotScheduleCron({
    this.minute = '0',
    this.hour = '*',
    this.dom = '*',
    this.month = '*',
    this.dow = '*',
    this.begin = '00:00',
    this.end = '23:59',
  });
  final String minute, hour, dom, month, dow, begin, end;
  String? get validationError {
    final minutes = _scheduleCronField(minute, 0, 59),
        hours = _scheduleCronField(hour, 0, 23),
        days = _scheduleCronField(dom, 1, 31),
        months = _scheduleCronField(month, 1, 12),
        weekdays = _scheduleCronField(dow, 0, 7);
    if ([minutes, hours, days, months, weekdays].any((v) => v == null)) {
      return 'Use bounded numeric cron values, lists, ranges or a single range/* step. Sunday is 0 or 7; Monday–Saturday are 1–6.';
    }
    final start = _scheduleTime(begin), finish = _scheduleTime(end);
    if (start == null || finish == null || start >= finish) {
      return 'Use a same-day HH:MM window with begin strictly before end. Equal times mean all day on this server and are not supported here.';
    }
    if (!hours!.any(
      (h) => minutes!.any((m) => h * 60 + m >= start && h * 60 + m <= finish),
    )) {
      return 'The minute/hour schedule does not occur inside the selected time window.';
    }
    for (var year = 2024; year <= 2052; year++) {
      for (final month in months!) {
        final max = DateTime.utc(year, month + 1, 0).day;
        for (var day = 1; day <= max; day++) {
          final domMatches = days!.contains(day),
              dowMatches =
                  weekdays!.contains(DateTime.utc(year, month, day).weekday) ||
                  DateTime.utc(year, month, day).weekday == 7 &&
                      weekdays.contains(0);
          if (dom == '*'
              ? dowMatches
              : dow == '*'
              ? domMatches
              : domMatches || dowMatches) {
            return null;
          }
        }
      }
    }
    return 'The cron calendar has no valid matching date.';
  }

  Map<String, Object?> get _wire => {
    'minute': minute,
    'hour': hour,
    'dom': dom,
    'month': month,
    'dow': dow,
    'begin': begin,
    'end': end,
  };
}

final class SnapshotScheduleSettings {
  const SnapshotScheduleSettings({
    required this.dataset,
    this.recursive = false,
    this.exclude = const [],
    this.lifetimeValue = 2,
    this.lifetimeUnit = 'WEEK',
    this.enabled = true,
    this.namingSchema = 'auto-%Y-%m-%d_%H-%M',
    this.allowEmpty = true,
    this.cron = const SnapshotScheduleCron(),
  });
  final String dataset, lifetimeUnit, namingSchema;
  final bool recursive, enabled, allowEmpty;
  final List<String> exclude;
  final int lifetimeValue;
  final SnapshotScheduleCron cron;
  int get lifetimeSeconds =>
      lifetimeValue *
      (const {
            'HOUR': 3600,
            'DAY': 86400,
            'WEEK': 604800,
            'MONTH': 2592000,
            'YEAR': 31536000,
          }[lifetimeUnit] ??
          0);
  String? get validationError {
    if (!_scheduleDatasetName(dataset)) {
      return 'Choose a valid dataset from this inventory.';
    }
    if (lifetimeValue < 1 ||
        lifetimeValue > 3650 ||
        !snapshotScheduleLifetimeUnits.contains(lifetimeUnit)) {
      return 'Use 1–3650 supported retention units; zero or negative retention is not allowed.';
    }
    if (exclude.length > 64 ||
        exclude.toSet().length != exclude.length ||
        !recursive && exclude.isNotEmpty ||
        exclude.any(
          (e) => !_scheduleDatasetName(e) || !e.startsWith('$dataset/'),
        )) {
      return 'Exclusions must be distinct existing descendants of a recursive task (at most 64).';
    }
    if (!_scheduleNaming(namingSchema)) {
      return 'Use a safe naming pattern containing %Y, %m, %d, %H and %M exactly once; other date tokens are not supported.';
    }
    return cron.validationError;
  }

  Map<String, Object?> get _wire => {
    'dataset': dataset,
    'recursive': recursive,
    'exclude': List<String>.of(exclude),
    'lifetime_value': lifetimeValue,
    'lifetime_unit': lifetimeUnit,
    'enabled': enabled,
    'naming_schema': namingSchema,
    'allow_empty': allowEmpty,
    'schedule': cron._wire,
  };
}

final class SnapshotScheduleDataset {
  const SnapshotScheduleDataset({
    required this.id,
    required this.guid,
    required this.kind,
    this.blockedReason,
  });
  final String id, guid, kind;
  final String? blockedReason;
  bool get available => blockedReason == null;
}

final class SnapshotScheduleTask {
  const SnapshotScheduleTask({
    required this.id,
    required this.settings,
    this.state = 'PENDING',
    this.vmwareSync = false,
    this.blockedReason,
  });
  final int id;
  final SnapshotScheduleSettings settings;
  final String state;
  final bool vmwareSync;
  final String? blockedReason;
  bool get editable => blockedReason == null;
}

final class SnapshotScheduleInventory {
  SnapshotScheduleInventory({
    required List<SnapshotScheduleTask> tasks,
    required List<SnapshotScheduleDataset> datasets,
    required this.timezone,
  }) : tasks = List.unmodifiable(tasks),
       datasets = List.unmodifiable(datasets);
  final List<SnapshotScheduleTask> tasks;
  final List<SnapshotScheduleDataset> datasets;
  final String timezone;
}

enum SnapshotScheduleAction { create, update, run, delete }

final class SnapshotScheduleRequest {
  const SnapshotScheduleRequest({
    required this.inventory,
    required this.action,
    this.task,
    this.settings,
  });
  final SnapshotScheduleInventory inventory;
  final SnapshotScheduleAction action;
  final SnapshotScheduleTask? task;
  final SnapshotScheduleSettings? settings;
  String get target => action == SnapshotScheduleAction.create
      ? settings?.dataset ?? ''
      : 'Task ${task?.id}: ${task?.settings.dataset ?? ''}';
  String? get validationError {
    if (action == SnapshotScheduleAction.create
        ? task != null || settings == null
        : task == null || !inventory.tasks.contains(task)) {
      return 'Choose an existing task or a complete new schedule from this inventory.';
    }
    if (task != null && !task!.editable) return task!.blockedReason;
    if ({
          SnapshotScheduleAction.run,
          SnapshotScheduleAction.delete,
        }.contains(action) &&
        settings != null) {
      return 'This action does not accept configuration changes.';
    }
    if (action == SnapshotScheduleAction.run && !task!.settings.enabled) {
      return 'Enable this task in a separate reviewed change before running it.';
    }
    if (action == SnapshotScheduleAction.update && settings == null) {
      return 'Provide the proposed settings.';
    }
    if (settings?.validationError != null) return settings!.validationError;
    if (settings != null &&
        !inventory.datasets.any(
          (d) => d.id == settings!.dataset && d.available,
        )) {
      return 'The selected dataset is not available in the current inventory.';
    }
    if (action == SnapshotScheduleAction.update &&
        _adminEqual(task!.settings._wire, settings!._wire)) {
      return 'Select at least one changed setting.';
    }
    return null;
  }
}

final class SnapshotScheduleReview {
  SnapshotScheduleReview({
    required this.action,
    required this.target,
    required this.identity,
    required List<String> changes,
    required List<String> warnings,
    List<String> affectedSnapshots = const [],
  }) : changes = List.unmodifiable(changes),
       warnings = List.unmodifiable(warnings),
       affectedSnapshots = List.unmodifiable(affectedSnapshots);
  final SnapshotScheduleAction action;
  final String target, identity;
  final List<String> changes, warnings, affectedSnapshots;
}

enum SnapshotScheduleOutcome { verified, accepted, rejected, unknown }

final class SnapshotScheduleResult {
  const SnapshotScheduleResult(this.outcome, this.message);
  final SnapshotScheduleOutcome outcome;
  final String message;
}

enum SnapshotSchedulesExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  invalid,
  stale,
  busy,
  dependency,
  unavailable,
}

final class SnapshotSchedulesException implements Exception {
  const SnapshotSchedulesException(this.reason);
  final SnapshotSchedulesExceptionReason reason;
  String get userMessage => switch (reason) {
    SnapshotSchedulesExceptionReason.notAuthenticated =>
      'Reconnect before managing snapshot schedules.',
    SnapshotSchedulesExceptionReason.unsupportedVersion =>
      'Snapshot schedules require stable TrueNAS 25.10.',
    SnapshotSchedulesExceptionReason.unavailableMethod => 'Required schedule, retention, dataset or dependency reads are unavailable.',
    SnapshotSchedulesExceptionReason.invalid =>
      'Schedule settings, scope or response could not be verified safely.',
    SnapshotSchedulesExceptionReason.stale => 'The task, datasets, timezone, retention impact or session changed. Reload and review again.',
    SnapshotSchedulesExceptionReason.busy =>
      'Another server operation or unresolved schedule change is in progress.',
    SnapshotSchedulesExceptionReason.dependency => 'VMware-bound, replication-bound, running or protected dataset tasks require a coordinated workflow.',
    SnapshotSchedulesExceptionReason.unavailable =>
      'Snapshot schedule data could not be read. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

final class _SessionSnapshotSchedules {
  _SessionSnapshotSchedules({
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
  bool _reading = false, _writing = false, _uncertain = false;
  final _inventories = <SnapshotScheduleInventory, _ScheduleObservation>{};
  final _reviews = <SnapshotScheduleReview, _SchedulePlan>{};
  bool get isBusy => _writing || _uncertain;
  SnapshotSchedulesCapabilities get capabilities =>
      SnapshotSchedulesCapabilities(
        connected: isCurrent(),
        versionSupported: versionSupported,
        methods: methods,
      );
  void _guard([String? method]) {
    if (!isCurrent()) {
      throw const SnapshotSchedulesException(
        SnapshotSchedulesExceptionReason.notAuthenticated,
      );
    }
    if (!versionSupported) {
      throw const SnapshotSchedulesException(
        SnapshotSchedulesExceptionReason.unsupportedVersion,
      );
    }
    if (!capabilities.supported ||
        method != null && !methods.contains(method)) {
      throw const SnapshotSchedulesException(
        SnapshotSchedulesExceptionReason.unavailableMethod,
      );
    }
  }

  Future<Object?> _call(String method, List<Object?> args) async {
    _guard(method);
    final result = await client
        .call(method, id: nextId(), params: args)
        .timeout(requestTimeout);
    _guard();
    return result;
  }

  Future<_ScheduleObservation> _read() async {
    final datasetRows = await _call('pool.dataset.query', [
      [
        [
          'type',
          'in',
          ['FILESYSTEM', 'VOLUME'],
        ],
      ],
      {
        'limit': 513,
        'select': [
          'id',
          'name',
          'type',
          'guid',
          'creation',
          'locked',
          'readonly',
          ['user_properties.managedby', 'managedby'],
        ],
        'extra': {
          'flat': true,
          'retrieve_children': false,
          'retrieve_user_props': true,
          'properties': [
            'guid',
            'creation',
            'readonly',
            'encryption',
            'keystatus',
          ],
        },
      },
    ]);
    final choices = await _call('pool.filesystem_choices', []);
    if (datasetRows is! List ||
        datasetRows.length > 512 ||
        choices is! List ||
        choices.length > 512 ||
        choices.any((v) => !_scheduleDatasetName(v)) ||
        choices.toSet().length != choices.length) {
      _scheduleInvalid();
    }
    final datasets = <SnapshotScheduleDataset>[],
        identities = <Map<String, Object?>>[];
    for (final raw in datasetRows) {
      if (raw is! Map ||
          !_scheduleDatasetName(raw['id']) ||
          raw['name'] != raw['id'] ||
          !{'FILESYSTEM', 'VOLUME'}.contains(raw['type']) ||
          raw['locked'] is! bool) {
        _scheduleInvalid();
      }
      final id = raw['id'] as String,
          guid = _scheduleRaw(raw['guid']),
          created = _scheduleRaw(raw['creation']);
      if (guid == null ||
          !RegExp(r'^[0-9]{1,20}$').hasMatch(guid) ||
          BigInt.parse(guid) == BigInt.zero ||
          BigInt.parse(guid) > BigInt.parse('18446744073709551615') ||
          created == null ||
          !RegExp(r'^\d{1,16}$').hasMatch(created)) {
        _scheduleInvalid();
      }
      final managed = raw.containsKey('managedby')
              ? _scheduleRaw(raw['managedby'])
              : '-',
          readonly = _scheduleRaw(raw['readonly']);
      final reason =
          !choices.contains(id) ||
              !id.contains('/') ||
              id
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
                  )
          ? 'System, pool-root or unavailable datasets are protected.'
          : raw['locked'] == true || readonly != 'off'
          ? 'Locked or read-only datasets are protected.'
          : managed == null || !{'', '-'}.contains(managed)
          ? 'Externally managed datasets are protected.'
          : null;
      datasets.add(
        SnapshotScheduleDataset(
          id: id,
          guid: guid,
          kind: raw['type'] as String,
          blockedReason: reason,
        ),
      );
      identities.add({
        'id': id,
        'guid': guid,
        'creation': created,
        'type': raw['type'],
        'locked': raw['locked'],
        'readonly': readonly,
        'managedby': managed,
        'choice': choices.contains(id),
      });
    }
    if (datasets.map((d) => d.id).toSet().length != datasets.length ||
        choices.any((c) => !datasets.any((d) => d.id == c))) {
      _scheduleInvalid();
    }
    for (var i = 0; i < datasets.length; i++) {
      final child = datasets[i], parts = child.id.split('/');
      var unsafe = false;
      for (var n = 1; n < parts.length; n++) {
        final ancestor = identities
            .where((r) => r['id'] == parts.take(n).join('/'))
            .firstOrNull;
        if (ancestor == null ||
            ancestor['locked'] != false ||
            ancestor['readonly'] != 'off' ||
            !{'', '-'}.contains(ancestor['managedby'])) {
          unsafe = true;
        }
      }
      if (unsafe) {
        datasets[i] = SnapshotScheduleDataset(
          id: child.id,
          guid: child.guid,
          kind: child.kind,
          blockedReason: 'An ancestor dataset is missing, locked, read-only or externally managed.',
        );
      }
    }
    final general = await _call('system.general.config', []);
    if (general is! Map || !_scheduleText(general['timezone'], 128)) {
      _scheduleInvalid();
    }
    final timezone = general['timezone'] as String;
    final rawTasks = await _call('pool.snapshottask.query', [
      [],
      {
        'limit': 129,
        'select': ['id', ..._scheduleSettingKeys, 'vmware_sync', 'state'],
      },
    ]);
    if (rawTasks is! List || rawTasks.length > 128) _scheduleInvalid();
    final tasks = <SnapshotScheduleTask>[];
    for (final raw in rawTasks) {
      final task = _scheduleParseTask(raw);
      final ds = datasets
          .where((d) => d.id == task.settings.dataset)
          .firstOrNull;
      tasks.add(
        SnapshotScheduleTask(
          id: task.id,
          settings: task.settings,
          state: task.state,
          vmwareSync: task.vmwareSync,
          blockedReason:
              task.blockedReason ??
              (ds == null || !ds.available
                  ? 'The task dataset is missing or protected.'
                  : null),
        ),
      );
    }
    if (tasks.map((t) => t.id).toSet().length != tasks.length) {
      _scheduleInvalid();
    }
    tasks.sort((a, b) => a.id.compareTo(b.id));
    datasets.sort((a, b) => a.id.compareTo(b.id));
    identities.sort((a, b) => (a['id'] as String).compareTo(b['id'] as String));
    return _ScheduleObservation(
      SnapshotScheduleInventory(
        tasks: tasks,
        datasets: datasets,
        timezone: timezone,
      ),
      identities,
    );
  }

  Future<SnapshotScheduleInventory> load() async {
    _guard();
    if (_reading || _writing) {
      throw const SnapshotSchedulesException(
        SnapshotSchedulesExceptionReason.busy,
      );
    }
    _reading = true;
    try {
      final read = await _read();
      _inventories.clear();
      _reviews.clear();
      _inventories[read.inventory] = read;
      return read.inventory;
    } on SnapshotSchedulesException {
      rethrow;
    } on Object {
      throw const SnapshotSchedulesException(
        SnapshotSchedulesExceptionReason.unavailable,
      );
    } finally {
      _reading = false;
    }
  }

  bool _allowed(SnapshotScheduleAction action) => switch (action) {
    SnapshotScheduleAction.create => capabilities.canCreate,
    SnapshotScheduleAction.update => capabilities.canUpdate,
    SnapshotScheduleAction.run => capabilities.canRun,
    SnapshotScheduleAction.delete => capabilities.canDelete,
  };
  List<SnapshotScheduleDataset> _scope(
    SnapshotScheduleSettings settings,
    _ScheduleObservation read,
  ) {
    final result = read.inventory.datasets
        .where(
          (d) =>
              (d.id == settings.dataset ||
                  settings.recursive &&
                      d.id.startsWith('${settings.dataset}/')) &&
              !settings.exclude.any((e) => d.id == e || d.id.startsWith('$e/')),
        )
        .toList();
    if (result.isEmpty ||
        result.length > 128 ||
        result.any((d) => !d.available) ||
        settings.exclude.any(
          (e) => !read.inventory.datasets.any((d) => d.id == e),
        )) {
      throw const SnapshotSchedulesException(
        SnapshotSchedulesExceptionReason.dependency,
      );
    }
    return result;
  }

  Future<Map<String, Object?>> _dependencies(
    SnapshotScheduleRequest request,
    _ScheduleObservation read,
  ) async {
    final settings = request.settings ?? request.task!.settings;
    _scope(settings, read);
    if (request.task != null) _scope(request.task!.settings, read);
    final replication = await _call('replication.query', [
      [],
      {
        'limit': 129,
        'select': ['id', 'periodic_snapshot_tasks'],
      },
    ]);
    if (replication is! List || replication.length > 128) _scheduleInvalid();
    final bindings = <Map<String, Object?>>[];
    for (final row in replication) {
      if (row is! Map ||
          !_scheduleId(row['id']) ||
          row['periodic_snapshot_tasks'] is! List ||
          (row['periodic_snapshot_tasks'] as List).length > 128) {
        _scheduleInvalid();
      }
      final ids = <int>[];
      for (final task in row['periodic_snapshot_tasks'] as List) {
        if (task is! Map || !_scheduleId(task['id'])) _scheduleInvalid();
        ids.add(task['id'] as int);
      }
      ids.sort();
      if (ids.toSet().length != ids.length) _scheduleInvalid();
      if (request.task != null && ids.contains(request.task!.id)) {
        throw const SnapshotSchedulesException(
          SnapshotSchedulesExceptionReason.dependency,
        );
      }
      bindings.add({'id': row['id'], 'tasks': ids});
    }
    if (bindings.map((b) => b['id']).toSet().length != bindings.length) {
      _scheduleInvalid();
    }
    bindings.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
    final vmware = await _call('vmware.query', [
      [],
      {
        'limit': 129,
        'select': ['id', 'filesystem'],
      },
    ]);
    if (vmware is! List || vmware.length > 128) _scheduleInvalid();
    final vms = <Map<String, Object?>>[];
    for (final row in vmware) {
      if (row is! Map ||
          !_scheduleId(row['id']) ||
          !_scheduleDatasetName(row['filesystem'])) {
        _scheduleInvalid();
      }
      // The middleware VMware-sync flag includes recursive descendants even
      // when the snapshot task excludes them; do not infer independence.
      if ([settings, if (request.task != null) request.task!.settings].any(
        (s) =>
            row['filesystem'] == s.dataset ||
            s.recursive &&
                (row['filesystem'] as String).startsWith('${s.dataset}/'),
      )) {
        throw const SnapshotSchedulesException(
          SnapshotSchedulesExceptionReason.dependency,
        );
      }
      vms.add({'id': row['id'], 'filesystem': row['filesystem']});
    }
    if (vms.map((v) => v['id']).toSet().length != vms.length) {
      _scheduleInvalid();
    }
    vms.sort((a, b) => (a['id'] as int).compareTo(b['id'] as int));
    return {'replication': bindings, 'vmware': vms};
  }

  Map<String, Object?> _patch(SnapshotScheduleRequest request) => {
    for (final e in request.settings!._wire.entries)
      if (request.task == null ||
          !_adminEqual(e.value, request.task!.settings._wire[e.key]))
        e.key: e.value,
  };
  Future<Map<String, Object?>> _impact(
    SnapshotScheduleRequest request,
    _ScheduleObservation read,
  ) async {
    final settings = request.settings ?? request.task!.settings;
    final scope = {
      ..._scope(settings, read).map((d) => d.id),
      if (request.task != null)
        ..._scope(request.task!.settings, read).map((d) => d.id),
    }.toList()..sort();
    final raw = await _call('pool.snapshot.query', [
      [
        ['dataset', 'in', scope],
      ],
      {
        'limit': 257,
        'select': ['id', 'dataset'],
      },
    ]);
    if (raw is! List || raw.length > 256) _scheduleInvalid();
    final snapshots = <String>[];
    for (final row in raw) {
      if (row is! Map ||
          !_scheduleText(row['id'], 512) ||
          !scope.contains(row['dataset']) ||
          !(row['id'] as String).startsWith('${row['dataset']}@') ||
          (row['id'] as String).split('@').length != 2) {
        _scheduleInvalid();
      }
      snapshots.add(row['id'] as String);
    }
    snapshots.sort();
    if (snapshots.toSet().length != snapshots.length) _scheduleInvalid();
    final result = <String, Object?>{'scope': scope, 'snapshots': snapshots};
    if (request.action == SnapshotScheduleAction.update ||
        request.action == SnapshotScheduleAction.delete) {
      result['current_retention'] = _scheduleRetention(
        await _call('pool.snapshottask.delete_will_change_retention_for', [
          request.task!.id,
        ]),
        scope,
      );
      if (request.action == SnapshotScheduleAction.update) {
        result['leaving_retention'] = _scheduleRetention(
          await _call('pool.snapshottask.update_will_change_retention_for', [
            request.task!.id,
            _patch(request),
          ]),
          scope,
        );
      }
    }
    for (final key in ['current_retention', 'leaving_retention']) {
      final retained = result[key];
      if (retained is Map) {
        for (final e in retained.entries) {
          for (final name in e.value as List) {
            if (!snapshots.contains('${e.key}@$name')) {
              throw const SnapshotSchedulesException(
                SnapshotSchedulesExceptionReason.stale,
              );
            }
          }
        }
      }
    }
    return result;
  }

  Future<SnapshotScheduleReview> review(SnapshotScheduleRequest request) async {
    _guard();
    if (_reading || isBusy || isOtherBusy()) {
      throw const SnapshotSchedulesException(
        SnapshotSchedulesExceptionReason.busy,
      );
    }
    final issued = _inventories[request.inventory];
    if (issued == null) {
      throw const SnapshotSchedulesException(
        SnapshotSchedulesExceptionReason.stale,
      );
    }
    if (!_allowed(request.action)) {
      throw const SnapshotSchedulesException(
        SnapshotSchedulesExceptionReason.unavailableMethod,
      );
    }
    if (request.validationError != null) {
      throw const SnapshotSchedulesException(
        SnapshotSchedulesExceptionReason.invalid,
      );
    }
    request = SnapshotScheduleRequest(
      inventory: request.inventory,
      action: request.action,
      task: request.task,
      settings: request.settings == null
          ? null
          : _scheduleSettings(request.settings!._wire),
    );
    _reading = true;
    try {
      final fresh = await _read();
      if (!_adminEqual(fresh.fingerprint, issued.fingerprint)) {
        throw const SnapshotSchedulesException(
          SnapshotSchedulesExceptionReason.stale,
        );
      }
      final dependencies = await _dependencies(request, fresh),
          impact = await _impact(request, fresh);
      final settings = request.settings ?? request.task!.settings;
      final warnings = <String>[
        'Times use server timezone ${fresh.inventory.timezone}. Day-of-month and weekday constraints use cron OR semantics when both are restricted. DST can skip or repeat local times.',
        'Existing snapshots in the reviewed scope are potentially affected; this list is not an exact expiry calculation. Matching snapshot names and schedules can be adopted by this policy. Other policies and explicit removal-date properties also affect retention.',
        'Automatic scheduling and retention can run concurrently. The reviewed manifest is checked again before one request; external races cannot be made atomic.',
        if (settings.recursive) 'Recursive scope includes current descendants listed below and future descendants, except excluded subtrees. New descendants can become eligible without editing this policy.',
        if (request.action == SnapshotScheduleAction.delete) 'Deletes the schedule policy only. This request does not directly destroy snapshots. Removing the policy changes future retention eligibility; snapshots may remain indefinitely or expire under other policies. Existing removal dates are NOT fixated.',
        if (request.action == SnapshotScheduleAction.update) 'Existing removal dates are NOT fixated. Changing dataset, exclusions, naming, schedule or enabled state can change ownership and future expiry of existing snapshots.',
        if (request.task != null &&
            request.settings != null &&
            settings.lifetimeSeconds < request.task!.settings.lifetimeSeconds)
          'DANGER: retention is shortened. Already-old matching snapshots may be destroyed on the next automatic retention pass. This is not reversible by restoring the old policy.',
        if (!settings.enabled) 'This policy is disabled; it will not run automatically. Changing retention ownership can still affect existing snapshots.',
        if (request.action == SnapshotScheduleAction.run) 'Run only queues the task. A null acknowledgement is not proof that a snapshot completed; no owned completion job is returned. Do not replay this request to check progress.',
      ];
      final changes = <String>[
        if (request.action == SnapshotScheduleAction.run)
          'Queue enabled snapshot task ${request.task!.id} once.'
        else if (request.action == SnapshotScheduleAction.delete)
          'Delete snapshot task ${request.task!.id}; never call pool.snapshot.delete.'
        else ...[
          for (final e in _patch(request).entries)
            '${e.key}: ${request.task == null ? '(new)' : _scheduleDisplay(request.task!.settings._wire[e.key])} → ${_scheduleDisplay(e.value)}',
        ],
        'Dataset scope: ${(impact['scope'] as List).join(', ')}',
        'Retention: ${settings.lifetimeValue} ${settings.lifetimeUnit}; MONTH = 30 days, YEAR = 365 days.',
      ];
      final value = SnapshotScheduleReview(
        action: request.action,
        target: request.target,
        identity: request.task == null
            ? 'New policy on dataset GUID ${fresh.inventory.datasets.firstWhere((d) => d.id == settings.dataset).guid}'
            : 'Task ${request.task!.id}; exact reviewed configuration and dataset GUIDs',
        changes: changes,
        warnings: warnings,
        affectedSnapshots: (impact['snapshots'] as List).cast<String>(),
      );
      // Store only immutable normalized settings, never the caller's mutable exclusion list.
      final frozen = SnapshotScheduleRequest(
        inventory: request.inventory,
        action: request.action,
        task: request.task,
        settings: request.settings == null
            ? null
            : _scheduleSettings(request.settings!._wire),
      );
      _reviews.clear();
      _reviews[value] = _SchedulePlan(frozen, fresh, dependencies, impact);
      return value;
    } on SnapshotSchedulesException {
      rethrow;
    } on Object {
      throw const SnapshotSchedulesException(
        SnapshotSchedulesExceptionReason.unavailable,
      );
    } finally {
      _reading = false;
    }
  }

  Future<SnapshotScheduleResult> execute(
    SnapshotScheduleReview review,
    String confirmation,
  ) async {
    _guard();
    if (_reading || isBusy || isOtherBusy()) {
      throw const SnapshotSchedulesException(
        SnapshotSchedulesExceptionReason.busy,
      );
    }
    final plan = _reviews.remove(review);
    if (plan == null || confirmation != review.target) {
      throw const SnapshotSchedulesException(
        SnapshotSchedulesExceptionReason.stale,
      );
    }
    if (!_allowed(review.action)) {
      throw const SnapshotSchedulesException(
        SnapshotSchedulesExceptionReason.unavailableMethod,
      );
    }
    _writing = true;
    var dispatched = false;
    try {
      final fresh = await _read();
      if (!_adminEqual(fresh.fingerprint, plan.before.fingerprint)) {
        throw const SnapshotSchedulesException(
          SnapshotSchedulesExceptionReason.stale,
        );
      }
      final dependencies = await _dependencies(plan.request, fresh),
          impact = await _impact(plan.request, fresh);
      if (!_adminEqual(dependencies, plan.dependencies) ||
          !_adminEqual(impact, plan.impact)) {
        throw const SnapshotSchedulesException(
          SnapshotSchedulesExceptionReason.stale,
        );
      }
      final finalRead = await _read();
      if (!_adminEqual(finalRead.fingerprint, fresh.fingerprint)) {
        throw const SnapshotSchedulesException(
          SnapshotSchedulesExceptionReason.stale,
        );
      }
      final action = review.action, request = plan.request;
      final method = 'pool.snapshottask.${action.name}';
      final args = <Object?>[
        if (action == SnapshotScheduleAction.create)
          request.settings!._wire
        else
          request.task!.id,
        if (action == SnapshotScheduleAction.update)
          {..._patch(request), 'fixate_removal_date': false},
        if (action == SnapshotScheduleAction.delete)
          {'fixate_removal_date': false},
      ];
      _guard(method);
      if (isOtherBusy()) {
        throw const SnapshotSchedulesException(
          SnapshotSchedulesExceptionReason.busy,
        );
      }
      dispatched = true;
      final receipt = await _call(method, args);
      _reviews.clear();
      _inventories.clear();
      if (action == SnapshotScheduleAction.run) {
        if (receipt != null) return _unknown();
        final after = await _read();
        if (!_adminEqual(after.configuration, plan.before.configuration)) {
          return _unknown();
        }
        return const SnapshotScheduleResult(
          SnapshotScheduleOutcome.accepted,
          'The server accepted one queued task run. Snapshot completion was not verified; inspect task status or snapshot inventory. Do not replay it.',
        );
      }
      int? newId;
      if (action == SnapshotScheduleAction.delete) {
        if (receipt != true) return _unknown();
      } else {
        final returned = _scheduleParseTask(receipt);
        if (action == SnapshotScheduleAction.update &&
                returned.id != request.task!.id ||
            !_adminEqual(returned.settings._wire, request.settings!._wire)) {
          return _unknown();
        }
        newId = returned.id;
        if (action == SnapshotScheduleAction.create &&
            plan.before.inventory.tasks.any((t) => t.id == newId)) {
          return _unknown();
        }
      }
      final after = await _read();
      if (!_adminEqual(after.datasetIdentity, plan.before.datasetIdentity) ||
          after.inventory.timezone != plan.before.inventory.timezone) {
        return _unknown();
      }
      final expected = <int, Map<String, Object?>>{
        for (final t in plan.before.inventory.tasks) t.id: t.settings._wire,
      };
      final expectedSync = {
        for (final t in plan.before.inventory.tasks) t.id: t.vmwareSync,
      };
      if (action == SnapshotScheduleAction.delete) {
        expected.remove(request.task!.id);
      } else {
        expected[newId!] = request.settings!._wire;
        expectedSync[newId] = false;
      }
      if (after.inventory.tasks.length != expected.length ||
          after.inventory.tasks.any(
            (t) =>
                !expected.containsKey(t.id) ||
                !_adminEqual(expected[t.id], t.settings._wire) ||
                t.vmwareSync != expectedSync[t.id],
          )) {
        return _unknown();
      }
      return SnapshotScheduleResult(
        SnapshotScheduleOutcome.verified,
        action == SnapshotScheduleAction.delete
            ? 'Schedule policy deletion was read back. No snapshot-delete request was sent; future retention eligibility has changed.'
            : 'The exact schedule configuration was read back. This verifies policy settings, not future snapshot creation or expiry.',
      );
    } on Object catch (error) {
      if (dispatched) return _unknown();
      if (error is SnapshotSchedulesException) rethrow;
      throw const SnapshotSchedulesException(
        SnapshotSchedulesExceptionReason.unavailable,
      );
    } finally {
      _writing = false;
    }
  }

  SnapshotScheduleResult _unknown() {
    _uncertain = true;
    _reviews.clear();
    _inventories.clear();
    return const SnapshotScheduleResult(
      SnapshotScheduleOutcome.unknown,
      'The schedule change may have applied or a run may have queued. Do not replay it. Inspect the original server and reconnect before further writes.',
    );
  }
}

const _scheduleSettingKeys = [
  'dataset',
  'recursive',
  'exclude',
  'lifetime_value',
  'lifetime_unit',
  'enabled',
  'naming_schema',
  'allow_empty',
  'schedule',
];

final class _ScheduleObservation {
  const _ScheduleObservation(this.inventory, this.datasetIdentity);
  final SnapshotScheduleInventory inventory;
  final List<Map<String, Object?>> datasetIdentity;
  Object get configuration => {
    'datasets': datasetIdentity,
    'timezone': inventory.timezone,
    'tasks': [
      for (final t in inventory.tasks)
        {'id': t.id, ...t.settings._wire, 'vmware_sync': t.vmwareSync},
    ],
  };
  Object get fingerprint => {
    'configuration': configuration,
    'states': [
      for (final t in inventory.tasks)
        {'id': t.id, 'state': t.state, 'blocked': t.blockedReason},
    ],
  };
}

final class _SchedulePlan {
  const _SchedulePlan(
    this.request,
    this.before,
    this.dependencies,
    this.impact,
  );
  final SnapshotScheduleRequest request;
  final _ScheduleObservation before;
  final Map<String, Object?> dependencies, impact;
}

SnapshotScheduleSettings _scheduleSettings(Map raw) {
  if (!_scheduleDatasetName(raw['dataset']) ||
      raw['recursive'] is! bool ||
      raw['enabled'] is! bool ||
      raw['allow_empty'] is! bool ||
      raw['lifetime_value'] is! int ||
      (raw['lifetime_value'] as int) < 1 ||
      (raw['lifetime_value'] as int) > 9007199254740991 ||
      !_scheduleText(raw['lifetime_unit'], 16) ||
      !_scheduleText(raw['naming_schema'], 150) ||
      raw['exclude'] is! List ||
      (raw['exclude'] as List).length > 64 ||
      (raw['exclude'] as List).any((e) => !_scheduleDatasetName(e)) ||
      raw['schedule'] is! Map) {
    _scheduleInvalid();
  }
  final cron = raw['schedule'] as Map;
  if (cron.length != 7 ||
      ![
        'minute',
        'hour',
        'dom',
        'month',
        'dow',
        'begin',
        'end',
      ].every((k) => _scheduleText(cron[k], 100))) {
    _scheduleInvalid();
  }
  return SnapshotScheduleSettings(
    dataset: raw['dataset'] as String,
    recursive: raw['recursive'] as bool,
    enabled: raw['enabled'] as bool,
    allowEmpty: raw['allow_empty'] as bool,
    lifetimeValue: raw['lifetime_value'] as int,
    lifetimeUnit: raw['lifetime_unit'] as String,
    namingSchema: raw['naming_schema'] as String,
    exclude: List<String>.unmodifiable((raw['exclude'] as List).cast<String>()),
    cron: SnapshotScheduleCron(
      minute: cron['minute'] as String,
      hour: cron['hour'] as String,
      dom: cron['dom'] as String,
      month: cron['month'] as String,
      dow: cron['dow'] as String,
      begin: cron['begin'] as String,
      end: cron['end'] as String,
    ),
  );
}

SnapshotScheduleTask _scheduleParseTask(Object? raw) {
  if (raw is! Map || !_scheduleId(raw['id']) || raw['vmware_sync'] is! bool) {
    _scheduleInvalid();
  }
  final settings = _scheduleSettings(raw), stateRaw = raw['state'];
  final state = stateRaw is Map && _scheduleText(stateRaw['state'], 32)
      ? stateRaw['state'] as String
      : 'UNKNOWN';
  final reason = raw['vmware_sync'] == true
      ? 'VMware-synchronized tasks require a coordinated workflow.'
      : !{'PENDING', 'FINISHED', 'ERROR'}.contains(state)
      ? 'Running, waiting or unknown task states are protected.'
      : settings.validationError;
  return SnapshotScheduleTask(
    id: raw['id'] as int,
    settings: settings,
    state: state,
    vmwareSync: raw['vmware_sync'] as bool,
    blockedReason: reason,
  );
}

Map<String, List<String>> _scheduleRetention(Object? raw, List<String> scope) {
  if (raw is! Map || raw.length > 128) _scheduleInvalid();
  final result = <String, List<String>>{};
  var count = 0;
  for (final e in raw.entries) {
    if (!scope.contains(e.key) ||
        e.value is! List ||
        (e.value as List).length > 256 ||
        (e.value as List).any(
          (n) =>
              !_scheduleText(n, 256) ||
              (n as String).contains('@') ||
              n.contains('/'),
        )) {
      _scheduleInvalid();
    }
    final names = (e.value as List).cast<String>().toList()..sort();
    count += names.length;
    if (count > 256 || names.toSet().length != names.length) _scheduleInvalid();
    result[e.key as String] = names;
  }
  return result;
}

bool _scheduleId(Object? v) => v is int && v > 0 && v <= 2147483647;
bool _scheduleText(Object? v, int max) =>
    v is String &&
    v.isNotEmpty &&
    v.length <= max &&
    !v.contains(RegExp(r'[\x00-\x1f\x7f]'));
bool _scheduleDatasetName(Object? v) =>
    _scheduleText(v, 200) &&
    RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.:/ -]*$').hasMatch(v as String) &&
    v.split('/').every((p) => p.isNotEmpty && p != '.' && p != '..');
String? _scheduleRaw(Object? raw) {
  final value = raw is Map
      ? raw['rawvalue'] ?? raw['value'] ?? raw['parsed']
      : raw;
  return value is String ? value : null;
}

Never _scheduleInvalid() => throw const SnapshotSchedulesException(
  SnapshotSchedulesExceptionReason.invalid,
);
String _scheduleDisplay(Object? value) {
  if (value is Map) {
    return value.entries
        .map((e) => '${e.key}=${_scheduleDisplay(e.value)}')
        .join(', ');
  }
  if (value is List) return value.isEmpty ? 'none' : value.join(', ');
  return '$value';
}

int? _scheduleTime(String value) {
  if (!RegExp(r'^([01]\d|2[0-3]):[0-5]\d$').hasMatch(value)) return null;
  final parts = value.split(':');
  return int.parse(parts[0]) * 60 + int.parse(parts[1]);
}

Set<int>? _scheduleCronField(String raw, int min, int max) {
  if (raw.isEmpty ||
      raw.length > 100 ||
      !RegExp(r'^[0-9*,/\-]+$').hasMatch(raw)) {
    return null;
  }
  if (raw.contains('/') &&
      !RegExp(r'^(\*|[0-9]+-[0-9]+)/[0-9]+$').hasMatch(raw)) {
    return null;
  }
  final result = <int>{};
  for (final piece in raw.split(',')) {
    final parts = piece.split('/');
    if (parts.length > 2) return null;
    final step = parts.length == 2 ? int.tryParse(parts[1]) : 1;
    if (step == null || step < 1 || step > max - min + 1) return null;
    final base = parts[0];
    int? start, end;
    if (base == '*') {
      start = min;
      end = max;
    } else if (base.contains('-')) {
      final range = base.split('-');
      if (range.length != 2) return null;
      start = int.tryParse(range[0]);
      end = int.tryParse(range[1]);
    } else {
      start = int.tryParse(base);
      end = start;
    }
    if (start == null ||
        end == null ||
        start < min ||
        end > max ||
        start > end) {
      return null;
    }
    for (var v = start; v <= end; v += step) {
      result.add(v);
    }
  }
  return result.isEmpty ? null : result;
}

bool _scheduleNaming(String raw) {
  if (raw.isEmpty ||
      raw.length > 100 ||
      !RegExp(r'^[A-Za-z0-9_][A-Za-z0-9_.%:-]*$').hasMatch(raw)) {
    return false;
  }
  var remaining = raw;
  for (final token in ['%Y', '%m', '%d', '%H', '%M']) {
    if (token.allMatches(raw).length != 1) return false;
    remaining = remaining.replaceAll(token, '');
  }
  return !remaining.contains('%');
}
