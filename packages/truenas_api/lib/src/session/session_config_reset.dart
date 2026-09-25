part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedConfigurationResetSession {
  ConfigurationResetCapabilities get configurationResetCapabilities;
  Future<ConfigurationResetInventory> loadConfigurationReset();
  Future<ConfigurationResetReview> reviewConfigurationReset(
    ConfigurationResetRequest request,
  );
  Future<ConfigurationResetResult> executeConfigurationReset(
    ConfigurationResetReview review,
    String confirmation, {
    required bool Function() isCurrent,
  });
}

final class ConfigurationResetCapabilities {
  const ConfigurationResetCapabilities({
    this.connected = false,
    this.versionSupported = false,
    this.available = false,
  });
  const ConfigurationResetCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false;
  final bool connected, versionSupported, available;
  bool get supported => connected && versionSupported && available;
  bool get canReset => supported;
  String? get blockedReason => !connected
      ? 'Connect before reviewing a factory configuration reset.'
      : !versionSupported
      ? 'Native factory configuration reset requires stable TrueNAS 25.10.'
      : !available
      ? 'Required public reset and maintenance-readiness methods are unavailable.'
      : null;
}

final class ConfigurationResetInventory {
  ConfigurationResetInventory({
    required this.endpoint,
    required this.hostId,
    required this.bootId,
    required this.currentVersion,
    required this.state,
    required this.fullAdmin,
    required this.failoverLicensed,
    required this.conflictingJob,
    required this.bootPool,
    required this.bootHealthy,
    required List<BootEnvironmentSnapshot> environments,
    List<String> rebootReasonCodes = const [],
  }) : environments = List.unmodifiable(environments),
       rebootReasonCodes = List.unmodifiable(rebootReasonCodes);
  final String endpoint, hostId, bootId, currentVersion, state, bootPool;
  final bool fullAdmin, failoverLicensed, conflictingJob, bootHealthy;
  final List<BootEnvironmentSnapshot> environments;
  final List<String> rebootReasonCodes;
  BootEnvironmentSnapshot? get currentEnvironment =>
      environments.where((e) => e.active).singleOrNull;
  BootEnvironmentSnapshot? get nextEnvironment =>
      environments.where((e) => e.activated).singleOrNull;
  String? get blockedReason => !fullAdmin
      ? 'Factory configuration reset requires FULL_ADMIN privileges.'
      : failoverLicensed
      ? 'Do not factory-reset HA systems; contact TrueNAS Enterprise Support for recovery guidance.'
      : state != 'READY'
      ? 'The original server must report READY.'
      : conflictingJob
      ? 'An active or waiting server job prevents factory reset.'
      : !bootHealthy
      ? 'The boot pool must be healthy, online and not scanning.'
      : currentEnvironment == null || nextEnvironment == null
      ? 'Exactly one current and one next-boot environment are required.'
      : !currentEnvironment!.canActivate ||
            currentEnvironment!.id != nextEnvironment!.id
      ? 'A different or non-bootable next environment requires the TrueNAS recovery workflow.'
      : null;
}

final class ConfigurationResetRequest {
  const ConfigurationResetRequest({required this.inventory});
  final ConfigurationResetInventory inventory;
  String get target => 'RESET ${inventory.hostId}';
  String? get validationError => inventory.blockedReason;
}

final class ConfigurationResetReview {
  ConfigurationResetReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final ConfigurationResetRequest request;
  final String endpoint;
  final List<String> warnings;
  String get target => request.target;
}

enum ConfigurationResetOutcome { accepted, rejected, unknown }

final class ConfigurationResetResult {
  const ConfigurationResetResult(this.outcome, this.message, {this.jobId});
  final ConfigurationResetOutcome outcome;
  final String message;
  final int? jobId;
}

