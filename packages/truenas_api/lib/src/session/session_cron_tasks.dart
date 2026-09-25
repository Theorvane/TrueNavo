part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedCronTasksSession {
  CronTasksCapabilities get cronTasksCapabilities;
  Future<CronTasksInventory> loadCronTasks();
  Future<CronTasksReview> reviewCronTasks(CronTasksRequest request);
  Future<CronTasksResult> executeCronTasks(
    CronTasksReview review,
    String confirmation, {
    required bool Function() isCurrent,
  });
}

enum CronTasksAction { create, edit, enable, disable, delete, run }

final class CronTasksCapabilities {
  const CronTasksCapabilities({
    this.connected = false,
    this.versionSupported = false,
    this.available = false,
    this.canCreate = false,
    this.canUpdate = false,
    this.canDelete = false,
    this.canRun = false,
  });
  const CronTasksCapabilities.disconnected()
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
  bool allows(CronTasksAction action) =>
      supported &&
      switch (action) {
        CronTasksAction.create => canCreate,
        CronTasksAction.delete => canDelete,
        CronTasksAction.run => canRun,
        _ => canUpdate,
      };
  String? get blockedReason => !connected
      ? 'Connect to inspect scheduled cron tasks.'
      : !versionSupported
      ? 'Native cron tasks require stable TrueNAS 25.10.'
      : !available
      ? 'Safe public cron, local-account, timezone and readiness reads are required.'
      : null;
}

final class CronTaskSchedule {
  const CronTaskSchedule({
    this.minute = '0',
    this.hour = '2',
    this.dom = '*',
    this.month = '*',
    this.dow = '*',
  });
  final String minute, hour, dom, month, dow;
  String? get validationError {
    final values = [minute, hour, dom, month, dow],
        bounds = [(0, 59), (0, 23), (1, 31), (1, 12), (0, 7)];
    for (var n = 0; n < 5; n++) {
      if (RegExp(r'^[0-9*,/\-]+$').stringMatch(values[n]) != values[n] ||
          _scheduleCronField(values[n], bounds[n].$1, bounds[n].$2) == null) {
        return 'Use bounded numeric cron values, lists, ranges or a single range/* step. Sunday is 0 or 7; no names, macros or whitespace.';
      }
    }
    if (dom != '*' && dow != '*') {
      return 'Restrict either day of month or weekday, not both, in this bounded editor.';
    }
    final days = _scheduleCronField(dom, 1, 31)!,
        months = _scheduleCronField(month, 1, 12)!;
    if (dom != '*' &&
        !months.any(
          (m) => days.any((d) => d <= DateTime.utc(2024, m + 1, 0).day),
        )) {
      return 'The selected day does not occur in any selected month.';
    }
    return null;
  }

  String get expression => '$minute $hour $dom $month $dow';
}

final class CronTaskSettings {
  const CronTaskSettings({
    required this.user,
    required this.description,
    required this.schedule,
    required this.hideStdout,
    required this.hideStderr,
  });
  final String user, description;
  final CronTaskSchedule schedule;
  final bool hideStdout, hideStderr;
  String? get validationError => !_cronUsername(user)
      ? 'Choose a verified local username from this server.'
      : !_emailText(description, 200)
      ? 'Use a description up to 200 characters without ASCII controls; do not place secrets in descriptions.'
      : schedule.validationError;
}

final class CronTaskSnapshot {
  const CronTaskSnapshot({
    required this.id,
    required this.enabled,
    required this.settings,
  });
  final int id;
  final bool enabled;
  final CronTaskSettings settings;
}

final class CronTaskUser {
  const CronTaskUser({
    required this.id,
    required this.uid,
    required this.username,
  });
  final int id, uid;
  final String username;
}

/// A write-only, disposable command. There is deliberately no plaintext getter.
final class CronTaskCommand {
  factory CronTaskCommand.fromText(String value) {
    if (validationErrorFor(value) != null) {
      throw const CronTasksException(CronTasksExceptionReason.invalidRequest);
    }
    return CronTaskCommand._(Uint8List.fromList(utf8.encode(value)));
  }
  CronTaskCommand._(this._bytes);
  Uint8List? _bytes;
  bool get isDisposed => _bytes == null;
  int get byteLength => _bytes?.length ?? 0;
  static String? validationErrorFor(String value) =>
      value.isEmpty ||
          value.trim().isEmpty ||
          value.length > 4096 ||
          _cronMasked(value) ||
          !_emailText(value, 4096) ||
          utf8.encode(value).length > 4096
      ? 'Enter a nonempty single-line command up to 4096 UTF-8 bytes without ASCII controls. Shell syntax and safety are not verified.'
      : null;
  void dispose() {
    final bytes = _bytes;
    _bytes = null;
    bytes?.fillRange(0, bytes.length, 0);
  }

