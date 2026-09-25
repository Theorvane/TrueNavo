part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedNotificationProvidersSession {
  NotificationProvidersCapabilities get notificationProvidersCapabilities;
  Future<NotificationProvidersInventory> loadNotificationProviders();
  Future<NotificationProvidersReview> reviewNotificationProviders(
    NotificationProvidersRequest request,
  );
  Future<NotificationProvidersResult> executeNotificationProviders(
    NotificationProvidersReview review,
    String confirmation, {
    required bool Function() isCurrent,
  });
}

enum NotificationProvidersAction { create, replace, enable, disable, delete }

enum NotificationProviderType {
  slack,
  mattermost,
  telegram,
  pagerDuty,
  opsGenie,
  victorOps,
  awsSns,
  influxDb,
  snmpTrap;

  String get wireName => switch (this) {
    slack => 'Slack',
    mattermost => 'Mattermost',
    telegram => 'Telegram',
    pagerDuty => 'PagerDuty',
    opsGenie => 'OpsGenie',
    victorOps => 'VictorOps',
    awsSns => 'AWSSNS',
    influxDb => 'InfluxDB',
    snmpTrap => 'SNMPTrap',
  };
  String get label => switch (this) {
    awsSns => 'Amazon SNS',
    influxDb => 'InfluxDB',
    snmpTrap => 'SNMP trap (v2c)',
    _ => wireName,
  };
  bool get unencrypted => this == influxDb || this == snmpTrap;
}

enum NotificationFieldKind { text, integer, integerList, secret, secretUrl }

final class NotificationProviderField {
  const NotificationProviderField(
    this.key,
    this.label,
    this.kind, {
    this.optional = false,
    this.initialValue = '',
  });
  final String key, label;
  final NotificationFieldKind kind;
  final bool optional;
  final Object initialValue;
  bool get secret =>
      kind == NotificationFieldKind.secret ||
      kind == NotificationFieldKind.secretUrl;
}

List<NotificationProviderField> notificationProviderFields(
  NotificationProviderType type,
) => switch (type) {
  NotificationProviderType.slack => const [
    NotificationProviderField(
      'url',
      'HTTPS webhook URL',
      NotificationFieldKind.secretUrl,
    ),
  ],
  NotificationProviderType.mattermost => const [
    NotificationProviderField(
      'url',
      'HTTPS webhook URL',
      NotificationFieldKind.secretUrl,
    ),
    NotificationProviderField(
      'username',
      'Display username',
      NotificationFieldKind.text,
    ),
    NotificationProviderField(
      'channel',
      'Channel (blank uses webhook default)',
      NotificationFieldKind.text,
      optional: true,
    ),
    NotificationProviderField(
      'icon_url',
      'HTTPS icon URL (optional; provider may fetch it)',
      NotificationFieldKind.secretUrl,
      optional: true,
    ),
  ],
  NotificationProviderType.telegram => const [
    NotificationProviderField(
      'bot_token',
      'Bot token',
      NotificationFieldKind.secret,
    ),
    NotificationProviderField(
      'chat_ids',
      'Exact chat IDs (comma-separated integers)',
      NotificationFieldKind.integerList,
      initialValue: <int>[],
    ),
  ],
  NotificationProviderType.pagerDuty => const [
    NotificationProviderField(
      'service_key',
      'Service integration key',
      NotificationFieldKind.secret,
    ),
    NotificationProviderField(
      'client_name',
      'Client name',
      NotificationFieldKind.text,
    ),
  ],
  NotificationProviderType.opsGenie => const [
    NotificationProviderField(
      'api_key',
      'API key',
      NotificationFieldKind.secret,
    ),
    NotificationProviderField(
      'api_url',
      'HTTPS API base URL (blank uses api.opsgenie.com)',
      NotificationFieldKind.secretUrl,
      optional: true,
    ),
  ],
  NotificationProviderType.victorOps => const [
    NotificationProviderField(
      'api_key',
      'API key',
      NotificationFieldKind.secret,
    ),
    NotificationProviderField(
      'routing_key',
      'Routing key',
      NotificationFieldKind.secret,
    ),
  ],
  NotificationProviderType.awsSns => const [
    NotificationProviderField(
      'region',
      'AWS region',
      NotificationFieldKind.text,
    ),
    NotificationProviderField(
      'topic_arn',
      'Exact SNS topic ARN',
      NotificationFieldKind.text,
    ),
    NotificationProviderField(
      'aws_access_key_id',
      'AWS access key ID',
      NotificationFieldKind.secret,
    ),
    NotificationProviderField(
      'aws_secret_access_key',
      'AWS secret access key',
      NotificationFieldKind.secret,
    ),
  ],
  NotificationProviderType.influxDb => const [
    NotificationProviderField(
      'host',
      'Server hostname or IPv4 address (port fixed to 8086)',
      NotificationFieldKind.text,
    ),
    NotificationProviderField(
      'username',
      'Username',
      NotificationFieldKind.text,
    ),
    NotificationProviderField(
      'password',
      'Password',
      NotificationFieldKind.secret,
    ),
    NotificationProviderField(
      'database',
      'Database',
      NotificationFieldKind.text,
    ),
    NotificationProviderField(
      'series_name',
      'Series name',
      NotificationFieldKind.text,
    ),
  ],
  NotificationProviderType.snmpTrap => const [
    NotificationProviderField(
      'host',
      'Receiver hostname or IPv4 address',
      NotificationFieldKind.text,
    ),
    NotificationProviderField(
      'port',
      'UDP receiver port',
      NotificationFieldKind.integer,
      initialValue: 162,
    ),
    NotificationProviderField(
      'community',
      'Community (sent without encryption)',
      NotificationFieldKind.secret,
    ),
  ],
};

