part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedSmbSettingsSession {
  SmbSettingsCapabilities get smbSettingsCapabilities;
  Future<SmbSettingsInventory> loadSmbSettings();
  Future<SmbSettingsReview> reviewSmbSettings(SmbSettingsRequest request);
  Future<SmbSettingsResult> executeSmbSettings(
    SmbSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  });
}

enum SmbTransportEncryption { defaultMode, negotiate, desired, required }

final class SmbSettingsCapabilities {
  const SmbSettingsCapabilities({
    this.connected = false,
    this.versionSupported = false,
    this.available = false,
    this.canUpdate = false,
  });
  const SmbSettingsCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      canUpdate = false;
  final bool connected, versionSupported, available, canUpdate;
  bool get supported => connected && versionSupported && available;
  bool get canConfigure => supported && canUpdate;
  String? get blockedReason => !connected
      ? 'Connect to inspect global SMB settings.'
      : !versionSupported
      ? 'Native global SMB settings require stable TrueNAS 25.10.'
      : !available
      ? 'Required public SMB configuration and readiness reads are unavailable.'
      : null;
}

final class SmbGlobalSettings {
  const SmbGlobalSettings({
    required this.netbiosName,
    required this.workgroup,
    required this.description,
    required this.multichannel,
    required this.encryption,
  });
  final String netbiosName, workgroup, description;
  final bool multichannel;
  final SmbTransportEncryption encryption;
  String? get validationError =>
      !_smbSettingsName(netbiosName) || !_smbSettingsName(workgroup)
      ? 'Use 1–15 ASCII letters, digits or hyphens, beginning with a letter; reserved NetBIOS names are not permitted.'
      : netbiosName.toLowerCase() == workgroup.toLowerCase()
      ? 'The server name and workgroup must differ.'
      : !_emailText(description, 120)
      ? 'Use a description up to 120 characters without control characters.'
      : null;
}

final class SmbConfigSnapshot {
  SmbConfigSnapshot({
    required this.id,
    required this.settings,
    required List<String> aliases,
    required this.smb1Enabled,
    required this.ntlmv1Enabled,
    required this.appleExtensions,
    required this.localMaster,
    required this.syslogEnabled,
    required this.debugEnabled,
    required this.auxiliaryParametersPresent,
    required this.serverSidKnown,
    required this.defaultGuestAccount,
    required this.privilegedGroupConfigured,
  }) : aliases = List.unmodifiable(aliases);
  final int id;
  final SmbGlobalSettings settings;
  final List<String> aliases;
  final bool smb1Enabled,
      ntlmv1Enabled,
      appleExtensions,
      localMaster,
      syslogEnabled,
      debugEnabled,
      auxiliaryParametersPresent,
      serverSidKnown,
      defaultGuestAccount,
      privilegedGroupConfigured;
  String? get blockedReason => auxiliaryParametersPresent
      ? 'Auxiliary SMB parameters are protected; use the full TrueNAS workflow.'
      : smb1Enabled || ntlmv1Enabled
      ? 'Legacy SMB1 or NTLMv1 is enabled. This workspace cannot preserve or enable that weak profile; harden it independently first.'
      : !serverSidKnown
      ? 'An existing valid server SID is required; this workspace does not initialize or replace SMB identity.'
      : !defaultGuestAccount || privilegedGroupConfigured
      ? 'Custom guest or privileged SMB account mappings are protected in this bounded workspace.'
      : settings.validationError;
}

final class SmbConfiguredShare {
  const SmbConfiguredShare({required this.id, required this.enabled});
  final int id;
  final bool enabled;
}

final class SmbSettingsInventory {
  SmbSettingsInventory({
    required this.readiness,
    required this.config,
    required List<SmbConfiguredShare> shares,
    this.directoryConfigured,
    this.securityManaged,
    this.appleDependentShareCount,
  }) : shares = List.unmodifiable(shares);
  final AlertSettingsInventory readiness;
  final SmbConfigSnapshot config;
  final List<SmbConfiguredShare> shares;
  final bool? directoryConfigured, securityManaged;
  final int? appleDependentShareCount;
  String get endpoint => readiness.endpoint;
  String get hostId => readiness.hostId;
  String get bootId => readiness.bootId;
  String get currentVersion => readiness.currentVersion;
  String? get readinessBlockedReason => readiness.readinessBlockedReason;
  String? get blockedReason =>
      readinessBlockedReason ??
      config.blockedReason ??
      (directoryConfigured != false
          ? 'An unconfigured, disabled directory-service profile must be verified. No directory health probe is performed.'
          : securityManaged != false
          ? 'FIPS/STIG security-managed or unknown profiles require the full TrueNAS workflow.'
          : appleDependentShareCount == null
          ? 'Apple-dependent share configuration could not be verified.'
          : !config.appleExtensions && appleDependentShareCount! > 0
          ? 'Existing Apple-dependent shares require Apple extensions; repair this separately.'
          : null);
}