  @override
  String toString() => 'Protected cron command';
}

final class CronTasksInventory {
  CronTasksInventory({
    required this.readiness,
    required List<CronTaskSnapshot> tasks,
    required List<CronTaskUser> users,
    required this.timezone,
    required this.directoryConfigured,
  }) : tasks = List.unmodifiable(tasks),
       users = List.unmodifiable(users);
  final AlertSettingsInventory readiness;
  final List<CronTaskSnapshot> tasks;
  final List<CronTaskUser> users;
  final String timezone;
  final bool? directoryConfigured;
  String get endpoint => readiness.endpoint;
  String get hostId => readiness.hostId;
  String get bootId => readiness.bootId;
  String get currentVersion => readiness.currentVersion;
  String? get readinessBlockedReason => readiness.readinessBlockedReason;
  String? get blockedReason =>
      readinessBlockedReason ??
      (directoryConfigured != false
          ? 'A disabled and unconfigured directory-service profile is required. No NSS or directory health probe is issued by this app.'
          : null);
}

final class CronTasksRequest {
  const CronTasksRequest({
    required this.inventory,
    required this.action,
    this.task,
    this.settings,
    this.command,
  });
  final CronTasksInventory inventory;
  final CronTasksAction action;
  final CronTaskSnapshot? task;
  final CronTaskSettings? settings;
  final CronTaskCommand? command;
  String get target =>
      '${action == CronTasksAction.edit ? 'EDIT' : action.name.toUpperCase()} CRON ${inventory.hostId}${action == CronTasksAction.create ? '' : ' #${task?.id ?? 0}'}';
  bool get changesExecution => action == CronTasksAction.enable;
  String? get validationError {
    if (inventory.blockedReason != null) return inventory.blockedReason;
    if (command?.isDisposed == true) {
      return 'The replacement command was discarded; prepare a new draft.';
    }
    if (action == CronTasksAction.create) {
      if (task != null || settings == null || command == null) {
        return 'A new disabled task requires settings and a protected command.';
      }
      if (inventory.tasks.length >= 256) {
        return 'The bounded task inventory is full.';
      }
    } else {
      if (task == null || !inventory.tasks.any((v) => identical(v, task))) {
        return 'Choose the exact task from the issued inventory.';
      }
      if (action == CronTasksAction.edit &&
          (task!.enabled || settings == null)) {
        return 'Disable a task before editing it.';
      }
      if (action == CronTasksAction.enable && task!.enabled ||
          action == CronTasksAction.disable && !task!.enabled ||
          action == CronTasksAction.delete && task!.enabled) {
        return 'Enable, disable and delete are separate state-specific actions; delete only disabled tasks.';
      }
      if (action == CronTasksAction.run && !task!.enabled) {
        return 'Only an enabled task can be run manually.';
      }
      if (action != CronTasksAction.edit &&
          (settings != null || command != null)) {
        return 'This lifecycle action cannot include replacement settings or a command.';
      }
    }
    if (action == CronTasksAction.delete) return null;
    final effective = settings ?? task!.settings;
    if (action != CronTasksAction.disable &&
        effective.validationError != null) {
      return effective.validationError;
    }
    if (!inventory.users.any((u) => u.username == effective.user)) {
      return 'The selected account is not a freshly verified local user.';
    }
    if (action == CronTasksAction.edit &&
        command == null &&
        _cronSettingsProof(effective) == _cronSettingsProof(task!.settings)) {
      return 'Choose changed settings or explicitly replace the protected command.';
    }
    return null;
  }
}

final class CronTasksReview {
  CronTasksReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final CronTasksRequest request;
  final String endpoint;
  final List<String> warnings;
  String get target => request.target;
}

enum CronTasksOutcome { completed, rejected, unknown }

final class CronTasksResult {
  const CronTasksResult(this.outcome, this.message);
  final CronTasksOutcome outcome;
  final String message;
}