final class NotificationProvidersCapabilities {
  const NotificationProvidersCapabilities({
    this.connected = false,
    this.versionSupported = false,
    this.available = false,
    this.canCreate = false,
    this.canUpdate = false,
    this.canDelete = false,
  });
  const NotificationProvidersCapabilities.disconnected()
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
  bool supports(NotificationProvidersAction action) =>
      supported &&
      switch (action) {
        NotificationProvidersAction.create => canCreate,
        NotificationProvidersAction.delete => canDelete,
        _ => canUpdate,
      };
  String? get blockedReason => !connected
      ? 'Connect to inspect notification providers.'
      : !versionSupported
      ? 'Native notification providers require stable TrueNAS 25.10.'
      : !available
      ? 'Required public provider and readiness reads are unavailable.'
      : null;
}

final class NotificationProviderSnapshot {
  const NotificationProviderSnapshot({
    required this.id,
    required this.name,
    required this.type,
    required this.level,
    required this.enabled,
  });
  final int id;
  final String name, type;
  final AlertDeliveryLevel level;
  final bool enabled;
  NotificationProviderType? get provider => NotificationProviderType.values
      .where((p) => p.wireName == type)
      .singleOrNull;
}

final class NotificationProvidersInventory {
  NotificationProvidersInventory({
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
    required List<NotificationProviderSnapshot> services,
    List<String> rebootReasonCodes = const [],
  }) : environments = List.unmodifiable(environments),
       services = List.unmodifiable(services),
       rebootReasonCodes = List.unmodifiable(rebootReasonCodes);
  final String endpoint, hostId, bootId, currentVersion, state, bootPool;
  final bool fullAdmin, failoverLicensed, conflictingJob, bootHealthy;
  final List<BootEnvironmentSnapshot> environments;
  final List<NotificationProviderSnapshot> services;
  final List<String> rebootReasonCodes;
  BootEnvironmentSnapshot? get currentEnvironment =>
      environments.where((e) => e.active).singleOrNull;
  BootEnvironmentSnapshot? get nextEnvironment =>
      environments.where((e) => e.activated).singleOrNull;
  String? get readinessBlockedReason => !fullAdmin
      ? 'FULL_ADMIN is required for notification-provider changes.'
      : failoverLicensed
      ? 'Use the coordinated TrueNAS HA workflow.'
      : state != 'READY'
      ? 'The original server must report READY.'
      : conflictingJob
      ? 'A visible active or waiting job prevents a provider change.'
      : !bootHealthy
      ? 'The boot pool must be healthy, online and not scanning.'
      : currentEnvironment == null ||
            nextEnvironment == null ||
            !currentEnvironment!.canActivate ||
            currentEnvironment!.id != nextEnvironment!.id
      ? 'An unchanged bootable current and next environment is required.'
      : null;
  String? get blockedReason => readinessBlockedReason;
}

final class NotificationProviderSettings {
  NotificationProviderSettings({
    required this.provider,
    required this.name,
    this.level = AlertDeliveryLevel.warning,
    required Map<String, Object?> fields,
  }) : fields = Map.unmodifiable({
         for (final e in fields.entries)
           e.key: e.value is List
               ? List<Object?>.unmodifiable(e.value as List)
               : e.value,
       });
  final NotificationProviderType provider;
  final String name;
  final AlertDeliveryLevel level;
  final Map<String, Object?> fields;
  String? get validationError => !_deliveryName(name)
      ? 'Use a nonempty service name up to 120 characters without surrounding whitespace or controls.'
      : _npValidateFields(provider, fields);
}

final class NotificationProviderCredentials {
  factory NotificationProviderCredentials({
    required NotificationProviderType provider,
    required Map<String, String> values,
  }) {
    final definitions = notificationProviderFields(provider)
        .where((f) => f.secret)
        .toList();
    final valid =
        values.length == definitions.length &&
        definitions.every(
          (f) =>
              values.containsKey(f.key) &&
              _npSecret(values[f.key]!, optional: f.optional),
        );
    return NotificationProviderCredentials._(
      provider,
      valid
          ? {
              for (final e in values.entries)
                e.key: Uint8List.fromList(e.value.codeUnits),
            }
          : {},
      valid,
    );
  }
  NotificationProviderCredentials._(this.provider, this._values, this._valid);
  final NotificationProviderType provider;
  final Map<String, Uint8List> _values;
  final bool _valid;
  bool _disposed = false;
  bool get isDisposed => _disposed;
  String? get validationError => !_valid || _disposed
      ? 'Enter every required new credential as bounded printable ASCII. Masked, missing or disposed credentials cannot be submitted.'
      : null;
  void dispose() {
    for (final bytes in _values.values) {
      bytes.fillRange(0, bytes.length, 0);
    }
    _values.clear();
    _disposed = true;
  }

  @override
  String toString() =>
      'NotificationProviderCredentials(${provider.name}, redacted)';
}

