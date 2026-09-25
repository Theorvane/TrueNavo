part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedInitShutdownTasksSession {
  InitShutdownTasksCapabilities get initShutdownTasksCapabilities;
  Future<InitShutdownTasksInventory> loadInitShutdownTasks();
  Future<InitShutdownTasksReview> reviewInitShutdownTasks(
    InitShutdownTasksRequest request,
  );
  Future<InitShutdownTasksResult> executeInitShutdownTasks(
    InitShutdownTasksReview review,
    String confirmation, {
    required bool Function() isCurrent,
  });
}

enum InitShutdownTasksAction { create, replace, enable, disable, delete }

enum InitShutdownTaskPhase {
  preinit,
  postinit,
  shutdown;

  String get wireName => name.toUpperCase();
}

final class InitShutdownTasksCapabilities {
  const InitShutdownTasksCapabilities({
    this.connected = false,
    this.versionSupported = false,
    this.available = false,
    this.canCreate = false,
    this.canUpdate = false,
    this.canDelete = false,
  });
  const InitShutdownTasksCapabilities.disconnected()
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
  bool supports(InitShutdownTasksAction action) =>
      supported &&
      switch (action) {
        InitShutdownTasksAction.create => canCreate,
        InitShutdownTasksAction.delete => canDelete,
        _ => canUpdate,
      };
  String? get blockedReason => !connected
      ? 'Connect to inspect init/shutdown task headers.'
      : !versionSupported
      ? 'Native init/shutdown tasks require stable TrueNAS 25.10.'
      : !available
      ? 'Required public task and readiness reads are unavailable.'
      : null;
}

final class InitShutdownTaskSettings {
  const InitShutdownTaskSettings({
    required this.phase,
    required this.timeoutSeconds,
  });
  final InitShutdownTaskPhase phase;

  /// An await budget, not a reliable process-kill deadline.
  final int timeoutSeconds;
  String? get validationError => timeoutSeconds < 1 || timeoutSeconds > 300
      ? 'Choose a wait budget of 1–300 seconds. Expiry does not reliably stop the command or its descendants.'
      : null;
}

final class InitShutdownTaskCommand {
  factory InitShutdownTaskCommand(String command) {
    final valid = _istNewCommand(command);
    return InitShutdownTaskCommand._(
      valid ? Uint8List.fromList(command.codeUnits) : Uint8List(0),
      valid,
    );
  }
  InitShutdownTaskCommand._(this._bytes, this._valid);
  final Uint8List _bytes;
  final bool _valid;
  bool _disposed = false;
  bool get isDisposed => _disposed;
  String? get validationError => !_valid || _disposed
      ? 'Enter a new nonempty single-line command, at most 300 printable ASCII characters. Masked or disposed command bodies cannot be submitted.'
      : null;
  void dispose() {
    _bytes.fillRange(0, _bytes.length, 0);
    _disposed = true;
  }

  @override
  String toString() => 'InitShutdownTaskCommand(redacted)';
}

final class InitShutdownTaskSnapshot {
  const InitShutdownTaskSnapshot({
    required this.id,
    required this.type,
    required this.phase,
    required this.enabled,
    required this.timeoutSeconds,
  });
  final int id, timeoutSeconds;
  final String type;
  final InitShutdownTaskPhase phase;
  final bool enabled;
  bool get isCommand => type == 'COMMAND';
  String? get blockedReason => !isCommand
      ? 'SCRIPT file tasks are protected and display-only; no filesystem validation or conversion is offered.'
      : null;
}

final class InitShutdownTasksInventory {
  InitShutdownTasksInventory({
    required this.readiness,
    required List<InitShutdownTaskSnapshot> tasks,
  }) : tasks = List.unmodifiable(tasks);
  final AlertSettingsInventory readiness;
  final List<InitShutdownTaskSnapshot> tasks;
  String get endpoint => readiness.endpoint;
  String get hostId => readiness.hostId;
  String get bootId => readiness.bootId;
  String get currentVersion => readiness.currentVersion;
  String? get readinessBlockedReason => readiness.readinessBlockedReason;
  String? get blockedReason => readinessBlockedReason;
}

