part of 'true_nas_session_repository.dart';

/// Bounded 25.10 directory workflows. Passwords, bind DNs and raw
/// configuration never leave this session part; sanitized LDAP authorities do.
abstract interface class AuthenticatedDirectoryIdmapSession {
  DirectoryIdmapCapabilities get directoryIdmapCapabilities;
  Future<DirectoryIdmapInventory> loadDirectoryIdmap();
  Future<DirectoryIdmapReview> reviewDirectoryIdmap(
    DirectoryIdmapRangeDraft draft,
  );
  Future<DirectoryIdmapResult> executeDirectoryIdmap(
    DirectoryIdmapReview review,
    String confirmation,
  );
  Future<DirectoryIdmapResult> pollDirectoryIdmap(DirectoryIdmapJob job);
  Future<DirectoryLdapReview> reviewDirectoryLdap(DirectoryLdapDraft draft);
  Future<DirectoryLdapResult> executeDirectoryLdap(
    DirectoryLdapReview review,
    String confirmation,
  );
  Future<DirectoryLdapResult> pollDirectoryLdap(DirectoryLdapJob job);
  Future<DirectoryLdapActivationReview> reviewDirectoryLdapActivation(
    bool enable,
  );
  Future<DirectoryLdapActivationResult> executeDirectoryLdapActivation(
    DirectoryLdapActivationReview review,
    String confirmation,
  );
  Future<DirectoryLdapActivationResult> pollDirectoryLdapActivation(
    DirectoryLdapActivationJob job,
  );
  Future<DirectoryMaintenanceReview> reviewDirectoryCacheRefresh();
  Future<DirectoryMaintenanceResult> executeDirectoryCacheRefresh(
    DirectoryMaintenanceReview review,
    String confirmation,
  );
  Future<DirectoryMaintenanceResult> pollDirectoryCacheRefresh(
    DirectoryMaintenanceJob job,
  );
  Future<DirectoryMaintenanceReview> reviewDirectoryKeytabSync();
  Future<DirectoryMaintenanceResult> executeDirectoryKeytabSync(
    DirectoryMaintenanceReview review,
    String confirmation,
  );
  Future<DirectoryMaintenanceResult> pollDirectoryKeytabSync(
    DirectoryMaintenanceJob job,
  );
}

final class DirectoryIdmapCapabilities {
  const DirectoryIdmapCapabilities({
    this.connected = false,
    this.versionSupported = false,
    this.available = false,
    this.editAvailable = false,
    this.cacheRefreshAvailable = false,
    this.keytabSyncAvailable = false,
  });
  const DirectoryIdmapCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      editAvailable = false,
      cacheRefreshAvailable = false,
      keytabSyncAvailable = false;
  final bool connected, versionSupported, available, editAvailable;
  final bool cacheRefreshAvailable, keytabSyncAvailable;
  bool get canRead => connected && versionSupported && available;
  bool get canEdit => canRead && editAvailable;
  bool get canRefreshCache => canRead && cacheRefreshAvailable;
  bool get canSyncKeytab => canRead && keytabSyncAvailable;
}

final class DirectoryIdmapRange {
  const DirectoryIdmapRange({required this.low, required this.high});
  final int low, high;

  /// TrueNAS 25.10 allows IDs from 1000 through 2147000000 and requires
  /// range_high - range_low >= 10000 (inclusive endpoints).
  bool get valid =>
      low >= 1000 && high <= 2147000000 && low < high && high - low >= 10000;

  bool overlaps(DirectoryIdmapRange other) =>
      low <= other.high && other.low <= high;
}

/// Non-secret RID/AD backend settings projected for a single domain.
final class DirectoryIdmapBackendOptions {
  const DirectoryIdmapBackendOptions.rid({required this.sssdCompat})
    : backend = 'RID',
      schemaMode = null,
      unixPrimaryGroup = null,
      unixNssInfo = null;

  const DirectoryIdmapBackendOptions.ad({
    required this.schemaMode,
    required this.unixPrimaryGroup,
    required this.unixNssInfo,
  }) : backend = 'AD',
       sssdCompat = null;