final class NotificationProvidersRequest {
  const NotificationProvidersRequest({
    required this.inventory,
    required this.action,
    this.service,
    this.settings,
    this.credentials,
  });
  final NotificationProvidersInventory inventory;
  final NotificationProvidersAction action;
  final NotificationProviderSnapshot? service;
  final NotificationProviderSettings? settings;
  final NotificationProviderCredentials? credentials;
  NotificationProviderType? get provider =>
      settings?.provider ?? service?.provider;
  String get target =>
      '${action.name.toUpperCase()} NOTIFICATION ${inventory.hostId} ${provider?.wireName ?? 'UNSUPPORTED'}${service == null ? '' : ' ${service!.id}'}';
  String? get validationError {
    if (inventory.blockedReason != null) return inventory.blockedReason;
    if (provider == null) {
      return 'Choose a supported non-Mail provider. Unknown providers and Mail use separate workflows.';
    }
    if (action == NotificationProvidersAction.create) {
      if (service != null || inventory.services.length >= 128) {
        return 'Create a new disabled provider; at most 128 configured services are supported.';
      }
    } else if (service == null ||
        !inventory.services.any((s) => identical(s, service)) ||
        service!.provider != provider) {
      return 'Choose the exact supported provider row from this inventory; conversion is not permitted.';
    }
    if (action == NotificationProvidersAction.create ||
        action == NotificationProvidersAction.replace) {
      if (action == NotificationProvidersAction.replace && service!.enabled) {
        return 'Disable the provider separately before replacing its configuration.';
      }
      if (settings == null || settings!.validationError != null) {
        return settings?.validationError ??
            'Enter the complete replacement configuration.';
      }
      if (credentials == null ||
          credentials!.provider != provider ||
          credentials!.validationError != null) {
        return credentials?.validationError ??
            'Enter fresh credentials for this provider.';
      }
      if (inventory.services.any(
        (s) =>
            !identical(s, service) &&
            s.name.toLowerCase() == settings!.name.toLowerCase(),
      )) {
        return 'Choose a service name not already configured.';
      }
      return _npValidateAttributes(
        provider!,
        _npNewAttributes(settings!, credentials!),
        forEnable: true,
      );
    }
    if (settings != null || credentials != null) {
      return 'Enable, disable and delete preserve the reviewed row; edited values are not allowed.';
    }
    return switch (action) {
      NotificationProvidersAction.enable =>
        service!.enabled ? 'The provider is already enabled.' : null,
      NotificationProvidersAction.disable =>
        !service!.enabled ? 'The provider is already disabled.' : null,
      NotificationProvidersAction.delete =>
        service!.enabled
            ? 'Disable the provider separately before deletion.'
            : null,
      _ => null,
    };
  }
}

final class NotificationProvidersReview {
  NotificationProvidersReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
    required this.destinationSummary,
    required Map<String, String> publicFields,
    required this.unencrypted,
  }) : warnings = List.unmodifiable(warnings),
       publicFields = Map.unmodifiable(publicFields);
  final NotificationProvidersRequest request;
  final String endpoint, destinationSummary;
  final List<String> warnings;
  final Map<String, String> publicFields;
  final bool unencrypted;
  String get target => request.target;
  NotificationProvidersAction get action => request.action;
}

enum NotificationProvidersOutcome { completed, rejected, unknown }

final class NotificationProvidersResult {
  const NotificationProvidersResult(this.outcome, this.message);
  final NotificationProvidersOutcome outcome;
  final String message;
}

enum NotificationProvidersExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class NotificationProvidersException implements Exception {
  const NotificationProvidersException(this.reason);
  final NotificationProvidersExceptionReason reason;
  String get userMessage => switch (reason) {
    NotificationProvidersExceptionReason.notAuthenticated =>
      'Connect again before changing notification providers.',
    NotificationProvidersExceptionReason.unsupportedVersion =>
      'Native provider changes require stable TrueNAS 25.10.',
    NotificationProvidersExceptionReason.unavailableMethod =>
      'Required public provider methods are unavailable.',
    NotificationProvidersExceptionReason.busy =>
      'Another operation or an unresolved outcome blocks this change.',
    NotificationProvidersExceptionReason.staleReview => 'The reviewed provider, connection or authorization changed; no new request was authorized.',
    NotificationProvidersExceptionReason.invalidRequest => 'Complete the supported provider fields and resolve displayed restrictions.',
    NotificationProvidersExceptionReason.invalidResponse => 'Provider attributes are masked, unknown or outside the supported variant. Use TrueNAS; no secret values are exposed.',
    NotificationProvidersExceptionReason.unavailable => 'Provider information is unavailable. Remote details and credentials were withheld.',
  };
  @override
  String toString() => userMessage;
}

bool _npSecret(String value, {bool optional = false}) =>
    (optional && value.isEmpty ||
        value.isNotEmpty &&
            value.length <= 1024 &&
            value.codeUnits.every((c) => c >= 32 && c <= 126)) &&
    !_npMasked(value);
bool _npMasked(String value) =>
    RegExp(r'^\*+$').hasMatch(value) ||
    const {'<redacted>', '<hidden>', '********', 'REDACTED'}.contains(value);