enum CronTasksExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class CronTasksException implements Exception {
  const CronTasksException(this.reason);
  final CronTasksExceptionReason reason;
  String get userMessage => switch (reason) {
    CronTasksExceptionReason.notAuthenticated =>
      'Connect again before changing cron tasks.',
    CronTasksExceptionReason.unsupportedVersion =>
      'Native cron tasks require stable TrueNAS 25.10.',
    CronTasksExceptionReason.unavailableMethod =>
      'Required public cron lifecycle methods are unavailable.',
    CronTasksExceptionReason.busy =>
      'Another operation or uncertain outcome prevents cron changes.',
    CronTasksExceptionReason.staleReview => 'The issued review, protected command, task, dependencies or connection changed. No cron mutation was submitted.',
    CronTasksExceptionReason.invalidRequest => 'Resolve the task state, local-user, schedule and protected-command requirements.',
    CronTasksExceptionReason.invalidResponse =>
      'Cron configuration could not be safely verified.',
    CronTasksExceptionReason.unavailable => 'Cron information is unavailable. Command and remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

const _cronReads = {
  ..._powerReads,
  'auth.me',
  'system.info',
  'directoryservices.config',
  'user.query',
  'cronjob.query',
};
const _cronHeaders = [
  'id',
  'enabled',
  'description',
  'user',
  'schedule',
  'stdout',
  'stderr',
];

final class _CronRead {
  const _CronRead(this.inventory, this.dependencies);
  final CronTasksInventory inventory;
  final String dependencies;
}

final class _CronRow {
  const _CronRow(
    this.header,
    this.commandProof,
    this.commandSupported,
    this.extraProof,
  );
  final CronTaskSnapshot header;
  final String commandProof, extraProof;
  final bool commandSupported;
}

final class _CronLease {
  const _CronLease(
    this.created,
    this.inventoryProof,
    this.rowProof,
    this.replacementProof,
  );
  final DateTime created;
  final String inventoryProof;
  final String? rowProof, replacementProof;
}

final class _SessionCronTasks {
  _SessionCronTasks({
    required this.client,
    required ServerSummary summary,
    required Object? metadata,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherMutationBusy,
    required this.requestTimeout,
    DateTime Function()? now,
  }) : _version =
           _managementVersion(summary.version) == _ManagementVersion.v2510,
       _endpoint = summary.endpointUri.toString(),
       _metadata = metadata is Map ? Map.of(metadata) : const {},
       _now = now ?? DateTime.now {
    _power = _SessionSystemPower(
      client: client,
      summary: summary,
      metadata: metadata,
      nextId: nextId,
      isCurrent: _current,
      isOtherMutationBusy: isOtherMutationBusy,
      requestTimeout: requestTimeout,
      now: now,
    );
  }
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherMutationBusy;
  final Duration requestTimeout;
  final bool _version;
  final String _endpoint;
  final Map _metadata;
  final DateTime Function() _now;
  late final _SessionSystemPower _power;
  final Uint8List _key = Uint8List.fromList(
    List.generate(32, (_) => math.Random.secure().nextInt(256)),
  );
  final Map<CronTasksInventory, String> _inventories = {};
  final Map<CronTasksReview, _CronLease> _reviews = {};
  final Set<CronTaskCommand> _ownedCommands = {};
  void _releaseCommand(CronTaskCommand? command) {
    if (command != null && _ownedCommands.remove(command)) command.dispose();
  }

  void _forgetReviews({CronTaskCommand? keep}) {
    _reviews.clear();
    for (final command in _ownedCommands.toList()) {
      if (!identical(command, keep)) _releaseCommand(command);
    }
  }

  bool _calling = false, _terminal = false, _disposed = false;
  bool Function()? _operationCurrent;
  bool get isBusy => _calling || _terminal;
  void dispose() {
    _disposed = true;
    _inventories.clear();
    _forgetReviews();
    _key.fillRange(0, _key.length, 0);
  }

  bool _current() {
    try {
      return !_disposed && isCurrent() && (_operationCurrent?.call() ?? true);
    } on Object {
      return false;
    }
  }

  bool _method(String name) {
    final row = _metadata[name];
    return row is Map &&
        row['job'] == false &&
        row['uploadable'] == false &&
        row['downloadable'] == false &&
        row['no_auth_required'] == false &&
        row['private'] != true &&
        row['_private'] != true &&
        (row['check_pipes'] == null ||
            row['check_pipes'] == false ||
            row['check_pipes'] is List && (row['check_pipes'] as List).isEmpty);
  }

  bool _jobMethod(String name) {
    final row = _metadata[name];
    return row is Map &&
        row['job'] == true &&
        row['uploadable'] == false &&
        row['downloadable'] == false &&
        row['no_auth_required'] == false &&
        row['private'] != true &&
        row['_private'] != true &&
        (row['check_pipes'] == null ||
            row['check_pipes'] == false ||
            row['check_pipes'] is List && (row['check_pipes'] as List).isEmpty);
  }

  CronTasksCapabilities get capabilities => CronTasksCapabilities(
    connected: !_disposed && isCurrent(),
    versionSupported: _version,
    available: _cronReads.every(_method),
    canRun: _jobMethod('cronjob.run'),
    canCreate: _method('cronjob.create'),
    canUpdate: _method('cronjob.update'),
    canDelete: _method('cronjob.delete'),
  );
  void _guard({CronTasksAction? action}) {
    if (_disposed || !isCurrent()) {
      _cronThrow(CronTasksExceptionReason.notAuthenticated);
    }
    if (!_current()) _cronThrow(CronTasksExceptionReason.staleReview);
    if (!_version) _cronThrow(CronTasksExceptionReason.unsupportedVersion);
    if (!capabilities.supported ||
        action != null && !capabilities.allows(action)) {
      _cronThrow(CronTasksExceptionReason.unavailableMethod);
    }
  }

  Future<Object?> _call(String method, List<Object?> params) async {
    _guard();
    final value = await client
        .call(method, id: nextId(), params: params)
        .timeout(requestTimeout);
    _guard();
    return value;
  }

  String _digest(Object? value) {
    if (!_smbBounded(value)) {
      _cronThrow(CronTasksExceptionReason.invalidResponse);
    }
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(_smbCanonical(value))),
    );
    try {
      return crypto.Hmac(crypto.sha256, _key).convert(bytes).toString();
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  String? _replacement(CronTaskCommand? command) {
    if (command == null) return null;
    final bytes = command._bytes;
    if (bytes == null || bytes.isEmpty || bytes.length > 4096) {
      _cronThrow(CronTasksExceptionReason.staleReview);
    }
    return crypto.Hmac(crypto.sha256, _key).convert(bytes).toString();
  }

  String _commandDigest(String command) {
    final bytes = Uint8List.fromList(utf8.encode(command));
    try {
      return crypto.Hmac(crypto.sha256, _key).convert(bytes).toString();
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  _CronRow _row(Object? raw) {
    if (raw is! Map ||
        !raw.containsKey('command') ||
        raw['command'] is! String ||
        (raw['command'] as String).length > 65536 ||
        !_smbBounded(raw)) {
      _cronThrow(CronTasksExceptionReason.invalidResponse);
    }
    final command = raw['command'] as String;
    if (_cronMasked(command)) {
      _cronThrow(CronTasksExceptionReason.invalidResponse);
    }
    return _CronRow(
      _cronHeader(raw),
      _commandDigest(command),
      CronTaskCommand.validationErrorFor(command) == null,
      _digest({
        for (final e in raw.entries)
          if (!_cronHeaders.contains(e.key) && e.key != 'command')
            e.key: e.value,
      }),
    );
  }

  Future<_CronRow> _selected(int id) async {
    final row = _row(
      await _call('cronjob.query', [
        [
          ['id', '=', id],
        ],
        {'get': true},
      ]),
    );
    if (row.header.id != id) _cronThrow(CronTasksExceptionReason.staleReview);
    return row;
  }

  Future<_CronRead> _read() async {
    final admin = _configurationBackupAdmin(await _call('auth.me', const [])),
        power = await _power._read();
    final timezone = _cronTimezone(await _call('system.info', const []));
    final ds = await _call('directoryservices.config', const []),
        dsProof = _digest(ds);
    bool? directory;
    if (ds is Map &&
        ds['enable'] is bool &&
        [
          'service_type',
          'credential',
          'configuration',
          'kerberos_realm',
        ].every(ds.containsKey)) {
      directory =
          ds['enable'] == true ||
          ds['service_type'] != null ||
          ds['credential'] != null ||
          ds['configuration'] != null ||
          ds['kerberos_realm'] != null;
    }
    final rawUsers = await _call('user.query', const [
      [
        ['local', '=', true],
      ],
      {
        'limit': 1025,
        'select': ['id', 'uid', 'username', 'local', 'locked'],
      },
    ]);
    if (rawUsers is! List || rawUsers.length > 1024) {
      _cronThrow(CronTasksExceptionReason.invalidResponse);
    }
    final users = <CronTaskUser>[], userIds = <int>{}, usernames = <String>{};
    for (final row in rawUsers) {
      if (row is! Map ||
          !_powerId(row['id']) ||
          row['uid'] is! int ||
          (row['uid'] as int) < 0 ||
          (row['uid'] as int) > 4294967295 ||
          row['username'] is! String ||
          !_emailText(row['username'], 60) ||
          row['local'] != true ||
          row['locked'] is! bool ||
          !userIds.add(row['id'] as int) ||
          !usernames.add(row['username'] as String)) {
        _cronThrow(CronTasksExceptionReason.invalidResponse);
      }
      if (row['locked'] == false && _cronUsername(row['username'] as String)) {
        users.add(
          CronTaskUser(
            id: row['id'] as int,
            uid: row['uid'] as int,
            username: row['username'] as String,
          ),
        );
      }
    }
    users.sort((a, b) => a.id.compareTo(b.id));
    final accountProof = _digest([
      for (final row in (List<Map>.from(
        rawUsers,
      )..sort((a, b) => (a['id'] as int).compareTo(b['id'] as int))))
        {
          for (final k in ['id', 'uid', 'username', 'local', 'locked'])
            k: row[k],
        },
    ]);
    final rawTasks = await _call('cronjob.query', const [
      [],
      {'limit': 257, 'select': _cronHeaders},
    ]);
    if (rawTasks is! List || rawTasks.length > 256) {
      _cronThrow(CronTasksExceptionReason.invalidResponse);
    }
    final tasks = <CronTaskSnapshot>[], ids = <int>{};
    for (final raw in rawTasks) {
      final row = _cronHeader(raw);
      if (!ids.add(row.id)) {
        _cronThrow(CronTasksExceptionReason.invalidResponse);
      }
      tasks.add(row);
    }
    tasks.sort((a, b) => a.id.compareTo(b.id));
    final adminAfter = _configurationBackupAdmin(
          await _call('auth.me', const []),
        ),
        host = await _call('system.host_id', const []),
        reboot = _powerReboot(await _call('system.reboot.info', const [])),
        state = await _call('system.state', const []);
    if (admin != adminAfter ||
        host != power.hostId ||
        reboot.$1 != power.bootId ||
        state != power.state ||
        jsonEncode(reboot.$2) != jsonEncode(power.rebootReasonCodes)) {
      _cronThrow(CronTasksExceptionReason.staleReview);
    }
    return _CronRead(
      CronTasksInventory(
        readiness: AlertSettingsInventory(
          endpoint: power.endpoint,
          hostId: power.hostId,
          bootId: power.bootId,
          currentVersion: power.currentVersion,
          state: power.state,
          fullAdmin: admin,
          failoverLicensed: power.failoverLicensed,
          conflictingJob: power.conflictingJob,
          bootPool: power.bootPool,
          bootHealthy: power.bootHealthy,
          environments: power.environments,
          rebootReasonCodes: power.rebootReasonCodes,
          services: const [],
        ),
        tasks: tasks,
        users: users,
        timezone: timezone,
        directoryConfigured: directory,
      ),
      jsonEncode([dsProof, accountProof]),
    );
  }

  Future<CronTasksInventory> load() async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      _cronThrow(CronTasksExceptionReason.busy);
    }
    _calling = true;
    _inventories.clear();
    _forgetReviews();
    try {
      final read = await _read();
      if (isOtherMutationBusy()) _cronThrow(CronTasksExceptionReason.busy);
      _inventories[read.inventory] = _cronReadProof(read);
      return read.inventory;
    } on CronTasksException {
      rethrow;
    } on Object {
      _cronThrow(CronTasksExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<CronTasksReview> review(CronTasksRequest request) async {
    final alreadyOwned = _ownedCommands.contains(request.command);
    try {
      return await _review(request);
    } on Object {
      if (!alreadyOwned || !_ownedCommands.contains(request.command)) {
        _ownedCommands.remove(request.command);
        request.command?.dispose();
      }
      rethrow;
    }
  }

  Future<CronTasksReview> _review(CronTasksRequest request) async {
    _guard(action: request.action);
    if (isBusy || isOtherMutationBusy()) {
      _cronThrow(CronTasksExceptionReason.busy);
    }
    final proof = _inventories[request.inventory];
    if (proof == null || request.inventory.endpoint != _endpoint) {
      _cronThrow(CronTasksExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      _cronThrow(CronTasksExceptionReason.invalidRequest);
    }
    _calling = true;
    _forgetReviews(keep: request.command);
    if (request.command != null) _ownedCommands.add(request.command!);
    try {
      final replacement = _replacement(request.command), before = await _read();
      if (_cronReadProof(before) != proof ||
          before.inventory.blockedReason != null ||
          isOtherMutationBusy()) {
        _cronThrow(CronTasksExceptionReason.staleReview);
      }
      final row = request.task == null
          ? null
          : await _selected(request.task!.id);
      if (row != null &&
              _cronHeaderProof(row.header) != _cronHeaderProof(request.task!) ||
          (request.action == CronTasksAction.enable ||
                  request.action == CronTasksAction.run) &&
              row?.commandSupported != true ||
          replacement != _replacement(request.command) ||
          isOtherMutationBusy()) {
        _cronThrow(CronTasksExceptionReason.staleReview);
      }
      final review = CronTasksReview(
        request: request,
        endpoint: _endpoint,
        warnings: [
          'Commands are arbitrary shell programs executed with the selected local account privileges; root can alter or destroy the appliance and data. This app does not parse shell syntax, prove command safety, check executable paths or run a test. Stored command text is never revealed; independently inspect it before enabling a preserved task.',
          if (request.action == CronTasksAction.run) 'Manual run immediately submits the selected enabled command as one middleware job. It can start, wait or fail after acceptance; output, logs, email delivery and completion are intentionally not read or polled by this app.',
          'Create is always disabled. Edit and delete require a disabled task; enable and disable are separate reviewed actions. Every change can write the database before globally regenerating cron configuration through service.control RESTART cron. This is not proof of an OS daemon restart, and other scheduled subsystems can be affected by regeneration.',
          'Enabling allows execution at the next matching server-local schedule without another prompt. There is no per-task timezone or execution timeout here; long-running commands and a queued same-task run are possible. Clock adjustments, daylight-saving transitions and background scheduler behavior affect execution. Configured schedules are not exact next-run or completion guarantees.',
          'The scheduled wrapper launches the stored command as the selected user. Commands, output and failures can appear in middleware job logs and emails to that account’s configured address, potentially disclosing credentials or other secrets. Hide-output flags suppress stdout/stderr; they do not guarantee command secrecy, prevent side effects or remove command text from failure messages. No log or user-email content is read by this app.',
          'Disabling or deleting does not cancel a command already running, already fetched, independently invoked or queued. No manual run, job abort, shell, queue cancellation, notification or account probe is requested. Backend create/update validation may perform account resolution; only freshly verified local identities in a standalone directory profile are admitted.',
          'Readiness and selected-row preservation checks are bounded and non-atomic. Other administrators are not locked. Only selected full-row private proof and safe headers of other tasks are compared; unrelated hidden commands are not fetched. A write may precede later errors, so uncertainty is not rollback or permission to repeat. Independently inspect the original server before further mutations.',
        ],
      );
      _reviews[review] = _CronLease(
        _now(),
        proof,
        row == null ? null : _cronRowProof(row),
        replacement,
      );
      return review;
    } on CronTasksException {
      _releaseCommand(request.command);
      rethrow;
    } on Object {
      _releaseCommand(request.command);
      _cronThrow(CronTasksExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<CronTasksResult> execute(
    CronTasksReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    final lease = _reviews.remove(review), request = review.request;
    var sent = false, owns = false;
    Uint8List? copy;
    bool ageValid() {
      if (lease == null) return false;
      final age = _now().difference(lease.created);
      return !age.isNegative && age <= const Duration(minutes: 5);
    }

    bool authorized() {
      try {
        return isCurrent();
      } on Object {
        return false;
      }
    }

    try {
      _guard(action: request.action);
      if (isBusy || isOtherMutationBusy()) {
        _cronThrow(CronTasksExceptionReason.busy);
      }
      if (lease == null ||
          !authorized() ||
          !ageValid() ||
          confirmation != review.target ||
          review.endpoint != _endpoint ||
          request.validationError != null ||
          lease.replacementProof != _replacement(request.command)) {
        _cronThrow(CronTasksExceptionReason.staleReview);
      }
      _calling = true;
      owns = true;
      _operationCurrent = isCurrent;
      final before = await _read(),
          row = request.task == null ? null : await _selected(request.task!.id);
      if (_cronReadProof(before) != lease.inventoryProof ||
          (row == null ? null : _cronRowProof(row)) != lease.rowProof ||
          before.inventory.blockedReason != null ||
          isOtherMutationBusy() ||
          lease.replacementProof != _replacement(request.command)) {
        _cronThrow(CronTasksExceptionReason.staleReview);
      }
      if (request.command != null) {
        copy = Uint8List.fromList(request.command!._bytes!);
      }
      if (request.action == CronTasksAction.run) {
        if (row == null || !row.header.enabled || !row.commandSupported) {
          _cronThrow(CronTasksExceptionReason.staleReview);
        }
        _guard(action: request.action);
        if (!ageValid() || !authorized()) {
          _cronThrow(CronTasksExceptionReason.staleReview);
        }
        sent = true;
        final response = await client
            .call('cronjob.run', id: nextId(), params: [request.task!.id, true])
            .timeout(requestTimeout);
        _guard(action: request.action);
        if (!_powerId(response)) return _unknown();
        _inventories.clear();
        _forgetReviews();
        return CronTasksResult(
          CronTasksOutcome.completed,
          'The server accepted manual cron job #$response for task #${request.task!.id}. It may still be waiting, running or failed; this app did not read logs, output, email delivery or completion status.',
        );
      }
      final method = switch (request.action) {
        CronTasksAction.create => 'cronjob.create',
        CronTasksAction.delete => 'cronjob.delete',
        _ => 'cronjob.update',
      };
      final expectedSettings = request.settings ?? row?.header.settings,
          expectedEnabled = request.action == CronTasksAction.enable;
      final patch = <String, Object?>{};
      if (request.action == CronTasksAction.create) {
        patch.addAll({
          'enabled': false,
          ..._cronSettingsMap(request.settings!),
        });
      } else if (request.action == CronTasksAction.edit) {
        final old = _cronSettingsMap(row!.header.settings);
        for (final e in _cronSettingsMap(request.settings!).entries) {
          if (jsonEncode(old[e.key]) != jsonEncode(e.value)) {
            patch[e.key] = e.value;
          }
        }
      } else if (request.action != CronTasksAction.delete) {
        patch['enabled'] = expectedEnabled;
      }
      if (copy != null) patch['command'] = utf8.decode(copy);
      final params = <Object?>[
        if (request.task != null) request.task!.id,
        if (request.action != CronTasksAction.delete) patch,
      ];
      _guard(action: request.action);
      if (!ageValid() ||
          !authorized() ||
          lease.replacementProof != _replacement(request.command)) {
        _cronThrow(CronTasksExceptionReason.staleReview);
      }
      sent = true;
      final response = await client
          .call(method, id: nextId(), params: params)
          .timeout(requestTimeout);
      _guard(action: request.action);
      _CronRow? receipt;
      if (request.action == CronTasksAction.delete) {
        if (response != true) return _unknown();
      } else {
        receipt = _row(response);
        if (receipt.header.enabled != expectedEnabled ||
            _cronSettingsProof(receipt.header.settings) !=
                _cronSettingsProof(expectedSettings!) ||
            receipt.commandProof !=
                (lease.replacementProof ?? row?.commandProof) ||
            receipt.extraProof != (row?.extraProof ?? _digest({})) ||
            request.task != null && receipt.header.id != request.task!.id ||
            request.action == CronTasksAction.create &&
                before.inventory.tasks.any((t) => t.id == receipt!.header.id)) {
          return _unknown();
        }
      }
      final after = await _read();
      if (_cronBaseProof(before) != _cronBaseProof(after) ||
          after.inventory.blockedReason != null ||
          isOtherMutationBusy()) {
        return _unknown();
      }
      final expectedTasks = [
        for (final task in before.inventory.tasks)
          if (task.id != request.task?.id) task,
        if (receipt != null) receipt.header,
      ]..sort((a, b) => a.id.compareTo(b.id));
      if (jsonEncode(expectedTasks.map(_cronHeaderProof).toList()) !=
          jsonEncode(after.inventory.tasks.map(_cronHeaderProof).toList())) {
        return _unknown();
      }
      if (receipt != null) {
        final fresh = await _selected(receipt.header.id);
        if (_cronRowProof(fresh) != _cronRowProof(receipt)) return _unknown();
      }
      _guard(action: request.action);
      if (isOtherMutationBusy()) return _unknown();
      _inventories.clear();
      _forgetReviews();
      return const CronTasksResult(
        CronTasksOutcome.completed,
        'Expected saved cron task state and selected-row preservation matched the response and independent readback. Command execution, scheduler timing, output, notification delivery and cancellation were not verified.',
      );
    } on Object catch (error) {
      if (sent) return _unknown();
      return CronTasksResult(
        CronTasksOutcome.rejected,
        error is CronTasksException ? error.userMessage : 'Cron authorization expired or preflight failed. No mutation was submitted.',
      );
    } finally {
      copy?.fillRange(0, copy.length, 0);
      if (lease != null) _releaseCommand(request.command);
      if (owns) {
        _operationCurrent = null;
        _calling = false;
      }
    }
  }

  CronTasksResult _unknown() {
    _terminal = true;
    _inventories.clear();
    _forgetReviews();
    return const CronTasksResult(
      CronTasksOutcome.unknown,
      'Cron configuration may already have changed and permitted scheduled command execution. The outcome is unverified, not rollback. Further writes are fenced; independently inspect the original server without retrying.',
    );
  }
}

Never _cronThrow(CronTasksExceptionReason reason) =>
    throw CronTasksException(reason);
bool _cronMasked(String value) => const {
  '********',
  '*****',
  '<redacted>',
  '[redacted]',
  '<hidden>',
  '[hidden]',
  'redacted',
}.contains(value.trim().toLowerCase());
bool _cronUsername(String value) =>
    value.length <= 60 &&
    RegExp(r'^[A-Za-z_][A-Za-z0-9_.\-]*\$?$').stringMatch(value) == value;
String _cronTimezone(Object? raw) {
  if (raw is! Map ||
      raw['timezone'] is! String ||
      !_emailText(raw['timezone'], 120) ||
      (raw['timezone'] as String).isEmpty) {
    _cronThrow(CronTasksExceptionReason.invalidResponse);
  }
  return raw['timezone'] as String;
}

CronTaskSnapshot _cronHeader(Object? raw) {
  if (raw is! Map ||
      !_powerId(raw['id']) ||
      raw['enabled'] is! bool ||
      raw['stdout'] is! bool ||
      raw['stderr'] is! bool ||
      raw['user'] is! String ||
      !_emailText(raw['user'], 60) ||
      raw['description'] is! String ||
      !_emailText(raw['description'], 200)) {
    _cronThrow(CronTasksExceptionReason.invalidResponse);
  }
  final s = raw['schedule'];
  if (s is! Map ||
      s.length != 5 ||
      !['minute', 'hour', 'dom', 'month', 'dow'].every(
        (k) =>
            s[k] is String &&
            _emailText(s[k], 100) &&
            (s[k] as String).isNotEmpty,
      )) {
    _cronThrow(CronTasksExceptionReason.invalidResponse);
  }
  return CronTaskSnapshot(
    id: raw['id'] as int,
    enabled: raw['enabled'] as bool,
    settings: CronTaskSettings(
      user: raw['user'] as String,
      description: raw['description'] as String,
      schedule: CronTaskSchedule(
        minute: s['minute'] as String,
        hour: s['hour'] as String,
        dom: s['dom'] as String,
        month: s['month'] as String,
        dow: s['dow'] as String,
      ),
      hideStdout: raw['stdout'] as bool,
      hideStderr: raw['stderr'] as bool,
    ),
  );
}

Map<String, Object?> _cronSettingsMap(CronTaskSettings s) => {
  'description': s.description,
  'user': s.user,
  'schedule': {
    'minute': s.schedule.minute,
    'hour': s.schedule.hour,
    'dom': s.schedule.dom,
    'month': s.schedule.month,
    'dow': s.schedule.dow,
  },
  'stdout': s.hideStdout,
  'stderr': s.hideStderr,
};
String _cronSettingsProof(CronTaskSettings s) =>
    jsonEncode(_cronSettingsMap(s));
String _cronHeaderProof(CronTaskSnapshot s) =>
    jsonEncode([s.id, s.enabled, _cronSettingsProof(s.settings)]);
String _cronRowProof(_CronRow s) =>
    jsonEncode([_cronHeaderProof(s.header), s.commandProof, s.extraProof]);
String _cronBaseProof(_CronRead r) => jsonEncode([
  _deliveryBaseProof(r.inventory.readiness),
  r.inventory.timezone,
  r.inventory.directoryConfigured,
  r.dependencies,
]);
String _cronReadProof(_CronRead r) => jsonEncode([
  _cronBaseProof(r),
  r.inventory.tasks.map(_cronHeaderProof).toList(),
]);
