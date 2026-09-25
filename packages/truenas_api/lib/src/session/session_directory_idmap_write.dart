part of 'true_nas_session_repository.dart';

Uint8List _idmapKey() {
  final random = math.Random.secure();
  return Uint8List.fromList(List.generate(32, (_) => random.nextInt(256)));
}

bool _idmapKeys(Map value, Set<String> allowed, Set<String> required) =>
    value.keys.every((key) => key is String && allowed.contains(key)) &&
    required.every(value.containsKey);

bool _idmapText(Object? value, {bool nullable = false}) =>
    nullable && value == null ||
    value is String &&
        value.isNotEmpty &&
        value.length <= 512 &&
        !value.runes.any((rune) => rune < 32 || rune == 127);

bool _idmapPrimaryShape(Map value) {
  const common = {'name', 'idmap_backend', 'range_low', 'range_high'};
  switch (value['idmap_backend']) {
    case 'RID':
      return _idmapKeys(
            value,
            {...common, 'sssd_compat'},
            {'idmap_backend', 'range_low', 'range_high'},
          ) &&
          (!value.containsKey('sssd_compat') || value['sssd_compat'] is bool);
    case 'AD':
      return _idmapKeys(
            value,
            {...common, 'schema_mode', 'unix_primary_group', 'unix_nss_info'},
            {
              'idmap_backend',
              'range_low',
              'range_high',
              'schema_mode',
              'unix_primary_group',
              'unix_nss_info',
            },
          ) &&
          {'RFC2307', 'SFU', 'SFU20'}.contains(value['schema_mode']) &&
          value['unix_primary_group'] is bool &&
          value['unix_nss_info'] is bool;
    default:
      return false;
  }
}

typedef _IdmapEditSnapshot = ({
  DirectoryIdmapInventory inventory,
  Map<String, Object?> configuration,
  Map<String, Object?> credential,
  Map<String, Object?> common,
  String proof,
});

extension _DirectoryIdmapWriter on _SessionDirectoryIdmap {
  String _digest(Object? value) {
    if (!_smbBounded(value)) throw const DirectoryIdmapException();
    final bytes = Uint8List.fromList(
      utf8.encode(jsonEncode(_smbCanonical(value))),
    );
    try {
      return crypto.Hmac(crypto.sha256, _key).convert(bytes).toString();
    } finally {
      bytes.fillRange(0, bytes.length, 0);
    }
  }

  Future<Object?> _writeCall(String method, List<Object?> params) async {
    if (_disposed || !isCurrent() || !capabilities.canEdit) {
      throw const DirectoryIdmapException();
    }
    final result = await client
        .call(method, id: nextId(), params: params)
        .timeout(requestTimeout);
    if (_disposed || !isCurrent()) throw const DirectoryIdmapException();
    return result;
  }

