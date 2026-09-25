part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedSystemPowerSession {
  SystemPowerCapabilities get systemPowerCapabilities;
  Future<SystemPowerInventory> loadSystemPower();
  Future<SystemPowerReview> reviewSystemPower(SystemPowerRequest request);
  Future<SystemPowerResult> executeSystemPower(
    SystemPowerReview review,
    String confirmation,
  );
}

enum SystemPowerAction { reboot, shutdown }

final class SystemPowerCapabilities {
  const SystemPowerCapabilities({
    this.connected = false,
    this.versionSupported = false,
    this.available = false,
    this.canReboot = false,
    this.canShutdown = false,
  });
  const SystemPowerCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      canReboot = false,
      canShutdown = false;
  final bool connected, versionSupported, available, canReboot, canShutdown;
  bool get supported => connected && versionSupported && available;
  bool supports(SystemPowerAction action) =>
      supported &&
      switch (action) {
        SystemPowerAction.reboot => canReboot,
        SystemPowerAction.shutdown => canShutdown,
      };
  String? get blockedReason => !connected
      ? 'Connect to inspect system power readiness.'
      : !versionSupported
      ? 'Native system power requires stable TrueNAS 25.10.'
      : !available
      ? 'Public host identity, boot identity, state, version, boot pool, environment, HA and job reads are required.'
      : null;
}

final class SystemPowerInventory {
  SystemPowerInventory({
    required this.endpoint,
    required this.hostId,
    required this.bootId,
    required this.currentVersion,
    required this.state,
    required this.failoverLicensed,
    required this.conflictingJob,
    required this.bootPool,
    required this.bootHealthy,
    required List<BootEnvironmentSnapshot> environments,
    List<String> rebootReasonCodes = const [],
  }) : environments = List.unmodifiable(environments),
       rebootReasonCodes = List.unmodifiable(rebootReasonCodes);
  final String endpoint, hostId, bootId, currentVersion, state, bootPool;
  final bool failoverLicensed, conflictingJob, bootHealthy;
  final List<BootEnvironmentSnapshot> environments;
  final List<String> rebootReasonCodes;
  BootEnvironmentSnapshot? get currentEnvironment =>
      environments.where((e) => e.active).singleOrNull;
  BootEnvironmentSnapshot? get nextEnvironment =>
      environments.where((e) => e.activated).singleOrNull;
  String? get blockedReason => failoverLicensed
      ? 'HA power actions require the coordinated TrueNAS workflow.'
      : state != 'READY'
      ? 'The server must report READY, not booting or shutting down.'
      : conflictingJob
      ? 'An active or waiting server job prevents a new power action.'
      : !bootHealthy
      ? 'The boot pool must be healthy, online and not scanning.'
      : currentEnvironment == null || nextEnvironment == null
      ? 'Exactly one current and one next-boot environment are required.'
      : !currentEnvironment!.canActivate ||
            currentEnvironment!.id != nextEnvironment!.id
      ? 'A different or non-bootable next environment requires the TrueNAS maintenance workflow.'
      : null;
}

final class SystemPowerRequest {
  const SystemPowerRequest({
    required this.inventory,
    required this.action,
    required this.reason,
  });
  final SystemPowerInventory inventory;
  final SystemPowerAction action;
  final String reason;
  String get target => '${action.name.toUpperCase()} ${inventory.hostId}';
  String? get validationError =>
      inventory.blockedReason ??
      (!_powerText(reason, 256) || reason.trim() != reason
          ? 'Enter a non-empty audit reason of at most 256 characters without surrounding whitespace or control characters.'
          : null);
}

final class SystemPowerReview {
  SystemPowerReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final SystemPowerRequest request;
  final String endpoint;
  final List<String> warnings;
  String get target => request.target;
  SystemPowerAction get action => request.action;
}

enum SystemPowerOutcome { accepted, rejected, unknown }

final class SystemPowerResult {
  const SystemPowerResult(this.outcome, this.message, {this.jobId});
  final SystemPowerOutcome outcome;
  final String message;
  final int? jobId;
}