  final String backend;
  final bool? sssdCompat, unixPrimaryGroup, unixNssInfo;
  final String? schemaMode;

  bool get valid => backend == 'RID'
      ? sssdCompat != null &&
            schemaMode == null &&
            unixPrimaryGroup == null &&
            unixNssInfo == null
      : backend == 'AD' &&
            {'RFC2307', 'SFU', 'SFU20'}.contains(schemaMode) &&
            sssdCompat == null &&
            unixPrimaryGroup != null &&
            unixNssInfo != null;

  bool sameAs(DirectoryIdmapBackendOptions other) =>
      backend == other.backend &&
      sssdCompat == other.sssdCompat &&
      schemaMode == other.schemaMode &&
      unixPrimaryGroup == other.unixPrimaryGroup &&
      unixNssInfo == other.unixNssInfo;
}

final class DirectoryIdmapDomain {
  const DirectoryIdmapDomain({
    required this.label,
    required this.backend,
    required this.range,
    this.options,
  });
  final String label, backend;
  final DirectoryIdmapRange range;
  final DirectoryIdmapBackendOptions? options;
}

/// One new, explicitly named trusted domain. No discovery or domain join occurs.
final class DirectoryIdmapTrustedAddition {
  const DirectoryIdmapTrustedAddition({
    required this.name,
    required this.range,
    required this.options,
  });
  final String name;
  final DirectoryIdmapRange range;
  final DirectoryIdmapBackendOptions options;

  bool get valid =>
      RegExp(r'^[A-Z][A-Z0-9_-]{0,14}$').stringMatch(name) == name &&
      name != 'BUILTIN' &&
      range.valid &&
      options.valid;

  Map<String, Object?> toConfiguration() => {
    'name': name,
    'idmap_backend': options.backend,
    'range_low': range.low,
    'range_high': range.high,
    if (options.backend == 'RID')
      'sssd_compat': options.sssdCompat
    else ...{
      'schema_mode': options.schemaMode,
      'unix_primary_group': options.unixPrimaryGroup,
      'unix_nss_info': options.unixNssInfo,
    },
  };
}

/// An isolated backend migration for one existing primary or trusted domain.
/// The caller must independently verify account mappings before applying it.
final class DirectoryIdmapBackendTransition {
  const DirectoryIdmapBackendTransition.primary(this.options)
    : trustedName = null;
  const DirectoryIdmapBackendTransition.trusted(this.trustedName, this.options);

  final String? trustedName;
  final DirectoryIdmapBackendOptions options;

  String get label => trustedName ?? 'Primary domain';
}

/// A local-only proposal. It never contains the directory credential or raw
/// configuration, and cannot itself dispatch a server mutation.
final class DirectoryIdmapRangeDraft {
  DirectoryIdmapRangeDraft({
    required this.builtin,
    required this.primary,
    List<DirectoryIdmapRange> trusted = const [],
    List<DirectoryIdmapBackendOptions?> options = const [],
    this.addition,
    this.removal,
    this.transition,
  }) : trusted = List.unmodifiable(trusted),
       options = List.unmodifiable(options);

  final DirectoryIdmapRange builtin, primary;
  final List<DirectoryIdmapRange> trusted;
  final List<DirectoryIdmapBackendOptions?> options;
  final DirectoryIdmapTrustedAddition? addition;
  final String? removal;
  final DirectoryIdmapBackendTransition? transition;

