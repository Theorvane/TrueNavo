part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedNfsSettingsSession {
  NfsSettingsCapabilities get nfsSettingsCapabilities;
  Future<NfsSettingsInventory> loadNfsSettings();
  Future<NfsSettingsReview> reviewNfsSettings(NfsSettingsRequest request);
  Future<NfsSettingsResult> executeNfsSettings(
    NfsSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  });
}

final class NfsSettingsCapabilities {
  const NfsSettingsCapabilities({
    this.connected = false,
    this.versionSupported = false,
    this.available = false,
    this.canUpdate = false,
  });
  const NfsSettingsCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      canUpdate = false;
  final bool connected, versionSupported, available, canUpdate;
  bool get supported => connected && versionSupported && available;
  bool get canConfigure => supported && canUpdate;
  String? get blockedReason => !connected
      ? 'Connect to inspect global NFS settings.'
      : !versionSupported
      ? 'Native global NFS settings require stable TrueNAS 25.10.'
      : !available
      ? 'Required public NFS configuration and readiness reads are unavailable.'
      : null;
}

final class NfsGlobalSettings {
  NfsGlobalSettings({
    required this.serverThreads,
    required List<String> protocols,
    required List<String> bindAddresses,
    required this.mountdLog,
    required this.statdLockdLog,
  }) : protocols = List.unmodifiable(protocols),
       bindAddresses = List.unmodifiable(bindAddresses);

  /// Null means automatic tuning; the server reports a separate computed count.
  final int? serverThreads;
  final List<String> protocols, bindAddresses;
  final bool mountdLog, statdLockdLog;
  String? get validationError =>
      serverThreads != null && (serverThreads! < 1 || serverThreads! > 256)
      ? 'Choose automatic tuning or 1–256 server threads.'
      : protocols.isEmpty ||
            protocols.length > 2 ||
            protocols.toSet().length != protocols.length ||
            protocols.any((p) => p != 'NFSV3' && p != 'NFSV4')
      ? 'Select at least one supported protocol: NFSV3 or NFSV4.'
      : bindAddresses.length > 32 ||
            bindAddresses.toSet().length != bindAddresses.length ||
            bindAddresses.any((v) => !_nfsSettingsAddress(v))
      ? 'Configured binding addresses must be unique bounded IP literals.'
      : null;
}

final class NfsConfigSnapshot {
  const NfsConfigSnapshot({
    required this.id,
    required this.settings,
    required this.reportedServers,
    required this.managedNfsd,
    required this.allowNonroot,
    required this.v4Krb,
    required this.v4Domain,
    required this.v4KrbEnabled,
    required this.keytabHasNfsSpn,
    required this.rdma,
    required this.userdManageGids,
    required this.mountdPort,
    required this.rpcstatdPort,
    required this.rpclockdPort,
  });
  final int id, reportedServers;
  final NfsGlobalSettings settings;
  final bool managedNfsd,
      allowNonroot,
      v4Krb,
      v4KrbEnabled,
      keytabHasNfsSpn,
      rdma,
      userdManageGids;
  final String v4Domain;
  final int? mountdPort, rpcstatdPort, rpclockdPort;
  String? get blockedReason => rdma
      ? 'RDMA configuration is protected; use the coordinated TrueNAS workflow.'
      : v4Krb || v4KrbEnabled || keytabHasNfsSpn
      ? 'Kerberos/NFS keytab configuration is protected; use the coordinated TrueNAS workflow.'
      : settings.validationError;
}

final class NfsConfiguredExport {
  NfsConfiguredExport({
    required this.id,
    required this.enabled,
    required List<String> security,
  }) : security = List.unmodifiable(security);
  final int id;
  final bool enabled;
  final List<String> security;
}