enum ConfigurationResetExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class ConfigurationResetException implements Exception {
  const ConfigurationResetException(this.reason);
  final ConfigurationResetExceptionReason reason;
  String get userMessage => switch (reason) {
    ConfigurationResetExceptionReason.notAuthenticated =>
      'Connect again before reviewing factory configuration reset.',
    ConfigurationResetExceptionReason.unsupportedVersion =>
      'Native factory configuration reset requires stable TrueNAS 25.10.',
    ConfigurationResetExceptionReason.unavailableMethod =>
      'Required public reset methods are unavailable.',
    ConfigurationResetExceptionReason.busy => 'Another operation is active or a submitted operation requires independent original-server recovery inspection.',
    ConfigurationResetExceptionReason.staleReview => 'The connection, foreground authorization, readiness or review changed. No factory-reset request was submitted.',
    ConfigurationResetExceptionReason.invalidRequest => 'Choose a ready standalone FULL_ADMIN session with a healthy unchanged boot environment and no visible active jobs.',
    ConfigurationResetExceptionReason.invalidResponse =>
      'Factory-reset readiness could not be validated.',
    ConfigurationResetExceptionReason.unavailable =>
      'Factory-reset readiness is unavailable. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

final class _ConfigurationResetLease {
  const _ConfigurationResetLease(this.created, this.proof);
  final DateTime created;
  final String proof;
}

final class _SessionConfigurationReset {
  _SessionConfigurationReset({
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
  bool _calling = false, _terminal = false;
  bool Function()? _operationCurrent;
  final Set<ConfigurationResetInventory> _inventories = {};
  final Map<ConfigurationResetReview, _ConfigurationResetLease> _reviews = {};
  bool get isBusy => _calling || _terminal;
  bool _current() {
    try {
      return isCurrent() && (_operationCurrent?.call() ?? true);
    } on Object {
      return false;
    }
  }

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

  ConfigurationResetCapabilities get capabilities =>
      ConfigurationResetCapabilities(
        connected: isCurrent(),
        versionSupported: _version,
        available:
            _powerReads.every(_method) &&
            _method('auth.me') &&
            _method('config.reset', job: true),
      );
  void _guard() {
    if (!isCurrent()) {
      _resetThrow(ConfigurationResetExceptionReason.notAuthenticated);
    }
    if (!_current()) _resetThrow(ConfigurationResetExceptionReason.staleReview);
    if (!_version) {
      _resetThrow(ConfigurationResetExceptionReason.unsupportedVersion);
    }
    if (!capabilities.available) {
      _resetThrow(ConfigurationResetExceptionReason.unavailableMethod);
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

  Future<ConfigurationResetInventory> _read() async {
    final admin = _configurationBackupAdmin(await _call('auth.me', const []));
    // Reuse only public maintenance reads, never power execution or file APIs.
    final power = await _powerReader._read();
    final finalAdmin = _configurationBackupAdmin(
      await _call('auth.me', const []),
    );
    if (admin != finalAdmin) {
      _resetThrow(ConfigurationResetExceptionReason.staleReview);
    }
    _guard();
    return ConfigurationResetInventory(
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
    );
  }

  Future<ConfigurationResetInventory> load() async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      _resetThrow(ConfigurationResetExceptionReason.busy);
    }
    _calling = true;
    _inventories.clear();
    _reviews.clear();
    try {
      final inventory = await _read();
      if (isOtherMutationBusy()) {
        _resetThrow(ConfigurationResetExceptionReason.busy);
      }
      _inventories.add(inventory);
      return inventory;
    } on ConfigurationResetException {
      rethrow;
    } on Object {
      _resetThrow(ConfigurationResetExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<ConfigurationResetReview> review(
    ConfigurationResetRequest request,
  ) async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      _resetThrow(ConfigurationResetExceptionReason.busy);
    }
    if (!_inventories.contains(request.inventory) ||
        request.inventory.endpoint != _endpoint) {
      _resetThrow(ConfigurationResetExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      _resetThrow(ConfigurationResetExceptionReason.invalidRequest);
    }
    _calling = true;
    _reviews.clear();
    try {
      final fresh = await _read(), proof = _resetProof(request.inventory);
      if (fresh.blockedReason != null ||
          proof != _resetProof(fresh) ||
          isOtherMutationBusy()) {
        _resetThrow(ConfigurationResetExceptionReason.staleReview);
      }
      final review = ConfigurationResetReview(
        request: request,
        endpoint: _endpoint,
        warnings: const [
          'This immediately replaces the live TrueNAS configuration database with factory defaults. It is not a dry run or a reversible preview. This app always requests reboot; after successful reset hooks, TrueNAS schedules reboot with a 10-second delay.',
          'Database replacement occurs before later hooks and reboot scheduling. An error, failed job or lost connection can happen after configuration has already changed. None proves rollback or that the old configuration remains intact.',
          'Accounts, credentials, certificates, networking, shares and service configuration may be lost or changed. Access to stored dataset encryption keys and other secrets may be lost. Independently secure a current configuration backup and separate recovery-key material before continuing.',
          'Arrange independent console or physical access and verify your recovery plan. The server may acquire a different address or certificate and this app may be unable to reconnect. No automatic discovery, certificate trust fallback, migration to another address or restoration is performed.',
          'Factory configuration reset is not disk wiping, secure erasure or proof that sensitive data or keys have been removed from every location. Storage contents may remain but accessibility, imports, mounts, services and application or VM data availability are not guaranteed.',
          'Readiness checks cover public host and boot identity, stable version, FULL_ADMIN privilege, READY standalone state, boot-pool health, unchanged current/next boot environment and visible job headers. They cannot prove that pending uploaded configuration files are absent. Reset does not clear those files: startup can install a previously uploaded configuration instead of factory defaults. Independently rule out pending restoration before continuing. These reads also do not guarantee free space, workload quiescence or atomicity against other administrators.',
          'A positive reset job ID acknowledges acceptance only, not completion, reboot or recovery. After submission this session blocks further management writes. Independently inspect the original server before deliberate reconnection; never repeat reset to test whether it worked. No polling, job abort, retry or separate reboot request is issued.',
        ],
      );
      _reviews[review] = _ConfigurationResetLease(_now(), proof);
      return review;
    } on ConfigurationResetException {
      rethrow;
    } on Object {
      _resetThrow(ConfigurationResetExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<ConfigurationResetResult> execute(
    ConfigurationResetReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    final lease = _reviews.remove(
      review,
    ); // Every attempt consumes its issued lease.
    var sent = false, owns = false;
    bool authorized() {
      try {
        return isCurrent();
      } on Object {
        return false;
      }
    }

    bool validAge() {
      if (lease == null) return false;
      final age = _now().difference(lease.created);
      return !age.isNegative && age <= const Duration(minutes: 5);
    }

    try {
      _guard();
      if (isBusy || isOtherMutationBusy()) {
        _resetThrow(ConfigurationResetExceptionReason.busy);
      }
      if (lease == null ||
          !authorized() ||
          !validAge() ||
          confirmation != review.target ||
          review.endpoint != _endpoint ||
          review.request.validationError != null) {
        _resetThrow(ConfigurationResetExceptionReason.staleReview);
      }
      _calling = true;
      owns = true;
      _operationCurrent = isCurrent;
      final fresh = await _read();
      if (fresh.blockedReason != null ||
          _resetProof(fresh) != lease.proof ||
          isOtherMutationBusy()) {
        _resetThrow(ConfigurationResetExceptionReason.staleReview);
      }
      _guard();
      if (!validAge()) {
        _resetThrow(ConfigurationResetExceptionReason.staleReview);
      }
      // No preflight await remains. Mark submitted at the exact RPC invocation,
      // not during earlier local/foreground validation. No reboot=false option.
      sent = true;
      final receipt = await client
          .call(
            'config.reset',
            id: nextId(),
            params: const [
              {'reboot': true},
            ],
          )
          .timeout(requestTimeout);
      _fence();
      if (!_powerId(receipt) || !_current()) return _unknown();
      return ConfigurationResetResult(
        ConfigurationResetOutcome.accepted,
        'TrueNAS returned a factory-reset job ID. Acceptance is acknowledged only; configuration replacement, scheduled reboot and recovery are unverified. Inspect the original server independently before deliberate reconnection. Do not repeat reset.',
        jobId: receipt as int,
      );
    } on Object catch (error) {
      if (sent) return _unknown();
      return ConfigurationResetResult(
        ConfigurationResetOutcome.rejected,
        error is ConfigurationResetException ? error.userMessage : 'Factory-reset preflight failed or foreground authorization expired. No reset request was submitted.',
      );
    } finally {
      if (owns) {
        _operationCurrent = null;
        _calling = false;
      }
    }
  }

  void _fence() {
    _terminal = true;
    _inventories.clear();
    _reviews.clear();
  }

  ConfigurationResetResult _unknown() {
    _fence();
    return const ConfigurationResetResult(
      ConfigurationResetOutcome.unknown,
      'A factory-reset request may already have replaced configuration and scheduled reboot, but its outcome is unknown. An error or disconnection does not prove rollback. Independently inspect the original machine before deliberate reconnection; do not repeat reset.',
    );
  }
}

Never _resetThrow(ConfigurationResetExceptionReason reason) =>
    throw ConfigurationResetException(reason);
String _resetProof(ConfigurationResetInventory i) => jsonEncode([
  i.endpoint,
  i.hostId,
  i.bootId,
  i.currentVersion,
  i.state,
  i.fullAdmin,
  i.failoverLicensed,
  i.conflictingJob,
  i.bootPool,
  i.bootHealthy,
  i.rebootReasonCodes,
  for (final e in i.environments)
    [e.id, e.dataset, e.created, e.active, e.activated, e.keep, e.canActivate],
]);