  String? validateAgainst(DirectoryIdmapInventory inventory) {
    if (!inventory.isActiveDirectory ||
        inventory.enabled ||
        inventory.status != null && inventory.status != 'DISABLED' ||
        inventory.builtin == null ||
        inventory.primary == null) {
      return 'Disable Active Directory before editing ID mapping.';
    }
    if (!{'RID', 'AD'}.contains(inventory.primary!.backend) ||
        inventory.trusted.length > 8 ||
        trusted.length != inventory.trusted.length ||
        inventory.trusted.any(
          (domain) => !{'RID', 'AD'}.contains(domain.backend),
        ) ||
        inventory.trusted.map((domain) => domain.label).toSet().length !=
            inventory.trusted.length) {
      return 'This editor supports up to eight existing RID or AD trusted domains without changing their identity.';
    }
    if (inventory.warnings.isNotEmpty) {
      return 'Resolve existing range issues in TrueNAS before using this bounded editor.';
    }
    if (addition != null &&
        (inventory.trusted.length >= 8 ||
            !addition!.valid ||
            inventory.trusted.any(
              (domain) => domain.label.toUpperCase() == addition!.name,
            ))) {
      return 'A new trusted domain needs a unique uppercase NetBIOS name, a supported RID/AD backend and a valid range.';
    }
    if (removal != null &&
        (addition != null ||
            inventory.trusted
                    .where((domain) => domain.label == removal)
                    .length !=
                1)) {
      return 'Remove exactly one existing trusted domain without adding another.';
    }
    if (transition != null) {
      final matches = transition!.trustedName == null
          ? [inventory.primary!]
          : inventory.trusted
                .where((domain) => domain.label == transition!.trustedName)
                .toList();
      if (matches.length != 1 ||
          matches.single.options == null ||
          !transition!.options.valid ||
          matches.single.backend == transition!.options.backend ||
          addition != null ||
          removal != null) {
        return 'Migrate one existing RID or AD domain to the other backend separately.';
      }
    }

    if (options.isNotEmpty) {
      final domains = [inventory.primary!, ...inventory.trusted];
      if (options.length != domains.length) {
        return 'Backend option count must match the existing domains.';
      }
      for (var i = 0; i < options.length; i++) {
        final option = options[i];
        if (option != null &&
            (!option.valid ||
                option.backend != domains[i].backend ||
                domains[i].options == null)) {
          return 'Only supported options of existing RID or AD domains may be edited.';
        }
      }
    }
    final proposed = [
      builtin,
      primary,
      ...trusted,
      if (addition != null) addition!.range,
    ];
    if (proposed.any((range) => !range.valid)) {
      return 'Each range must be 1000–2147000000 and span at least 10000 IDs.';
    }
    for (var i = 0; i < proposed.length; i++) {
      for (var j = i + 1; j < proposed.length; j++) {
        if (proposed[i].overlaps(proposed[j])) {
          return 'BUILTIN, primary and trusted domain ranges must not overlap.';
        }
      }
    }
    final changes = changesFrom(inventory);
    if (removal != null && changes.length != 1) {
      return 'Remove a trusted domain separately from range and option edits.';
    }
    if (transition != null && changes.length != 1) {
      return 'Migrate a backend separately from range and option edits.';
    }
    if (changes.isEmpty) {
      return 'Change at least one range or backend option.';
    }
    return null;
  }

  List<String> changesFrom(DirectoryIdmapInventory inventory) {
    final changes = <String>[];
    void add(
      String label,
      DirectoryIdmapRange? before,
      DirectoryIdmapRange after,
    ) {
      if (before == null) return;
      if (before.low != after.low || before.high != after.high) {
        changes.add(
          '$label: ${before.low}–${before.high} → ${after.low}–${after.high}',
        );
      }
    }

    add('BUILTIN', inventory.builtin?.range, builtin);
    add('Primary domain', inventory.primary?.range, primary);
    for (var i = 0; i < trusted.length && i < inventory.trusted.length; i++) {
      add(inventory.trusted[i].label, inventory.trusted[i].range, trusted[i]);
    }
    final domains = [
      if (inventory.primary != null) inventory.primary!,
      ...inventory.trusted,
    ];
    for (var i = 0; i < options.length && i < domains.length; i++) {
      final after = options[i], before = domains[i].options;
      if (after == null || before == null || after.backend != before.backend) {
        continue;
      }
      void option(String label, Object? oldValue, Object? newValue) {
        if (oldValue != newValue) {
          changes.add('${domains[i].label} $label: $oldValue → $newValue');
        }
      }

      option('SSSD compatibility', before.sssdCompat, after.sssdCompat);
      option('schema mode', before.schemaMode, after.schemaMode);
      option(
        'Unix primary group',
        before.unixPrimaryGroup,
        after.unixPrimaryGroup,
      );
      option('Unix NSS info', before.unixNssInfo, after.unixNssInfo);
    }
    if (addition != null) {
      changes.add(
        'Add trusted domain ${addition!.name} (${addition!.options.backend}): ${addition!.range.low}–${addition!.range.high}',
      );
    }
    if (removal != null) {
      changes.add('Remove trusted domain $removal');
    }
    if (transition != null) {
      final current = transition!.trustedName == null
          ? inventory.primary
          : inventory.trusted
                .where((domain) => domain.label == transition!.trustedName)
                .firstOrNull;
      changes.add(
        '${transition!.label} backend: ${current?.backend ?? 'unknown'} → ${transition!.options.backend}',
      );
    }
    return List.unmodifiable(changes);
  }
}

