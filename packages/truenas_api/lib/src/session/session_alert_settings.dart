part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedAlertSettingsSession {
  AlertSettingsCapabilities get alertSettingsCapabilities;
  Future<AlertSettingsInventory> loadAlertSettings();
  Future<AlertSettingsReview> reviewAlertSettings(AlertSettingsRequest request);
  Future<AlertSettingsResult> executeAlertSettings(
    AlertSettingsReview review,
    String confirmation, {
    required bool Function() isCurrent,
  });
}

enum AlertSettingsAction {
  createEmail,
  editEmail,
  enableEmail,
  disableEmail,
  deleteEmail,
}

enum AlertDeliveryLevel {
  info,
  notice,
  warning,
  error,
  critical,
  alert,
  emergency,
}

final class AlertSettingsCapabilities {
  const AlertSettingsCapabilities({
    this.connected = false,
    this.versionSupported = false,
    this.available = false,
    this.canCreate = false,
    this.canUpdate = false,
    this.canDelete = false,
  });
  const AlertSettingsCapabilities.disconnected()
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
  bool supports(AlertSettingsAction action) =>
      supported &&
      switch (action) {
        AlertSettingsAction.createEmail => canCreate,
        AlertSettingsAction.deleteEmail => canDelete,
        _ => canUpdate,
      };
  String? get blockedReason => !connected
      ? 'Connect to inspect notification services.'
      : !versionSupported
      ? 'Native notification services require stable TrueNAS 25.10.'
      : !available
      ? 'Required public notification-service and readiness reads are unavailable.'
      : null;
}

final class EmailAlertServiceSettings {
  const EmailAlertServiceSettings({
    required this.name,
    required this.recipient,
    this.level = AlertDeliveryLevel.warning,
  });
  final String name, recipient;
  final AlertDeliveryLevel level;
  String? get validationError => !_deliveryName(name)
      ? 'Use a nonempty service name up to 120 characters without controls or surrounding whitespace.'
      : !_emailAddress(recipient)
      ? 'Choose exactly one explicit plain ASCII recipient up to 120 characters. Administrator fallback is not enabled here.'
      : null;
}

final class AlertServiceSnapshot {
  const AlertServiceSnapshot({
    required this.id,
    required this.name,
    required this.type,
    required this.level,
    required this.enabled,
    this.recipient,
    this.emailAttributesSupported = false,
  });
  final int id;
  final String name, type;
  final AlertDeliveryLevel level;
  final bool enabled;
  final String? recipient;
  final bool emailAttributesSupported;
  bool get isEmail => type == 'Mail';
  bool get supportedEmail => isEmail && emailAttributesSupported;
  bool get usesAdministratorFallback => supportedEmail && recipient == '';
  String? get blockedReason => !isEmail
      ? 'This provider is display-only; its credentials and attributes are not exposed.'
      : !emailAttributesSupported
      ? 'This Mail row has unsupported or unprovable attributes; manage it in TrueNAS.'
      : null;
}