String? _npValidateFields(
  NotificationProviderType type,
  Map<String, Object?> fields,
) {
  final definitions = notificationProviderFields(type)
      .where((f) => !f.secret)
      .toList();
  if (fields.length != definitions.length ||
      definitions.any((f) => !fields.containsKey(f.key))) {
    return 'Supply exactly the compiled public fields for this provider.';
  }
  for (final field in definitions) {
    final value = fields[field.key];
    if (field.kind == NotificationFieldKind.integer) {
      if (value is! int || value < 1 || value > 65535) {
        return 'Use a port from 1 to 65535.';
      }
    } else if (field.kind == NotificationFieldKind.integerList) {
      if (value is! List ||
          value.isEmpty ||
          value.length > 32 ||
          value.any((v) => v is! int || v == 0 || v.abs() > 9007199254740991) ||
          value.toSet().length != value.length) {
        return 'Use 1–32 unique nonzero exact chat IDs within safe integer bounds.';
      }
    } else if (value is! String ||
        !_emailText(value, 256) ||
        !field.optional && value.isEmpty ||
        value.trim() != value) {
      return 'Enter bounded text without controls or surrounding whitespace.';
    }
  }
  if (type == NotificationProviderType.influxDb ||
      type == NotificationProviderType.snmpTrap) {
    final host = fields['host'] as String;
    if (!_sshHost(host) || host.contains(':') || host.length > 120) {
      return 'Use a hostname or IPv4 literal without a URL, scope, port or IPv6 literal.';
    }
  }
  if (type == NotificationProviderType.awsSns) {
    final region = fields['region'] as String,
        arn = fields['topic_arn'] as String;
    if (!RegExp(r'^[a-z]{2}(?:-[a-z]+)+-\d+$').hasMatch(region) ||
        !RegExp(
          r'^arn:aws(?:-cn|-us-gov)?:sns:[a-z0-9-]+:\d{12}:[A-Za-z0-9_-]+(?:\.fifo)?$',
        ).hasMatch(arn) ||
        arn.split(':')[3] != region) {
      return 'Use an exact SNS topic ARN with a matching AWS region; subscriptions remain unverified.';
    }
  }
  return null;
}

Map<String, Object?> _npNewAttributes(
  NotificationProviderSettings settings,
  NotificationProviderCredentials credentials,
) => {
  'type': settings.provider.wireName,
  ...settings.fields,
  for (final entry in credentials._values.entries)
    entry.key: String.fromCharCodes(entry.value),
  if (settings.provider == NotificationProviderType.snmpTrap) ...{
    'v3': false,
    'v3_username': null,
    'v3_authkey': null,
    'v3_privkey': null,
    'v3_authprotocol': null,
    'v3_privprotocol': null,
  },
};
String? _npValidateAttributes(
  NotificationProviderType type,
  Map<String, Object?> attributes, {
  required bool forEnable,
}) {
  final definitions = notificationProviderFields(type),
      expected = {
        'type',
        for (final field in notificationProviderFields(type)) field.key,
        if (type == NotificationProviderType.snmpTrap) ...[
          'v3',
          'v3_username',
          'v3_authkey',
          'v3_privkey',
          'v3_authprotocol',
          'v3_privprotocol',
        ],
      };
  if (attributes.length != expected.length ||
      attributes.keys.any((k) => !expected.contains(k)) ||
      attributes['type'] != type.wireName) {
    return 'Unknown provider attributes are not writable.';
  }
  if (type == NotificationProviderType.snmpTrap &&
      (attributes['v3'] != false ||
          [
            'v3_username',
            'v3_authkey',
            'v3_privkey',
            'v3_authprotocol',
            'v3_privprotocol',
          ].any((key) => attributes[key] != null))) {
    return 'SNMP v3 and mixed legacy attributes are read-only in this workspace.';
  }
  final error = _npValidateFields(type, {
    for (final field in definitions.where((f) => !f.secret))
      field.key: attributes[field.key],
  });
  if (error != null) return error;
  for (final field in definitions.where((f) => f.secret)) {
    final value = attributes[field.key];
    if (value is! String || !_npSecret(value, optional: field.optional)) {
      return 'Provider credentials are masked, missing or unsupported.';
    }
    if (field.kind == NotificationFieldKind.secretUrl && value.isNotEmpty) {
      final uri = Uri.tryParse(value);
      if (uri == null ||
          !uri.hasAuthority ||
          uri.host.isEmpty ||
          !_sshHost(uri.host) ||
          uri.userInfo.isNotEmpty ||
          uri.fragment.isNotEmpty ||
          !['http', 'https'].contains(uri.scheme) ||
          forEnable && uri.scheme != 'https') {
        return 'Use HTTPS URLs without embedded userinfo or fragments; legacy HTTP cannot be enabled here.';
      }
      if (forEnable &&
          (value != uri.toString() ||
              uri.path.isEmpty ||
              uri.hasPort && uri.port == 443 ||
              value.contains('%') ||
              value.contains('\\') ||
              value.contains(' ') ||
              uri.normalizePath().toString() != value)) {
        return 'Use a canonical HTTPS URL: lowercase scheme and hostname, an explicit path (or /), no default port, whitespace, dot segments or percent-encoded variants.';
      }
    }
  }
  if (type == NotificationProviderType.telegram &&
      !RegExp(r'^\d+:[A-Za-z0-9_-]+$')
          .hasMatch(attributes['bot_token'] as String)) {
    return 'Use a bot token without URL path delimiters or controls.';
  }
  if (type == NotificationProviderType.victorOps &&
      ['api_key', 'routing_key'].any(
        (key) =>
            !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(attributes[key] as String),
      )) {
    return 'Use API and routing keys without URL path delimiters or controls.';
  }
  return null;
}