/// Read-only LDAP settings; credentials and raw configuration are excluded.
final class DirectoryLdapOverview {
  DirectoryLdapOverview({
    required List<String> serverUrls,
    required this.baseDn,
    required this.schema,
    required this.startTls,
    required this.validateCertificates,
    this.credentialType,
    this.userSearchBase,
    this.groupSearchBase,
    this.netgroupSearchBase,
    this.attributeMaps,
    this.hasAuxiliaryParameters = false,
  }) : serverUrls = List.unmodifiable(serverUrls);

  final List<String> serverUrls;
  final String baseDn, schema;
  final String? credentialType;
  final String? userSearchBase, groupSearchBase, netgroupSearchBase;
  final DirectoryLdapAttributeMaps? attributeMaps;
  final bool startTls, validateCertificates, hasAuxiliaryParameters;
  bool get encryptedTransport =>
      startTls || serverUrls.every((url) => url.startsWith('ldaps://'));
}

final class DirectoryIdmapInventory {
  DirectoryIdmapInventory({
    required this.endpoint,
    required this.hostId,
    required this.serviceType,
    required this.enabled,
    required this.status,
    required this.builtin,
    required this.primary,
    required List<DirectoryIdmapDomain> trusted,
    this.ldap,
  }) : trusted = List.unmodifiable(trusted);
  final String endpoint, hostId;
  final String? serviceType, status;
  final bool enabled;
  final DirectoryIdmapDomain? builtin, primary;
  final List<DirectoryIdmapDomain> trusted;
  final DirectoryLdapOverview? ldap;

  bool get isActiveDirectory => serviceType == 'ACTIVEDIRECTORY';
  List<DirectoryIdmapDomain> get domains =>
      List.unmodifiable([?builtin, ?primary, ...trusted]);
  List<String> get warnings {
    final rows = domains;
    final issues = <String>[];
    for (final row in rows) {
      if (!row.range.valid) {
        issues.add(
          '${row.label}: range is outside the supported bounds or has fewer than 10,000 IDs.',
        );
      }
    }
    for (var i = 0; i < rows.length; i++) {
      for (var j = i + 1; j < rows.length; j++) {
        if (rows[i].range.overlaps(rows[j].range)) {
          issues.add('${rows[i].label} overlaps ${rows[j].label}.');
        }
      }
    }
    return List.unmodifiable(issues);
  }
}

final class DirectoryIdmapException implements Exception {
  const DirectoryIdmapException();
  String get userMessage =>
      'Unable to inspect or update directory ID mapping safely.';
}

final class DirectoryIdmapReview {
  DirectoryIdmapReview._({
    required this.draft,
    required this.inventory,
    required this.confirmation,
    required this.expiresAt,
    required this.proof,
  });

  final DirectoryIdmapRangeDraft draft;
  final DirectoryIdmapInventory inventory;
  final String confirmation;
  final DateTime expiresAt;
  final String proof;
  List<String> get changes => draft.changesFrom(inventory);
}

final class DirectoryIdmapJob {
  const DirectoryIdmapJob._(
    this.id,
    this.endpoint,
    this.payloadProof,
    this._beforeProof,
    this._expectedConfiguration,
    this._expectedCredential,
    this._draft,
    this._hostId,
  );
  final int id;
  final String endpoint, payloadProof;
  final String _beforeProof, _hostId;
  final Map<String, Object?> _expectedConfiguration;
  final Map<String, Object?> _expectedCredential;
  final DirectoryIdmapRangeDraft _draft;
}