final class NfsSettingsInventory {
  NfsSettingsInventory({
    required this.readiness,
    required this.config,
    required List<NfsConfiguredExport> exports,
    required this.serviceState,
    required this.serviceEnabled,
    required List<String> bindChoices,
    required this.directoryConfigured,
  }) : exports = List.unmodifiable(exports),
       bindChoices = List.unmodifiable(bindChoices);
  final AlertSettingsInventory readiness;
  final NfsConfigSnapshot config;
  final List<NfsConfiguredExport> exports;
  final String serviceState;
  final bool serviceEnabled, directoryConfigured;
  final List<String> bindChoices;
  String get endpoint => readiness.endpoint;
  String get hostId => readiness.hostId;
  String get bootId => readiness.bootId;
  String get currentVersion => readiness.currentVersion;
  int get enabledExportCount => exports.where((s) => s.enabled).length;
  String? get readinessBlockedReason => readiness.readinessBlockedReason;
  String? get blockedReason =>
      readinessBlockedReason ??
      config.blockedReason ??
      (directoryConfigured
          ? 'An unconfigured, disabled directory-service profile is required. No directory health probe is performed.'
          : serviceState != 'STOPPED'
          ? 'Stop NFS independently before changing global settings. This workspace never starts, stops or restarts a service.'
          : config.settings.bindAddresses.any((v) => !bindChoices.contains(v))
          ? 'An existing binding is absent from the current static interface choices; repair it in TrueNAS before a global update.'
          : null);
}

final class NfsSettingsRequest {
  const NfsSettingsRequest({required this.inventory, required this.settings});
  final NfsSettingsInventory inventory;
  final NfsGlobalSettings settings;
  bool get changesProtocols =>
      jsonEncode(settings.protocols) !=
      jsonEncode(inventory.config.settings.protocols);
  bool get changesBindings =>
      jsonEncode(settings.bindAddresses) !=
      jsonEncode(inventory.config.settings.bindAddresses);
  String get target => 'UPDATE NFS ${inventory.hostId}';
  String? get validationError {
    if (inventory.blockedReason != null) return inventory.blockedReason;
    if (settings.validationError != null) return settings.validationError;
    if ((changesProtocols || changesBindings) &&
        inventory.enabledExportCount != 0) {
      return 'Protocol and binding changes require zero enabled exports; disable exports independently and reload.';
    }
    if (changesProtocols &&
        !settings.protocols.contains('NFSV4') &&
        (inventory.config.v4Domain.isNotEmpty ||
            inventory.exports.any((s) => s.security.any((v) => v != 'SYS')))) {
      return 'NFSV4 is required by a protected domain or a configured export security flavor, including disabled exports.';
    }
    if (changesBindings &&
        (inventory.config.settings.bindAddresses.any((v) => !_networkIPv4(v)) ||
            settings.bindAddresses.any(
              (v) => !_networkIPv4(v) || !inventory.bindChoices.contains(v),
            ))) {
      return 'Binding edits support only current static unicast IPv4 choices. Existing other bindings must remain unchanged.';
    }
    if (_nfsSettingsValues(settings) ==
        _nfsSettingsValues(inventory.config.settings)) {
      return 'Choose a changed global NFS setting.';
    }
    return null;
  }
}

final class NfsSettingsReview {
  NfsSettingsReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final NfsSettingsRequest request;
  final String endpoint;
  final List<String> warnings;
  String get target => request.target;
}

enum NfsSettingsOutcome { completed, rejected, unknown }

final class NfsSettingsResult {
  const NfsSettingsResult(this.outcome, this.message);
  final NfsSettingsOutcome outcome;
  final String message;
}

enum NfsSettingsExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class NfsSettingsException implements Exception {
  const NfsSettingsException(this.reason);
  final NfsSettingsExceptionReason reason;
  String get userMessage => switch (reason) {
    NfsSettingsExceptionReason.notAuthenticated =>
      'Connect again before changing global NFS settings.',
    NfsSettingsExceptionReason.unsupportedVersion =>
      'Native global NFS settings require stable TrueNAS 25.10.',
    NfsSettingsExceptionReason.unavailableMethod =>
      'Required public NFS configuration methods are unavailable.',
    NfsSettingsExceptionReason.busy =>
      'Another operation or uncertain outcome prevents NFS changes.',
    NfsSettingsExceptionReason.staleReview => 'The review, connection, configuration or dependencies changed. No NFS update was submitted.',
    NfsSettingsExceptionReason.invalidRequest => 'Resolve the displayed NFS compatibility and stopped-service restrictions.',
    NfsSettingsExceptionReason.invalidResponse =>
      'NFS configuration and dependencies could not be safely verified.',
    NfsSettingsExceptionReason.unavailable => 'NFS information is unavailable. Remote and protected details were withheld.',
  };
  @override
  String toString() => userMessage;
}