final class InitShutdownTasksRequest {
  const InitShutdownTasksRequest({
    required this.inventory,
    required this.action,
    this.task,
    this.settings,
    this.command,
  });
  final InitShutdownTasksInventory inventory;
  final InitShutdownTasksAction action;
  final InitShutdownTaskSnapshot? task;
  final InitShutdownTaskSettings? settings;
  final InitShutdownTaskCommand? command;
  String get target =>
      '${action.name.toUpperCase()} INIT TASK ${inventory.hostId} ${task?.id ?? 'NEW'}';
  String? get validationError {
    if (inventory.blockedReason != null) return inventory.blockedReason;
    if (action == InitShutdownTasksAction.create) {
      if (task != null || inventory.tasks.length >= 128) {
        return 'Create a new disabled command task; at most 128 tasks are supported.';
      }
    } else if (task == null ||
        !inventory.tasks.any((t) => identical(t, task)) ||
        !task!.isCommand) {
      return 'Choose the exact COMMAND task from this inventory. SCRIPT tasks are protected.';
    }
    if (action == InitShutdownTasksAction.create ||
        action == InitShutdownTasksAction.replace) {
      if (action == InitShutdownTasksAction.replace && task!.enabled) {
        return 'Disable the task separately before replacing its command or settings.';
      }
      if (settings == null || settings!.validationError != null) {
        return settings?.validationError ?? 'Choose a phase and wait budget.';
      }
      if (command == null || command!.validationError != null) {
        return command?.validationError ??
            'Enter a complete fresh command body; the existing body is never filled in.';
      }
      return null;
    }
    if (settings != null || command != null) {
      return 'Enable, disable and delete preserve existing task fields; replacement content is not allowed.';
    }
    return switch (action) {
      InitShutdownTasksAction.enable =>
        task!.enabled
            ? 'The task is already enabled.'
            : task!.timeoutSeconds < 1 || task!.timeoutSeconds > 300
            ? 'Existing wait budgets outside 1–300 seconds must be replaced while disabled before enabling.'
            : null,
      InitShutdownTasksAction.disable =>
        !task!.enabled ? 'The task is already disabled.' : null,
      InitShutdownTasksAction.delete =>
        task!.enabled ? 'Disable the task separately before deletion.' : null,
      _ => null,
    };
  }
}

final class InitShutdownTasksReview {
  InitShutdownTasksReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
    required this.commandReference,
  }) : warnings = List.unmodifiable(warnings);
  final InitShutdownTasksRequest request;
  final String endpoint, commandReference;
  final List<String> warnings;
  String get target => request.target;
  InitShutdownTasksAction get action => request.action;
}

enum InitShutdownTasksOutcome { completed, rejected, unknown }

final class InitShutdownTasksResult {
  const InitShutdownTasksResult(this.outcome, this.message);
  final InitShutdownTasksOutcome outcome;
  final String message;
}