enum DirectoryIdmapOutcome { pending, completed, rejected, unknown }

final class DirectoryIdmapResult {
  const DirectoryIdmapResult(this.outcome, this.message, {this.job});
  final DirectoryIdmapOutcome outcome;
  final String message;
  final DirectoryIdmapJob? job;
}

enum DirectoryMaintenanceAction {
  refreshCache,
  syncKeytab;

  String get method => switch (this) {
    refreshCache => 'directoryservices.cache_refresh',
    syncKeytab => 'directoryservices.sync_keytab',
  };
  String get label => switch (this) {
    refreshCache => 'cache refresh',
    syncKeytab => 'keytab sync',
  };
}

final class DirectoryMaintenanceReview {
  const DirectoryMaintenanceReview._(
    this.action,
    this.inventory,
    this.confirmation,
    this.expiresAt,
    this._proof,
  );
  final DirectoryMaintenanceAction action;
  final DirectoryIdmapInventory inventory;
  final String confirmation;
  final DateTime expiresAt;
  final String _proof;
}

final class DirectoryMaintenanceJob {
  const DirectoryMaintenanceJob._(
    this.action,
    this.id,
    this.endpoint,
    this.hostId,
    this._proof,
  );
  final DirectoryMaintenanceAction action;
  final int id;
  final String endpoint, hostId, _proof;
}

final class DirectoryMaintenanceResult {
  const DirectoryMaintenanceResult(this.outcome, this.message, {this.job});
  final DirectoryIdmapOutcome outcome;
  final String message;
  final DirectoryMaintenanceJob? job;
}

final class _SessionDirectoryIdmap {
  _SessionDirectoryIdmap({
    required this.client,
    required ServerSummary summary,
    required Object? metadata,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherMutationBusy,
    required this.requestTimeout,
  }) : _endpoint = summary.endpointUri.toString(),
       _version =
           _managementVersion(summary.version) == _ManagementVersion.v2510,
       _metadata = metadata is Map ? Map.of(metadata) : const {};

  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent;
  final bool Function() isOtherMutationBusy;
  final Duration requestTimeout;
  final String _endpoint;
  final bool _version;
  final Map _metadata;
  final Uint8List _key = _idmapKey();
  DirectoryIdmapReview? _review;
  DirectoryIdmapJob? _job;
  DirectoryLdapReview? _ldapReview;
  DirectoryLdapJob? _ldapJob;
  DirectoryLdapActivationReview? _activationReview;
  DirectoryLdapActivationJob? _activationJob;
  DirectoryMaintenanceReview? _maintenanceReview;
  DirectoryMaintenanceJob? _maintenanceJob;
  bool _busy = false, _uncertain = false, _disposed = false;
  bool get isBusy => _busy || _uncertain;
  void dispose() {
    _disposed = true;
    _key.fillRange(0, _key.length, 0);
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
        (row['check_pipes'] == null || row['check_pipes'] == false);
  }

  DirectoryIdmapCapabilities get capabilities => DirectoryIdmapCapabilities(
    connected: isCurrent(),
    versionSupported: _version,
    available: [
      'system.host_id',
      'directoryservices.config',
      'directoryservices.status',
    ].every(_method),
    cacheRefreshAvailable:
        !_disposed &&
        [
          'auth.me',
          'failover.licensed',
          'system.state',
          'core.get_jobs',
        ].every(_method) &&
        _jobMethod('directoryservices.cache_refresh'),
    keytabSyncAvailable:
        !_disposed &&
        [
          'auth.me',
          'failover.licensed',
          'system.state',
          'core.get_jobs',
        ].every(_method) &&
        _jobMethod('directoryservices.sync_keytab'),
    editAvailable:
        !_disposed &&
        [
          'auth.me',
          'failover.licensed',
          'system.state',
          'core.get_jobs',
        ].every(_method) &&
        _jobMethod('directoryservices.update'),
  );