final class AlertSettingsInventory {
  AlertSettingsInventory({
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
    required List<AlertServiceSnapshot> services,
    List<String> rebootReasonCodes = const [],
  }) : environments = List.unmodifiable(environments),
       services = List.unmodifiable(services),
       rebootReasonCodes = List.unmodifiable(rebootReasonCodes);
  final String endpoint, hostId, bootId, currentVersion, state, bootPool;
  final bool fullAdmin, failoverLicensed, conflictingJob, bootHealthy;
  final List<BootEnvironmentSnapshot> environments;
  final List<AlertServiceSnapshot> services;
  final List<String> rebootReasonCodes;
  BootEnvironmentSnapshot? get currentEnvironment =>
      environments.where((e) => e.active).singleOrNull;
  BootEnvironmentSnapshot? get nextEnvironment =>
      environments.where((e) => e.activated).singleOrNull;
  String? get readinessBlockedReason => !fullAdmin
      ? 'This app requires FULL_ADMIN for notification-service changes.'
      : failoverLicensed
      ? 'HA notification changes require the coordinated TrueNAS workflow.'
      : state != 'READY'
      ? 'The original server must report READY.'
      : conflictingJob
      ? 'A visible active or waiting job prevents a notification change.'
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

final class AlertSettingsRequest {
  const AlertSettingsRequest({
    required this.inventory,
    required this.action,
    this.service,
    this.settings,
  });
  final AlertSettingsInventory inventory;
  final AlertSettingsAction action;
  final AlertServiceSnapshot? service;
  final EmailAlertServiceSettings? settings;
  String get target => switch (action) {
    AlertSettingsAction.createEmail =>
      'CREATE EMAIL ALERT ${inventory.hostId} ${settings?.recipient ?? ""}',
    AlertSettingsAction.editEmail =>
      'EDIT EMAIL ALERT ${inventory.hostId} ${service?.id ?? ""} ${settings?.recipient ?? ""}',
    AlertSettingsAction.enableEmail =>
      'ENABLE EMAIL ALERT ${inventory.hostId} ${service?.id ?? ""} ${service?.recipient ?? ""}',
    AlertSettingsAction.disableEmail =>
      'DISABLE EMAIL ALERT ${inventory.hostId} ${service?.id ?? ""}',
    AlertSettingsAction.deleteEmail =>
      'DELETE EMAIL ALERT ${inventory.hostId} ${service?.id ?? ""}',
  };
  String? get validationError {
    if (inventory.blockedReason != null) return inventory.blockedReason;
    if (action == AlertSettingsAction.createEmail) {
      if (service != null ||
          settings == null ||
          inventory.services.length >= 128) {
        return 'Create a new disabled Mail service; at most 128 service rows are supported.';
      }
    } else {
      if (service == null ||
          !inventory.services.any((s) => identical(s, service))) {
        return 'Choose the exact service from this inventory.';
      }
      if (service!.blockedReason != null) return service!.blockedReason;
    }
    if (action == AlertSettingsAction.createEmail ||
        action == AlertSettingsAction.editEmail) {
      if (settings == null || settings!.validationError != null) {
        return settings?.validationError ??
            'Enter complete Mail service settings.';
      }
      if (action == AlertSettingsAction.editEmail && service!.enabled) {
        return 'Disable the Mail service explicitly before editing it.';
      }
      if (inventory.services.any(
        (s) =>
            !identical(s, service) &&
            s.name.toLowerCase() == settings!.name.toLowerCase(),
      )) {
        return 'Choose a service name not already configured.';
      }
      if (action == AlertSettingsAction.editEmail &&
          _deliverySettingsProof(settings!) ==
              _deliverySettingsProof(_deliverySettings(service!))) {
        return 'Choose a changed name, recipient or minimum severity.';
      }
      return null;
    }
    if (settings != null) {
      return 'Enable, disable and delete preserve the reviewed service settings; no edited fields are allowed.';
    }
    return switch (action) {
      AlertSettingsAction.enableEmail =>
        service!.enabled
            ? 'The service is already enabled.'
            : !_emailAddress(service!.recipient ?? '')
            ? 'Set an explicit single recipient while disabled before enabling; administrator fallback is not enabled here.'
            : null,
      AlertSettingsAction.disableEmail =>
        !service!.enabled ? 'The service is already disabled.' : null,
      AlertSettingsAction.deleteEmail =>
        service!.enabled
            ? 'Disable the service explicitly before deleting it.'
            : null,
      _ => null,
    };
  }
}

final class AlertSettingsReview {
  AlertSettingsReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final AlertSettingsRequest request;
  final String endpoint;
  final List<String> warnings;
  AlertSettingsAction get action => request.action;
  String get target => request.target;
}

enum AlertSettingsOutcome { completed, rejected, unknown }

final class AlertSettingsResult {
  const AlertSettingsResult(this.outcome, this.message);
  final AlertSettingsOutcome outcome;
  final String message;
}

enum AlertSettingsExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class AlertSettingsException implements Exception {
  const AlertSettingsException(this.reason);
  final AlertSettingsExceptionReason reason;
  String get userMessage => switch (reason) {
    AlertSettingsExceptionReason.notAuthenticated =>
      'Connect again before changing notification services.',
    AlertSettingsExceptionReason.unsupportedVersion =>
      'Native notification services require stable TrueNAS 25.10.',
    AlertSettingsExceptionReason.unavailableMethod =>
      'Required public notification-service methods are unavailable.',
    AlertSettingsExceptionReason.busy => 'Another operation is active or an uncertain outcome requires independent inspection.',
    AlertSettingsExceptionReason.staleReview => 'The issued review, connection, service or authorization changed. No notification change was submitted.',
    AlertSettingsExceptionReason.invalidRequest => 'Choose a supported Mail lifecycle action and resolve the displayed restrictions.',
    AlertSettingsExceptionReason.invalidResponse =>
      'Notification-service configuration could not be safely verified.',
    AlertSettingsExceptionReason.unavailable => 'Notification-service information is unavailable. Remote and provider details were withheld.',
  };
  @override
  String toString() => userMessage;
}

const _deliveryReads = {..._powerReads, 'auth.me', 'alertservice.query'};
// Only top-level fields may be projected here. Partial nested attributes fail
// the pinned API's provider-union result validation for credentialed providers.
const _deliveryHeads = ['id', 'name', 'level', 'enabled', 'type__title'];
const _deliveryDetails = ['id', 'name', 'level', 'enabled', 'attributes'];
const _deliveryTypes = {
  'AWSSNS',
  'InfluxDB',
  'Mail',
  'Mattermost',
  'OpsGenie',
  'PagerDuty',
  'Slack',
  'SNMPTrap',
  'Telegram',
  'VictorOps',
};

final class _DeliveryRead {
  const _DeliveryRead(this.inventory, this.typeHashes);
  final AlertSettingsInventory inventory;
  final Map<int, String> typeHashes;
}

final class _DeliveryLease {
  const _DeliveryLease(this.created, this.proof);
  final DateTime created;
  final String proof;
}

final class _SessionAlertSettings {
  _SessionAlertSettings({
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
  final Map<AlertSettingsInventory, String> _inventories = {};
  final Map<AlertSettingsReview, _DeliveryLease> _reviews = {};
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

  AlertSettingsCapabilities get capabilities => AlertSettingsCapabilities(
    connected: isCurrent(),
    versionSupported: _version,
    available: _deliveryReads.every(_method),
    canCreate: _method('alertservice.create'),
    canUpdate: _method('alertservice.update'),
    canDelete: _method('alertservice.delete'),
  );
  void _guard([AlertSettingsAction? action]) {
    if (!isCurrent()) {
      _deliveryThrow(AlertSettingsExceptionReason.notAuthenticated);
    }
    if (!_current()) _deliveryThrow(AlertSettingsExceptionReason.staleReview);
    if (!_version) {
      _deliveryThrow(AlertSettingsExceptionReason.unsupportedVersion);
    }
    if (!capabilities.supported ||
        action != null && !capabilities.supports(action)) {
      _deliveryThrow(AlertSettingsExceptionReason.unavailableMethod);
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

  Future<_DeliveryRead> _read() async {
    final admin = _configurationBackupAdmin(await _call('auth.me', const []));
    final power = await _powerReader._read();
    final heads = _deliveryRows(
      await _call('alertservice.query', const [
        [],
        {'limit': 129, 'select': _deliveryHeads},
      ]),
      details: false,
    );
    final rows = heads.$1, types = heads.$2;
    final mailIds = rows.where((s) => s.isEmail).map((s) => s.id).toList();
    {
      // Filter after the server's extension (no force_sql_filters). The display
      // title is not authority: only actual Mail attributes grant editability.
      final details = _deliveryRows(
        await _call('alertservice.query', [
          [
            ['attributes.type', '=', 'Mail'],
          ],
          const {'limit': 129, 'select': _deliveryDetails},
        ]),
        details: true,
      );
      if (details.$1.length != mailIds.length ||
          details.$1.any((s) => !mailIds.contains(s.id) || !s.isEmail)) {
        _deliveryThrow(AlertSettingsExceptionReason.staleReview);
      }
      for (final detail in details.$1) {
        final index = rows.indexWhere((s) => s.id == detail.id);
        if (index < 0 ||
            _deliveryHeadProof(rows[index]) != _deliveryHeadProof(detail) ||
            types[detail.id] != details.$2[detail.id]) {
          _deliveryThrow(AlertSettingsExceptionReason.staleReview);
        }
        rows[index] = detail;
      }
    }
    final finalAdmin = _configurationBackupAdmin(
      await _call('auth.me', const []),
    );
    final host = await _call('system.host_id', const []),
        reboot = _powerReboot(await _call('system.reboot.info', const []));
    final state = await _call('system.state', const []);
    if (admin != finalAdmin ||
        host != power.hostId ||
        reboot.$1 != power.bootId ||
        state != power.state ||
        jsonEncode(reboot.$2) != jsonEncode(power.rebootReasonCodes)) {
      _deliveryThrow(AlertSettingsExceptionReason.staleReview);
    }
    return _DeliveryRead(
      AlertSettingsInventory(
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
        services: rows,
      ),
      types,
    );
  }

  Future<AlertSettingsInventory> load() async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      _deliveryThrow(AlertSettingsExceptionReason.busy);
    }
    _calling = true;
    _inventories.clear();
    _reviews.clear();
    try {
      final read = await _read();
      if (isOtherMutationBusy()) {
        _deliveryThrow(AlertSettingsExceptionReason.busy);
      }
      _inventories[read.inventory] = _deliveryProof(read);
      return read.inventory;
    } on AlertSettingsException {
      rethrow;
    } on Object {
      _deliveryThrow(AlertSettingsExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<AlertSettingsReview> review(AlertSettingsRequest request) async {
    _guard(request.action);
    if (isBusy || isOtherMutationBusy()) {
      _deliveryThrow(AlertSettingsExceptionReason.busy);
    }
    final proof = _inventories[request.inventory];
    if (proof == null || request.inventory.endpoint != _endpoint) {
      _deliveryThrow(AlertSettingsExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      _deliveryThrow(AlertSettingsExceptionReason.invalidRequest);
    }
    _calling = true;
    _reviews.clear();
    try {
      final fresh = await _read();
      if (_deliveryProof(fresh) != proof ||
          fresh.inventory.blockedReason != null ||
          isOtherMutationBusy()) {
        _deliveryThrow(AlertSettingsExceptionReason.staleReview);
      }
      final review = AlertSettingsReview(
        request: request,
        endpoint: _endpoint,
        warnings: [
          'Only the Mail notification-service lifecycle is supported. New services are always disabled; edit and delete require a prior explicit disable. Updates send the full source-required Mail envelope, including an explicit enabled value, while preserving every unedited supported field. This is not a partial wire patch.',
          if (request.action == AlertSettingsAction.enableEmail)
            'Enabling authorizes ongoing external notification delivery. TrueNAS can send HTML containing complete alert details, new/cleared/current alert text, product and NAS hostname to the explicit recipient through its saved mail configuration. These details may expose sensitive system information; approve that recipient and SMTP destination independently.'
          else if (request.action == AlertSettingsAction.disableEmail ||
              request.action == AlertSettingsAction.deleteEmail)
            'Disabling or deleting this configured service can remove an important notification path, including the last enabled Mail service. It does not retract mail already queued or in flight, cancel SMTP jobs, or disable independent default per-alert mail and proactive-support paths.'
          else
            'This stores a disabled Mail service configuration and does not send a test. It does not validate SMTP credentials, recipient ownership, reachability or delivery; enabling later requires its own explicit review.',
          'Mail alert delivery uses the server mail.send defaults, including queued retries; the separate TrueRAID fixed SMTP test\'s queue:false does not apply here. Existing queue entries can retry using current SMTP settings. This app cannot inspect, cancel or recall that queue.',
          'Minimum severity is a configured threshold, not delivery frequency or health. Alert-class policies independently affect visibility and batching. Enabling is not a guarantee that existing alerts will be replayed. No alert-class severity/frequency override or proactive-support setting is changed.',
          'No provider test, SMTP send, alert send, probe, shell, job polling, retry or forced delivery method is invoked by this workflow. Concurrent background notification processing can observe an enabled row; CRUD completion does not prove whether a notification left the machine.',
          'Saved SMTP credentials and transport are not read or changed here. TLS/SSL on the pinned TrueNAS SMTP path is not a verified SMTP certificate/hostname guarantee. API certificate pinning does not secure server-to-SMTP traffic. Review the separate Email settings before enabling.',
          'A database change may precede a later response/hook error. An error, timeout or mismatched readback is unknown, not rollback or permission to repeat. Public readiness and complete configured-row readback are bounded, non-atomic checks; other-provider secrets, effective notification coverage and recipient delivery remain unverified.',
        ],
      );
      _reviews[review] = _DeliveryLease(_now(), proof);
      return review;
    } on AlertSettingsException {
      rethrow;
    } on Object {
      _deliveryThrow(AlertSettingsExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<AlertSettingsResult> execute(
    AlertSettingsReview review,
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
        _deliveryThrow(AlertSettingsExceptionReason.busy);
      }
      if (lease == null ||
          !authorized() ||
          !ageValid() ||
          review.endpoint != _endpoint ||
          confirmation != review.target ||
          review.request.validationError != null) {
        _deliveryThrow(AlertSettingsExceptionReason.staleReview);
      }
      _calling = true;
      owns = true;
      _operationCurrent = isCurrent;
      final before = await _read();
      if (_deliveryProof(before) != lease.proof ||
          before.inventory.blockedReason != null ||
          isOtherMutationBusy()) {
        _deliveryThrow(AlertSettingsExceptionReason.staleReview);
      }
      _guard(review.action);
      if (!ageValid()) _deliveryThrow(AlertSettingsExceptionReason.staleReview);
      final params = _deliveryParams(review.request);
      sent = true;
      final raw = await client
          .call(_deliveryMethod(review.action), id: nextId(), params: params)
          .timeout(requestTimeout);
      _guard(review.action);
      AlertServiceSnapshot? receipt;
      if (review.action == AlertSettingsAction.deleteEmail) {
        if (raw != true) return _unknown();
      } else {
        receipt = _deliveryRow(raw, details: true).$1;
        if (!_deliveryReceiptMatches(review.request, receipt)) {
          return _unknown();
        }
      }
      final after = await _read();
      if (!_deliveryReadback(review.request, before, after, receipt) ||
          isOtherMutationBusy()) {
        return _unknown();
      }
      _inventories.clear();
      _reviews.clear();
      return const AlertSettingsResult(
        AlertSettingsOutcome.completed,
        'The expected service response and fresh configured-row readback matched. This confirms configuration only, not notification coverage, SMTP success or recipient delivery. No test was sent and no queued message was recalled.',
      );
    } on Object catch (error) {
      if (sent) return _unknown();
      return AlertSettingsResult(
        AlertSettingsOutcome.rejected,
        error is AlertSettingsException ? error.userMessage : 'Notification-service preflight failed or authorization expired. No change was submitted.',
      );
    } finally {
      if (owns) {
        _operationCurrent = null;
        _calling = false;
      }
    }
  }

  AlertSettingsResult _unknown() {
    _terminal = true;
    _inventories.clear();
    _reviews.clear();
    return const AlertSettingsResult(
      AlertSettingsOutcome.unknown,
      'A notification-service change may already have occurred, and background delivery may be affected. Its outcome is unverified, not rollback or permission to retry. Further writes are fenced; inspect the original server independently.',
    );
  }
}

Never _deliveryThrow(AlertSettingsExceptionReason reason) =>
    throw AlertSettingsException(reason);
bool _deliveryName(String name) =>
    name.isNotEmpty && name.trim() == name && _emailText(name, 120);
String _deliveryTypeHash(String type) =>
    crypto.sha256.convert(utf8.encode(type)).toString();
(AlertServiceSnapshot, String) _deliveryRow(
  Object? raw, {
  required bool details,
}) {
  if (raw is! Map ||
      !_powerId(raw['id']) ||
      raw['name'] is! String ||
      !_deliveryName(raw['name'] as String) ||
      raw['enabled'] is! bool ||
      raw['level'] is! String) {
    _deliveryThrow(AlertSettingsExceptionReason.invalidResponse);
  }
  final levels = AlertDeliveryLevel.values.where(
    (l) => l.name.toUpperCase() == raw['level'],
  );
  if (levels.length != 1) {
    _deliveryThrow(AlertSettingsExceptionReason.invalidResponse);
  }
  if (!details) {
    final title = raw['type__title'];
    if (title is! String || title.isEmpty || !_emailText(title, 120)) {
      _deliveryThrow(AlertSettingsExceptionReason.invalidResponse);
    }
    // Only the source-confirmed Mail title is mapped to a candidate provider.
    // Other titles are safe display metadata, not credentials or mutation scope.
    final type = title == 'Email'
        ? 'Mail'
        : _deliveryTypes.contains(title) && title != 'Mail'
        ? title
        : 'Other';
    return (
      AlertServiceSnapshot(
        id: raw['id'] as int,
        name: raw['name'] as String,
        type: type,
        level: levels.single,
        enabled: raw['enabled'] as bool,
      ),
      _deliveryTypeHash(title == 'Email' ? 'Mail' : title),
    );
  }
  final attributes = raw['attributes'];
  if (attributes is! Map || attributes['type'] != 'Mail') {
    _deliveryThrow(AlertSettingsExceptionReason.invalidResponse);
  }
  const type = 'Mail';
  final isMail = type == 'Mail';
  final safeRecipient =
      isMail &&
      details &&
      attributes['email'] is String &&
      _emailText(attributes['email'], 120);
  final supported =
      safeRecipient &&
      attributes.length == 2 &&
      attributes.keys.every((key) => key == 'type' || key == 'email');
  return (
    AlertServiceSnapshot(
      id: raw['id'] as int,
      name: raw['name'] as String,
      type: _deliveryTypes.contains(type) ? type : 'Other',
      level: levels.single,
      enabled: raw['enabled'] as bool,
      recipient: safeRecipient ? attributes['email'] as String : null,
      emailAttributesSupported: supported,
    ),
    _deliveryTypeHash(type),
  );
}

(List<AlertServiceSnapshot>, Map<int, String>) _deliveryRows(
  Object? raw, {
  required bool details,
}) {
  if (raw is! List || raw.length > 128) {
    _deliveryThrow(AlertSettingsExceptionReason.invalidResponse);
  }
  final rows = <AlertServiceSnapshot>[], types = <int, String>{};
  for (final item in raw) {
    final row = _deliveryRow(item, details: details);
    if (types.containsKey(row.$1.id)) {
      _deliveryThrow(AlertSettingsExceptionReason.invalidResponse);
    }
    rows.add(row.$1);
    types[row.$1.id] = row.$2;
  }
  rows.sort((a, b) => a.id.compareTo(b.id));
  return (rows, types);
}

EmailAlertServiceSettings _deliverySettings(AlertServiceSnapshot s) =>
    EmailAlertServiceSettings(
      name: s.name,
      recipient: s.recipient ?? '',
      level: s.level,
    );
Map<String, Object?> _deliveryEnvelope(
  EmailAlertServiceSettings s,
  bool enabled,
) => {
  'name': s.name,
  'attributes': {'type': 'Mail', 'email': s.recipient},
  'level': s.level.name.toUpperCase(),
  'enabled': enabled,
};
String _deliverySettingsProof(EmailAlertServiceSettings s) =>
    jsonEncode(_deliveryEnvelope(s, false));
String _deliveryHeadProof(AlertServiceSnapshot s) =>
    jsonEncode([s.id, s.name, s.type, s.level.name, s.enabled]);
String _deliveryServicesProof(List<AlertServiceSnapshot> rows) => jsonEncode([
  for (final s in rows)
    [_deliveryHeadProof(s), s.recipient, s.emailAttributesSupported],
]);
String _deliveryTypesProof(Map<int, String> types) => jsonEncode([
  for (final id in types.keys.toList()..sort()) [id, types[id]],
]);
String _deliveryBaseProof(AlertSettingsInventory i) => jsonEncode([
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
String _deliveryProof(_DeliveryRead r) => jsonEncode([
  _deliveryBaseProof(r.inventory),
  _deliveryServicesProof(r.inventory.services),
  _deliveryTypesProof(r.typeHashes),
]);
String _deliveryMethod(AlertSettingsAction action) => switch (action) {
  AlertSettingsAction.createEmail => 'alertservice.create',
  AlertSettingsAction.deleteEmail => 'alertservice.delete',
  _ => 'alertservice.update',
};
List<Object?> _deliveryParams(AlertSettingsRequest r) => switch (r.action) {
  AlertSettingsAction.createEmail => [_deliveryEnvelope(r.settings!, false)],
  AlertSettingsAction.editEmail => [
    r.service!.id,
    _deliveryEnvelope(r.settings!, false),
  ],
  AlertSettingsAction.enableEmail => [
    r.service!.id,
    _deliveryEnvelope(_deliverySettings(r.service!), true),
  ],
  AlertSettingsAction.disableEmail => [
    r.service!.id,
    _deliveryEnvelope(_deliverySettings(r.service!), false),
  ],
  AlertSettingsAction.deleteEmail => [r.service!.id],
};
bool _deliveryReceiptMatches(AlertSettingsRequest r, AlertServiceSnapshot s) {
  if (!s.supportedEmail) return false;
  final settings = r.settings ?? _deliverySettings(r.service!);
  return _deliverySettingsProof(_deliverySettings(s)) ==
          _deliverySettingsProof(settings) &&
      s.enabled == (r.action == AlertSettingsAction.enableEmail) &&
      (r.action == AlertSettingsAction.createEmail
          ? !r.inventory.services.any((v) => v.id == s.id)
          : s.id == r.service!.id);
}

bool _deliveryReadback(
  AlertSettingsRequest r,
  _DeliveryRead before,
  _DeliveryRead after,
  AlertServiceSnapshot? receipt,
) {
  if (_deliveryBaseProof(before.inventory) !=
          _deliveryBaseProof(after.inventory) ||
      after.inventory.blockedReason != null) {
    return false;
  }
  final expected = before.inventory.services.toList(),
      types = Map<int, String>.of(before.typeHashes);
  if (r.action != AlertSettingsAction.createEmail) {
    expected.removeWhere((s) => s.id == r.service!.id);
    types.remove(r.service!.id);
  }
  if (receipt != null) {
    expected.add(receipt);
    types[receipt.id] = _deliveryTypeHash('Mail');
  }
  expected.sort((a, b) => a.id.compareTo(b.id));
  return _deliveryServicesProof(expected) ==
          _deliveryServicesProof(after.inventory.services) &&
      _deliveryTypesProof(types) == _deliveryTypesProof(after.typeHashes);
}