enum InitShutdownTasksExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class InitShutdownTasksException implements Exception {
  const InitShutdownTasksException(this.reason);
  final InitShutdownTasksExceptionReason reason;
  String get userMessage => switch (reason) {
    InitShutdownTasksExceptionReason.notAuthenticated =>
      'Connect again before changing init/shutdown tasks.',
    InitShutdownTasksExceptionReason.unsupportedVersion =>
      'Native init/shutdown tasks require stable TrueNAS 25.10.',
    InitShutdownTasksExceptionReason.unavailableMethod =>
      'Required public task methods are unavailable.',
    InitShutdownTasksExceptionReason.busy =>
      'Another operation or uncertain outcome prevents task changes.',
    InitShutdownTasksExceptionReason.staleReview => 'The issued review, connection, authorization or task changed. No new task write was submitted.',
    InitShutdownTasksExceptionReason.invalidRequest => 'Resolve the displayed task lifecycle restrictions and enter supported fresh settings.',
    InitShutdownTasksExceptionReason.invalidResponse => 'Task metadata or protected command preservation could not be safely verified.',
    InitShutdownTasksExceptionReason.unavailable => 'Task information is unavailable. Commands, paths and remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

const _istReads = {..._powerReads, 'auth.me', 'initshutdownscript.query'};
const _istHeads = ['id', 'type', 'when', 'enabled', 'timeout'];
const _istDetails = [..._istHeads, 'command', 'script', 'comment'];

final class _IstLease {
  const _IstLease(
    this.created,
    this.inventoryProof,
    this.beforeProof,
    this.afterProof,
  );
  final DateTime created;
  final String inventoryProof, beforeProof, afterProof;
}

final class _SessionInitShutdownTasks {
  _SessionInitShutdownTasks({
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
    _powerReader = _SessionSystemPower(
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
  late final _SessionSystemPower _powerReader;
  final _proofKey = Uint8List.fromList(
    List.generate(32, (_) => math.Random.secure().nextInt(256)),
  );
  final _inventories = <InitShutdownTasksInventory, String>{},
      _reviews = <InitShutdownTasksReview, _IstLease>{};
  final _commands = <InitShutdownTaskCommand>{};
  bool _calling = false, _terminal = false, _disposed = false;
  bool Function()? _operationCurrent;
  bool get isBusy => _calling || _terminal;
  bool _current() {
    try {
      return !_disposed && isCurrent() && (_operationCurrent?.call() ?? true);
    } on Object {
      return false;
    }
  }

  bool _method(String method) {
    final r = _metadata[method];
    return r is Map &&
        r['job'] == false &&
        r['uploadable'] == false &&
        r['downloadable'] == false &&
        r['no_auth_required'] == false &&
        r['private'] != true &&
        r['_private'] != true &&
        (r['check_pipes'] == null ||
            r['check_pipes'] == false ||
            r['check_pipes'] is List && (r['check_pipes'] as List).isEmpty);
  }

  InitShutdownTasksCapabilities get capabilities =>
      InitShutdownTasksCapabilities(
        connected: !_disposed && isCurrent(),
        versionSupported: _version,
        available: _istReads.every(_method),
        canCreate: _method('initshutdownscript.create'),
        canUpdate: _method('initshutdownscript.update'),
        canDelete: _method('initshutdownscript.delete'),
      );
  void _guard([InitShutdownTasksAction? action]) {
    if (_disposed || !isCurrent()) {
      _istThrow(InitShutdownTasksExceptionReason.notAuthenticated);
    }
    if (!_current()) _istThrow(InitShutdownTasksExceptionReason.staleReview);
    if (!_version) {
      _istThrow(InitShutdownTasksExceptionReason.unsupportedVersion);
    }
    if (!capabilities.supported ||
        action != null && !capabilities.supports(action)) {
      _istThrow(InitShutdownTasksExceptionReason.unavailableMethod);
    }
  }

  Future<Object?> _call(String method, List<Object?> params) async {
    _guard();
    final raw = await client
        .call(method, id: nextId(), params: params)
        .timeout(requestTimeout);
    _guard();
    return raw;
  }

  String _hash(Object? value) {
    final bytes = utf8.encode(jsonEncode(_npCanonical(value)));
    try {
      return crypto.Hmac(crypto.sha256, _proofKey).convert(bytes).toString();
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  void _clearReviews() {
    _reviews.clear();
    for (final c in _commands) {
      c.dispose();
    }
    _commands.clear();
  }

  void dispose() {
    _disposed = true;
    _clearReviews();
    _inventories.clear();
    _proofKey.fillRange(0, _proofKey.length, 0);
  }

  Future<InitShutdownTasksInventory> _read() async {
    final admin = _configurationBackupAdmin(await _call('auth.me', const [])),
        power = await _powerReader._read();
    final raw = await _call('initshutdownscript.query', const [
      [],
      {'limit': 129, 'select': _istHeads},
    ]);
    if (raw is! List || raw.length > 128) {
      _istThrow(InitShutdownTasksExceptionReason.invalidResponse);
    }
    final tasks = <InitShutdownTaskSnapshot>[];
    for (final value in raw) {
      if (value is! Map ||
          value.length != _istHeads.length ||
          value.keys.any((k) => !_istHeads.contains(k))) {
        _istThrow(InitShutdownTasksExceptionReason.invalidResponse);
      }
      final task = _istHeader(value);
      if (tasks.any((t) => t.id == task.id)) {
        _istThrow(InitShutdownTasksExceptionReason.invalidResponse);
      }
      tasks.add(task);
    }
    tasks.sort((a, b) => a.id.compareTo(b.id));
    final finalAdmin = _configurationBackupAdmin(
          await _call('auth.me', const []),
        ),
        host = await _call('system.host_id', const []),
        reboot = _powerReboot(await _call('system.reboot.info', const [])),
        state = await _call('system.state', const []);
    if (admin != finalAdmin ||
        host != power.hostId ||
        reboot.$1 != power.bootId ||
        state != power.state ||
        jsonEncode(reboot.$2) != jsonEncode(power.rebootReasonCodes)) {
      _istThrow(InitShutdownTasksExceptionReason.staleReview);
    }
    return InitShutdownTasksInventory(
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
    );
  }

  String _proof(InitShutdownTasksInventory i) =>
      _hash([_deliveryBaseProof(i.readiness), _istHeaders(i.tasks)]);
  Future<Map<String, Object?>> _detail(InitShutdownTaskSnapshot task) async {
    final raw = await _call('initshutdownscript.query', [
      [
        ['id', '=', task.id],
        ['type', '=', 'COMMAND'],
      ],
      const {'limit': 2, 'select': _istDetails},
    ]);
    if (raw is! List || raw.length != 1) {
      _istThrow(InitShutdownTasksExceptionReason.invalidResponse);
    }
    final value = _istPrivateRow(raw.single);
    if (_hash(_istHeadValue(_istHeader(value))) != _hash(_istHeadValue(task))) {
      _istThrow(InitShutdownTasksExceptionReason.staleReview);
    }
    return value;
  }

  Future<InitShutdownTasksInventory> load() async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      _istThrow(InitShutdownTasksExceptionReason.busy);
    }
    _calling = true;
    _clearReviews();
    _inventories.clear();
    try {
      final i = await _read();
      if (isOtherMutationBusy()) {
        _istThrow(InitShutdownTasksExceptionReason.busy);
      }
      _inventories[i] = _proof(i);
      return i;
    } on InitShutdownTasksException {
      rethrow;
    } on Object {
      _istThrow(InitShutdownTasksExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<InitShutdownTasksReview> review(
    InitShutdownTasksRequest request,
  ) async {
    var owns = false;
    try {
      _guard(request.action);
      if (isBusy || isOtherMutationBusy()) {
        _istThrow(InitShutdownTasksExceptionReason.busy);
      }
      final proof = _inventories[request.inventory];
      if (proof == null || request.inventory.endpoint != _endpoint) {
        _istThrow(InitShutdownTasksExceptionReason.staleReview);
      }
      if (request.validationError != null) {
        _istThrow(InitShutdownTasksExceptionReason.invalidRequest);
      }
      _calling = true;
      owns = true;
      _clearReviews();
      if (request.command != null) _commands.add(request.command!);
      final fresh = await _read();
      if (_proof(fresh) != proof ||
          fresh.blockedReason != null ||
          isOtherMutationBusy()) {
        _istThrow(InitShutdownTasksExceptionReason.staleReview);
      }
      final before = request.task == null
          ? <String, Object?>{}
          : await _detail(request.task!);
      final after = _istExpected(request, before);
      if (request.action == InitShutdownTasksAction.enable &&
          !_istNewCommand(after['command'] as String)) {
        _istThrow(InitShutdownTasksExceptionReason.invalidRequest);
      }
      if (request.action == InitShutdownTasksAction.replace &&
          _hash(before) == _hash(after)) {
        _istThrow(InitShutdownTasksExceptionReason.invalidRequest);
      }
      final confirmation = await _read();
      if (_proof(confirmation) != proof ||
          request.validationError != null ||
          isOtherMutationBusy()) {
        _istThrow(InitShutdownTasksExceptionReason.staleReview);
      }
      if (request.task != null &&
          _hash(await _detail(request.task!)) != _hash(before)) {
        _istThrow(InitShutdownTasksExceptionReason.staleReview);
      }
      _guard(request.action);
      if (request.validationError != null || isOtherMutationBusy()) {
        _istThrow(InitShutdownTasksExceptionReason.staleReview);
      }
      final review = InitShutdownTasksReview(
        request: request,
        endpoint: _endpoint,
        warnings: _istWarnings,
        commandReference: _hash([
          'command-reference',
          after['command'] ?? before['command'],
        ]),
      );
      _reviews[review] = _IstLease(_now(), proof, _hash(before), _hash(after));
      return review;
    } on InitShutdownTasksException {
      request.command?.dispose();
      rethrow;
    } on Object {
      request.command?.dispose();
      _istThrow(InitShutdownTasksExceptionReason.unavailable);
    } finally {
      if (owns) _calling = false;
    }
  }

  Future<InitShutdownTasksResult> execute(
    InitShutdownTasksReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    final lease = _reviews.remove(review);
    var sent = false, owns = false;
    bool authorized() {
      try {
        return isCurrent();
      } on Object {
        return false;
      }
    }

    bool age() {
      if (lease == null) return false;
      final d = _now().difference(lease.created);
      return !d.isNegative && d <= const Duration(minutes: 5);
    }

    try {
      _guard(review.action);
      if (isBusy || isOtherMutationBusy()) {
        _istThrow(InitShutdownTasksExceptionReason.busy);
      }
      if (lease == null ||
          !authorized() ||
          !age() ||
          review.endpoint != _endpoint ||
          confirmation != review.target ||
          review.request.validationError != null) {
        _istThrow(InitShutdownTasksExceptionReason.staleReview);
      }
      _calling = true;
      owns = true;
      _operationCurrent = () =>
          isCurrent() && review.request.validationError == null;
      final request = review.request, beforeRead = await _read();
      if (_proof(beforeRead) != lease.inventoryProof ||
          beforeRead.blockedReason != null) {
        _istThrow(InitShutdownTasksExceptionReason.staleReview);
      }
      final before = request.task == null
              ? <String, Object?>{}
              : await _detail(request.task!),
          after = _istExpected(request, before);
      if (_hash(before) != lease.beforeProof ||
          _hash(after) != lease.afterProof) {
        _istThrow(InitShutdownTasksExceptionReason.staleReview);
      }
      final confirmed = await _read();
      if (_proof(confirmed) != lease.inventoryProof ||
          isOtherMutationBusy() ||
          !authorized() ||
          !age()) {
        _istThrow(InitShutdownTasksExceptionReason.staleReview);
      }
      if (request.task != null &&
          _hash(await _detail(request.task!)) != lease.beforeProof) {
        _istThrow(InitShutdownTasksExceptionReason.staleReview);
      }
      final method = switch (request.action) {
        InitShutdownTasksAction.create => 'initshutdownscript.create',
        InitShutdownTasksAction.delete => 'initshutdownscript.delete',
        _ => 'initshutdownscript.update',
      };
      final params = switch (request.action) {
        InitShutdownTasksAction.create => <Object?>[after],
        InitShutdownTasksAction.delete => <Object?>[request.task!.id],
        InitShutdownTasksAction.replace => <Object?>[
          request.task!.id,
          {
            'command': after['command'],
            'when': after['when'],
            'timeout': after['timeout'],
          },
        ],
        _ => <Object?>[
          request.task!.id,
          {'enabled': request.action == InitShutdownTasksAction.enable},
        ],
      };
      _guard(review.action);
      if (!authorized() ||
          !age() ||
          request.validationError != null ||
          isOtherMutationBusy()) {
        _istThrow(InitShutdownTasksExceptionReason.staleReview);
      }
      sent = true;
      final raw = await client
          .call(method, id: nextId(), params: params)
          .timeout(requestTimeout);
      _guard(review.action);
      InitShutdownTaskSnapshot? receipt;
      Map<String, Object?>? returned;
      if (request.action == InitShutdownTasksAction.delete) {
        if (raw != true) return _unknown();
      } else {
        returned = _istPrivateRow(raw);
        receipt = _istHeader(returned);
        final expected = {...after, 'id': receipt.id};
        if (_hash(returned) != _hash(expected) ||
            (request.task == null
                ? request.inventory.tasks.any((t) => t.id == receipt!.id)
                : receipt.id != request.task!.id)) {
          return _unknown();
        }
      }
      final afterRead = await _read(),
          expectedHeads = beforeRead.tasks.toList();
      if (request.task != null) {
        expectedHeads.removeWhere((t) => t.id == request.task!.id);
      }
      if (receipt != null) {
        if (_hash(await _detail(receipt)) != _hash(returned)) return _unknown();
        expectedHeads.add(receipt);
      }
      expectedHeads.sort((a, b) => a.id.compareTo(b.id));
      if (_deliveryBaseProof(beforeRead.readiness) !=
              _deliveryBaseProof(afterRead.readiness) ||
          _hash(_istHeaders(expectedHeads)) !=
              _hash(_istHeaders(afterRead.tasks)) ||
          afterRead.blockedReason != null ||
          isOtherMutationBusy()) {
        return _unknown();
      }
      _inventories.clear();
      _clearReviews();
      return const InitShutdownTasksResult(
        InitShutdownTasksOutcome.completed,
        'The expected task configuration and bounded readback matched. No command was run or tested by this workflow; future execution, boot/shutdown availability and already-running work remain unverified.',
      );
    } on Object catch (error) {
      if (sent) return _unknown();
      return InitShutdownTasksResult(
        InitShutdownTasksOutcome.rejected,
        error is InitShutdownTasksException ? error.userMessage : 'Task preflight failed or expired; command and remote details were withheld. No new write was submitted.',
      );
    } finally {
      review.request.command?.dispose();
      _commands.remove(review.request.command);
      if (owns) {
        _operationCurrent = null;
        _calling = false;
      }
    }
  }

  InitShutdownTasksResult _unknown() {
    _terminal = true;
    _inventories.clear();
    _clearReviews();
    return const InitShutdownTasksResult(
      InitShutdownTasksOutcome.unknown,
      'An init/shutdown task change may already have occurred. Future or already-running root commands may be affected. The outcome is unverified, not rollback or permission to retry. Inspect the original server independently.',
    );
  }
}

const _istWarnings = [
  'COMMAND tasks run with middleware/root privileges through sh -c during PREINIT, POSTINIT or SHUTDOWN. Enabling permits arbitrary system and data changes, external connections, credential disclosure, boot/shutdown delay and loss of access. Inspect the exact task body independently before enabling; this app does not expose or vet existing bodies.',
  'The configured timeout is only a wait budget. The pinned implementation awaits subprocess.run in a worker thread; expiring the await does not reliably terminate the command or descendants. Processes may continue and overlap later tasks. The pinned shutdown unit has TimeoutStopSec=0, not a finite additive process deadline.',
  'PREINIT runs before network-pre.target and after ix-zfs; POSTINIT follows multi-user.target; SHUTDOWN is triggered by the shutdown unit. Phase names do not prove that a network, pool, key, application or external dependency is ready. No task ordering guarantee is inferred.',
  'New tasks are disabled. Replacement requires a disabled COMMAND task and a complete new manually authored body; unchanged script/comment fields are preserved privately. SCRIPT paths are protected because source validation calls filesystem.stat and script execution has different path semantics. No file validation, chmod or conversion is offered.',
  'The execution job snapshots enabled tasks once. Disabling or deleting a row afterward does not cancel snapshotted, in-flight or descendant processes. This is not a kill switch. No run-now, private execute_init_tasks, reboot, shutdown, service command, test, polling or retry is invoked here.',
  'The app withholds command bodies, script paths and comments from inventory, review and logs, but the TrueNAS database stores them, CRUD query events can contain complete task rows, and execution failures/timeouts can log command text and output. This workspace does not subscribe to task events. Do not embed secrets casually. In-memory zeroing is best effort; editor/platform/transport copies cannot be guaranteed erased.',
  'CRUD configuration changes can precede a response failure. Fresh bounded readback verifies configuration only, not execution success, safety, process cancellation or availability. Readiness checks are not atomic with concurrent administrators or lifecycle transitions.',
];
Never _istThrow(InitShutdownTasksExceptionReason r) =>
    throw InitShutdownTasksException(r);
bool _istMasked(String s) => const {
  '********',
  '*****',
  '<redacted>',
  '[redacted]',
  '<hidden>',
  '[hidden]',
  'redacted',
}.contains(s.trim().toLowerCase());
bool _istNewCommand(String s) =>
    s.isNotEmpty &&
    s.trim().isNotEmpty &&
    s.length <= 300 &&
    s.codeUnits.every((c) => c >= 0x20 && c <= 0x7e) &&
    !_istMasked(s);
InitShutdownTaskSnapshot _istHeader(Map raw) {
  if (!_powerId(raw['id']) ||
      !const {'COMMAND', 'SCRIPT'}.contains(raw['type']) ||
      raw['enabled'] is! bool ||
      raw['timeout'] is! int ||
      (raw['timeout'] as int).abs() > 9007199254740991) {
    _istThrow(InitShutdownTasksExceptionReason.invalidResponse);
  }
  final phases = InitShutdownTaskPhase.values.where(
    (p) => p.wireName == raw['when'],
  );
  if (phases.length != 1) {
    _istThrow(InitShutdownTasksExceptionReason.invalidResponse);
  }
  return InitShutdownTaskSnapshot(
    id: raw['id'] as int,
    type: raw['type'] as String,
    phase: phases.single,
    enabled: raw['enabled'] as bool,
    timeoutSeconds: raw['timeout'] as int,
  );
}

Object _istHeadValue(InitShutdownTaskSnapshot t) => [
  t.id,
  t.type,
  t.phase.wireName,
  t.enabled,
  t.timeoutSeconds,
];
Object _istHeaders(List<InitShutdownTaskSnapshot> tasks) =>
    tasks.map(_istHeadValue).toList();
Map<String, Object?> _istPrivateRow(Object? raw) {
  if (raw is! Map ||
      raw.length != _istDetails.length ||
      raw.keys.any((k) => !_istDetails.contains(k))) {
    _istThrow(InitShutdownTasksExceptionReason.invalidResponse);
  }
  final head = _istHeader(raw);
  if (!head.isCommand ||
      raw['command'] is! String ||
      (raw['command'] as String).isEmpty ||
      (raw['command'] as String).length > 1024 ||
      _istMasked(raw['command'] as String) ||
      raw['script'] != null && raw['script'] != '' ||
      raw['comment'] is! String ||
      (raw['comment'] as String).length > 255 ||
      _istMasked(raw['comment'] as String)) {
    _istThrow(InitShutdownTasksExceptionReason.invalidResponse);
  }
  return Map<String, Object?>.from(raw);
}

Map<String, Object?> _istExpected(
  InitShutdownTasksRequest r,
  Map<String, Object?> before,
) {
  if (r.action == InitShutdownTasksAction.delete) return {};
  if (r.command != null && r.command!.validationError != null) {
    _istThrow(InitShutdownTasksExceptionReason.staleReview);
  }
  return switch (r.action) {
    InitShutdownTasksAction.create => {
      'type': 'COMMAND',
      'command': String.fromCharCodes(r.command!._bytes),
      'script': '',
      'comment': '',
      'when': r.settings!.phase.wireName,
      'timeout': r.settings!.timeoutSeconds,
      'enabled': false,
    },
    InitShutdownTasksAction.replace => {
      ...before,
      'command': String.fromCharCodes(r.command!._bytes),
      'when': r.settings!.phase.wireName,
      'timeout': r.settings!.timeoutSeconds,
    },
    _ => {...before, 'enabled': r.action == InitShutdownTasksAction.enable},
  };
}