  Future<Object?> _call(String method) async {
    if (!capabilities.canRead) throw const DirectoryIdmapException();
    final value = await client
        .call(method, id: nextId(), params: const [])
        .timeout(requestTimeout);
    if (!capabilities.canRead) throw const DirectoryIdmapException();
    return value;
  }

  Future<DirectoryIdmapInventory> load() async {
    try {
      final host = await _call('system.host_id');
      if (host is! String ||
          host.length != 64 ||
          RegExp(r'^[0-9a-f]{64}$').stringMatch(host) != host) {
        throw const DirectoryIdmapException();
      }
      // The full response may include protected credential material. Project
      // only the fields below and never retain or expose the source map.
      final raw = await _call('directoryservices.config');
      final statusRaw = await _call('directoryservices.status');
      final afterHost = await _call('system.host_id');
      if (afterHost != host ||
          raw is! Map ||
          raw['enable'] is! bool ||
          !{
            null,
            'ACTIVEDIRECTORY',
            'IPA',
            'LDAP',
          }.contains(raw['service_type']) ||
          statusRaw is! Map ||
          (raw['enable'] == true
              ? statusRaw['type'] != raw['service_type']
              : statusRaw['type'] != null &&
                    statusRaw['type'] != raw['service_type']) ||
          !{
            null,
            'DISABLED',
            'FAULTED',
            'LEAVING',
            'JOINING',
            'HEALTHY',
          }.contains(statusRaw['status'])) {
        throw const DirectoryIdmapException();
      }
      final type = raw['service_type'] as String?;
      DirectoryIdmapDomain? builtin, primary;
      final trusted = <DirectoryIdmapDomain>[];
      DirectoryLdapOverview? ldap;
      if (type == 'ACTIVEDIRECTORY') {
        final config = raw['configuration'];
        if (config is! Map || config['idmap'] is! Map) {
          throw const DirectoryIdmapException();
        }
        final idmap = config['idmap'] as Map;
        builtin = _domain(idmap['builtin'], 'BUILTIN', 'TDB');
        primary = _domain(idmap['idmap_domain'], 'Primary domain');
        final others = config['trusted_domains'];
        if (others is! List || others.length > 64) {
          throw const DirectoryIdmapException();
        }
        for (final item in others) {
          if (item is! Map ||
              item['name'] is! String ||
              (item['name'] as String).isEmpty ||
              (item['name'] as String).length > 120 ||
              !_safeName(item['name'] as String)) {
            throw const DirectoryIdmapException();
          }
          trusted.add(_domain(item, item['name'] as String));
        }
      } else if (type == 'LDAP') {
        ldap = _ldapOverview(raw['configuration'], raw['credential']);
      }
      return DirectoryIdmapInventory(
        endpoint: _endpoint,
        hostId: host,
        serviceType: type,
        enabled: raw['enable'] as bool,
        status: statusRaw['status'] as String?,
        builtin: builtin,
        primary: primary,
        trusted: trusted,
        ldap: ldap,
      );
    } on Object {
      throw const DirectoryIdmapException();
    }
  }