const _nfsSettingsReads = {
  ..._powerReads,
  'auth.me',
  'nfs.config',
  'nfs.bindip_choices',
  'service.query',
  'sharing.nfs.query',
  'directoryservices.config',
};
const _nfsSettingsKeys = {
  'id',
  'servers',
  'allow_nonroot',
  'protocols',
  'v4_krb',
  'v4_domain',
  'bindip',
  'mountd_port',
  'rpcstatd_port',
  'rpclockd_port',
  'mountd_log',
  'statd_lockd_log',
  'v4_krb_enabled',
  'userd_manage_gids',
  'keytab_has_nfs_spn',
  'managed_nfsd',
  'rdma',
};

final class _NfsSettingsRead {
  const _NfsSettingsRead(this.inventory, this.config, this.dependencies);
  final NfsSettingsInventory inventory;
  final Map<String, Object?> config;
  final String dependencies;
}

final class _NfsSettingsLease {
  const _NfsSettingsLease(this.created, this.proof);
  final DateTime created;
  final String proof;
}

final class _SessionNfsSettings {
  _SessionNfsSettings({
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
  final _inventories = <NfsSettingsInventory, String>{},
      _reviews = <NfsSettingsReview, _NfsSettingsLease>{};
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

  bool _method(String name) {
    final r = _metadata[name];
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

  NfsSettingsCapabilities get capabilities => NfsSettingsCapabilities(
    connected: !_disposed && isCurrent(),
    versionSupported: _version,
    available: _nfsSettingsReads.every(_method),
    canUpdate: _method('nfs.update'),
  );
  void _guard({bool write = false}) {
    if (_disposed || !isCurrent()) {
      _nfsSettingsThrow(NfsSettingsExceptionReason.notAuthenticated);
    }
    if (!_current()) _nfsSettingsThrow(NfsSettingsExceptionReason.staleReview);
    if (!_version) {
      _nfsSettingsThrow(NfsSettingsExceptionReason.unsupportedVersion);
    }
    if (!capabilities.supported || write && !capabilities.canConfigure) {
      _nfsSettingsThrow(NfsSettingsExceptionReason.unavailableMethod);
    }
  }

  void dispose() {
    _disposed = true;
    _inventories.clear();
    _reviews.clear();
    _proofKey.fillRange(0, _proofKey.length, 0);
  }

  String _hash(Object? value) {
    final bytes = utf8.encode(jsonEncode(_npCanonical(value)));
    try {
      return crypto.Hmac(crypto.sha256, _proofKey).convert(bytes).toString();
    } finally {
      bytes.fillRange(0, bytes.length, 0);
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

  Future<_NfsSettingsRead> _read() async {
    final admin = _configurationBackupAdmin(await _call('auth.me', const []));
    final power = await _powerReader._read();
    final raw = await _call('nfs.config', const []),
        config = _nfsSettingsConfig(raw);
    // This is a local configuration read, not directoryservices.status/health.
    // Secret-bearing raw data is reduced to a keyed proof within this invocation.
    final directory = await _call('directoryservices.config', const []);
    if (directory is! Map ||
        directory['enable'] is! bool ||
        !directory.containsKey('service_type') ||
        !directory.containsKey('credential') ||
        !directory.containsKey('configuration') ||
        !directory.containsKey('kerberos_realm') ||
        jsonEncode(directory).length > 1024 * 1024) {
      _nfsSettingsThrow(NfsSettingsExceptionReason.invalidResponse);
    }
    final directoryConfigured =
        directory['enable'] != false ||
        directory['service_type'] != null ||
        directory['credential'] != null ||
        directory['configuration'] != null ||
        directory['kerberos_realm'] != null;
    final directoryProof = _hash(directory);
    final choicesRaw = await _call('nfs.bindip_choices', const []);
    if (choicesRaw is! Map ||
        choicesRaw.length > 128 ||
        choicesRaw.entries.any(
          (e) =>
              e.key is! String ||
              e.key != e.value ||
              !_nfsSettingsAddress(e.key as String),
        )) {
      _nfsSettingsThrow(NfsSettingsExceptionReason.invalidResponse);
    }
    final choices = choicesRaw.keys.cast<String>().toList()..sort();
    final exportsRaw = await _call('sharing.nfs.query', const [
      [],
      {
        'limit': 257,
        'select': ['id', 'enabled', 'security'],
        'extra': {'retrieve_locked_info': false},
      },
    ]);
    if (exportsRaw is! List || exportsRaw.length > 256) {
      _nfsSettingsThrow(NfsSettingsExceptionReason.invalidResponse);
    }
    final exports = <NfsConfiguredExport>[];
    for (final r in exportsRaw) {
      if (r is! Map ||
          !_powerId(r['id']) ||
          r['enabled'] is! bool ||
          r['security'] is! List ||
          (r['security'] as List).length > 4 ||
          (r['security'] as List).any(
            (v) => !const {'SYS', 'KRB5', 'KRB5I', 'KRB5P'}.contains(v),
          ) ||
          (r['security'] as List).toSet().length !=
              (r['security'] as List).length ||
          exports.any((e) => e.id == r['id'])) {
        _nfsSettingsThrow(NfsSettingsExceptionReason.invalidResponse);
      }
      exports.add(
        NfsConfiguredExport(
          id: r['id'] as int,
          enabled: r['enabled'] as bool,
          security: (r['security'] as List).cast<String>(),
        ),
      );
    }
    exports.sort((a, b) => a.id.compareTo(b.id));
    final serviceRaw = await _call('service.query', const [
      [
        ['service', '=', 'nfs'],
      ],
      {
        'limit': 2,
        'select': ['id', 'service', 'state', 'enable'],
      },
    ]);
    if (serviceRaw is! List ||
        serviceRaw.length != 1 ||
        serviceRaw.single is! Map) {
      _nfsSettingsThrow(NfsSettingsExceptionReason.invalidResponse);
    }
    final service = serviceRaw.single as Map;
    if (!_powerId(service['id']) ||
        service['service'] != 'nfs' ||
        service['enable'] is! bool ||
        !const {
          'RUNNING',
          'STOPPED',
          'CRASHED',
          'UNKNOWN',
        }.contains(service['state'])) {
      _nfsSettingsThrow(NfsSettingsExceptionReason.invalidResponse);
    }
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
      _nfsSettingsThrow(NfsSettingsExceptionReason.staleReview);
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
    final inventory = NfsSettingsInventory(
      readiness: readiness,
      config: config,
      exports: exports,
      serviceState: service['state'] as String,
      serviceEnabled: service['enable'] as bool,
      bindChoices: choices,
      directoryConfigured: directoryConfigured,
    );
    return _NfsSettingsRead(
      inventory,
      Map<String, Object?>.from(raw as Map),
      _hash([
        directoryProof,
        choices,
        [
          service['id'],
          service['service'],
          service['state'],
          service['enable'],
        ],
        for (final e in exports) [e.id, e.enabled, e.security],
      ]),
    );
  }

  String _proof(_NfsSettingsRead r) => _hash([
    _deliveryBaseProof(r.inventory.readiness),
    r.config,
    r.dependencies,
  ]);
  Future<NfsSettingsInventory> load() async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      _nfsSettingsThrow(NfsSettingsExceptionReason.busy);
    }
    _calling = true;
    _inventories.clear();
    _reviews.clear();
    try {
      final r = await _read();
      if (isOtherMutationBusy()) {
        _nfsSettingsThrow(NfsSettingsExceptionReason.busy);
      }
      _inventories[r.inventory] = _proof(r);
      return r.inventory;
    } on NfsSettingsException {
      rethrow;
    } on Object {
      _nfsSettingsThrow(NfsSettingsExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<NfsSettingsReview> review(NfsSettingsRequest request) async {
    _guard(write: true);
    if (isBusy || isOtherMutationBusy()) {
      _nfsSettingsThrow(NfsSettingsExceptionReason.busy);
    }
    final proof = _inventories[request.inventory];
    if (proof == null || request.inventory.endpoint != _endpoint) {
      _nfsSettingsThrow(NfsSettingsExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      _nfsSettingsThrow(NfsSettingsExceptionReason.invalidRequest);
    }
    _calling = true;
    _reviews.clear();
    try {
      final fresh = await _read();
      if (_proof(fresh) != proof ||
          fresh.inventory.blockedReason != null ||
          isOtherMutationBusy()) {
        _nfsSettingsThrow(NfsSettingsExceptionReason.staleReview);
      }
      final review = NfsSettingsReview(
        request: request,
        endpoint: _endpoint,
        warnings: const [
          'Global NFS updates write configuration, regenerate rc configuration and request service restart only if NFS is running. This workspace requires STOPPED, but checks are not atomic: another administrator starting it can cause a restart, client interruption and export regeneration after the final check. No start/stop command is sent here.',
          'A running restart may resolve export hosts/users/groups and clean generated export files or ZFS sharenfs properties. Keep NFS stopped and coordinate client/export recovery independently. A stopped configuration update is not a dry run and still has server-side effects.',
          'Changing mountd logging additionally reloads syslogd after the configuration/service update. A later error does not roll back an earlier database write. Thread counts are configuration, not measured concurrency or throughput.',
          'Protocol and binding changes require no enabled exports. Disabled exports still constrain NFSV4 removal when using Kerberos security. Bind edits support only currently available static IPv4 choices; empty binding listens on all interfaces when started and changes exposure.',
          'Ports, insecure non-root source-port acceptance, group-list management, NFSV4 domain, Kerberos, keytabs, RDMA, directory services, individual exports and service boot enablement are not changed. Kerberos/keytab/RDMA or configured directory-service profiles are protected. A keytab capability does not mean Kerberos is forced for every export.',
          'Readback verifies configured values only, not effective exports, client mounts, access, firewall reachability, identity mapping, security or performance. Start the service only through an independently reviewed service workflow; no automatic start, reconnect, probe, polling or retry occurs.',
        ],
      );
      _reviews[review] = _NfsSettingsLease(_now(), proof);
      return review;
    } on NfsSettingsException {
      rethrow;
    } on Object {
      _nfsSettingsThrow(NfsSettingsExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<NfsSettingsResult> execute(
    NfsSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    final lease = _reviews.remove(review);
    var sent = false, owns = false;
    bool age() {
      if (lease == null) return false;
      final d = _now().difference(lease.created);
      return !d.isNegative && d <= const Duration(minutes: 5);
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
        _nfsSettingsThrow(NfsSettingsExceptionReason.busy);
      }
      if (lease == null ||
          !authorized() ||
          !age() ||
          review.endpoint != _endpoint ||
          confirmation != review.target ||
          review.request.validationError != null) {
        _nfsSettingsThrow(NfsSettingsExceptionReason.staleReview);
      }
      _calling = true;
      owns = true;
      _operationCurrent = isCurrent;
      final before = await _read();
      if (_proof(before) != lease.proof ||
          before.inventory.blockedReason != null ||
          isOtherMutationBusy()) {
        _nfsSettingsThrow(NfsSettingsExceptionReason.staleReview);
      }
      _guard(write: true);
      if (!age() || !authorized()) {
        _nfsSettingsThrow(NfsSettingsExceptionReason.staleReview);
      }
      final patch = _nfsSettingsPatch(review.request);
      sent = true;
      final raw = await client
          .call('nfs.update', id: nextId(), params: [patch])
          .timeout(requestTimeout);
      _guard(write: true);
      final receipt = _nfsSettingsConfig(raw);
      final expected = {...before.config, ...patch};
      expected['managed_nfsd'] = review.request.settings.serverThreads == null;
      expected['servers'] =
          review.request.settings.serverThreads ?? receipt.reportedServers;
      if (_hash(expected) != _hash(raw)) return _unknown();
      final after = await _read();
      if (after.inventory.blockedReason != null ||
          _deliveryBaseProof(before.inventory.readiness) !=
              _deliveryBaseProof(after.inventory.readiness) ||
          before.dependencies != after.dependencies ||
          _hash(raw) != _hash(after.config) ||
          isOtherMutationBusy()) {
        return _unknown();
      }
      _inventories.clear();
      _reviews.clear();
      return const NfsSettingsResult(
        NfsSettingsOutcome.completed,
        'Expected NFS configuration and protected dependencies matched a fresh readback. This does not prove service operation, exports, client access or performance. NFS was not started by this workflow.',
      );
    } on Object catch (error) {
      if (sent) return _unknown();
      return NfsSettingsResult(
        NfsSettingsOutcome.rejected,
        error is NfsSettingsException
            ? error.userMessage
            : 'NFS preflight expired or failed. No update was submitted.',
      );
    } finally {
      if (owns) {
        _operationCurrent = null;
        _calling = false;
      }
    }
  }

  NfsSettingsResult _unknown() {
    _terminal = true;
    _inventories.clear();
    _reviews.clear();
    return const NfsSettingsResult(
      NfsSettingsOutcome.unknown,
      'NFS configuration or service-side effects may already have changed. The outcome is unverified, not rollback or permission to retry. Inspect the original server independently; further writes are fenced.',
    );
  }
}

Never _nfsSettingsThrow(NfsSettingsExceptionReason reason) =>
    throw NfsSettingsException(reason);
bool _nfsSettingsAddress(String v) {
  if (v.isEmpty || v.length > 64 || v.trim() != v) return false;
  if (v.contains(':')) {
    if (!RegExp(r'^[0-9a-fA-F:.]+$').hasMatch(v)) return false;
    try {
      Uri.parse('http://[$v]/');
      return true;
    } on FormatException {
      return false;
    }
  }
  return RegExp(r'^[0-9.]+$').hasMatch(v) &&
      v.split('.').length == 4 &&
      v
          .split('.')
          .every(
            (p) =>
                p.isNotEmpty &&
                int.tryParse(p) != null &&
                int.parse(p) >= 0 &&
                int.parse(p) <= 255 &&
                (p == '0' || !p.startsWith('0')),
          );
}

String _nfsSettingsValues(NfsGlobalSettings s) => jsonEncode([
  s.serverThreads,
  s.protocols,
  s.bindAddresses,
  s.mountdLog,
  s.statdLockdLog,
]);
Map<String, Object?> _nfsSettingsPatch(NfsSettingsRequest r) {
  final old = r.inventory.config.settings, s = r.settings;
  return {
    if (s.serverThreads != old.serverThreads) 'servers': s.serverThreads,
    if (r.changesProtocols) 'protocols': s.protocols,
    if (r.changesBindings) 'bindip': s.bindAddresses,
    if (s.mountdLog != old.mountdLog) 'mountd_log': s.mountdLog,
    if (s.statdLockdLog != old.statdLockdLog)
      'statd_lockd_log': s.statdLockdLog,
  };
}

NfsConfigSnapshot _nfsSettingsConfig(Object? raw) {
  if (raw is! Map ||
      raw.length != _nfsSettingsKeys.length ||
      raw.keys.any((k) => !_nfsSettingsKeys.contains(k)) ||
      !_powerId(raw['id']) ||
      raw['servers'] is! int ||
      (raw['servers'] as int) < 1 ||
      (raw['servers'] as int) > 256 ||
      const [
        'managed_nfsd',
        'allow_nonroot',
        'v4_krb',
        'mountd_log',
        'statd_lockd_log',
        'v4_krb_enabled',
        'userd_manage_gids',
        'keytab_has_nfs_spn',
        'rdma',
      ].any((k) => raw[k] is! bool) ||
      raw['v4_domain'] is! String ||
      !_emailText(raw['v4_domain'] as String, 1024) ||
      raw['protocols'] is! List ||
      raw['bindip'] is! List ||
      (raw['protocols'] as List).any((v) => v is! String) ||
      (raw['bindip'] as List).any((v) => v is! String) ||
      const ['mountd_port', 'rpcstatd_port', 'rpclockd_port'].any(
        (k) =>
            raw[k] != null &&
            (raw[k] is! int ||
                (raw[k] as int) < 1 ||
                (raw[k] as int) > 65535 ||
                raw[k] == 20049),
      ) ||
      raw['managed_nfsd'] == true && (raw['servers'] as int) > 32 ||
      raw['v4_krb_enabled'] !=
          (raw['v4_krb'] == true || raw['keytab_has_nfs_spn'] == true)) {
    _nfsSettingsThrow(NfsSettingsExceptionReason.invalidResponse);
  }
  final settings = NfsGlobalSettings(
    serverThreads: raw['managed_nfsd'] == true ? null : raw['servers'] as int,
    protocols: (raw['protocols'] as List).cast<String>(),
    bindAddresses: (raw['bindip'] as List).cast<String>(),
    mountdLog: raw['mountd_log'] as bool,
    statdLockdLog: raw['statd_lockd_log'] as bool,
  );
  if (settings.validationError != null) {
    _nfsSettingsThrow(NfsSettingsExceptionReason.invalidResponse);
  }
  return NfsConfigSnapshot(
    id: raw['id'] as int,
    settings: settings,
    reportedServers: raw['servers'] as int,
    managedNfsd: raw['managed_nfsd'] as bool,
    allowNonroot: raw['allow_nonroot'] as bool,
    v4Krb: raw['v4_krb'] as bool,
    v4Domain: raw['v4_domain'] as String,
    v4KrbEnabled: raw['v4_krb_enabled'] as bool,
    keytabHasNfsSpn: raw['keytab_has_nfs_spn'] as bool,
    rdma: raw['rdma'] as bool,
    userdManageGids: raw['userd_manage_gids'] as bool,
    mountdPort: raw['mountd_port'] as int?,
    rpcstatdPort: raw['rpcstatd_port'] as int?,
    rpclockdPort: raw['rpclockd_port'] as int?,
  );
}
