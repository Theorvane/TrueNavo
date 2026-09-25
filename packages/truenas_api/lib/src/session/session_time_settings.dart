part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedTimeSettingsSession {
  TimeSettingsCapabilities get timeSettingsCapabilities;
  Future<TimeSettingsInventory> loadTimeSettings();
  Future<TimeSettingsReview> reviewTimeSettings(TimeSettingsRequest request);
  Future<TimeSettingsResult> executeTimeSettings(
    TimeSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  });
}

enum TimeSettingsAction { timezone, createNtp, updateNtp, deleteNtp }

final class TimeSettingsCapabilities {
  const TimeSettingsCapabilities({
    this.connected = false,
    this.versionSupported = false,
    this.available = false,
    this.canChangeTimezone = false,
    this.canCreateNtp = false,
    this.canUpdateNtp = false,
    this.canDeleteNtp = false,
  });
  const TimeSettingsCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      canChangeTimezone = false,
      canCreateNtp = false,
      canUpdateNtp = false,
      canDeleteNtp = false;
  final bool connected,
      versionSupported,
      available,
      canChangeTimezone,
      canCreateNtp,
      canUpdateNtp,
      canDeleteNtp;
  bool get supported => connected && versionSupported && available;
  bool supports(TimeSettingsAction action) =>
      supported &&
      switch (action) {
        TimeSettingsAction.timezone => canChangeTimezone,
        TimeSettingsAction.createNtp => canCreateNtp,
        TimeSettingsAction.updateNtp => canUpdateNtp,
        TimeSettingsAction.deleteNtp => canDeleteNtp,
      };
  String? get blockedReason => !connected
      ? 'Connect to inspect time configuration.'
      : !versionSupported
      ? 'Native time settings require stable TrueNAS 25.10.'
      : !available
      ? 'Required public time-configuration and readiness methods are unavailable.'
      : null;
}

final class NtpServerSettings {
  const NtpServerSettings({
    required this.address,
    this.burst = false,
    this.iburst = true,
    this.prefer = false,
    this.minPoll = 6,
    this.maxPoll = 10,
  });
  final String address;
  final bool burst, iburst, prefer;
  final int minPoll, maxPoll;
  String? get validationError => !_timeAddress(address) || address.contains(':')
      ? 'Use a hostname or IPv4 address up to 120 ASCII characters; no URL, port, whitespace or shell syntax. TrueNAS validation requires IPv4 reachability.'
      : minPoll < 4 || maxPoll > 17 || minPoll >= maxPoll
      ? 'This app supports poll exponents from 4 to 17 with minimum less than maximum (intervals are 2^exponent seconds).'
      : null;
}

final class NtpServerSnapshot {
  const NtpServerSnapshot({required this.id, required this.settings});
  final int id;
  final NtpServerSettings settings;
}

final class TimeSettingsInventory {
  TimeSettingsInventory({
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
    required this.timezone,
    required List<String> timezones,
    required List<NtpServerSnapshot> servers,
    this.guiRollbackKnown = false,
    this.guiRollbackSeconds,
    List<String> rebootReasonCodes = const [],
  }) : environments = List.unmodifiable(environments),
       timezones = List.unmodifiable(timezones),
       servers = List.unmodifiable(servers),
       rebootReasonCodes = List.unmodifiable(rebootReasonCodes);
  final String endpoint,
      hostId,
      bootId,
      currentVersion,
      state,
      bootPool,
      timezone;
  final bool fullAdmin,
      failoverLicensed,
      conflictingJob,
      bootHealthy,
      guiRollbackKnown;

  /// Null with known=true means no rollback; null with known=false is unknown.
  /// Zero is still pending: TrueNAS truncates a positive sub-second remainder.
  final int? guiRollbackSeconds;
  final List<BootEnvironmentSnapshot> environments;
  final List<String> timezones, rebootReasonCodes;
  final List<NtpServerSnapshot> servers;
  BootEnvironmentSnapshot? get currentEnvironment =>
      environments.where((e) => e.active).singleOrNull;
  BootEnvironmentSnapshot? get nextEnvironment =>
      environments.where((e) => e.activated).singleOrNull;
  String? get blockedReason => !fullAdmin
      ? 'Time changes require FULL_ADMIN in this app.'
      : failoverLicensed
      ? 'HA time changes require the coordinated TrueNAS workflow.'
      : state != 'READY'
      ? 'The original server must report READY.'
      : conflictingJob
      ? 'An active or waiting server job prevents this time change.'
      : !bootHealthy
      ? 'The boot pool must be healthy, online and not scanning.'
      : currentEnvironment == null || nextEnvironment == null
      ? 'Exactly one current and one next-boot environment are required.'
      : !currentEnvironment!.canActivate ||
            currentEnvironment!.id != nextEnvironment!.id
      ? 'An unchanged bootable current/next environment is required.'
      : null;
  String? get timezoneBlockedReason =>
      blockedReason ??
      (!guiRollbackKnown
          ? 'GUI rollback status is unknown; timezone changes are unavailable.'
          : guiRollbackSeconds != null
          ? 'A pending GUI rollback prevents timezone changes. Resolve it independently in TrueNAS.'
          : null);
}