final class SmbSettingsRequest {
  const SmbSettingsRequest({required this.inventory, required this.settings});
  final SmbSettingsInventory inventory;
  final SmbGlobalSettings settings;
  bool get changesIdentity =>
      settings.netbiosName != inventory.config.settings.netbiosName ||
      settings.workgroup != inventory.config.settings.workgroup;
  bool get strengthensEncryption =>
      settings.encryption != inventory.config.settings.encryption;
  String get target =>
      'UPDATE SMB ${inventory.hostId} ${inventory.config.settings.netbiosName}';
  String? get validationError {
    if (inventory.blockedReason != null) return inventory.blockedReason;
    if (settings.validationError != null) return settings.validationError;
    if (inventory.config.aliases.any(
      (name) => name.toLowerCase() == settings.workgroup.toLowerCase(),
    )) {
      return 'The workgroup conflicts with a protected NetBIOS alias.';
    }
    if (settings.netbiosName != inventory.config.settings.netbiosName &&
        inventory.config.aliases.any(
          (name) => name.toLowerCase() == settings.netbiosName.toLowerCase(),
        )) {
      return 'The new server name conflicts with an existing protected alias.';
    }
    if (strengthensEncryption &&
        _smbEncryptionRank(settings.encryption) <=
            _smbEncryptionRank(inventory.config.settings.encryption)) {
      return 'Encryption may only remain unchanged or become strictly stronger; downgrades and DEFAULT/NEGOTIATE swaps are protected.';
    }
    if (_smbSettingsProof(settings) ==
        _smbSettingsProof(inventory.config.settings)) {
      return 'Choose a changed global SMB setting.';
    }
    return null;
  }
}

final class SmbSettingsReview {
  SmbSettingsReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final SmbSettingsRequest request;
  final String endpoint;
  final List<String> warnings;
  String get target => request.target;
}

enum SmbSettingsOutcome { completed, rejected, unknown }

final class SmbSettingsResult {
  const SmbSettingsResult(this.outcome, this.message);
  final SmbSettingsOutcome outcome;
  final String message;
}

enum SmbSettingsExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class SmbSettingsException implements Exception {
  const SmbSettingsException(this.reason);
  final SmbSettingsExceptionReason reason;
  String get userMessage => switch (reason) {
    SmbSettingsExceptionReason.notAuthenticated =>
      'Connect again before changing global SMB settings.',
    SmbSettingsExceptionReason.unsupportedVersion =>
      'Native global SMB settings require stable TrueNAS 25.10.',
    SmbSettingsExceptionReason.unavailableMethod =>
      'Required public SMB configuration methods are unavailable.',
    SmbSettingsExceptionReason.busy =>
      'Another operation or uncertain outcome prevents SMB changes.',
    SmbSettingsExceptionReason.staleReview => 'The issued review, configuration, dependencies or connection changed. No SMB update was submitted.',
    SmbSettingsExceptionReason.invalidRequest =>
      'Resolve the displayed SMB profile and compatibility restrictions.',
    SmbSettingsExceptionReason.invalidResponse =>
      'SMB configuration could not be safely verified.',
    SmbSettingsExceptionReason.unavailable => 'SMB configuration is unavailable. Remote and protected details were withheld.',
  };
  @override
  String toString() => userMessage;
}

const _smbSettingsReads = {
  ..._powerReads,
  'auth.me',
  'smb.config',
  'directoryservices.config',
  'system.security.config',
  'sharing.smb.query',
};
const _smbEditableKeys = {
  'netbiosname',
  'workgroup',
  'description',
  'multichannel',
  'encryption',
};
const _smbConfigKeys = {
  'id',
  'netbiosname',
  'netbiosalias',
  'workgroup',
  'description',
  'enable_smb1',
  'unixcharset',
  'localmaster',
  'syslog',
  'aapl_extensions',
  'admin_group',
  'guest',
  'filemask',
  'dirmask',
  'ntlmv1_auth',
  'multichannel',
  'encryption',
  'bindip',
  'server_sid',
  'smb_options',
  'debug',
};

