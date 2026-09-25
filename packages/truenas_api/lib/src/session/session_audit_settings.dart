part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedAuditSettingsSession {
  AuditSettingsCapabilities get auditSettingsCapabilities;
  Future<AuditSettingsInventory> loadAuditSettings();
  Future<AuditSettingsReview> reviewAuditSettings(AuditSettingsRequest request);
  Future<AuditSettingsResult> executeAuditSettings(
    AuditSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  });
}

final class AuditSettingsCapabilities {
  const AuditSettingsCapabilities({
    this.connected = false,
    this.versionSupported = false,
    this.available = false,
    this.canUpdate = false,
  });
  const AuditSettingsCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      canUpdate = false;
  final bool connected, versionSupported, available, canUpdate;
  bool get supported => connected && versionSupported && available;
  bool get canConfigure => supported && canUpdate;
}

final class AuditSettingsSnapshot {
  const AuditSettingsSnapshot({
    required this.id,
    required this.retentionDays,
    required this.reservationGiB,
    required this.quotaGiB,
    required this.warningPercent,
    required this.criticalPercent,
    required this.remoteLoggingEnabled,
    required this.usedBytes,
    required this.usedByDatasetBytes,
    required this.usedBySnapshotsBytes,
    required this.availableBytes,
  });
  final int id, retentionDays, reservationGiB, quotaGiB;
  final int warningPercent, criticalPercent;
  final bool remoteLoggingEnabled;
  final int usedBytes, usedByDatasetBytes, usedBySnapshotsBytes, availableBytes;
}

final class AuditSettingsInventory {
  const AuditSettingsInventory({
    required this.readiness,
    required this.settings,
  });
  final AlertSettingsInventory readiness;
  final AuditSettingsSnapshot settings;
  String get endpoint => readiness.endpoint;
  String get hostId => readiness.hostId;
  String? get blockedReason => readiness.readinessBlockedReason;
}

final class AuditSettingsRequest {
  const AuditSettingsRequest({
    required this.inventory,
    required this.retentionDays,
    required this.shorterRetentionAccepted,
    required this.datasetImpactAccepted,
    this.reservationGiB,
    this.quotaGiB,
    this.warningPercent,
    this.criticalPercent,
  });
  final AuditSettingsInventory inventory;
  final int retentionDays;
  final int? reservationGiB, quotaGiB, warningPercent, criticalPercent;
  final bool shorterRetentionAccepted, datasetImpactAccepted;
  int get desiredReservationGiB =>
      reservationGiB ?? inventory.settings.reservationGiB;
  int get desiredQuotaGiB => quotaGiB ?? inventory.settings.quotaGiB;
  int get desiredWarningPercent =>
      warningPercent ?? inventory.settings.warningPercent;
  int get desiredCriticalPercent =>
      criticalPercent ?? inventory.settings.criticalPercent;
  bool get shortens => retentionDays < inventory.settings.retentionDays;
  bool get storageChanges =>
      desiredReservationGiB != inventory.settings.reservationGiB ||
      desiredQuotaGiB != inventory.settings.quotaGiB ||
      desiredWarningPercent != inventory.settings.warningPercent ||
      desiredCriticalPercent != inventory.settings.criticalPercent;
  Map<String, int> get changes => {
    if (retentionDays != inventory.settings.retentionDays)
      "retention": retentionDays,
    if (desiredReservationGiB != inventory.settings.reservationGiB)
      "reservation": desiredReservationGiB,
    if (desiredQuotaGiB != inventory.settings.quotaGiB)
      "quota": desiredQuotaGiB,
    if (desiredWarningPercent != inventory.settings.warningPercent)
      "quota_fill_warning": desiredWarningPercent,
    if (desiredCriticalPercent != inventory.settings.criticalPercent)
      "quota_fill_critical": desiredCriticalPercent,
  };
  String get target {
    final summary = changes.entries
        .map((entry) => "${entry.key.toUpperCase()} ${entry.value}")
        .join(" ");
    return "UPDATE AUDIT CONFIG ${inventory.hostId} $summary";
  }

  String? get validationError => _auditRequestError(this, inventory.settings);
}