  Future<_IdmapEditSnapshot> _snapshot() async {
    if (!capabilities.canEdit) throw const DirectoryIdmapException();
    final inventory = await load();
    final admin = _configurationBackupAdmin(
      await _writeCall('auth.me', const []),
    );
    final ha = await _writeCall('failover.licensed', const []);
    final state = await _writeCall('system.state', const []);
    final beforeHost = await _writeCall('system.host_id', const []);
    final raw = await _writeCall('directoryservices.config', const []);
    final status = await _writeCall('directoryservices.status', const []);
    final afterHost = await _writeCall('system.host_id', const []);
    final adminAfter = _configurationBackupAdmin(
      await _writeCall('auth.me', const []),
    );
    if (!admin ||
        !adminAfter ||
        ha != false ||
        state != 'READY' ||
        beforeHost != inventory.hostId ||
        afterHost != inventory.hostId ||
        raw is! Map ||
        !_smbBounded(raw) ||
        !_idmapKeys(
          raw,
          {
            'id',
            'enable',
            'service_type',
            'credential',
            'configuration',
            'kerberos_realm',
            'enable_account_cache',
            'enable_dns_updates',
            'timeout',
          },
          {
            'enable',
            'service_type',
            'credential',
            'configuration',
            'kerberos_realm',
            'enable_account_cache',
            'enable_dns_updates',
            'timeout',
          },
        ) ||
        raw['enable'] != false ||
        raw['service_type'] != 'ACTIVEDIRECTORY' ||
        status is! Map ||
        status['type'] != null && status['type'] != 'ACTIVEDIRECTORY' ||
        status['status'] != null && status['status'] != 'DISABLED' ||
        !inventory.isActiveDirectory ||
        inventory.enabled ||
        inventory.status != status['status']) {
      throw const DirectoryIdmapException();
    }
    final credential = raw['credential'];
    final configuration = raw['configuration'];
    if (credential is! Map ||
        !_idmapKeys(
          credential,
          {'credential_type', 'principal'},
          {'credential_type', 'principal'},
        ) ||
        credential['credential_type'] != 'KERBEROS_PRINCIPAL' ||
        !_idmapText(credential['principal']) ||
        configuration is! Map ||
        !_idmapKeys(
          configuration,
          {
            'hostname',
            'domain',
            'idmap',
            'site',
            'computer_account_ou',
            'use_default_domain',
            'enable_trusted_domains',
            'trusted_domains',
          },
          {
            'hostname',
            'domain',
            'idmap',
            'site',
            'computer_account_ou',
            'use_default_domain',
            'enable_trusted_domains',
            'trusted_domains',
          },
        ) ||
        !_idmapText(configuration['hostname']) ||
        !_idmapText(configuration['domain']) ||
        !_idmapText(configuration['site'], nullable: true) ||
        !_idmapText(configuration['computer_account_ou'], nullable: true) ||
        configuration['use_default_domain'] is! bool ||
        configuration['enable_trusted_domains'] is! bool ||
        configuration['trusted_domains'] is! List ||
        (configuration['trusted_domains'] as List).length > 8 ||
        (configuration['enable_trusted_domains'] as bool) !=
            (configuration['trusted_domains'] as List).isNotEmpty ||
        raw['enable_account_cache'] is! bool ||
        raw['enable_dns_updates'] is! bool ||
        raw['timeout'] is! int ||
        (raw['timeout'] as int) < 5 ||
        (raw['timeout'] as int) > 60 ||
        !_idmapText(raw['kerberos_realm'], nullable: true)) {
      throw const DirectoryIdmapException();
    }
    final idmap = configuration['idmap'];
    if (idmap is! Map ||
        !_idmapKeys(
          idmap,
          {'builtin', 'idmap_domain'},
          {'builtin', 'idmap_domain'},
        )) {
      throw const DirectoryIdmapException();
    }
    final builtin = idmap['builtin'], primary = idmap['idmap_domain'];
    if (builtin is! Map ||
        !_idmapKeys(
          builtin,
          {'name', 'range_low', 'range_high'},
          {'range_low', 'range_high'},
        ) ||
        builtin['name'] != null && !_idmapText(builtin['name']) ||
        primary is! Map ||
        !_idmapPrimaryShape(primary) ||
        primary['name'] != null && !_idmapText(primary['name']) ||
        primary['idmap_backend'] != inventory.primary?.backend ||
        builtin['range_low'] != inventory.builtin?.range.low ||
        builtin['range_high'] != inventory.builtin?.range.high ||
        primary['range_low'] != inventory.primary?.range.low ||
        primary['range_high'] != inventory.primary?.range.high) {
      throw const DirectoryIdmapException();
    }
    final trusted = configuration['trusted_domains'] as List;
    if (trusted.length != inventory.trusted.length) {
      throw const DirectoryIdmapException();
    }
    for (var i = 0; i < trusted.length; i++) {
      final row = trusted[i];
      final projected = inventory.trusted[i];
      if (row is! Map ||
          !_idmapPrimaryShape(row) ||
          row['name'] is! String ||
          !_safeName(row['name'] as String) ||
          row['name'] != projected.label ||
          row['idmap_backend'] != projected.backend ||
          row['range_low'] != projected.range.low ||
          row['range_high'] != projected.range.high) {
        throw const DirectoryIdmapException();
      }
    }
    final safeConfiguration = <String, Object?>{
      for (final entry in configuration.entries)
        entry.key as String: entry.value,
    };
    final safeCredential = <String, Object?>{
      'credential_type': 'KERBEROS_PRINCIPAL',
      'principal': credential['principal'],
    };
    return (
      inventory: inventory,
      configuration: safeConfiguration,
      credential: safeCredential,
      common: {
        'enable_account_cache': raw['enable_account_cache'],
        'enable_dns_updates': raw['enable_dns_updates'],
        'timeout': raw['timeout'],
        'kerberos_realm': raw['kerberos_realm'],
      },
      proof: _digest(raw),
    );
  }

  bool _additionNameAvailable(
    _IdmapEditSnapshot snapshot,
    DirectoryIdmapRangeDraft draft,
  ) {
    final addition = draft.addition;
    if (addition == null) return true;
    final idmap = snapshot.configuration['idmap'] as Map;
    for (final row in [idmap['builtin'], idmap['idmap_domain']]) {
      final name = row is Map ? row['name'] : null;
      if (name is String && name.toUpperCase() == addition.name) return false;
    }
    return true;
  }