enum SystemPowerExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class SystemPowerException implements Exception {
  const SystemPowerException(this.reason);
  final SystemPowerExceptionReason reason;
  String get userMessage => switch (reason) {
    SystemPowerExceptionReason.notAuthenticated =>
      'Connect again before reviewing system power.',
    SystemPowerExceptionReason.unsupportedVersion =>
      'Native system power requires stable TrueNAS 25.10.',
    SystemPowerExceptionReason.unavailableMethod =>
      'Required public system power methods are unavailable.',
    SystemPowerExceptionReason.busy => 'Another operation is active or a power request requires original-server inspection before reconnecting.',
    SystemPowerExceptionReason.staleReview => 'The server identity, boot state, connection, inventory or review changed. Reload and review again.',
    SystemPowerExceptionReason.invalidRequest => 'Choose a ready standalone server with unchanged next-boot environment and a valid audit reason.',
    SystemPowerExceptionReason.invalidResponse =>
      'System power readiness information could not be validated.',
    SystemPowerExceptionReason.unavailable =>
      'System power readiness is unavailable. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

const _powerReads = {
  'system.version_short',
  'system.host_id',
  'system.reboot.info',
  'system.state',
  'failover.licensed',
  'boot.get_state',
  'boot.environment.query',
  'core.get_jobs',
};
const _powerBootSelect = [
  'id',
  'dataset',
  'created',
  'used_bytes',
  'active',
  'activated',
  'keep',
  'can_activate',
];

final class _PowerLease {
  const _PowerLease(this.created, this.proof);
  final DateTime created;
  final String proof;
}

final class _SessionSystemPower {
  _SessionSystemPower({
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
       _sessionVersion = summary.version,
       _endpoint = summary.endpointUri.toString(),
       _metadata = metadata is Map ? Map.of(metadata) : const {},
       _now = now ?? DateTime.now;
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherMutationBusy;
  final Duration requestTimeout;
  final bool _version;
  final String _sessionVersion, _endpoint;
  final Map _metadata;
  final DateTime Function() _now;
  bool _calling = false, _terminal = false;
  final Set<SystemPowerInventory> _inventories = {};
  final Map<SystemPowerReview, _PowerLease> _reviews = {};
  bool get isBusy => _calling || _terminal;
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

  SystemPowerCapabilities get capabilities => SystemPowerCapabilities(
    connected: isCurrent(),
    versionSupported: _version,
    available: _powerReads.every(_method),
    canReboot: _method('system.reboot', job: true),
    canShutdown: _method('system.shutdown', job: true),
  );
  void _guard({SystemPowerAction? action}) {
    if (!isCurrent()) {
      throw const SystemPowerException(
        SystemPowerExceptionReason.notAuthenticated,
      );
    }
    if (!_version) {
      throw const SystemPowerException(
        SystemPowerExceptionReason.unsupportedVersion,
      );
    }
    if (!capabilities.supported ||
        action != null && !capabilities.supports(action)) {
      throw const SystemPowerException(
        SystemPowerExceptionReason.unavailableMethod,
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

  Future<SystemPowerInventory> _read() async {
    final version = await _call('system.version_short', const []);
    final host = await _call('system.host_id', const []);
    final reboot = await _call('system.reboot.info', const []);
    final state = await _call('system.state', const []);
    final licensed = await _call('failover.licensed', const []);
    final boot = await _call('boot.get_state', const []);
    final rows = await _call('boot.environment.query', const [
      [],
      {'limit': 129, 'select': _powerBootSelect},
    ]);
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
    if (version != _sessionVersion ||
        !_powerText(version, 96) ||
        host is! String ||
        RegExp(r'^[0-9a-f]{64}$').stringMatch(host) != host ||
        !const {'BOOTING', 'READY', 'SHUTTING_DOWN'}.contains(state) ||
        licensed is! bool ||
        boot is! Map ||
        !_bootNewName(boot['name']) ||
        boot['healthy'] is! bool ||
        !_powerText(boot['status'], 32) ||
        rows is! List ||
        rows.length > 128 ||
        jobs is! List ||
        jobs.length > 128) {
      _powerInvalid();
    }
    final (bootId, codes) = _powerReboot(reboot);
    final environments = <BootEnvironmentSnapshot>[];
    try {
      environments.addAll(rows.map(_bootParse));
    } on Object {
      _powerInvalid();
    }
    environments.sort((a, b) => a.id.compareTo(b.id));
    if (environments.map((e) => e.id).toSet().length != environments.length ||
        environments.any((e) => e.dataset.split('/').first != boot['name'])) {
      _powerInvalid();
    }
    final ids = <int>{};
    for (final job in jobs) {
      if (job is! Map ||
          !_powerId(job['id']) ||
          !ids.add(job['id'] as int) ||
          job['method'] is! String ||
          RegExp(r'^[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)+$')
                  .stringMatch(job['method'] as String) !=
              job['method'] ||
          (job['method'] as String).length > 128 ||
          !const {'WAITING', 'RUNNING'}.contains(job['state'])) {
        _powerInvalid();
      }
    }
    if (!boot.containsKey('scan') ||
        boot['scan'] != null && boot['scan'] is! Map) {
      _powerInvalid();
    }
    final scan = boot['scan'];
    if (scan is Map &&
        !const {
          'NONE',
          'SCANNING',
          'FINISHED',
          'CANCELED',
        }.contains(scan['state'])) {
      _powerInvalid();
    }
    // Bound this assembled snapshot to one boot/host and stable state. This is
    // not an atomic server transaction and does not eliminate external races.
    final finalHost = await _call('system.host_id', const []);
    final finalReboot = _powerReboot(
      await _call('system.reboot.info', const []),
    );
    final finalState = await _call('system.state', const []);
    if (host != finalHost ||
        bootId != finalReboot.$1 ||
        jsonEncode(codes) != jsonEncode(finalReboot.$2) ||
        state != finalState) {
      throw const SystemPowerException(SystemPowerExceptionReason.staleReview);
    }
    return SystemPowerInventory(
      endpoint: _endpoint,
      hostId: host,
      bootId: bootId,
      currentVersion: version as String,
      state: state as String,
      failoverLicensed: licensed,
      conflictingJob: jobs.isNotEmpty,
      bootPool: boot['name'] as String,
      bootHealthy:
          boot['healthy'] == true &&
          boot['status'] == 'ONLINE' &&
          (scan == null || scan['state'] != 'SCANNING'),
      environments: environments,
      rebootReasonCodes: codes,
    );
  }

  Future<SystemPowerInventory> load() async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      throw const SystemPowerException(SystemPowerExceptionReason.busy);
    }
    _calling = true;
    _reviews.clear();
    _inventories.clear();
    try {
      final inventory = await _read();
      if (isOtherMutationBusy()) {
        throw const SystemPowerException(SystemPowerExceptionReason.busy);
      }
      _inventories.add(inventory);
      return inventory;
    } on SystemPowerException {
      rethrow;
    } on Object {
      throw const SystemPowerException(SystemPowerExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<SystemPowerReview> review(SystemPowerRequest request) async {
    _guard(action: request.action);
    if (isBusy || isOtherMutationBusy()) {
      throw const SystemPowerException(SystemPowerExceptionReason.busy);
    }
    if (!_inventories.contains(request.inventory) ||
        request.inventory.endpoint != _endpoint) {
      throw const SystemPowerException(SystemPowerExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      throw const SystemPowerException(
        SystemPowerExceptionReason.invalidRequest,
      );
    }
    _calling = true;
    _reviews.clear();
    try {
      final proof = _powerProof(request.inventory);
      final fresh = await _read();
      if (fresh.blockedReason != null ||
          _powerProof(fresh) != proof ||
          isOtherMutationBusy()) {
        throw const SystemPowerException(
          SystemPowerExceptionReason.staleReview,
        );
      }
      final review = SystemPowerReview(
        request: request,
        endpoint: _endpoint,
        warnings: const [
          'This requests immediate operating-system reboot or shutdown. Connected clients, shares, applications, containers, virtual machines and transfers may be interrupted. No workload quiescence or application-consistency guarantee is available.',
          'Verify independent console or physical access, backups and required encrypted-storage unlock material before confirming. Shutdown has no app-based power-on path; reboot may not return. No recovery readiness has been verified.',
          'The audit reason is sent to TrueNAS and recorded in its audit/event data. Do not include passwords, keys or other secrets.',
          'The exact endpoint, permanent host identifier, current boot identifier, version, READY state, standalone status, boot-pool health, current/next boot identity and visible job headers are rechecked. This does not see every workload or prevent last-moment changes by another administrator.',
          'Only the same current and next-boot environment is admitted. No update installation, alternate environment activation, HA coordination, forced action, delay or cancellation is performed.',
          'A positive job ID acknowledges scheduling only. Disconnection, a successful server job or elapsed time does not prove reboot, shutdown, successful boot or service recovery. No post-submit polling or automatic reconnect is performed.',
          'Accepted and unknown submissions permanently block further writes in this session. Inspect the original server independently before deliberately reconnecting. Do not repeat the power action to test whether it worked. Recovery records do not survive app restart.',
        ],
      );
      _reviews[review] = _PowerLease(_now(), proof);
      return review;
    } on SystemPowerException {
      rethrow;
    } on Object {
      throw const SystemPowerException(SystemPowerExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<SystemPowerResult> execute(
    SystemPowerReview review,
    String confirmation,
  ) async {
    var sent = false, owns = false;
    // Every execution attempt consumes its lease, including a lost session or
    // shared-busy rejection that occurs before any preflight RPC.
    final lease = _reviews.remove(review);
    try {
      _guard(action: review.action);
      if (isBusy || isOtherMutationBusy()) {
        throw const SystemPowerException(SystemPowerExceptionReason.busy);
      }
      final age = lease == null ? null : _now().difference(lease.created);
      if (lease == null ||
          review.endpoint != _endpoint ||
          confirmation != review.target ||
          age!.isNegative ||
          age > const Duration(minutes: 5) ||
          review.request.validationError != null) {
        throw const SystemPowerException(
          SystemPowerExceptionReason.staleReview,
        );
      }
      _calling = true;
      owns = true;
      final fresh = await _read();
      if (fresh.blockedReason != null ||
          _powerProof(fresh) != lease.proof ||
          isOtherMutationBusy()) {
        throw const SystemPowerException(
          SystemPowerExceptionReason.staleReview,
        );
      }
      _guard(action: review.action);
      final dispatchAge = _now().difference(lease.created);
      if (dispatchAge.isNegative || dispatchAge > const Duration(minutes: 5)) {
        throw const SystemPowerException(
          SystemPowerExceptionReason.staleReview,
        );
      }
      sent = true;
      final receipt = await _call('system.${review.action.name}', [
        review.request.reason,
        const {'delay': null},
      ]);
      _fence();
      if (!_powerId(receipt)) return _unknown();
      return SystemPowerResult(
        SystemPowerOutcome.accepted,
        'TrueNAS returned a power job ID. Scheduling is acknowledged; actual reboot, shutdown and recovery are unverified. Inspect the original server independently before deliberately reconnecting. Do not repeat the action.',
        jobId: receipt as int,
      );
    } on Object catch (error) {
      if (sent) return _unknown();
      return SystemPowerResult(
        SystemPowerOutcome.rejected,
        error is SystemPowerException
            ? error.userMessage
            : 'Power preflight failed. No power action was submitted.',
      );
    } finally {
      if (owns) _calling = false;
    }
  }

  void _fence() {
    _terminal = true;
    _reviews.clear();
    _inventories.clear();
  }

  SystemPowerResult _unknown() {
    _fence();
    return const SystemPowerResult(
      SystemPowerOutcome.unknown,
      'A power request may have reached TrueNAS, but its outcome is unknown. Disconnection is not proof of reboot or shutdown. Inspect the original server independently before deliberately reconnecting; do not repeat the action.',
    );
  }
}

(String, List<String>) _powerReboot(Object? value) {
  if (value is! Map ||
      value['boot_id'] is! String ||
      RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
              .stringMatch(value['boot_id'] as String) !=
          value['boot_id'] ||
      value['reboot_required_reasons'] is! List ||
      (value['reboot_required_reasons'] as List).length > 64) {
    _powerInvalid();
  }
  final codes = <String>{};
  for (final reason in value['reboot_required_reasons'] as List) {
    if (reason is! Map ||
        reason['code'] is! String ||
        RegExp(r'^[A-Z][A-Z0-9_]{0,63}$')
                .stringMatch(reason['code'] as String) !=
            reason['code'] ||
        !codes.add(reason['code'] as String)) {
      _powerInvalid();
    }
    // Human-readable reason is server-owned and intentionally not retained.
  }
  return (value['boot_id'] as String, codes.toList()..sort());
}

String _powerProof(SystemPowerInventory i) => jsonEncode([
  i.endpoint,
  i.hostId,
  i.bootId,
  i.currentVersion,
  i.state,
  i.failoverLicensed,
  i.conflictingJob,
  i.bootPool,
  i.bootHealthy,
  i.rebootReasonCodes,
  for (final e in i.environments)
    [e.id, e.dataset, e.created, e.active, e.activated, e.keep, e.canActivate],
]);
bool _powerId(Object? value) =>
    value is int && value > 0 && value <= 9007199254740991;
bool _powerText(Object? value, int max) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= max &&
    !RegExp(
      r'[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]',
    ).hasMatch(value);
Never _powerInvalid() => throw const SystemPowerException(
  SystemPowerExceptionReason.invalidResponse,
);