String? _auditRequestError(
  AuditSettingsRequest request,
  AuditSettingsSnapshot current,
) {
  final retention = request.retentionDays;
  final reservation = request.desiredReservationGiB;
  final quota = request.desiredQuotaGiB;
  final warning = request.desiredWarningPercent;
  final critical = request.desiredCriticalPercent;
  if (request.inventory.blockedReason case final reason?) return reason;
  if (retention < 1 || retention > 30) {
    return "Choose 1–30 days of local audit retention.";
  }
  if (reservation < 0 || reservation > 100 || quota < 0 || quota > 100) {
    return "Choose reservation and quota values from 0–100 GiB.";
  }
  if (quota < reservation) {
    return "Audit quota must be at least the reservation; zero disables quota only when reservation is also zero.";
  }
  if (warning < 5 ||
      warning > 80 ||
      critical < 50 ||
      critical > 95 ||
      warning >= critical) {
    return "Choose a 5–80% warning below a 50–95% critical threshold.";
  }
  if (request.changes.isEmpty) {
    return "Choose at least one changed audit setting.";
  }
  if (request.shortens && !request.shorterRetentionAccepted) {
    return "A shorter period can remove audit evidence; acknowledge that impact.";
  }
  if (!request.datasetImpactAccepted) {
    return "Acknowledge audit dataset and storage-property effects.";
  }
  if (request.desiredQuotaGiB != current.quotaGiB && quota > 0) {
    final bytes = quota * 1024 * 1024 * 1024;
    final used = current.usedByDatasetBytes + current.usedBySnapshotsBytes;
    if (used * 100 > bytes * warning) {
      return "The new quota would already exceed its warning threshold.";
    }
  }
  return null;
}

final class AuditSettingsReview {
  AuditSettingsReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final AuditSettingsRequest request;
  final String endpoint;
  final List<String> warnings;
  String get target => request.target;
}

enum AuditSettingsOutcome { completed, rejected, unknown }

final class AuditSettingsResult {
  const AuditSettingsResult(this.outcome, this.message);
  final AuditSettingsOutcome outcome;
  final String message;
}

enum AuditSettingsExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class AuditSettingsException implements Exception {
  const AuditSettingsException(this.reason);
  final AuditSettingsExceptionReason reason;
  String get userMessage => switch (reason) {
    AuditSettingsExceptionReason.notAuthenticated =>
      'Connect again before changing audit settings.',
    AuditSettingsExceptionReason.unsupportedVersion =>
      'Native audit retention requires stable TrueNAS 25.10.',
    AuditSettingsExceptionReason.unavailableMethod =>
      'Required public audit configuration methods are unavailable.',
    AuditSettingsExceptionReason.busy =>
      'Another operation or uncertain outcome prevents audit changes.',
    AuditSettingsExceptionReason.staleReview => 'The audit configuration, server, review or permissions changed. No update was submitted.',
    AuditSettingsExceptionReason.invalidRequest =>
      'Review the retention period and its storage/evidence effects.',
    AuditSettingsExceptionReason.invalidResponse =>
      'The audit configuration could not be safely verified.',
    AuditSettingsExceptionReason.unavailable =>
      'Audit settings are unavailable. Server details were withheld.',
  };
  @override
  String toString() => userMessage;
}

final class _AuditSettingsRead {
  const _AuditSettingsRead(this.inventory, this.configProof);
  final AuditSettingsInventory inventory;
  final String configProof;
}

final class _AuditSettingsLease {
  const _AuditSettingsLease(this.issuedAt, this.proof);
  final DateTime issuedAt;
  final String proof;
}