final class TimeSettingsRequest {
  const TimeSettingsRequest({
    required this.inventory,
    required this.action,
    this.server,
    this.settings,
    this.timezone,
  });
  final TimeSettingsInventory inventory;
  final TimeSettingsAction action;
  final NtpServerSnapshot? server;
  final NtpServerSettings? settings;
  final String? timezone;
  String get target => switch (action) {
    TimeSettingsAction.timezone =>
      'TIMEZONE ${inventory.hostId} ${timezone ?? ""}',
    TimeSettingsAction.createNtp =>
      'CREATE NTP ${inventory.hostId} ${settings?.address ?? ""}',
    TimeSettingsAction.updateNtp =>
      'UPDATE NTP ${inventory.hostId} ${server?.id ?? ""} ${settings?.address ?? ""}',
    TimeSettingsAction.deleteNtp =>
      'DELETE NTP ${inventory.hostId} ${server?.id ?? ""} ${server?.settings.address ?? ""}',
  };
  String? get validationError {
    if (inventory.blockedReason != null) return inventory.blockedReason;
    if (action == TimeSettingsAction.timezone) {
      if (inventory.timezoneBlockedReason != null) {
        return inventory.timezoneBlockedReason;
      }
      return server != null ||
              settings != null ||
              timezone == null ||
              !inventory.timezones.contains(timezone) ||
              timezone == inventory.timezone
          ? 'Choose a different exact advertised timezone and no NTP fields.'
          : null;
    }
    if (timezone != null) {
      return 'Timezone and NTP changes must be reviewed separately.';
    }
    if (action == TimeSettingsAction.createNtp) {
      if (server != null ||
          settings == null ||
          inventory.servers.length >= 128) {
        return 'Choose new NTP settings without an existing row; at most 128 sources are supported.';
      }
    } else if (server == null ||
        !inventory.servers.any((row) => identical(row, server))) {
      return 'Choose the exact NTP source from this inventory.';
    }
    if (action == TimeSettingsAction.deleteNtp) {
      return settings != null || inventory.servers.length < 2
          ? 'Deletion must leave at least one configured source; this is not proof of a healthy time source.'
          : null;
    }
    if (settings == null || settings!.validationError != null) {
      return settings?.validationError ?? 'Enter complete NTP source settings.';
    }
    if (inventory.servers.any(
      (row) =>
          !identical(row, server) &&
          row.settings.address.toLowerCase() == settings!.address.toLowerCase(),
    )) {
      return 'A source with this address is already configured.';
    }
    if (action == TimeSettingsAction.updateNtp &&
        _timeSettingsProof(settings!) == _timeSettingsProof(server!.settings)) {
      return 'Choose changed settings; an unchanged update still probes and restarts NTP.';
    }
    return null;
  }
}

final class TimeSettingsReview {
  TimeSettingsReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final TimeSettingsRequest request;
  final String endpoint;
  final List<String> warnings;
  TimeSettingsAction get action => request.action;
  String get target => request.target;
}

enum TimeSettingsOutcome { completed, rejected, unknown }

final class TimeSettingsResult {
  const TimeSettingsResult(this.outcome, this.message);
  final TimeSettingsOutcome outcome;
  final String message;
}