const _npTitles = <String, String>{
  'Slack': 'Slack',
  'Mattermost': 'Mattermost',
  'Telegram': 'Telegram',
  'PagerDuty': 'PagerDuty',
  'OpsGenie': 'OpsGenie',
  'VictorOps': 'VictorOps',
  'AWS SNS': 'AWSSNS',
  'InfluxDB': 'InfluxDB',
  'SNMP Trap': 'SNMPTrap',
  'Email': 'Mail',
};
const _npHeads = ['id', 'name', 'level', 'enabled', 'type__title'];
const _npDetails = ['id', 'name', 'level', 'enabled', 'attributes'];
const _npReads = {..._powerReads, 'auth.me', 'alertservice.query'};

final class _NpRead {
  const _NpRead(this.inventory, this.titles);
  final NotificationProvidersInventory inventory;
  final Map<int, String> titles;
}

final class _NpLease {
  const _NpLease(
    this.created,
    this.inventoryProof,
    this.beforeProof,
    this.afterProof,
  );
  final DateTime created;
  final String inventoryProof, beforeProof, afterProof;
}

final class _SessionNotificationProviders {
  _SessionNotificationProviders({
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
  final Uint8List _proofKey = Uint8List.fromList(
    List.generate(32, (_) => math.Random.secure().nextInt(256)),
  );
  final Map<NotificationProvidersInventory, String> _inventories = {};
  final Map<NotificationProvidersReview, _NpLease> _reviews = {};
  final Set<NotificationProviderCredentials> _credentials = {};
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
    final row = _metadata[method];
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

  NotificationProvidersCapabilities get capabilities =>
      NotificationProvidersCapabilities(
        connected: !_disposed && isCurrent(),
        versionSupported: _version,
        available: _npReads.every(_method),
        canCreate: _method('alertservice.create'),
        canUpdate: _method('alertservice.update'),
        canDelete: _method('alertservice.delete'),
      );
  void _guard([NotificationProvidersAction? action]) {
    if (_disposed || !isCurrent()) {
      _npThrow(NotificationProvidersExceptionReason.notAuthenticated);
    }
    if (!_current()) _npThrow(NotificationProvidersExceptionReason.staleReview);
    if (!_version) {
      _npThrow(NotificationProvidersExceptionReason.unsupportedVersion);
    }
    if (!capabilities.supported ||
        action != null && !capabilities.supports(action)) {
      _npThrow(NotificationProvidersExceptionReason.unavailableMethod);
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
    for (final credential in _credentials) {
      credential.dispose();
    }
    _credentials.clear();
  }

  void dispose() {
    _disposed = true;
    _clearReviews();
    _inventories.clear();
    _proofKey.fillRange(0, _proofKey.length, 0);
  }

  Future<_NpRead> _read() async {
    final admin = _configurationBackupAdmin(await _call('auth.me', const [])),
        power = await _powerReader._read();
    final raw = await _call('alertservice.query', const [
      [],
      {'limit': 129, 'select': _npHeads},
    ]);
    if (raw is! List || raw.length > 128) {
      _npThrow(NotificationProvidersExceptionReason.invalidResponse);
    }
    final services = <NotificationProviderSnapshot>[], titles = <int, String>{};
    for (final value in raw) {
      if (value is! Map ||
          value.length != _npHeads.length ||
          value.keys.any((k) => !_npHeads.contains(k)) ||
          !_emailText(value['type__title'], 120) ||
          (value['type__title'] as String).isEmpty) {
        _npThrow(NotificationProvidersExceptionReason.invalidResponse);
      }
      final row = _npHeader(value, _npTitles[value['type__title']] ?? 'Other');
      if (titles.containsKey(row.id)) {
        _npThrow(NotificationProvidersExceptionReason.invalidResponse);
      }
      services.add(row);
      titles[row.id] = _hash(value['type__title']);
    }
    services.sort((a, b) => a.id.compareTo(b.id));
    final finalAdmin = _configurationBackupAdmin(
      await _call('auth.me', const []),
    );
    final host = await _call('system.host_id', const []),
        reboot = _powerReboot(await _call('system.reboot.info', const [])),
        state = await _call('system.state', const []);
    if (admin != finalAdmin ||
        host != power.hostId ||
        reboot.$1 != power.bootId ||
        state != power.state ||
        jsonEncode(reboot.$2) != jsonEncode(power.rebootReasonCodes)) {
      _npThrow(NotificationProvidersExceptionReason.staleReview);
    }
    return _NpRead(
      NotificationProvidersInventory(
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
        services: services,
        rebootReasonCodes: power.rebootReasonCodes,
      ),
      titles,
    );
  }

  String _readProof(_NpRead read) => _hash([
    _npBase(read.inventory),
    _npHeaders(read.inventory.services),
    read.titles.map((k, v) => MapEntry('$k', v)),
  ]);
  Future<Map<String, Object?>> _detail(
    NotificationProviderSnapshot service,
  ) async {
    final raw = await _call('alertservice.query', [
      [
        ['id', '=', service.id],
        ['attributes.type', '=', service.type],
      ],
      const {'limit': 2, 'select': _npDetails},
    ]);
    if (raw is! List || raw.length != 1 || raw.single is! Map) {
      _npThrow(NotificationProvidersExceptionReason.invalidResponse);
    }
    final row = raw.single as Map,
        attributes = _npAttributes(row, service.provider!);
    if (_hash(_npHeaderValue(_npHeader(row, service.type))) !=
        _hash(_npHeaderValue(service))) {
      _npThrow(NotificationProvidersExceptionReason.staleReview);
    }
    return attributes;
  }

  Future<NotificationProvidersInventory> load() async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      _npThrow(NotificationProvidersExceptionReason.busy);
    }
    _calling = true;
    _clearReviews();
    _inventories.clear();
    try {
      final read = await _read();
      if (isOtherMutationBusy()) {
        _npThrow(NotificationProvidersExceptionReason.busy);
      }
      _inventories[read.inventory] = _readProof(read);
      return read.inventory;
    } on NotificationProvidersException {
      rethrow;
    } on Object {
      _npThrow(NotificationProvidersExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<NotificationProvidersReview> review(
    NotificationProvidersRequest request,
  ) async {
    _guard(request.action);
    if (isBusy || isOtherMutationBusy()) {
      _npThrow(NotificationProvidersExceptionReason.busy);
    }
    final proof = _inventories[request.inventory];
    if (proof == null || request.inventory.endpoint != _endpoint) {
      _npThrow(NotificationProvidersExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      _npThrow(NotificationProvidersExceptionReason.invalidRequest);
    }
    _calling = true;
    _clearReviews();
    if (request.credentials != null) _credentials.add(request.credentials!);
    try {
      final fresh = await _read();
      if (_readProof(fresh) != proof ||
          fresh.inventory.blockedReason != null ||
          isOtherMutationBusy()) {
        _npThrow(NotificationProvidersExceptionReason.staleReview);
      }
      final before = request.service == null
          ? <String, Object?>{}
          : await _detail(request.service!);
      final after = request.settings == null
          ? before
          : _npNewAttributes(request.settings!, request.credentials!);
      if (_npValidateAttributes(
            request.provider!,
            after,
            forEnable:
                request.action == NotificationProvidersAction.enable ||
                request.settings != null,
          ) !=
          null) {
        _npThrow(NotificationProvidersExceptionReason.invalidResponse);
      }
      if (request.action == NotificationProvidersAction.replace &&
          _hash(
                _npEnvelope(
                  request.service!.name,
                  request.service!.level,
                  before,
                  false,
                ),
              ) ==
              _hash(
                _npEnvelope(
                  request.settings!.name,
                  request.settings!.level,
                  after,
                  false,
                ),
              )) {
        _npThrow(NotificationProvidersExceptionReason.invalidRequest);
      }
      final confirmationRead = await _read();
      if (_readProof(confirmationRead) != proof ||
          isOtherMutationBusy() ||
          request.validationError != null) {
        _npThrow(NotificationProvidersExceptionReason.staleReview);
      }
      if (request.service != null &&
          _hash(await _detail(request.service!)) != _hash(before)) {
        _npThrow(NotificationProvidersExceptionReason.staleReview);
      }
      final review = NotificationProvidersReview(
        request: request,
        endpoint: _endpoint,
        warnings: _npWarnings(request.provider!),
        destinationSummary: _destination(request.provider!, after),
        publicFields: {
          for (final field in notificationProviderFields(
            request.provider!,
          ).where((f) => !f.secret))
            field.label: after[field.key] is List
                ? (after[field.key] as List).join(', ')
                : '${after[field.key]}',
        },
        unencrypted: request.provider!.unencrypted,
      );
      _reviews[review] = _NpLease(_now(), proof, _hash(before), _hash(after));
      return review;
    } on NotificationProvidersException {
      request.credentials?.dispose();
      rethrow;
    } on Object {
      request.credentials?.dispose();
      _npThrow(NotificationProvidersExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  String _destination(
    NotificationProviderType type,
    Map<String, Object?> attributes,
  ) {
    final reference = _hash(['destination', type.wireName, attributes]);
    final destination = switch (type) {
      NotificationProviderType.slack || NotificationProviderType.mattermost =>
        '${Uri.parse(attributes['url'] as String).host} (secret webhook path withheld)',
      NotificationProviderType.telegram =>
        'api.telegram.org · exact chat IDs ${(attributes['chat_ids'] as List).join(', ')}',
      NotificationProviderType.pagerDuty =>
        'events.pagerduty.com · private service integration',
      NotificationProviderType.opsGenie =>
        '${(attributes['api_url'] as String).isEmpty ? 'api.opsgenie.com' : Uri.parse(attributes['api_url'] as String).host} · private API integration',
      NotificationProviderType.victorOps =>
        'alert.victorops.com · private routing key',
      NotificationProviderType.awsSns =>
        '${attributes['region']} · exact topic ${attributes['topic_arn']}',
      NotificationProviderType.influxDb =>
        '${attributes['host']}:8086 · database ${attributes['database']} · series ${attributes['series_name']} (unencrypted)',
      NotificationProviderType.snmpTrap =>
        '${attributes['host']}:${attributes['port']} UDP · v2c community withheld (unencrypted)',
    };
    return '$destination\nOpaque per-session destination reference: $reference\nA reference binds this review; it is not recipient ownership or endpoint attestation.';
  }

  Future<NotificationProvidersResult> execute(
    NotificationProvidersReview review,
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
        _npThrow(NotificationProvidersExceptionReason.busy);
      }
      if (lease == null ||
          !authorized() ||
          !ageValid() ||
          review.endpoint != _endpoint ||
          confirmation != review.target ||
          review.request.validationError != null) {
        _npThrow(NotificationProvidersExceptionReason.staleReview);
      }
      _calling = true;
      owns = true;
      _operationCurrent = () =>
          isCurrent() && review.request.validationError == null;
      final request = review.request;
      // Private snapshot is invocation-local. Later UI disposal never authorizes
      // a late dispatch: every awaited preflight and the final call are fenced.
      final replacement = request.settings == null
          ? null
          : _npNewAttributes(request.settings!, request.credentials!);
      final beforeRead = await _read();
      if (_readProof(beforeRead) != lease.inventoryProof ||
          beforeRead.inventory.blockedReason != null) {
        _npThrow(NotificationProvidersExceptionReason.staleReview);
      }
      final before = request.service == null
          ? <String, Object?>{}
          : await _detail(request.service!);
      final attributes = replacement ?? before;
      if (_hash(before) != lease.beforeProof ||
          _hash(attributes) != lease.afterProof ||
          _npValidateAttributes(
                request.provider!,
                attributes,
                forEnable:
                    request.action == NotificationProvidersAction.enable ||
                    replacement != null,
              ) !=
              null) {
        _npThrow(NotificationProvidersExceptionReason.staleReview);
      }
      final confirmationRead = await _read();
      if (_readProof(confirmationRead) != lease.inventoryProof ||
          isOtherMutationBusy() ||
          !authorized() ||
          !ageValid()) {
        _npThrow(NotificationProvidersExceptionReason.staleReview);
      }
      if (request.service != null &&
          _hash(await _detail(request.service!)) != lease.beforeProof) {
        _npThrow(NotificationProvidersExceptionReason.staleReview);
      }
      final envelope = _npEnvelope(
        request.settings?.name ?? request.service!.name,
        request.settings?.level ?? request.service!.level,
        attributes,
        request.action == NotificationProvidersAction.enable,
      );
      final method = request.action == NotificationProvidersAction.create
          ? 'alertservice.create'
          : request.action == NotificationProvidersAction.delete
          ? 'alertservice.delete'
          : 'alertservice.update';
      final params = request.action == NotificationProvidersAction.create
          ? <Object?>[envelope]
          : request.action == NotificationProvidersAction.delete
          ? <Object?>[request.service!.id]
          : <Object?>[request.service!.id, envelope];
      _guard(request.action);
      if (isOtherMutationBusy() ||
          !authorized() ||
          !ageValid() ||
          request.validationError != null) {
        _npThrow(NotificationProvidersExceptionReason.staleReview);
      }
      sent = true;
      final raw = await client
          .call(method, id: nextId(), params: params)
          .timeout(requestTimeout);
      _guard(request.action);
      NotificationProviderSnapshot? receipt;
      if (request.action == NotificationProvidersAction.delete) {
        if (raw != true) return _unknown();
      } else {
        if (raw is! Map) return _unknown();
        final returned = _npAttributes(raw, request.provider!);
        receipt = _npHeader(raw, request.provider!.wireName);
        if (_hash(
                  _npEnvelope(
                    receipt.name,
                    receipt.level,
                    returned,
                    receipt.enabled,
                  ),
                ) !=
                _hash(envelope) ||
            (request.action == NotificationProvidersAction.create
                ? request.inventory.services.any((s) => s.id == receipt!.id)
                : receipt.id != request.service!.id)) {
          return _unknown();
        }
      }
      final afterRead = await _read(),
          expected = beforeRead.inventory.services.toList(),
          titles = Map<int, String>.of(beforeRead.titles);
      if (request.service != null) {
        expected.removeWhere((s) => s.id == request.service!.id);
        titles.remove(request.service!.id);
      }
      if (receipt != null) {
        final afterAttributes = await _detail(receipt);
        if (_hash(afterAttributes) != lease.afterProof) return _unknown();
        expected.add(receipt);
        titles[receipt.id] = _hash(
          _npTitles.entries.singleWhere((e) => e.value == receipt!.type).key,
        );
      }
      expected.sort((a, b) => a.id.compareTo(b.id));
      if (_hash(_npBase(beforeRead.inventory)) !=
              _hash(_npBase(afterRead.inventory)) ||
          _hash(_npHeaders(expected)) !=
              _hash(_npHeaders(afterRead.inventory.services)) ||
          _hash(titles.map((k, v) => MapEntry('$k', v))) !=
              _hash(afterRead.titles.map((k, v) => MapEntry('$k', v))) ||
          afterRead.inventory.blockedReason != null ||
          isOtherMutationBusy()) {
        return _unknown();
      }
      _inventories.clear();
      _clearReviews();
      return const NotificationProvidersResult(
        NotificationProvidersOutcome.completed,
        'The complete configured row and bounded readback matched. Notification delivery, external incident state, destination ownership and queued or in-flight work remain unverified. No provider test was invoked.',
      );
    } on Object catch (error) {
      if (sent) return _unknown();
      return NotificationProvidersResult(
        NotificationProvidersOutcome.rejected,
        error is NotificationProvidersException ? error.userMessage : 'Provider preflight failed; remote and credential details were withheld. No new write was authorized.',
      );
    } finally {
      review.request.credentials?.dispose();
      _credentials.remove(review.request.credentials);
      if (owns) {
        _operationCurrent = null;
        _calling = false;
      }
    }
  }

  NotificationProvidersResult _unknown() {
    _terminal = true;
    _inventories.clear();
    _clearReviews();
    return const NotificationProvidersResult(
      NotificationProvidersOutcome.unknown,
      'A provider configuration write or external notification may already have occurred. The outcome is unverified, not rollback or permission to repeat. Inspect the original server and external destinations independently.',
    );
  }
}

Never _npThrow(NotificationProvidersExceptionReason reason) =>
    throw NotificationProvidersException(reason);
Object? _npCanonical(Object? value) => value is Map
    ? {
        for (final key in value.keys.cast<String>().toList()..sort())
          key: _npCanonical(value[key]),
      }
    : value is List
    ? value.map(_npCanonical).toList()
    : value;
NotificationProviderSnapshot _npHeader(Map raw, String type) {
  if (!_powerId(raw['id']) ||
      raw['name'] is! String ||
      !_deliveryName(raw['name'] as String) ||
      raw['enabled'] is! bool ||
      raw['level'] is! String) {
    _npThrow(NotificationProvidersExceptionReason.invalidResponse);
  }
  final levels = AlertDeliveryLevel.values.where(
    (l) => l.name.toUpperCase() == raw['level'],
  );
  if (levels.length != 1) {
    _npThrow(NotificationProvidersExceptionReason.invalidResponse);
  }
  return NotificationProviderSnapshot(
    id: raw['id'] as int,
    name: raw['name'] as String,
    type: type,
    level: levels.single,
    enabled: raw['enabled'] as bool,
  );
}

Map<String, Object?> _npAttributes(Map row, NotificationProviderType type) {
  final raw = row['attributes'];
  if (raw is! Map || raw.keys.any((k) => k is! String)) {
    _npThrow(NotificationProvidersExceptionReason.invalidResponse);
  }
  final attributes = raw.cast<String, Object?>();
  if (_npValidateAttributes(type, attributes, forEnable: false) != null) {
    _npThrow(NotificationProvidersExceptionReason.invalidResponse);
  }
  return attributes;
}

Map<String, Object?> _npEnvelope(
  String name,
  AlertDeliveryLevel level,
  Map<String, Object?> attributes,
  bool enabled,
) => {
  'name': name,
  'level': level.name.toUpperCase(),
  'attributes': attributes,
  'enabled': enabled,
};
Object _npHeaderValue(NotificationProviderSnapshot s) => [
  s.id,
  s.name,
  s.type,
  s.level.name,
  s.enabled,
];
Object _npHeaders(List<NotificationProviderSnapshot> services) =>
    services.map(_npHeaderValue).toList();
Object _npBase(NotificationProvidersInventory i) => [
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
];
List<String> _npWarnings(NotificationProviderType provider) => [
  'Only the compiled TrueNAS 25.10.1 provider schema is used. Creation and full credential/configuration replacement remain disabled; replacement never preserves an omitted credential. Enable and disable are separately reviewed. Provider conversion, raw JSON, provider tests and forced delivery are not offered.',
  'Enabling permits ongoing external disclosure of formatted alert text and system identifiers. Cleared alerts can close or resolve external incidents. Disabling or deleting cannot recall prior messages, cancel in-flight work, resolve already-open incidents or globally mute independent notification paths. Backlog replay, retries and delivery timing are not guaranteed.',
  'The app’s TrueNAS certificate pin does not cover server-to-provider traffic. HTTPS configuration does not establish receiver ownership; HTTP clients can follow redirects. Secret URL paths, tokens, passwords, keys and community strings are withheld. Opaque keyed references bind a review, not external attestation.',
  if (provider == NotificationProviderType.telegram) 'The server loops over exact chat IDs; partial multi-recipient delivery is possible. The bot token is embedded in a private API path.',
  if (provider == NotificationProviderType.mattermost) 'Mattermost can use its webhook default channel when no channel is configured. The configured icon URL is forwarded and can cause an additional provider-side fetch.',
  if (provider == NotificationProviderType.awsSns) 'SNS publishes to the exact topic ARN and region; subscriptions, fan-out recipients and AWS library retries are not inspected or controlled.',
  if (provider == NotificationProviderType.influxDb) 'This pinned InfluxDB provider uses port 8086 without TLS. Credentials and alert data can be exposed in plaintext. No custom HTTPS port is available in this schema.',
  if (provider == NotificationProviderType.snmpTrap) 'Only SNMP v2c is supported here. The community and trap contents are unencrypted; the server uses an IPv4 UDP transport. Some delivery failures are logged without being raised. SNMP v3 variants require the TrueNAS workflow.',
  'A database mutation can precede a later error. Secret-bound readback proves configured values only, not notification delivery or coverage. No automatic test, polling, retry, reconnection or replay is performed.',
];