  Map<String, Object?> _updatedConfiguration(
    Map<String, Object?> configuration,
    DirectoryIdmapRangeDraft draft,
  ) {
    final idmap = configuration['idmap'] as Map;
    final builtin = idmap['builtin'] as Map;
    final primary = idmap['idmap_domain'] as Map;
    final trusted = configuration['trusted_domains'] as List;
    Map<String, Object?> backendOptions(int index) {
      if (draft.options.isEmpty || draft.options[index] == null) return {};
      final option = draft.options[index]!;
      return option.backend == 'RID'
          ? {'sssd_compat': option.sssdCompat}
          : {
              'schema_mode': option.schemaMode,
              'unix_primary_group': option.unixPrimaryGroup,
              'unix_nss_info': option.unixNssInfo,
            };
    }

    Map<String, Object?> migratedRow(Map row, DirectoryIdmapRange range) {
      final options = draft.transition!.options;
      return {
        if (row['name'] != null) 'name': row['name'],
        'idmap_backend': options.backend,
        'range_low': range.low,
        'range_high': range.high,
        ...options.backend == 'RID'
            ? {'sssd_compat': options.sssdCompat}
            : {
                'schema_mode': options.schemaMode,
                'unix_primary_group': options.unixPrimaryGroup,
                'unix_nss_info': options.unixNssInfo,
              },
      };
    }

    return {
      ...configuration,
      if (draft.addition != null) 'enable_trusted_domains': true,
      if (draft.removal != null) 'enable_trusted_domains': trusted.length > 1,
      'idmap': {
        'builtin': {
          ...builtin,
          'range_low': draft.builtin.low,
          'range_high': draft.builtin.high,
        },
        'idmap_domain':
            draft.transition?.trustedName == null && draft.transition != null
            ? migratedRow(primary, draft.primary)
            : {
                ...primary,
                ...backendOptions(0),
                'range_low': draft.primary.low,
                'range_high': draft.primary.high,
              },
      },
      'trusted_domains': [
        for (var i = 0; i < trusted.length; i++)
          if ((trusted[i] as Map)['name'] != draft.removal)
            if (draft.transition?.trustedName == (trusted[i] as Map)['name'])
              migratedRow(trusted[i] as Map, draft.trusted[i])
            else
              {
                ...(trusted[i] as Map),
                ...backendOptions(i + 1),
                'range_low': draft.trusted[i].low,
                'range_high': draft.trusted[i].high,
              },
        if (draft.addition != null) draft.addition!.toConfiguration(),
      ],
    };
  }