final class _SessionAuditSettings {
  _SessionAuditSettings({
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
  final Map<AuditSettingsInventory, String> _inventories = {};
  final Map<AuditSettingsReview, _AuditSettingsLease> _reviews = {};
  bool _calling = false, _terminal = false, _disposed = false;
  bool Function()? _operationCurrent;
  bool get isBusy => _calling || _terminal;
  void dispose() {
    _disposed = true;
    _inventories.clear();
    _reviews.clear();
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

  AuditSettingsCapabilities get capabilities => AuditSettingsCapabilities(
    connected: _current(),
    versionSupported: _version,
    available: _method('audit.config'),
    canUpdate: _method('audit.update'),
  );
  Never _throw(AuditSettingsExceptionReason reason) =>
      throw AuditSettingsException(reason);
  void _guard({bool write = false}) {
    if (_disposed || !isCurrent()) {
      _throw(AuditSettingsExceptionReason.notAuthenticated);
    }
    if (!_current()) _throw(AuditSettingsExceptionReason.staleReview);
    if (!_version) _throw(AuditSettingsExceptionReason.unsupportedVersion);
    if (!capabilities.supported || write && !capabilities.canConfigure) {
      _throw(AuditSettingsExceptionReason.unavailableMethod);
    }
  }

  Future<Object?> _call(String method, List<Object?> params) async {
    _guard();
    final response = await client
        .call(method, id: nextId(), params: params)
        .timeout(requestTimeout);
    _guard();
    return response;
  }

  String _digest(Object? value) {
    if (!_smbBounded(value)) {
      _throw(AuditSettingsExceptionReason.invalidResponse);
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

  AuditSettingsSnapshot _project(Object? raw) {
    if (raw is! Map ||
        raw.keys.toSet().length != 9 ||
        !raw.keys.toSet().containsAll({
          'id',
          'retention',
          'reservation',
          'quota',
          'quota_fill_warning',
          'quota_fill_critical',
          'remote_logging_enabled',
          'space',
          'enabled_services',
        }) ||
        !_powerId(raw['id']) ||
        raw['retention'] is! int ||
        (raw['retention'] as int) < 1 ||
        (raw['retention'] as int) > 30 ||
        raw['reservation'] is! int ||
        (raw['reservation'] as int) < 0 ||
        (raw['reservation'] as int) > 100 ||
        raw['quota'] is! int ||
        (raw['quota'] as int) < 0 ||
        (raw['quota'] as int) > 100 ||
        (raw['quota'] as int) != 0 &&
            (raw['quota'] as int) < (raw['reservation'] as int) ||
        raw['quota_fill_warning'] is! int ||
        (raw['quota_fill_warning'] as int) < 5 ||
        (raw['quota_fill_warning'] as int) > 80 ||
        raw['quota_fill_critical'] is! int ||
        (raw['quota_fill_critical'] as int) < 50 ||
        (raw['quota_fill_critical'] as int) > 95 ||
        raw['remote_logging_enabled'] is! bool ||
        raw['space'] is! Map ||
        raw['enabled_services'] is! Map ||
        !_smbBounded(raw)) {
      _throw(AuditSettingsExceptionReason.invalidResponse);
    }
    final space = raw['space'] as Map;
    if (space.keys.toSet().length != 5 ||
        !space.keys.toSet().containsAll({
          'used',
          'used_by_dataset',
          'used_by_reservation',
          'used_by_snapshots',
          'available',
        }) ||
        space.values.any((v) => v is! int || v < 0) ||
        (raw['enabled_services'] as Map).keys.toSet().length != 3 ||
        !(raw['enabled_services'] as Map).keys.toSet().containsAll({
          'MIDDLEWARE',
          'SMB',
          'SUDO',
        }) ||
        (raw['enabled_services'] as Map).values.any((v) => v is! List)) {
      _throw(AuditSettingsExceptionReason.invalidResponse);
    }
    return AuditSettingsSnapshot(
      id: raw['id'] as int,
      retentionDays: raw['retention'] as int,
      reservationGiB: raw['reservation'] as int,
      quotaGiB: raw['quota'] as int,
      warningPercent: raw['quota_fill_warning'] as int,
      criticalPercent: raw['quota_fill_critical'] as int,
      remoteLoggingEnabled: raw['remote_logging_enabled'] as bool,
      usedBytes: space['used'] as int,
      usedByDatasetBytes: space['used_by_dataset'] as int,
      usedBySnapshotsBytes: space['used_by_snapshots'] as int,
      availableBytes: space['available'] as int,
    );
  }

  String _configProof(Object? raw) {
    final map = Map<Object?, Object?>.of(raw as Map);
    map.remove('space'); // Audit usage changes while events arrive.
    return _digest(map);
  }

  String _inventoryProof(_AuditSettingsRead value) => _digest({
    'endpoint': value.inventory.endpoint,
    'host': value.inventory.hostId,
    'boot': value.inventory.readiness.bootId,
    'version': value.inventory.readiness.currentVersion,
    'state': value.inventory.readiness.state,
    'full_admin': value.inventory.readiness.fullAdmin,
    'failover': value.inventory.readiness.failoverLicensed,
    'jobs': value.inventory.readiness.conflictingJob,
    'boot_pool': value.inventory.readiness.bootPool,
    'boot_healthy': value.inventory.readiness.bootHealthy,
    'environments': value.inventory.readiness.environments
        .map(
          (e) => [
            e.id,
            e.dataset,
            e.active,
            e.activated,
            e.keep,
            e.canActivate,
          ],
        )
        .toList(),
    'reboot_reasons': value.inventory.readiness.rebootReasonCodes,
    'config': value.configProof,
  });
  Future<_AuditSettingsRead> _read() async {
    final admin = _configurationBackupAdmin(await _call('auth.me', const []));
    final power = await _power._read();
    final raw = await _call('audit.config', const []);
    final settings = _project(raw);
    final configProof = _configProof(raw);
    final adminAfter = _configurationBackupAdmin(
      await _call('auth.me', const []),
    );
    final host = await _call('system.host_id', const []),
        reboot = _powerReboot(await _call('system.reboot.info', const []));
    final state = await _call('system.state', const []);
    if (admin != adminAfter ||
        host != power.hostId ||
        reboot.$1 != power.bootId ||
        state != power.state ||
        jsonEncode(reboot.$2) != jsonEncode(power.rebootReasonCodes)) {
      _throw(AuditSettingsExceptionReason.staleReview);
    }
    final readiness = AlertSettingsInventory(
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
    );
    return _AuditSettingsRead(
      AuditSettingsInventory(readiness: readiness, settings: settings),
      configProof,
    );
  }

  Future<AuditSettingsInventory> load() async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      _throw(AuditSettingsExceptionReason.busy);
    }
    _calling = true;
    _inventories.clear();
    _reviews.clear();
    try {
      final value = await _read();
      if (isOtherMutationBusy()) _throw(AuditSettingsExceptionReason.busy);
      _inventories[value.inventory] = _inventoryProof(value);
      return value.inventory;
    } on AuditSettingsException {
      rethrow;
    } on Object {
      _throw(AuditSettingsExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<AuditSettingsReview> review(AuditSettingsRequest request) async {
    _guard(write: true);
    if (isBusy || isOtherMutationBusy()) {
      _throw(AuditSettingsExceptionReason.busy);
    }
    final proof = _inventories[request.inventory];
    if (proof == null || request.inventory.endpoint != _endpoint) {
      _throw(AuditSettingsExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      _throw(AuditSettingsExceptionReason.invalidRequest);
    }
    _calling = true;
    _reviews.clear();
    try {
      final before = await _read();
      if (_inventoryProof(before) != proof ||
          before.inventory.blockedReason != null ||
          _auditRequestError(request, before.inventory.settings) != null ||
          isOtherMutationBusy()) {
        _throw(AuditSettingsExceptionReason.staleReview);
      }
      final value = AuditSettingsReview(
        request: request,
        endpoint: _endpoint,
        warnings: const [
          'Changing audit retention can remove security evidence. Reservation and quota changes affect space available to other datasets and can interrupt future audit writes.',
          'audit.update changes ZFS audit dataset properties before its datastore update. A partial failure is not an automatic rollback; quota zero disables quota only when reservation is also zero.',
          'Audit space measurements and enabled-service lists are configuration/usage snapshots, not proof of complete event capture. Continuous event writes can change used space between reads. Other administrators and background cleanup are not locked by this app.',
          'Success verifies the requested saved settings and preserved configuration only. It does not prove event coverage, remote log delivery, cleanup timing or audit dataset health. A failure after dispatch is uncertain, never a rollback claim or permission to retry.',
        ],
      );
      _reviews[value] = _AuditSettingsLease(_now(), proof);
      return value;
    } on AuditSettingsException {
      rethrow;
    } on Object {
      _throw(AuditSettingsExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<AuditSettingsResult> execute(
    AuditSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    final lease = _reviews.remove(review);
    var sent = false, owns = false;
    bool ageValid() {
      if (lease == null) return false;
      final age = _now().difference(lease.issuedAt);
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
      _guard(write: true);
      if (isBusy || isOtherMutationBusy()) {
        _throw(AuditSettingsExceptionReason.busy);
      }
      if (lease == null ||
          !authorized() ||
          !ageValid() ||
          confirmation != review.target ||
          review.endpoint != _endpoint ||
          review.request.validationError != null) {
        _throw(AuditSettingsExceptionReason.staleReview);
      }
      _calling = true;
      owns = true;
      _operationCurrent = isCurrent;
      final before = await _read();
      if (_inventoryProof(before) != lease.proof ||
          before.inventory.blockedReason != null ||
          isOtherMutationBusy() ||
          !ageValid() ||
          !authorized()) {
        _throw(AuditSettingsExceptionReason.staleReview);
      }
      _guard(write: true);
      if (!ageValid() || !authorized()) {
        _throw(AuditSettingsExceptionReason.staleReview);
      }
      sent = true;
      final receiptRaw = await client
          .call('audit.update', id: nextId(), params: [review.request.changes])
          .timeout(requestTimeout);
      _guard(write: true);
      final receipt = _project(receiptRaw);
      final receiptProof = _configProof(receiptRaw);
      if (!_matchesRequest(review.request, receipt) ||
          receipt.id != before.inventory.settings.id ||
          !_preserved(before, receipt, review.request) ||
          receiptProof == before.configProof) {
        return _unknown();
      }
      final after = await _read();
      if (_readinessProof(before.inventory.readiness) !=
              _readinessProof(after.inventory.readiness) ||
          after.inventory.blockedReason != null ||
          !_preserved(before, after.inventory.settings, review.request) ||
          !_matchesRequest(review.request, after.inventory.settings) ||
          after.configProof != receiptProof ||
          isOtherMutationBusy()) {
        return _unknown();
      }
      _inventories.clear();
      _reviews.clear();
      return const AuditSettingsResult(
        AuditSettingsOutcome.completed,
        'Saved audit configuration matched the response and independent readback. Event coverage, cleanup, usable pool capacity, dataset health and remote delivery were not verified.',
      );
    } on Object catch (error) {
      if (sent) return _unknown();
      return AuditSettingsResult(
        AuditSettingsOutcome.rejected,
        error is AuditSettingsException ? error.userMessage : 'Audit authorization expired or preflight failed. No update was submitted.',
      );
    } finally {
      if (owns) {
        _operationCurrent = null;
        _calling = false;
      }
    }
  }

  bool _matchesRequest(
    AuditSettingsRequest request,
    AuditSettingsSnapshot now,
  ) =>
      now.retentionDays == request.retentionDays &&
      now.reservationGiB == request.desiredReservationGiB &&
      now.quotaGiB == request.desiredQuotaGiB &&
      now.warningPercent == request.desiredWarningPercent &&
      now.criticalPercent == request.desiredCriticalPercent;
  bool _preserved(
    _AuditSettingsRead before,
    AuditSettingsSnapshot now,
    AuditSettingsRequest request,
  ) =>
      (request.changes.containsKey("retention") ||
          now.retentionDays == before.inventory.settings.retentionDays) &&
      (request.changes.containsKey("reservation") ||
          now.reservationGiB == before.inventory.settings.reservationGiB) &&
      (request.changes.containsKey("quota") ||
          now.quotaGiB == before.inventory.settings.quotaGiB) &&
      (request.changes.containsKey("quota_fill_warning") ||
          now.warningPercent == before.inventory.settings.warningPercent) &&
      (request.changes.containsKey("quota_fill_critical") ||
          now.criticalPercent == before.inventory.settings.criticalPercent) &&
      now.remoteLoggingEnabled ==
          before.inventory.settings.remoteLoggingEnabled;
  String _readinessProof(AlertSettingsInventory ready) => _digest({
    'host': ready.hostId,
    'boot': ready.bootId,
    'version': ready.currentVersion,
    'state': ready.state,
    'admin': ready.fullAdmin,
    'failover': ready.failoverLicensed,
    'jobs': ready.conflictingJob,
    'bootPool': ready.bootPool,
    'bootHealthy': ready.bootHealthy,
    'environments': ready.environments
        .map(
          (e) => [
            e.id,
            e.dataset,
            e.active,
            e.activated,
            e.keep,
            e.canActivate,
          ],
        )
        .toList(),
    'rebootReasons': ready.rebootReasonCodes,
  });
  AuditSettingsResult _unknown() {
    _terminal = true;
    _inventories.clear();
    _reviews.clear();
    return const AuditSettingsResult(
      AuditSettingsOutcome.unknown,
      'Audit retention or dataset properties may already have changed. Further writes are fenced; inspect the original server independently before any new action.',
    );
  }
}