  DirectoryLdapOverview _ldapOverview(Object? source, Object? credential) {
    if (source is! Map ||
        source['server_urls'] is! List ||
        source['basedn'] is! String ||
        source['starttls'] != null && source['starttls'] is! bool ||
        source['validate_certificates'] != null &&
            source['validate_certificates'] is! bool ||
        source['schema'] != null &&
            !{'RFC2307', 'RFC2307BIS'}.contains(source['schema'])) {
      throw const DirectoryIdmapException();
    }
    final baseDn = source['basedn'] as String;
    final rawUrls = source['server_urls'] as List;
    if (baseDn.isEmpty ||
        baseDn.length > 1024 ||
        baseDn.runes.any((rune) => rune < 32 || rune == 127) ||
        rawUrls.isEmpty ||
        rawUrls.length > 16) {
      throw const DirectoryIdmapException();
    }
    final urls = <String>[];
    for (final value in rawUrls) {
      if (value is! String || value.length > 512) {
        throw const DirectoryIdmapException();
      }
      final uri = Uri.tryParse(value);
      if (uri == null ||
          !{'ldap', 'ldaps'}.contains(uri.scheme) ||
          !uri.hasAuthority ||
          uri.host.isEmpty ||
          uri.userInfo.isNotEmpty ||
          uri.path.isNotEmpty && uri.path != '/' ||
          uri.hasQuery ||
          uri.hasFragment) {
        throw const DirectoryIdmapException();
      }
      urls.add('${uri.scheme}://${uri.authority}');
    }
    final searchBases = source['search_bases'];
    if (searchBases != null &&
        (searchBases is! Map ||
            !_idmapKeys(searchBases, {
              'base_user',
              'base_group',
              'base_netgroup',
            }, {}) ||
            searchBases.values.any(
              (value) =>
                  value != null &&
                  (value is! String ||
                      !_idmapText(value) ||
                      value.length > 512),
            ))) {
      throw const DirectoryIdmapException();
    }
    final attributeMaps = DirectoryLdapAttributeMaps.parse(
      source['attribute_maps'],
    );
    if (attributeMaps == null) throw const DirectoryIdmapException();
    final credentialType = credential is Map
        ? credential['credential_type']
        : null;
    return DirectoryLdapOverview(
      serverUrls: urls,
      attributeMaps: attributeMaps,
      hasAuxiliaryParameters: source['auxiliary_parameters'] != null,
      credentialType:
          credentialType is String &&
              {
                'LDAP_ANONYMOUS',
                'LDAP_PLAIN',
                'LDAP_MTLS',
                'KERBEROS_USER',
                'KERBEROS_PRINCIPAL',
              }.contains(credentialType)
          ? credentialType
          : null,
      baseDn: baseDn,
      schema: source['schema'] as String? ?? 'RFC2307',
      startTls: source['starttls'] as bool? ?? false,
      validateCertificates: source['validate_certificates'] as bool? ?? true,
      userSearchBase: searchBases is Map
          ? searchBases['base_user'] as String?
          : null,
      groupSearchBase: searchBases is Map
          ? searchBases['base_group'] as String?
          : null,
      netgroupSearchBase: searchBases is Map
          ? searchBases['base_netgroup'] as String?
          : null,
    );
  }

  bool _safeName(String value) =>
      RegExp(r'^[A-Za-z0-9_.-]+$').stringMatch(value) == value;

  DirectoryIdmapDomain _domain(
    Object? raw,
    String label, [
    String? fixedBackend,
  ]) {
    if (raw is! Map ||
        raw['range_low'] is! int ||
        raw['range_high'] is! int ||
        raw['range_low'] < 0 ||
        raw['range_high'] < 0 ||
        raw['range_low'] > 4294967295 ||
        raw['range_high'] > 4294967295) {
      throw const DirectoryIdmapException();
    }
    final backend = fixedBackend ?? raw['idmap_backend'];
    if (backend is! String ||
        !{'RID', 'AD', 'LDAP', 'RFC2307', 'TDB', 'SSS'}.contains(backend)) {
      throw const DirectoryIdmapException();
    }
    DirectoryIdmapBackendOptions? options;
    if (backend == 'RID' && raw['sssd_compat'] is bool) {
      options = DirectoryIdmapBackendOptions.rid(
        sssdCompat: raw['sssd_compat'] as bool,
      );
    } else if (backend == 'AD' &&
        {'RFC2307', 'SFU', 'SFU20'}.contains(raw['schema_mode']) &&
        raw['unix_primary_group'] is bool &&
        raw['unix_nss_info'] is bool) {
      options = DirectoryIdmapBackendOptions.ad(
        schemaMode: raw['schema_mode'] as String,
        unixPrimaryGroup: raw['unix_primary_group'] as bool,
        unixNssInfo: raw['unix_nss_info'] as bool,
      );
    }
    return DirectoryIdmapDomain(
      label: label,
      backend: backend,
      options: options,
      range: DirectoryIdmapRange(
        low: raw['range_low'] as int,
        high: raw['range_high'] as int,
      ),
    );
  }
}
