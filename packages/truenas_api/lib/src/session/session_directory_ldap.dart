part of 'true_nas_session_repository.dart';

String? _directoryLdapAuthority(String value) {
  if (value.isEmpty || value.length > 512) return null;
  final uri = Uri.tryParse(value);
  if (uri == null ||
      !{'ldap', 'ldaps'}.contains(uri.scheme) ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.path.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  final normalized = '${uri.scheme}://${uri.authority}';
  return value == normalized ? normalized : null;
}

/// Exact public LDAP attribute-map fields from the TrueNAS 25.10 schema.
const directoryLdapAttributeFields = <String, List<String>>{
  'passwd': [
    'user_object_class',
    'user_name',
    'user_uid',
    'user_gid',
    'user_gecos',
    'user_home_directory',
    'user_shell',
  ],
  'shadow': [
    'shadow_last_change',
    'shadow_min',
    'shadow_max',
    'shadow_warning',
    'shadow_inactive',
    'shadow_expire',
  ],
  'group': ['group_object_class', 'group_gid', 'group_member'],
  'netgroup': ['netgroup_object_class', 'netgroup_member', 'netgroup_triple'],
};

/// Only LDAP schema attribute names are kept; no directory entry values.
final class DirectoryLdapAttributeMaps {
  DirectoryLdapAttributeMaps._(this.values);
  final Map<String, Map<String, String?>> values;

  static DirectoryLdapAttributeMaps? parse(Object? raw) {
    if (raw != null && raw is! Map) return null;
    final source = raw is Map ? raw : const <String, Object?>{};
    if (source.keys.any(
      (key) => key is! String || !directoryLdapAttributeFields.containsKey(key),
    )) {
      return null;
    }
    final normalized = <String, Map<String, String?>>{};
    final descriptor = RegExp(
      r'^(?:[A-Za-z][A-Za-z0-9-]*|[0-9]+(?:\.[0-9]+)+)$',
    );
    for (final category in directoryLdapAttributeFields.entries) {
      final part = source[category.key];
      if (part != null && part is! Map) return null;
      final entries = part is Map ? part : const <String, Object?>{};
      if (entries.keys.any(
        (key) => key is! String || !category.value.contains(key),
      )) {
        return null;
      }
      final values = <String, String?>{};
      for (final name in category.value) {
        final value = entries[name];
        if (value != null &&
            (value is! String ||
                value.length > 120 ||
                !descriptor.hasMatch(value))) {
          return null;
        }
        values[name] = value as String?;
      }
      normalized[category.key] = Map.unmodifiable(values);
    }
    return DirectoryLdapAttributeMaps._(Map.unmodifiable(normalized));
  }

  String? value(String category, String field) => values[category]?[field];

  int get overrideCount => values.values.fold(
    0,
    (sum, group) => sum + group.values.where((value) => value != null).length,
  );

  bool sameAs(DirectoryLdapAttributeMaps other) {
    for (final category in directoryLdapAttributeFields.entries) {
      for (final field in category.value) {
        if (value(category.key, field) != other.value(category.key, field)) {
          return false;
        }
      }
    }
    return true;
  }

  Map<String, Object?> toPayload() => {
    for (final category in directoryLdapAttributeFields.entries)
      category.key: {
        for (final field in category.value) field: value(category.key, field),
      },
  };
}

/// Non-secret local proposal for an already-configured anonymous LDAP service.
final class DirectoryLdapDraft {
  DirectoryLdapDraft({
    required List<String> serverUrls,
    required this.baseDn,
    required this.schema,
    required this.startTls,
    required this.validateCertificates,
    required this.userSearchBase,
    required this.groupSearchBase,
    required this.netgroupSearchBase,
    required this.attributeMaps,
  }) : serverUrls = List.unmodifiable(serverUrls);

  final List<String> serverUrls;
  final String baseDn, schema;
  final String? userSearchBase, groupSearchBase, netgroupSearchBase;
  final DirectoryLdapAttributeMaps? attributeMaps;
  final bool startTls, validateCertificates;

  String? validateAgainst(DirectoryIdmapInventory inventory) {
    final before = inventory.ldap;
    if (inventory.serviceType != 'LDAP' ||
        inventory.enabled ||
        inventory.status != null && inventory.status != 'DISABLED' ||
        before == null) {
      return 'Disable an existing LDAP service before editing it.';
    }
    if (serverUrls.isEmpty ||
        serverUrls.length > 8 ||
        serverUrls.any((url) => _directoryLdapAuthority(url) == null) ||
        serverUrls.toSet().length != serverUrls.length) {
      return 'Enter one to eight unique LDAP server authorities without credentials, paths or query strings.';
    }
    if (!_idmapText(baseDn) ||
        baseDn.length > 512 ||
        !{'RFC2307', 'RFC2307BIS'}.contains(schema)) {
      return 'Enter a valid base DN and supported LDAP schema.';
    }
    if (serverUrls.any((url) => url.startsWith('ldap://')) != startTls ||
        serverUrls.any((url) => url.startsWith('ldaps://')) == startTls ||
        !validateCertificates) {
      return 'Use LDAPS or StartTLS with certificate validation enabled.';
    }
    for (final value in [userSearchBase, groupSearchBase, netgroupSearchBase]) {
      if (value != null && (!_idmapText(value) || value.length > 512)) {
        return 'Enter valid optional user, group and netgroup search base DNs.';
      }
    }
    if (attributeMaps == null || before.attributeMaps == null) {
      return 'Enter only supported LDAP attribute names.';
    }
    if (changesFrom(inventory).isEmpty) {
      return 'Change at least one LDAP setting.';
    }
    return null;
  }

  List<String> changesFrom(DirectoryIdmapInventory inventory) {
    final before = inventory.ldap;
    if (before == null) return const [];
    final changes = <String>[];
    if (serverUrls.length != before.serverUrls.length ||
        List.generate(serverUrls.length, (i) => i).any(
          (i) =>
              i >= before.serverUrls.length ||
              serverUrls[i] != before.serverUrls[i],
        )) {
      changes.add(
        'LDAP servers: ${before.serverUrls.join(', ')} → ${serverUrls.join(', ')}',
      );
    }
    if (baseDn != before.baseDn) {
      changes.add('Base DN: ${before.baseDn} → $baseDn');
    }
    if (schema != before.schema) {
      changes.add('Schema: ${before.schema} → $schema');
    }
    if (startTls != before.startTls) {
      changes.add('StartTLS: ${before.startTls} → $startTls');
    }
    if (validateCertificates != before.validateCertificates) {
      changes.add(
        'Certificate validation: ${before.validateCertificates} → $validateCertificates',
      );
    }
    if (userSearchBase != before.userSearchBase) {
      changes.add(
        'User search base: ${before.userSearchBase ?? '(Base DN)'} → ${userSearchBase ?? '(Base DN)'}',
      );
    }
    if (groupSearchBase != before.groupSearchBase) {
      changes.add(
        'Group search base: ${before.groupSearchBase ?? '(Base DN)'} → ${groupSearchBase ?? '(Base DN)'}',
      );
    }
    if (netgroupSearchBase != before.netgroupSearchBase) {
      changes.add(
        'Netgroup search base: ${before.netgroupSearchBase ?? '(Base DN)'} → ${netgroupSearchBase ?? '(Base DN)'}',
      );
    }
    final afterMaps = attributeMaps, beforeMaps = before.attributeMaps;
    if (afterMaps != null && beforeMaps != null) {
      for (final category in directoryLdapAttributeFields.entries) {
        for (final field in category.value) {
          final oldValue = beforeMaps.value(category.key, field);
          final newValue = afterMaps.value(category.key, field);
          if (oldValue != newValue) {
            changes.add(
              '${category.key}.$field: ${oldValue ?? '(default)'} → ${newValue ?? '(default)'}',
            );
          }
        }
      }
    }
    return List.unmodifiable(changes);
  }
}

final class DirectoryLdapReview {
  const DirectoryLdapReview._(
    this.draft,
    this.inventory,
    this.confirmation,
    this.expiresAt,
    this._proof,
  );
  final DirectoryLdapDraft draft;
  final DirectoryIdmapInventory inventory;
  final String confirmation;
  final DateTime expiresAt;
  final String _proof;
  List<String> get changes => draft.changesFrom(inventory);
}

final class DirectoryLdapJob {
  const DirectoryLdapJob._(
    this.id,
    this.endpoint,
    this.hostId,
    this.payloadProof,
    this._beforeProof,
    this._expectedConfiguration,
  );
  final int id;
  final String endpoint, hostId, payloadProof, _beforeProof;
  final Map<String, Object?> _expectedConfiguration;
}

final class DirectoryLdapResult {
  const DirectoryLdapResult(this.outcome, this.message, {this.job});
  final DirectoryIdmapOutcome outcome;
  final String message;
  final DirectoryLdapJob? job;
}

typedef _DirectoryLdapSnapshot = ({
  DirectoryIdmapInventory inventory,
  Map<String, Object?> configuration,
  Map<String, Object?> common,
  String proof,
});

bool _ldapSearchBases(Object? value) {
  if (value == null) return true;
  if (value is! Map ||
      !_idmapKeys(value, {'base_user', 'base_group', 'base_netgroup'}, {})) {
    return false;
  }
  return value.values.every(
    (entry) =>
        entry == null ||
        entry is String && _idmapText(entry) && entry.length <= 512,
  );
}

extension _DirectoryLdapWriter on _SessionDirectoryIdmap {
  Future<_DirectoryLdapSnapshot> _ldapSnapshot({
    bool allowEnabled = false,
  }) async {
    if (!capabilities.canEdit) throw const DirectoryIdmapException();
    final inventory = await load();
    final beforeAdmin = _configurationBackupAdmin(
      await _writeCall('auth.me', const []),
    );
    final ha = await _writeCall('failover.licensed', const []);
    final state = await _writeCall('system.state', const []);
    final beforeHost = await _writeCall('system.host_id', const []);
    final raw = await _writeCall('directoryservices.config', const []);
    final status = await _writeCall('directoryservices.status', const []);
    final afterHost = await _writeCall('system.host_id', const []);
    final afterAdmin = _configurationBackupAdmin(
      await _writeCall('auth.me', const []),
    );
    if (!beforeAdmin ||
        !afterAdmin ||
        ha != false ||
        state != 'READY' ||
        beforeHost != inventory.hostId ||
        afterHost != inventory.hostId ||
        inventory.serviceType != 'LDAP' ||
        (!allowEnabled && inventory.enabled) ||
        (inventory.enabled
            ? !{'HEALTHY', 'FAULTED'}.contains(inventory.status)
            : inventory.status != null && inventory.status != 'DISABLED') ||
        inventory.ldap == null ||
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
        raw['enable'] != inventory.enabled ||
        raw['service_type'] != 'LDAP' ||
        status is! Map ||
        status['type'] != (inventory.enabled ? 'LDAP' : null) &&
            status['type'] != 'LDAP' ||
        status['status'] != inventory.status ||
        raw['kerberos_realm'] != null ||
        raw['enable_account_cache'] is! bool ||
        raw['enable_dns_updates'] is! bool ||
        raw['timeout'] is! int ||
        (raw['timeout'] as int) < 5 ||
        (raw['timeout'] as int) > 60) {
      throw const DirectoryIdmapException();
    }
    final credential = raw['credential'];
    final configuration = raw['configuration'];
    if (credential is! Map ||
        !_idmapKeys(credential, {'credential_type'}, {'credential_type'}) ||
        credential['credential_type'] != 'LDAP_ANONYMOUS' ||
        configuration is! Map ||
        !_idmapKeys(
          configuration,
          {
            'service_type',
            'server_urls',
            'basedn',
            'starttls',
            'validate_certificates',
            'schema',
            'search_bases',
            'attribute_maps',
            'auxiliary_parameters',
          },
          {'server_urls', 'basedn'},
        ) ||
        configuration['service_type'] != null &&
            configuration['service_type'] != 'LDAP' ||
        configuration['server_urls'] is! List ||
        configuration['basedn'] is! String ||
        configuration['starttls'] != null &&
            configuration['starttls'] is! bool ||
        configuration['validate_certificates'] != null &&
            configuration['validate_certificates'] is! bool ||
        configuration['schema'] != null &&
            !{'RFC2307', 'RFC2307BIS'}.contains(configuration['schema']) ||
        !_ldapSearchBases(configuration['search_bases']) ||
        DirectoryLdapAttributeMaps.parse(configuration['attribute_maps']) ==
            null ||
        configuration['auxiliary_parameters'] != null) {
      throw const DirectoryIdmapException();
    }
    final current = inventory.ldap!;
    final maps = DirectoryLdapAttributeMaps.parse(
      configuration['attribute_maps'],
    );
    if (maps == null ||
        current.attributeMaps == null ||
        !maps.sameAs(current.attributeMaps!)) {
      throw const DirectoryIdmapException();
    }
    final urls = configuration['server_urls'] as List;
    if (urls.length != current.serverUrls.length ||
        List.generate(urls.length, (i) => i).any(
          (i) =>
              urls[i] is! String ||
              _directoryLdapAuthority(urls[i] as String) !=
                  current.serverUrls[i],
        ) ||
        configuration['basedn'] != current.baseDn ||
        (configuration['schema'] ?? 'RFC2307') != current.schema ||
        (configuration['starttls'] ?? false) != current.startTls ||
        (configuration['validate_certificates'] ?? true) !=
            current.validateCertificates ||
        (configuration['search_bases'] is Map
                ? (configuration['search_bases'] as Map)['base_user']
                : null) !=
            current.userSearchBase ||
        (configuration['search_bases'] is Map
                ? (configuration['search_bases'] as Map)['base_group']
                : null) !=
            current.groupSearchBase ||
        (configuration['search_bases'] is Map
                ? (configuration['search_bases'] as Map)['base_netgroup']
                : null) !=
            current.netgroupSearchBase) {
      throw const DirectoryIdmapException();
    }
    return (
      inventory: inventory,
      configuration: {
        for (final entry in configuration.entries)
          entry.key as String: entry.value,
      },
      common: {
        'enable_account_cache': raw['enable_account_cache'],
        'enable_dns_updates': raw['enable_dns_updates'],
        'timeout': raw['timeout'],
        'kerberos_realm': null,
      },
      proof: _digest(raw),
    );
  }

  Future<DirectoryLdapReview> reviewLdap(DirectoryLdapDraft draft) async {
    if (_busy || _uncertain || _disposed || isOtherMutationBusy()) {
      throw const DirectoryIdmapException();
    }
    final snapshot = await _ldapSnapshot();
    if (draft.validateAgainst(snapshot.inventory) != null) {
      throw const DirectoryIdmapException();
    }
    final review = DirectoryLdapReview._(
      draft,
      snapshot.inventory,
      'LDAP ${snapshot.inventory.hostId.substring(0, 8)}',
      DateTime.now().toUtc().add(const Duration(minutes: 2)),
      snapshot.proof,
    );
    _review = null;
    _maintenanceReview = null;
    _activationReview = null;
    _ldapReview = review;
    return review;
  }

  DirectoryLdapResult _ldapUnknown(DirectoryLdapJob? job) {
    _busy = true;
    _uncertain = true;
    _ldapReview = null;
    return DirectoryLdapResult(
      DirectoryIdmapOutcome.unknown,
      job == null
          ? 'LDAP update may have taken effect. Inspect the original server; do not resubmit.'
          : 'The owned LDAP job or saved settings could not be verified.',
      job: job,
    );
  }

  Future<DirectoryLdapResult> executeLdap(
    DirectoryLdapReview review,
    String confirmation,
  ) async {
    if (_ldapReview != review ||
        _busy ||
        _uncertain ||
        _disposed ||
        isOtherMutationBusy() ||
        DateTime.now().toUtc().isAfter(review.expiresAt) ||
        confirmation != review.confirmation) {
      throw const DirectoryIdmapException();
    }
    _ldapReview = null;
    _busy = true;
    var sent = false;
    try {
      final fresh = await _ldapSnapshot();
      if (fresh.proof != review._proof ||
          fresh.inventory.endpoint != review.inventory.endpoint ||
          fresh.inventory.hostId != review.inventory.hostId ||
          review.draft.validateAgainst(fresh.inventory) != null) {
        throw const DirectoryIdmapException();
      }
      final updated = <String, Object?>{
        ...fresh.configuration,
        'service_type': 'LDAP',
        'server_urls': review.draft.serverUrls,
        'basedn': review.draft.baseDn,
        'schema': review.draft.schema,
        'starttls': review.draft.startTls,
        'validate_certificates': review.draft.validateCertificates,
        'search_bases': {
          'base_user': review.draft.userSearchBase,
          'base_group': review.draft.groupSearchBase,
          'base_netgroup': review.draft.netgroupSearchBase,
        },
        'attribute_maps': review.draft.attributeMaps!.toPayload(),
      };
      final payload = <String, Object?>{
        'enable': false,
        'service_type': 'LDAP',
        'credential': {'credential_type': 'LDAP_ANONYMOUS'},
        'configuration': updated,
        ...fresh.common,
        'force': false,
      };
      final payloadProof = _digest(payload);
      sent = true;
      final receipt = await _writeCall('directoryservices.update', [payload]);
      if (receipt is! int || receipt <= 0) return _ldapUnknown(null);
      final job = DirectoryLdapJob._(
        receipt,
        fresh.inventory.endpoint,
        fresh.inventory.hostId,
        payloadProof,
        fresh.proof,
        updated,
      );
      _ldapJob = job;
      return DirectoryLdapResult(
        DirectoryIdmapOutcome.pending,
        'The LDAP update was submitted once. Check its owned job.',
        job: job,
      );
    } on Object {
      if (sent) return _ldapUnknown(null);
      _busy = false;
      return const DirectoryLdapResult(
        DirectoryIdmapOutcome.rejected,
        'Preflight changed; no LDAP update was submitted.',
      );
    }
  }

  Future<DirectoryLdapResult> pollLdap(DirectoryLdapJob job) async {
    if (_ldapJob != job ||
        job.endpoint != _endpoint ||
        _disposed ||
        !isCurrent() ||
        !capabilities.canEdit) {
      throw const DirectoryIdmapException();
    }
    try {
      final rows = await _writeCall('core.get_jobs', [
        [
          ['id', '=', job.id],
        ],
        {
          'limit': 2,
          'select': ['id', 'method', 'arguments', 'state'],
        },
      ]);
      if (rows is! List || rows.length != 1 || rows.single is! Map) {
        return _ldapUnknown(job);
      }
      final row = rows.single as Map;
      if (row['id'] != job.id ||
          row['method'] != 'directoryservices.update' ||
          row['arguments'] is! List ||
          (row['arguments'] as List).length != 1 ||
          _digest((row['arguments'] as List).single) != job.payloadProof) {
        return _ldapUnknown(job);
      }
      if (row['state'] == 'WAITING' || row['state'] == 'RUNNING') {
        return DirectoryLdapResult(
          DirectoryIdmapOutcome.pending,
          'The owned LDAP update job is still running.',
          job: job,
        );
      }
      if (row['state'] == 'SUCCESS' ||
          row['state'] == 'FAILED' ||
          row['state'] == 'ABORTED') {
        final saved = await _ldapSnapshot();
        if (saved.inventory.endpoint != job.endpoint ||
            saved.inventory.hostId != job.hostId) {
          return _ldapUnknown(job);
        }
        if (row['state'] == 'SUCCESS' &&
            _digest(saved.configuration) !=
                _digest(job._expectedConfiguration)) {
          return _ldapUnknown(job);
        }
        if (row['state'] != 'SUCCESS' && saved.proof != job._beforeProof) {
          return _ldapUnknown(job);
        }
        _busy = false;
        _uncertain = false;
        _ldapJob = null;
        return row['state'] == 'SUCCESS'
            ? const DirectoryLdapResult(
                DirectoryIdmapOutcome.completed,
                'The owned LDAP job succeeded and saved settings were verified.',
              )
            : const DirectoryLdapResult(
                DirectoryIdmapOutcome.rejected,
                'The owned LDAP job did not succeed; original settings remain.',
              );
      }
      return _ldapUnknown(job);
    } on Object {
      return _ldapUnknown(job);
    }
  }
}