enum TimeSettingsExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class TimeSettingsException implements Exception {
  const TimeSettingsException(this.reason);
  final TimeSettingsExceptionReason reason;
  String get userMessage => switch (reason) {
    TimeSettingsExceptionReason.notAuthenticated =>
      'Connect again before reviewing time settings.',
    TimeSettingsExceptionReason.unsupportedVersion =>
      'Native time settings require stable TrueNAS 25.10.',
    TimeSettingsExceptionReason.unavailableMethod =>
      'Required public time methods are unavailable.',
    TimeSettingsExceptionReason.busy => 'Another operation is active or a prior uncertain operation requires independent inspection.',
    TimeSettingsExceptionReason.staleReview => 'The issued review, connection, authorization or time configuration changed. No time change was submitted.',
    TimeSettingsExceptionReason.invalidRequest => 'Choose a supported, changed time setting and resolve the displayed readiness restrictions.',
    TimeSettingsExceptionReason.invalidResponse =>
      'Time configuration could not be validated safely.',
    TimeSettingsExceptionReason.unavailable =>
      'Time configuration is unavailable. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

const _timeReads = {
  ..._powerReads,
  'auth.me',
  'system.general.config',
  'system.general.timezone_choices',
  'system.ntpserver.query',
};
const _timeNtpSelect = [
  'id',
  'address',
  'burst',
  'iburst',
  'prefer',
  'minpoll',
  'maxpoll',
];
String _timeMethod(TimeSettingsAction action) => switch (action) {
  TimeSettingsAction.timezone => 'system.general.update',
  TimeSettingsAction.createNtp => 'system.ntpserver.create',
  TimeSettingsAction.updateNtp => 'system.ntpserver.update',
  TimeSettingsAction.deleteNtp => 'system.ntpserver.delete',
};

final class _TimeLease {
  const _TimeLease(this.created, this.proof);
  final DateTime created;
  final String proof;
}

final class _SessionTimeSettings {
  _SessionTimeSettings({
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
  final Set<TimeSettingsInventory> _inventories = {};
  final Map<TimeSettingsReview, _TimeLease> _reviews = {};
  bool get isBusy => _calling || _terminal;
  bool _current() {
    try {
      return isCurrent() && (_operationCurrent?.call() ?? true);
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

  TimeSettingsCapabilities get capabilities => TimeSettingsCapabilities(
    connected: isCurrent(),
    versionSupported: _version,
    available: _timeReads.every(_method),
    canChangeTimezone:
        _method('system.general.update') &&
        _method('system.general.checkin_waiting'),
    canCreateNtp: _method('system.ntpserver.create'),
    canUpdateNtp: _method('system.ntpserver.update'),
    canDeleteNtp: _method('system.ntpserver.delete'),
  );
  void _guard([TimeSettingsAction? action]) {
    if (!isCurrent()) _timeThrow(TimeSettingsExceptionReason.notAuthenticated);
    if (!_current()) _timeThrow(TimeSettingsExceptionReason.staleReview);
    if (!_version) _timeThrow(TimeSettingsExceptionReason.unsupportedVersion);
    if (!capabilities.supported ||
        action != null && !capabilities.supports(action)) {
      _timeThrow(TimeSettingsExceptionReason.unavailableMethod);
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

  Future<TimeSettingsInventory> _read() async {
    final admin = _configurationBackupAdmin(await _call('auth.me', const []));
    final power = await _powerReader._read();
    // Config can contain nested certificate/private-key material. Project the
    // timezone immediately; never retain or publish the unfiltered response.
    final timezone = _timeTimezone(
      await _call('system.general.config', const []),
    );
    final choices = _timeZones(
      await _call('system.general.timezone_choices', const []),
    );
    if (!choices.contains(timezone)) {
      _timeThrow(TimeSettingsExceptionReason.invalidResponse);
    }
    final servers = _timeServers(
      await _call('system.ntpserver.query', const [
        [],
        {'limit': 129, 'select': _timeNtpSelect},
      ]),
    );
    var rollbackKnown = false;
    int? rollback;
    // This public read has a WRITE role requirement. Read-only inventory never
    // attempts it, even if a server advertises metadata for all methods.
    if (admin && _method('system.general.checkin_waiting')) {
      final value = await _call('system.general.checkin_waiting', const []);
      if (value != null &&
          (value is! int || value < 0 || value > 9007199254740991)) {
        _timeThrow(TimeSettingsExceptionReason.invalidResponse);
      }
      rollbackKnown = true;
      rollback = value as int?;
    }
    final finalAdmin = _configurationBackupAdmin(
      await _call('auth.me', const []),
    );
    final finalHost = await _call('system.host_id', const []);
    final finalReboot = _powerReboot(
      await _call('system.reboot.info', const []),
    );
    final finalState = await _call('system.state', const []);
    if (admin != finalAdmin ||
        finalHost != power.hostId ||
        finalReboot.$1 != power.bootId ||
        jsonEncode(finalReboot.$2) != jsonEncode(power.rebootReasonCodes) ||
        finalState != power.state) {
      _timeThrow(TimeSettingsExceptionReason.staleReview);
    }
    return TimeSettingsInventory(
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
      timezone: timezone,
      timezones: choices,
      servers: servers,
      guiRollbackKnown: rollbackKnown,
      guiRollbackSeconds: rollback,
    );
  }

  Future<TimeSettingsInventory> load() async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      _timeThrow(TimeSettingsExceptionReason.busy);
    }
    _calling = true;
    _inventories.clear();
    _reviews.clear();
    try {
      final inventory = await _read();
      if (isOtherMutationBusy()) _timeThrow(TimeSettingsExceptionReason.busy);
      _inventories.add(inventory);
      return inventory;
    } on TimeSettingsException {
      rethrow;
    } on Object {
      _timeThrow(TimeSettingsExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<TimeSettingsReview> review(TimeSettingsRequest request) async {
    _guard(request.action);
    if (isBusy || isOtherMutationBusy()) {
      _timeThrow(TimeSettingsExceptionReason.busy);
    }
    if (!_inventories.contains(request.inventory) ||
        request.inventory.endpoint != _endpoint) {
      _timeThrow(TimeSettingsExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      _timeThrow(TimeSettingsExceptionReason.invalidRequest);
    }
    _calling = true;
    _reviews.clear();
    try {
      final fresh = await _read(), proof = _timeProof(request.inventory);
      if (fresh.blockedReason != null ||
          _timeProof(fresh) != proof ||
          isOtherMutationBusy()) {
        _timeThrow(TimeSettingsExceptionReason.staleReview);
      }
      final review = TimeSettingsReview(
        request: request,
        endpoint: _endpoint,
        warnings: [
          if (request.action == TimeSettingsAction.timezone)
            'This changes only the timezone field through system.general.update, not the wall clock directly. TrueNAS updates replication timezone configuration, reloads time services, restarts cron and unconditionally starts SSL service after writing its database. Scheduled work and local timestamps may behave differently; no GUI restart, rollback timer or check-in is requested.'
          else if (request.action == TimeSettingsAction.deleteNtp)
            'This removes one NTP configuration row and restarts ntpd after the database deletion. At least one other configured source must remain. Its presence is not evidence that it is reachable, trustworthy or synchronized.'
          else
            'Executing this creation or update makes TrueNAS resolve and send an IPv4 NTP request to the entered remote address, even for an options-only update. Explicitly approve that server-originated remote probe. DNS must resolve to a reachable IPv4 source. Force is always false, never an override or dry run. After validation TrueNAS writes its database and restarts ntpd; burst and iburst can increase traffic. Enable burst only on a personally controlled source, never public servers.',
          'Poll values are exponents: the nominal interval is 2^value seconds, not the entered number of seconds. This app uses a conservative bounded subset of the server API. Choose independently trusted time sources; no authenticated-NTP or peer-health verification is provided.',
          'A database change can occur before service reconfiguration fails. Every post-dispatch error, timeout, unexpected receipt or inconsistent readback is unknown, not rollback or permission to retry. Independently inspect the original server before any further writes.',
          'The readback verifies only the bounded saved timezone and exact configured source rows. DHCP and sources.d files can supply additional effective chrony sources, so these rows are not the complete active source inventory. It does not prove time synchronization, clock accuracy, peer reachability, time-service health, workload consistency or absence of external administrator races. No private peer/probe method, shell, job polling or automatic retry is called.',
          'Public host and boot identity, FULL_ADMIN, READY standalone status, idle visible jobs and a healthy unchanged boot environment are conservative app checks, not server prerequisites or a guarantee of maintenance safety. A pending or unprovable GUI rollback separately blocks timezone changes because connectivity may change.',
        ],
      );
      _reviews[review] = _TimeLease(_now(), proof);
      return review;
    } on TimeSettingsException {
      rethrow;
    } on Object {
      _timeThrow(TimeSettingsExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<TimeSettingsResult> execute(
    TimeSettingsReview review,
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

    bool ageValid() {
      if (lease == null) return false;
      final age = _now().difference(lease.created);
      return !age.isNegative && age <= const Duration(minutes: 5);
    }

    try {
      _guard(review.action);
      if (isBusy || isOtherMutationBusy()) {
        _timeThrow(TimeSettingsExceptionReason.busy);
      }
      if (lease == null ||
          !authorized() ||
          !ageValid() ||
          confirmation != review.target ||
          review.endpoint != _endpoint ||
          review.request.validationError != null) {
        _timeThrow(TimeSettingsExceptionReason.staleReview);
      }
      _calling = true;
      owns = true;
      _operationCurrent = isCurrent;
      final before = await _read();
      if (_timeProof(before) != lease.proof ||
          before.blockedReason != null ||
          isOtherMutationBusy()) {
        _timeThrow(TimeSettingsExceptionReason.staleReview);
      }
      _guard(review.action);
      if (!ageValid()) _timeThrow(TimeSettingsExceptionReason.staleReview);
      sent = true;
      final receipt = _timeReceipt(
        review.action,
        await client
            .call(
              _timeMethod(review.action),
              id: nextId(),
              params: _timeParams(review.request),
            )
            .timeout(requestTimeout),
      );
      _guard(review.action);
      if (!_timeReceiptMatches(review.request, receipt)) return _unknown();
      // One bounded independent fresh snapshot, never a polling/retry loop.
      final after = await _read();
      if (!_timeReadbackMatches(review.request, before, after, receipt) ||
          isOtherMutationBusy()) {
        return _unknown();
      }
      _inventories.clear();
      _reviews.clear();
      return const TimeSettingsResult(
        TimeSettingsOutcome.completed,
        'The expected response and fresh saved configuration matched. This confirms configuration only, not NTP synchronization, clock accuracy, service health or successful scheduled work.',
      );
    } on Object catch (error) {
      if (sent) return _unknown();
      return TimeSettingsResult(
        TimeSettingsOutcome.rejected,
        error is TimeSettingsException ? error.userMessage : 'Time-setting preflight failed or authorization expired. No time-change request was submitted.',
      );
    } finally {
      if (owns) {
        _operationCurrent = null;
        _calling = false;
      }
    }
  }

  TimeSettingsResult _unknown() {
    _terminal = true;
    _inventories.clear();
    _reviews.clear();
    return const TimeSettingsResult(
      TimeSettingsOutcome.unknown,
      'The time-setting request may already have changed configuration or restarted services. Its result could not be verified and does not prove rollback. Further writes are blocked in this session; inspect the original server independently and do not repeat the request to test it.',
    );
  }
}

Never _timeThrow(TimeSettingsExceptionReason reason) =>
    throw TimeSettingsException(reason);
bool _timeAddress(String address) =>
    address.length <= 120 &&
    _sshHost(address) &&
    (!RegExp(r'^[0-9.]+$').hasMatch(address) || _networkIPv4(address));
bool _timeZone(Object? value) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= 120 &&
    RegExp(r'^[A-Za-z0-9_+-]+(?:/[A-Za-z0-9_+-]+)*$').stringMatch(value) ==
        value;
String _timeTimezone(Object? value) {
  if (value is! Map || !_timeZone(value['timezone'])) {
    _timeThrow(TimeSettingsExceptionReason.invalidResponse);
  }
  return value['timezone'] as String;
}

List<String> _timeZones(Object? value) {
  if (value is! Map || value.isEmpty || value.length > 2048) {
    _timeThrow(TimeSettingsExceptionReason.invalidResponse);
  }
  final zones = <String>[];
  for (final entry in value.entries) {
    if (!_timeZone(entry.key) || entry.value != entry.key) {
      _timeThrow(TimeSettingsExceptionReason.invalidResponse);
    }
    zones.add(entry.key as String);
  }
  zones.sort();
  return zones;
}

NtpServerSnapshot _timeServer(Object? value) {
  if (value is! Map ||
      !_powerId(value['id']) ||
      value['address'] is! String ||
      value['burst'] is! bool ||
      value['iburst'] is! bool ||
      value['prefer'] is! bool ||
      value['minpoll'] is! int ||
      value['maxpoll'] is! int) {
    _timeThrow(TimeSettingsExceptionReason.invalidResponse);
  }
  final settings = NtpServerSettings(
    address: value['address'] as String,
    burst: value['burst'] as bool,
    iburst: value['iburst'] as bool,
    prefer: value['prefer'] as bool,
    minPoll: value['minpoll'] as int,
    maxPoll: value['maxpoll'] as int,
  );
  // Keep bounded legacy/IPv6 rows visible and removable without allowing the
  // create/update validator to send an unsupported IPv4-only probe.
  if (!_timeAddress(settings.address) ||
      settings.minPoll < -64 ||
      settings.minPoll > 64 ||
      settings.maxPoll < -64 ||
      settings.maxPoll > 64) {
    _timeThrow(TimeSettingsExceptionReason.invalidResponse);
  }
  return NtpServerSnapshot(id: value['id'] as int, settings: settings);
}

List<NtpServerSnapshot> _timeServers(Object? value) {
  if (value is! List || value.length > 128) {
    _timeThrow(TimeSettingsExceptionReason.invalidResponse);
  }
  final rows = value.map(_timeServer).toList()
    ..sort((a, b) => a.id.compareTo(b.id));
  if (rows.map((row) => row.id).toSet().length != rows.length) {
    _timeThrow(TimeSettingsExceptionReason.invalidResponse);
  }
  return rows;
}

Map<String, Object?> _timeSettingsMap(NtpServerSettings s) => {
  'address': s.address,
  'burst': s.burst,
  'iburst': s.iburst,
  'prefer': s.prefer,
  'minpoll': s.minPoll,
  'maxpoll': s.maxPoll,
};
String _timeSettingsProof(NtpServerSettings s) =>
    jsonEncode(_timeSettingsMap(s));
String _timeServersProof(List<NtpServerSnapshot> rows) => jsonEncode([
  for (final row in rows) [row.id, _timeSettingsMap(row.settings)],
]);
String _timeBaseProof(TimeSettingsInventory i) => jsonEncode([
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
  i.guiRollbackKnown,
  i.guiRollbackSeconds == null,
  i.timezones,
  for (final e in i.environments)
    [e.id, e.dataset, e.created, e.active, e.activated, e.keep, e.canActivate],
]);
String _timeProof(TimeSettingsInventory i) =>
    jsonEncode([_timeBaseProof(i), i.timezone, _timeServersProof(i.servers)]);
List<Object?> _timeParams(TimeSettingsRequest r) => switch (r.action) {
  TimeSettingsAction.timezone => [
    {'timezone': r.timezone!},
  ],
  TimeSettingsAction.createNtp => [
    {..._timeSettingsMap(r.settings!), 'force': false},
  ],
  TimeSettingsAction.updateNtp => [
    r.server!.id,
    {..._timeSettingsMap(r.settings!), 'force': false},
  ],
  TimeSettingsAction.deleteNtp => [r.server!.id],
};
Object _timeReceipt(TimeSettingsAction action, Object? value) =>
    switch (action) {
      TimeSettingsAction.timezone => _timeTimezone(value),
      TimeSettingsAction.createNtp ||
      TimeSettingsAction.updateNtp => _timeServer(value),
      TimeSettingsAction.deleteNtp =>
        value == true
            ? true
            : throw const TimeSettingsException(
                TimeSettingsExceptionReason.invalidResponse,
              ),
    };
bool _timeReceiptMatches(
  TimeSettingsRequest r,
  Object receipt,
) => switch (r.action) {
  TimeSettingsAction.timezone => receipt == r.timezone,
  TimeSettingsAction.createNtp =>
    receipt is NtpServerSnapshot &&
        !r.inventory.servers.any((row) => row.id == receipt.id) &&
        _timeSettingsProof(receipt.settings) == _timeSettingsProof(r.settings!),
  TimeSettingsAction.updateNtp =>
    receipt is NtpServerSnapshot &&
        receipt.id == r.server!.id &&
        _timeSettingsProof(receipt.settings) == _timeSettingsProof(r.settings!),
  TimeSettingsAction.deleteNtp => receipt == true,
};
bool _timeReadbackMatches(
  TimeSettingsRequest r,
  TimeSettingsInventory before,
  TimeSettingsInventory after,
  Object receipt,
) {
  if (_timeBaseProof(before) != _timeBaseProof(after) ||
      after.blockedReason != null) {
    return false;
  }
  if (after.timezone !=
      (r.action == TimeSettingsAction.timezone
          ? r.timezone
          : before.timezone)) {
    return false;
  }
  final expected = before.servers.toList();
  switch (r.action) {
    case TimeSettingsAction.timezone:
      if (after.timezoneBlockedReason != null) return false;
    case TimeSettingsAction.createNtp:
      expected.add(receipt as NtpServerSnapshot);
    case TimeSettingsAction.updateNtp:
      expected.removeWhere((row) => row.id == r.server!.id);
      expected.add(receipt as NtpServerSnapshot);
    case TimeSettingsAction.deleteNtp:
      expected.removeWhere((row) => row.id == r.server!.id);
  }
  expected.sort((a, b) => a.id.compareTo(b.id));
  return _timeServersProof(expected) == _timeServersProof(after.servers);
}