  Future<DirectoryIdmapReview> review(DirectoryIdmapRangeDraft draft) async {
    if (_busy ||
        _uncertain ||
        _disposed ||
        !capabilities.canEdit ||
        isOtherMutationBusy()) {
      throw const DirectoryIdmapException();
    }
    final snapshot = await _snapshot();
    if (draft.validateAgainst(snapshot.inventory) != null ||
        !_additionNameAvailable(snapshot, draft)) {
      throw const DirectoryIdmapException();
    }
    final review = DirectoryIdmapReview._(
      draft: draft,
      inventory: snapshot.inventory,
      confirmation: draft.transition != null
          ? 'MIGRATE ${draft.transition!.trustedName ?? 'PRIMARY'} IDMAP ${snapshot.inventory.hostId.substring(0, 8)}'
          : draft.removal == null
          ? 'IDMAP ${snapshot.inventory.hostId.substring(0, 8)}'
          : 'REMOVE ${draft.removal} IDMAP ${snapshot.inventory.hostId.substring(0, 8)}',
      expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 2)),
      proof: snapshot.proof,
    );
    _maintenanceReview = null;
    _ldapReview = null;
    _activationReview = null;
    _review = review;
    return review;
  }

  DirectoryIdmapResult _unknown(DirectoryIdmapJob? job) {
    _uncertain = true;
    _busy = true;
    _review = null;
    return DirectoryIdmapResult(
      DirectoryIdmapOutcome.unknown,
      job == null
          ? 'Submission may have taken effect. Inspect this server before making any further changes; do not repeat it.'
          : 'The owned job or saved state could not be verified. Keep this operation fenced and inspect the server.',
      job: job,
    );
  }

  Future<DirectoryIdmapResult> execute(
    DirectoryIdmapReview review,
    String confirmation,
  ) async {
    if (_review != review ||
        _maintenanceReview != null ||
        _busy ||
        _uncertain ||
        !capabilities.canEdit ||
        isOtherMutationBusy() ||
        DateTime.now().toUtc().isAfter(review.expiresAt) ||
        confirmation != review.confirmation) {
      throw const DirectoryIdmapException();
    }
    _review = null;
    _busy = true;
    var sent = false;
    try {
      final fresh = await _snapshot();
      if (fresh.proof != review.proof ||
          fresh.inventory.endpoint != review.inventory.endpoint ||
          fresh.inventory.hostId != review.inventory.hostId ||
          review.draft.validateAgainst(fresh.inventory) != null ||
          !_additionNameAvailable(fresh, review.draft)) {
        throw const DirectoryIdmapException();
      }
      final updated = _updatedConfiguration(fresh.configuration, review.draft);
      final payload = <String, Object?>{
        'enable': false,
        'service_type': 'ACTIVEDIRECTORY',
        'credential': fresh.credential,
        'configuration': updated,
        ...fresh.common,
        'force': false,
      };
      final payloadProof = _digest(payload);
      sent = true;
      final receipt = await _writeCall('directoryservices.update', [payload]);
      if (receipt is! int || receipt <= 0) return _unknown(null);
      final job = DirectoryIdmapJob._(
        receipt,
        _endpoint,
        payloadProof,
        fresh.proof,
        updated,
        fresh.credential,
        review.draft,
        fresh.inventory.hostId,
      );
      _job = job;
      return DirectoryIdmapResult(
        DirectoryIdmapOutcome.pending,
        'The directory update job was submitted once. Check its status.',
        job: job,
      );
    } on Object {
      if (sent) return _unknown(null);
      _busy = false;
      return const DirectoryIdmapResult(
        DirectoryIdmapOutcome.rejected,
        'Preflight failed; no update was submitted.',
      );
    }
  }

  Future<DirectoryIdmapResult> poll(DirectoryIdmapJob job) async {
    if (_job != job ||
        job.endpoint != _endpoint ||
        _disposed ||
        !isCurrent() ||
        !capabilities.canEdit) {
      throw const DirectoryIdmapException();
    }
    try {
      final raw = await _writeCall('core.get_jobs', [
        [
          ['id', '=', job.id],
        ],
        {
          'limit': 2,
          'select': ['id', 'method', 'arguments', 'state'],
        },
      ]);
      if (raw is! List || raw.length != 1 || raw.single is! Map) {
        return _unknown(job);
      }
      final row = raw.single as Map;
      if (row['id'] != job.id ||
          row['method'] != 'directoryservices.update' ||
          row['arguments'] is! List ||
          (row['arguments'] as List).length != 1 ||
          _digest((row['arguments'] as List).single) != job.payloadProof) {
        return _unknown(job);
      }
      if (row['state'] == 'WAITING' || row['state'] == 'RUNNING') {
        return DirectoryIdmapResult(
          DirectoryIdmapOutcome.pending,
          'The owned directory update job is still running.',
          job: job,
        );
      }
      if (row['state'] == 'SUCCESS') {
        final saved = await _snapshot();
        final expectedTrusted =
            job._expectedConfiguration['trusted_domains'] as List;
        if (saved.inventory.hostId != job._hostId ||
            _digest(saved.configuration) !=
                _digest(job._expectedConfiguration) ||
            _digest(saved.credential) != _digest(job._expectedCredential) ||
            saved.inventory.builtin?.range.low != job._draft.builtin.low ||
            saved.inventory.builtin?.range.high != job._draft.builtin.high ||
            saved.inventory.primary?.backend !=
                (job._expectedConfiguration['idmap']
                    as Map)['idmap_domain']['idmap_backend'] ||
            saved.inventory.primary?.range.low != job._draft.primary.low ||
            saved.inventory.primary?.range.high != job._draft.primary.high ||
            saved.inventory.trusted.length != expectedTrusted.length ||
            List.generate(expectedTrusted.length, (i) => i).any((i) {
              final expected = expectedTrusted[i] as Map;
              final actual = saved.inventory.trusted[i];
              return actual.label != expected['name'] ||
                  actual.backend != expected['idmap_backend'] ||
                  actual.range.low != expected['range_low'] ||
                  actual.range.high != expected['range_high'];
            })) {
          return _unknown(job);
        }
        _busy = false;
        _uncertain = false;
        _job = null;
        return const DirectoryIdmapResult(
          DirectoryIdmapOutcome.completed,
          'The owned job succeeded and saved ID mapping was verified.',
        );
      }
      if (row['state'] == 'FAILED' || row['state'] == 'ABORTED') {
        final saved = await _snapshot();
        if (saved.proof != job._beforeProof) return _unknown(job);
        _busy = false;
        _uncertain = false;
        _job = null;
        return const DirectoryIdmapResult(
          DirectoryIdmapOutcome.rejected,
          'The owned job did not succeed and the original configuration remains.',
        );
      }
      return _unknown(job);
    } on Object {
      return _unknown(job);
    }
  }
}