final class _SmbRead {
  const _SmbRead(this.inventory, this.protectedProof, this.dependencyProof);
  final SmbSettingsInventory inventory;
  final String protectedProof;
  final String dependencyProof;
}

final class _SmbLease {
  const _SmbLease(this.created, this.proof);
  final DateTime created;
  final String proof;
}

final class _SessionSmbSettings {
  _SessionSmbSettings({
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
  final Uint8List _proofKey = Uint8List.fromList(
    List.generate(32, (_) => math.Random.secure().nextInt(256)),
  );
  final Map<SmbSettingsInventory, String> _inventories = {};
  final Map<SmbSettingsReview, _SmbLease> _reviews = {};
  bool _calling = false, _terminal = false, _disposed = false;
  bool Function()? _operationCurrent;
  bool get isBusy => _calling || _terminal;
  void dispose() {
    _disposed = true;
    _inventories.clear();
    _reviews.clear();
    _proofKey.fillRange(0, _proofKey.length, 0);
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

  SmbSettingsCapabilities get capabilities => SmbSettingsCapabilities(
    connected: !_disposed && isCurrent(),
    versionSupported: _version,
    available: _smbSettingsReads.every(_method),
    canUpdate: _method('smb.update'),
  );
  void _guard({bool write = false}) {
    if (_disposed || !isCurrent()) {
      _smbThrow(SmbSettingsExceptionReason.notAuthenticated);
    }
    if (!_current()) _smbThrow(SmbSettingsExceptionReason.staleReview);
    if (!_version) _smbThrow(SmbSettingsExceptionReason.unsupportedVersion);
    if (!capabilities.supported || write && !capabilities.canConfigure) {
      _smbThrow(SmbSettingsExceptionReason.unavailableMethod);
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
      _smbThrow(SmbSettingsExceptionReason.invalidResponse);
    }
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(_smbCanonical(value))),
    );
    try {
      return crypto.Hmac(crypto.sha256, _proofKey).convert(bytes).toString();
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  (SmbConfigSnapshot, String) _config(Object? raw) {
    if (raw is! Map ||
        raw.length != _smbConfigKeys.length ||
        !raw.keys.toSet().containsAll(_smbConfigKeys) ||
        !_powerId(raw['id'])) {
      _smbThrow(SmbSettingsExceptionReason.invalidResponse);
    }
    for (final field in [
      'enable_smb1',
      'localmaster',
      'syslog',
      'aapl_extensions',
      'ntlmv1_auth',
      'multichannel',
      'debug',
    ]) {
      if (raw[field] is! bool) {
        _smbThrow(SmbSettingsExceptionReason.invalidResponse);
      }
    }
    for (final field in [
      'netbiosname',
      'workgroup',
      'description',
      'unixcharset',
      'guest',
      'filemask',
      'dirmask',
    ]) {
      if (raw[field] is! String ||
          !_emailText(
            raw[field] as String,
            field == 'description' ? 4096 : 256,
          )) {
        _smbThrow(SmbSettingsExceptionReason.invalidResponse);
      }
    }
    final aux = raw['smb_options'];
    if (aux is! String || aux.length > 65536) {
      _smbThrow(SmbSettingsExceptionReason.invalidResponse);
    }
    final aliases = raw['netbiosalias'],
        bind = raw['bindip'],
        group = raw['admin_group'],
        sid = raw['server_sid'];
    if (aliases is! List ||
        aliases.length > 64 ||
        !aliases.every(
          (v) => v is String && _emailText(v, 15) && v.isNotEmpty,
        ) ||
        aliases.toSet().length != aliases.length ||
        bind is! List ||
        bind.length > 64 ||
        !bind.every((v) => v is String && _emailText(v, 128)) ||
        group != null && (group is! String || !_emailText(group, 256)) ||
        sid != null && (sid is! String || !_emailText(sid, 256))) {
      _smbThrow(SmbSettingsExceptionReason.invalidResponse);
    }
    final settings = SmbGlobalSettings(
      netbiosName: raw['netbiosname'] as String,
      workgroup: raw['workgroup'] as String,
      description: raw['description'] as String,
      multichannel: raw['multichannel'] as bool,
      encryption: _smbEncryption(raw['encryption']),
    );
    return (
      SmbConfigSnapshot(
        id: raw['id'] as int,
        settings: settings,
        aliases: aliases.cast<String>(),
        smb1Enabled: raw['enable_smb1'] as bool,
        ntlmv1Enabled: raw['ntlmv1_auth'] as bool,
        appleExtensions: raw['aapl_extensions'] as bool,
        localMaster: raw['localmaster'] as bool,
        syslogEnabled: raw['syslog'] as bool,
        debugEnabled: raw['debug'] as bool,
        auxiliaryParametersPresent: aux.isNotEmpty,
        serverSidKnown: _smbSid(sid),
        defaultGuestAccount: raw['guest'] == 'nobody',
        privilegedGroupConfigured: group != null && group != '',
      ),
      _digest({
        for (final entry in raw.entries)
          if (!_smbEditableKeys.contains(entry.key)) entry.key: entry.value,
      }),
    );
  }

  Future<_SmbRead> _read() async {
    final admin = _configurationBackupAdmin(await _call('auth.me', const []));
    final power = await _power._read();
    final config = _config(await _call('smb.config', const []));
    // ConfigService has no select support. Raw dependencies never escape this read;
    // only bounded, session-keyed proofs survive it. No raw secret is in a DTO.
    bool? directory;
    final ds = await _call('directoryservices.config', const []);
    final directoryProof = _digest(ds);
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
    bool? security;
    final sec = await _call('system.security.config', const []);
    final securityProof = _digest(sec);
    if (sec is Map &&
        sec['enable_fips'] is bool &&
        sec['enable_gpos_stig'] is bool) {
      security = sec['enable_fips'] == true || sec['enable_gpos_stig'] == true;
    }
    final rawShares = await _call('sharing.smb.query', const [
      [],
      {
        'limit': 257,
        'select': ['id', 'enabled'],
        'extra': {'retrieve_locked_info': false},
      },
    ]);
    if (rawShares is! List || rawShares.length > 256) {
      _smbThrow(SmbSettingsExceptionReason.invalidResponse);
    }
    final shares = <SmbConfiguredShare>[], ids = <int>{};
    for (final row in rawShares) {
      if (row is! Map ||
          !_powerId(row['id']) ||
          row['enabled'] is! bool ||
          !ids.add(row['id'] as int)) {
        _smbThrow(SmbSettingsExceptionReason.invalidResponse);
      }
      shares.add(
        SmbConfiguredShare(
          id: row['id'] as int,
          enabled: row['enabled'] as bool,
        ),
      );
    }
    shares.sort((a, b) => a.id.compareTo(b.id));
    final count = await _call('sharing.smb.query', const [
      [
        [
          'OR',
          [
            ['options.afp', '=', true],
            ['options.timemachine', '=', true],
            ['purpose', '=', 'TIMEMACHINE_SHARE'],
            ['purpose', '=', 'FCP_SHARE'],
          ],
        ],
      ],
      {
        'count': true,
        'extra': {'retrieve_locked_info': false},
      },
    ]);
    if (count is! int || count < 0 || count > shares.length) {
      _smbThrow(SmbSettingsExceptionReason.invalidResponse);
    }
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
      _smbThrow(SmbSettingsExceptionReason.staleReview);
    }
    return _SmbRead(
      SmbSettingsInventory(
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
        config: config.$1,
        shares: shares,
        directoryConfigured: directory,
        securityManaged: security,
        appleDependentShareCount: count,
      ),
      config.$2,
      jsonEncode([directoryProof, securityProof]),
    );
  }

  Future<SmbSettingsInventory> load() async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      _smbThrow(SmbSettingsExceptionReason.busy);
    }
    _calling = true;
    _inventories.clear();
    _reviews.clear();
    try {
      final read = await _read();
      if (isOtherMutationBusy()) _smbThrow(SmbSettingsExceptionReason.busy);
      _inventories[read.inventory] = _smbReadProof(read);
      return read.inventory;
    } on SmbSettingsException {
      rethrow;
    } on Object {
      _smbThrow(SmbSettingsExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<SmbSettingsReview> review(SmbSettingsRequest request) async {
    _guard(write: true);
    if (isBusy || isOtherMutationBusy()) {
      _smbThrow(SmbSettingsExceptionReason.busy);
    }
    final proof = _inventories[request.inventory];
    if (proof == null || request.inventory.endpoint != _endpoint) {
      _smbThrow(SmbSettingsExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      _smbThrow(SmbSettingsExceptionReason.invalidRequest);
    }
    _calling = true;
    _reviews.clear();
    try {
      final before = await _read();
      if (_smbReadProof(before) != proof ||
          before.inventory.blockedReason != null ||
          isOtherMutationBusy()) {
        _smbThrow(SmbSettingsExceptionReason.staleReview);
      }
      final review = SmbSettingsReview(
        request: request,
        endpoint: _endpoint,
        warnings: const [
          'Only changed server name, workgroup, description, multichannel and transport-encryption fields are submitted. Aliases, Apple extensions, bind addresses, charset, masks, guest/admin mappings, logging and all other configuration are preserved. Directory-integrated, HA, FIPS/STIG-managed, legacy-protocol, custom-account and auxiliary-parameter profiles are protected.',
          'Every update commits configuration before regenerating Samba configuration and requesting an SMB restart. Running client sessions and transfers can be interrupted; a stopped service still has configuration regenerated. No service start, stop, probe or share update is sent separately.',
          'Changing the server name additionally synchronizes the existing server SID and local password database, flushes identity caches and toggles configured network announcements. Workgroup/name changes may require client remapping and independently coordinated discovery or directory changes. An existing SID is preserved; runtime identity and client access are not verified.',
          'Stronger encryption can exclude incompatible clients, and multichannel can change client network paths and resource use. DEFAULT currently negotiates like NEGOTIATE; neither means every session is encrypted. Configuration readback does not prove encryption, throughput, active connections or data availability.',
          'Regeneration performs backend account/group resolution and share validation, and can omit invalid audit shares from generated configuration. Configured share counts include disabled rows and are not effective-access or health measurements. Only safe ID/enabled headers and a separate Apple-dependency count are read; paths, credentials and auxiliary parameters are withheld.',
          'Readiness, dependency snapshots and full configuration readback are bounded and non-atomic, without a server-side lock against other administrators. A database write may precede later errors: an uncertain result is not rollback or permission to retry. Inspect the original server independently before any further mutation.',
        ],
      );
      _reviews[review] = _SmbLease(_now(), proof);
      return review;
    } on SmbSettingsException {
      rethrow;
    } on Object {
      _smbThrow(SmbSettingsExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<SmbSettingsResult> execute(
    SmbSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  }) async {
    final lease = _reviews.remove(review);
    var sent = false, owns = false;
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
      _guard(write: true);
      if (isBusy || isOtherMutationBusy()) {
        _smbThrow(SmbSettingsExceptionReason.busy);
      }
      if (lease == null ||
          !authorized() ||
          !ageValid() ||
          review.endpoint != _endpoint ||
          confirmation != review.target ||
          review.request.validationError != null) {
        _smbThrow(SmbSettingsExceptionReason.staleReview);
      }
      _calling = true;
      owns = true;
      _operationCurrent = isCurrent;
      final before = await _read();
      if (_smbReadProof(before) != lease.proof ||
          before.inventory.blockedReason != null ||
          isOtherMutationBusy()) {
        _smbThrow(SmbSettingsExceptionReason.staleReview);
      }
      final patch = _smbPatch(
        before.inventory.config.settings,
        review.request.settings,
      );
      _guard(write: true);
      if (!ageValid()) _smbThrow(SmbSettingsExceptionReason.staleReview);
      sent = true;
      final receipt = _config(
        await client
            .call('smb.update', id: nextId(), params: [patch])
            .timeout(requestTimeout),
      );
      _guard(write: true);
      if (receipt.$2 != before.protectedProof ||
          _smbSettingsProof(receipt.$1.settings) !=
              _smbSettingsProof(review.request.settings)) {
        return _unknown();
      }
      final after = await _read();
      if (after.protectedProof != before.protectedProof ||
          after.dependencyProof != before.dependencyProof ||
          _smbDependencyProof(after.inventory) !=
              _smbDependencyProof(before.inventory) ||
          _smbSettingsProof(after.inventory.config.settings) !=
              _smbSettingsProof(review.request.settings) ||
          after.inventory.blockedReason != null ||
          isOtherMutationBusy()) {
        return _unknown();
      }
      _inventories.clear();
      _reviews.clear();
      return const SmbSettingsResult(
        SmbSettingsOutcome.completed,
        'Expected saved global SMB fields and preserved configuration matched the response and independent readback. Client connectivity, runtime encryption, password synchronization and share availability were not verified.',
      );
    } on Object catch (error) {
      if (sent) return _unknown();
      return SmbSettingsResult(
        SmbSettingsOutcome.rejected,
        error is SmbSettingsException ? error.userMessage : 'SMB authorization expired or preflight failed. No update was submitted.',
      );
    } finally {
      if (owns) {
        _operationCurrent = null;
        _calling = false;
      }
    }
  }

  SmbSettingsResult _unknown() {
    _terminal = true;
    _inventories.clear();
    _reviews.clear();
    return const SmbSettingsResult(
      SmbSettingsOutcome.unknown,
      'SMB configuration may already have changed and interrupted clients. The result is unverified, not rollback. Further writes are fenced; inspect the original server independently without retrying.',
    );
  }
}

Never _smbThrow(SmbSettingsExceptionReason reason) =>
    throw SmbSettingsException(reason);
bool _smbSettingsName(String name) =>
    RegExp(r'^[A-Za-z][A-Za-z0-9-]{0,14}$').stringMatch(name) == name &&
    !const {
      'ANONYMOUS',
      'AUTHENTICATED USER',
      'BATCH',
      'BUILTIN',
      'DIALUP',
      'ENTERPRISE',
      'INTERACTIVE',
      'INTERNET',
      'NETWORK',
      'NULL',
      'PROXY',
      'RESTRICTED',
      'SELF',
      'USERS',
      'WORLD',
      'GATEWAY',
      'GW',
      'TAC',
    }.contains(name.toUpperCase());
bool _smbSid(Object? sid) {
  if (sid is! String ||
      RegExp(r'^S-1-5-21-[0-9]{1,10}-[0-9]{1,10}-[0-9]{1,10}$')
              .stringMatch(sid) !=
          sid) {
    return false;
  }
  return sid.split('-').skip(4).every((s) {
    final n = int.tryParse(s);
    return n != null && n >= 0 && n <= 4294967295;
  });
}

SmbTransportEncryption _smbEncryption(Object? raw) {
  for (final v in SmbTransportEncryption.values) {
    if (_smbEncryptionWire(v) == raw) return v;
  }
  _smbThrow(SmbSettingsExceptionReason.invalidResponse);
}

String _smbEncryptionWire(SmbTransportEncryption v) =>
    v == SmbTransportEncryption.defaultMode ? 'DEFAULT' : v.name.toUpperCase();
int _smbEncryptionRank(SmbTransportEncryption v) => switch (v) {
  SmbTransportEncryption.defaultMode || SmbTransportEncryption.negotiate => 0,
  SmbTransportEncryption.desired => 1,
  SmbTransportEncryption.required => 2,
};
Map<String, Object?> _smbSettingsMap(SmbGlobalSettings s) => {
  'netbiosname': s.netbiosName,
  'workgroup': s.workgroup,
  'description': s.description,
  'multichannel': s.multichannel,
  'encryption': _smbEncryptionWire(s.encryption),
};
String _smbSettingsProof(SmbGlobalSettings s) => jsonEncode(_smbSettingsMap(s));
Map<String, Object?> _smbPatch(SmbGlobalSettings a, SmbGlobalSettings b) {
  final old = _smbSettingsMap(a);
  return {
    for (final e in _smbSettingsMap(b).entries)
      if (old[e.key] != e.value) e.key: e.value,
  };
}

Object? _smbCanonical(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: _smbCanonical(value[key])};
  }
  if (value is List) return value.map(_smbCanonical).toList();
  return value;
}

bool _smbBounded(Object? raw) {
  var nodes = 0, characters = 0;
  bool visit(Object? v, int depth) {
    if (++nodes > 4096 || depth > 12) return false;
    if (v == null || v is bool || v is int) return true;
    if (v is num) return v.isFinite;
    if (v is String) {
      characters += v.length;
      return v.length <= 131072 && characters <= 262144;
    }
    if (v is List) {
      return v.length <= 1024 && v.every((x) => visit(x, depth + 1));
    }
    if (v is Map) {
      return v.length <= 256 &&
          v.entries.every(
            (e) =>
                e.key is String &&
                (e.key as String).length <= 256 &&
                visit(e.key, depth + 1) &&
                visit(e.value, depth + 1),
          );
    }
    return false;
  }

  return visit(raw, 0);
}

String _smbDependencyProof(SmbSettingsInventory i) => jsonEncode([
  _deliveryBaseProof(i.readiness),
  i.directoryConfigured,
  i.securityManaged,
  i.appleDependentShareCount,
  i.shares.map((s) => [s.id, s.enabled]).toList(),
]);
String _smbReadProof(_SmbRead r) => jsonEncode([
  _smbDependencyProof(r.inventory),
  r.protectedProof,
  r.dependencyProof,
  _smbSettingsProof(r.inventory.config.settings),
]);
