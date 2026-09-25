part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedAlertPoliciesSession {
  AlertPoliciesCapabilities get alertPoliciesCapabilities;
  Future<AlertPoliciesInventory> loadAlertPolicies();
  Future<AlertPoliciesReview> reviewAlertPolicies(AlertPoliciesRequest request);
  Future<AlertPoliciesResult> executeAlertPolicies(
    AlertPoliciesReview review,
    String confirmation, {
    required bool Function() isCurrent,
  });
}

enum AlertPolicyFrequency { immediately, hourly, daily, never }

enum AlertPoliciesAction { configure, resetClass }

final class AlertPoliciesCapabilities {
  const AlertPoliciesCapabilities({
    this.connected = false,
    this.versionSupported = false,
    this.available = false,
    this.canUpdate = false,
    this.canReadSupportEligibility = false,
  });
  const AlertPoliciesCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      canUpdate = false,
      canReadSupportEligibility = false;
  final bool connected,
      versionSupported,
      available,
      canUpdate,
      canReadSupportEligibility;
  bool get supported => connected && versionSupported && available;
  bool get canConfigure => supported && canUpdate;
  String? get blockedReason => !connected
      ? 'Connect to inspect alert-class policies.'
      : !versionSupported
      ? 'Native alert policies require stable TrueNAS 25.10.'
      : !available
      ? 'Required public alert policy metadata and readiness reads are unavailable.'
      : null;
}

final class AlertClassOverrides {
  const AlertClassOverrides({this.level, this.policy, this.proactiveSupport});
  final AlertDeliveryLevel? level;
  final AlertPolicyFrequency? policy;
  final bool? proactiveSupport;
  bool get isEmpty =>
      level == null && policy == null && proactiveSupport == null;
}

final class AlertClassPolicySnapshot {
  const AlertClassPolicySnapshot({
    required this.id,
    required this.title,
    required this.categoryId,
    required this.categoryTitle,
    required this.defaultLevel,
    required this.supportsProactiveSupport,
    required this.hasOverride,
    this.overrides = const AlertClassOverrides(),
  });
  final String id, title, categoryId, categoryTitle;
  final AlertDeliveryLevel defaultLevel;
  final bool supportsProactiveSupport, hasOverride;
  final AlertClassOverrides overrides;
  AlertDeliveryLevel get effectiveLevel => overrides.level ?? defaultLevel;
  AlertPolicyFrequency get effectivePolicy =>
      overrides.policy ?? AlertPolicyFrequency.immediately;
  bool get effectiveProactiveSupport =>
      supportsProactiveSupport && (overrides.proactiveSupport ?? true);
}

final class AlertPoliciesInventory {
  AlertPoliciesInventory({
    required this.readiness,
    required this.configId,
    required List<AlertClassPolicySnapshot> classes,
    this.unlistedOverrideCount = 0,
    this.supportAvailable,
    this.supportEnabled,
  }) : classes = List.unmodifiable(classes);
  final AlertSettingsInventory readiness;
  final int configId, unlistedOverrideCount;
  final List<AlertClassPolicySnapshot> classes;
  final bool? supportAvailable, supportEnabled;
  String get endpoint => readiness.endpoint;
  String get hostId => readiness.hostId;
  String get bootId => readiness.bootId;
  String get currentVersion => readiness.currentVersion;
  String? get readinessBlockedReason => readiness.readinessBlockedReason;
  String? get blockedReason => readinessBlockedReason;
}

final class AlertPoliciesRequest {
  const AlertPoliciesRequest({
    required this.inventory,
    required this.classPolicy,
    required this.action,
    this.overrides,
    this.proactiveSupportDisclosureAccepted = false,
  });
  final AlertPoliciesInventory inventory;
  final AlertClassPolicySnapshot classPolicy;
  final AlertPoliciesAction action;
  final AlertClassOverrides? overrides;
  final bool proactiveSupportDisclosureAccepted;
  AlertClassOverrides get afterOverrides =>
      action == AlertPoliciesAction.resetClass
      ? const AlertClassOverrides()
      : overrides ?? const AlertClassOverrides();
  bool get changesProactiveSupport =>
      classPolicy.overrides.proactiveSupport != afterOverrides.proactiveSupport;
  bool get enablesProactiveSupport =>
      changesProactiveSupport &&
      classPolicy.supportsProactiveSupport &&
      (afterOverrides.proactiveSupport ?? true);
  String get target =>
      '${action == AlertPoliciesAction.configure ? 'UPDATE' : 'RESET'} ALERT POLICY ${inventory.hostId} ${classPolicy.id}';
  String? get validationError {
    if (inventory.blockedReason != null) return inventory.blockedReason;
    if (!inventory.classes.any((c) => identical(c, classPolicy))) {
      return 'Choose the exact class from this inventory.';
    }
    if (action == AlertPoliciesAction.resetClass) {
      if (overrides != null || !classPolicy.hasOverride) {
        return 'Reset only this existing class override; no replacement fields are accepted.';
      }
    } else {
      if (overrides == null) {
        return 'Choose explicit override fields or their defaults.';
      }
      if (!classPolicy.hasOverride &&
          inventory.unlistedOverrideCount +
                  inventory.classes.where((c) => c.hasOverride).length >=
              1024) {
        return 'At most 1024 stored class overrides are supported; no new row can be safely added.';
      }
      if (classPolicy.hasOverride &&
          _policiesOverrideProof(classPolicy.overrides) ==
              _policiesOverrideProof(overrides!)) {
        return 'Choose a changed override; resetting the row is a separate action.';
      }
      if (!classPolicy.hasOverride && overrides!.isEmpty) {
        return 'This class already uses its defaults.';
      }
      if (overrides!.proactiveSupport != null &&
          !classPolicy.supportsProactiveSupport) {
        return 'This alert class does not support proactive support.';
      }
    }
    if (changesProactiveSupport) {
      if (!classPolicy.supportsProactiveSupport) {
        return 'Proactive support is not available for this class.';
      }
      if (!proactiveSupportDisclosureAccepted) {
        return 'Explicitly acknowledge the external support and reporting effects.';
      }
      if (inventory.supportAvailable != true) {
        return 'Current public server eligibility for proactive support must be verified.';
      }
      if (enablesProactiveSupport && inventory.supportEnabled != true) {
        return 'Enabling or restoring proactive support requires verified globally enabled support. Configure global support independently.';
      }
    }
    return null;
  }
}

final class AlertPoliciesReview {
  AlertPoliciesReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final AlertPoliciesRequest request;
  final String endpoint;
  final List<String> warnings;
  String get target => request.target;
}

enum AlertPoliciesOutcome { completed, rejected, unknown }

final class AlertPoliciesResult {
  const AlertPoliciesResult(this.outcome, this.message);
  final AlertPoliciesOutcome outcome;
  final String message;
}

enum AlertPoliciesExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class AlertPoliciesException implements Exception {
  const AlertPoliciesException(this.reason);
  final AlertPoliciesExceptionReason reason;
  String get userMessage => switch (reason) {
    AlertPoliciesExceptionReason.notAuthenticated =>
      'Connect again before changing alert policies.',
    AlertPoliciesExceptionReason.unsupportedVersion =>
      'Native alert policies require stable TrueNAS 25.10.',
    AlertPoliciesExceptionReason.unavailableMethod =>
      'Required public alert policy methods are unavailable.',
    AlertPoliciesExceptionReason.busy =>
      'Another operation or uncertain outcome prevents alert policy changes.',
    AlertPoliciesExceptionReason.staleReview => 'The issued review, class metadata, policy configuration or connection changed. No policy update was submitted.',
    AlertPoliciesExceptionReason.invalidRequest => 'Resolve the displayed class policy and support eligibility restrictions.',
    AlertPoliciesExceptionReason.invalidResponse =>
      'Alert policy information could not be safely verified.',
    AlertPoliciesExceptionReason.unavailable =>
      'Alert policy information is unavailable. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

const _policiesReads = {
  ..._powerReads,
  'auth.me',
  'alert.list_categories',
  'alert.list_policies',
  'alertclasses.config',
};
const _policiesSupportReads = {
  'support.is_available',
  'support.is_available_and_enabled',
};

final class _PoliciesRead {
  const _PoliciesRead(this.inventory, this.overrides);
  final AlertPoliciesInventory inventory;
  final Map<String, AlertClassOverrides> overrides;
}

final class _PoliciesLease {
  const _PoliciesLease(this.created, this.proof);
  final DateTime created;
  final String proof;
}

final class _SessionAlertPolicies {
  _SessionAlertPolicies({
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
  bool _calling = false, _terminal = false;
  bool Function()? _operationCurrent;
  final Map<AlertPoliciesInventory, String> _inventories = {};
  final Map<AlertPoliciesReview, _PoliciesLease> _reviews = {};
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

  AlertPoliciesCapabilities get capabilities => AlertPoliciesCapabilities(
    connected: isCurrent(),
    versionSupported: _version,
    available: _policiesReads.every(_method),
    canUpdate: _method('alertclasses.update'),
    canReadSupportEligibility: _policiesSupportReads.every(_method),
  );
  void _guard({bool write = false}) {
    if (!isCurrent()) {
      _policiesThrow(AlertPoliciesExceptionReason.notAuthenticated);
    }
    if (!_current()) _policiesThrow(AlertPoliciesExceptionReason.staleReview);
    if (!_version) {
      _policiesThrow(AlertPoliciesExceptionReason.unsupportedVersion);
    }
    if (!capabilities.supported || write && !capabilities.canConfigure) {
      _policiesThrow(AlertPoliciesExceptionReason.unavailableMethod);
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

  Future<_PoliciesRead> _read() async {
    final admin = _configurationBackupAdmin(await _call('auth.me', const []));
    final power = await _power._read();
    final categories = await _call('alert.list_categories', const []);
    final policies = await _call('alert.list_policies', const []);
    if (policies is! List ||
        policies.length != 4 ||
        policies.toSet().length != 4 ||
        !policies.every(
          (p) =>
              AlertPolicyFrequency.values.any((v) => v.name.toUpperCase() == p),
        )) {
      _policiesThrow(AlertPoliciesExceptionReason.invalidResponse);
    }
    final config = _policiesConfig(
      await _call('alertclasses.config', const []),
    );
    final classes = _policiesClasses(categories, config.$2);
    bool? available, enabled;
    if (capabilities.canReadSupportEligibility) {
      try {
        final a = await _call('support.is_available', const []),
            e = await _call('support.is_available_and_enabled', const []);
        if (a is bool && e is bool && !(a == false && e == true)) {
          available = a;
          enabled = e;
        }
      } on Object {
        _guard();
      }
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
      _policiesThrow(AlertPoliciesExceptionReason.staleReview);
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
    return _PoliciesRead(
      AlertPoliciesInventory(
        readiness: readiness,
        configId: config.$1,
        classes: classes,
        unlistedOverrideCount: config.$2.keys
            .where((k) => !classes.any((c) => c.id == k))
            .length,
        supportAvailable: available,
        supportEnabled: enabled,
      ),
      config.$2,
    );
  }

  Future<AlertPoliciesInventory> load() async {
    _guard();
    if (isBusy || isOtherMutationBusy()) {
      _policiesThrow(AlertPoliciesExceptionReason.busy);
    }
    _calling = true;
    _inventories.clear();
    _reviews.clear();
    try {
      final read = await _read();
      if (isOtherMutationBusy()) {
        _policiesThrow(AlertPoliciesExceptionReason.busy);
      }
      _inventories[read.inventory] = _policiesProof(read);
      return read.inventory;
    } on AlertPoliciesException {
      rethrow;
    } on Object {
      _policiesThrow(AlertPoliciesExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<AlertPoliciesReview> review(AlertPoliciesRequest request) async {
    _guard(write: true);
    if (isBusy || isOtherMutationBusy()) {
      _policiesThrow(AlertPoliciesExceptionReason.busy);
    }
    final proof = _inventories[request.inventory];
    if (proof == null || request.inventory.endpoint != _endpoint) {
      _policiesThrow(AlertPoliciesExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      _policiesThrow(AlertPoliciesExceptionReason.invalidRequest);
    }
    _calling = true;
    _reviews.clear();
    try {
      final before = await _read();
      if (_policiesProof(before) != proof ||
          before.inventory.blockedReason != null ||
          isOtherMutationBusy()) {
        _policiesThrow(AlertPoliciesExceptionReason.staleReview);
      }
      final review = AlertPoliciesReview(
        request: request,
        endpoint: _endpoint,
        warnings: const [
          'This replaces the full alert-class override map, while preserving every unrelated class, empty override and field absence exactly. Reset removes only the selected override and restores its source defaults, including proactive support enabled by default for supported classes.',
          'NEVER hides this class from normal alert lists and associated events as well as configured notification services. It is not a global mute: independent per-alert mail and proactive-support reporting can still occur. Reducing severity may also suppress notification-service threshold matches.',
          'IMMEDIATELY, HOURLY and DAILY configure notification batching, not guaranteed delivery times. Policy snapshots, configured services and mail queues affect results. No test, send, queue cancellation, support ticket or probe is invoked here; already queued or in-flight delivery cannot be recalled.',
          'Changing or restoring proactive support may permit external automatic support tickets containing formatted new or cleared alerts, appliance serial, software version, licensed customer/company and configured primary/secondary contact details. These private details are not read by this app. Current global support eligibility/enabled status is read only as public booleans. No global enrollment, license, support contact or destination is changed.',
          'Readiness and full configuration readback are conservative, bounded and non-atomic. Concurrent administrators and background alert processing are not locked by this app. Configuration verification does not prove alert visibility everywhere, delivery, ticket creation or support response. A database write may precede a later error; an uncertain result is not rollback or permission to repeat.',
        ],
      );
      _reviews[review] = _PoliciesLease(_now(), proof);
      return review;
    } on AlertPoliciesException {
      rethrow;
    } on Object {
      _policiesThrow(AlertPoliciesExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<AlertPoliciesResult> execute(
    AlertPoliciesReview review,
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
        _policiesThrow(AlertPoliciesExceptionReason.busy);
      }
      if (lease == null ||
          !authorized() ||
          !ageValid() ||
          review.endpoint != _endpoint ||
          confirmation != review.target ||
          review.request.validationError != null) {
        _policiesThrow(AlertPoliciesExceptionReason.staleReview);
      }
      _calling = true;
      owns = true;
      _operationCurrent = isCurrent;
      final before = await _read();
      if (_policiesProof(before) != lease.proof ||
          before.inventory.blockedReason != null ||
          isOtherMutationBusy()) {
        _policiesThrow(AlertPoliciesExceptionReason.staleReview);
      }
      final expected = Map<String, AlertClassOverrides>.of(before.overrides);
      if (review.request.action == AlertPoliciesAction.resetClass) {
        expected.remove(review.request.classPolicy.id);
      } else {
        expected[review.request.classPolicy.id] = review.request.afterOverrides;
      }
      _guard(write: true);
      if (!ageValid()) _policiesThrow(AlertPoliciesExceptionReason.staleReview);
      final params = [
        {'classes': _policiesMap(expected)},
      ];
      sent = true;
      final receipt = _policiesConfig(
        await client
            .call('alertclasses.update', id: nextId(), params: params)
            .timeout(requestTimeout),
      );
      _guard(write: true);
      if (receipt.$1 != before.inventory.configId ||
          _policiesMapProof(receipt.$2) != _policiesMapProof(expected)) {
        return _unknown();
      }
      final after = await _read();
      if (_policiesBaseProof(before.inventory) !=
              _policiesBaseProof(after.inventory) ||
          _policiesMetadataProof(before.inventory.classes) !=
              _policiesMetadataProof(after.inventory.classes) ||
          _policiesMapProof(after.overrides) != _policiesMapProof(expected) ||
          after.inventory.blockedReason != null ||
          isOtherMutationBusy()) {
        return _unknown();
      }
      _inventories.clear();
      _reviews.clear();
      return const AlertPoliciesResult(
        AlertPoliciesOutcome.completed,
        'The selected override and complete saved class map matched the expected response and independent readback. Configuration only was verified, not notification delivery or support ticket creation.',
      );
    } on Object catch (error) {
      if (sent) return _unknown();
      return AlertPoliciesResult(
        AlertPoliciesOutcome.rejected,
        error is AlertPoliciesException ? error.userMessage : 'Alert policy authorization expired or preflight failed. No update was submitted.',
      );
    } finally {
      if (owns) {
        _operationCurrent = null;
        _calling = false;
      }
    }
  }

  AlertPoliciesResult _unknown() {
    _terminal = true;
    _inventories.clear();
    _reviews.clear();
    return const AlertPoliciesResult(
      AlertPoliciesOutcome.unknown,
      'Alert policy configuration may already have changed and affected visibility or external delivery. The result is unverified, not rollback. Further writes are fenced; inspect the original server independently without retrying.',
    );
  }
}

Never _policiesThrow(AlertPoliciesExceptionReason reason) =>
    throw AlertPoliciesException(reason);
bool _policiesId(Object? value) =>
    value is String &&
    value.length <= 128 &&
    RegExp(r'^[A-Za-z][A-Za-z0-9_]*$').stringMatch(value) == value;
AlertDeliveryLevel _policiesLevel(Object? raw) {
  for (final v in AlertDeliveryLevel.values) {
    if (v.name.toUpperCase() == raw) return v;
  }
  _policiesThrow(AlertPoliciesExceptionReason.invalidResponse);
}

AlertPolicyFrequency _policiesFrequency(Object? raw) {
  for (final v in AlertPolicyFrequency.values) {
    if (v.name.toUpperCase() == raw) return v;
  }
  _policiesThrow(AlertPoliciesExceptionReason.invalidResponse);
}

(int, Map<String, AlertClassOverrides>) _policiesConfig(Object? raw) {
  if (raw is! Map ||
      !_powerId(raw['id']) ||
      raw['classes'] is! Map ||
      (raw['classes'] as Map).length > 1024) {
    _policiesThrow(AlertPoliciesExceptionReason.invalidResponse);
  }
  final result = <String, AlertClassOverrides>{};
  for (final entry in (raw['classes'] as Map).entries) {
    final value = entry.value;
    if (!_policiesId(entry.key) ||
        value is! Map ||
        value.keys.any(
          (k) => !['level', 'policy', 'proactive_support'].contains(k),
        ) ||
        value.containsKey('proactive_support') &&
            value['proactive_support'] is! bool) {
      _policiesThrow(AlertPoliciesExceptionReason.invalidResponse);
    }
    result[entry.key as String] = AlertClassOverrides(
      level: value.containsKey('level') ? _policiesLevel(value['level']) : null,
      policy: value.containsKey('policy')
          ? _policiesFrequency(value['policy'])
          : null,
      proactiveSupport: value['proactive_support'] as bool?,
    );
  }
  return (raw['id'] as int, Map.unmodifiable(result));
}

List<AlertClassPolicySnapshot> _policiesClasses(
  Object? raw,
  Map<String, AlertClassOverrides> overrides,
) {
  if (raw is! List || raw.length > 64) {
    _policiesThrow(AlertPoliciesExceptionReason.invalidResponse);
  }
  final result = <AlertClassPolicySnapshot>[],
      ids = <String>{},
      categories = <String>{};
  for (final category in raw) {
    if (category is! Map ||
        !_policiesId(category['id']) ||
        category['title'] is! String ||
        !_emailText(category['title'], 512) ||
        (category['title'] as String).isEmpty ||
        !categories.add(category['id'] as String) ||
        category['classes'] is! List) {
      _policiesThrow(AlertPoliciesExceptionReason.invalidResponse);
    }
    final rows = category['classes'] as List;
    if (rows.length > 1024 || result.length + rows.length > 1024) {
      _policiesThrow(AlertPoliciesExceptionReason.invalidResponse);
    }
    for (final c in rows) {
      if (c is! Map ||
          !_policiesId(c['id']) ||
          !ids.add(c['id'] as String) ||
          c['title'] is! String ||
          !_emailText(c['title'], 512) ||
          (c['title'] as String).isEmpty ||
          c['proactive_support'] is! bool) {
        _policiesThrow(AlertPoliciesExceptionReason.invalidResponse);
      }
      final value = overrides[c['id']];
      if (c['proactive_support'] == false && value?.proactiveSupport != null) {
        _policiesThrow(AlertPoliciesExceptionReason.invalidResponse);
      }
      result.add(
        AlertClassPolicySnapshot(
          id: c['id'] as String,
          title: c['title'] as String,
          categoryId: category['id'] as String,
          categoryTitle: category['title'] as String,
          defaultLevel: _policiesLevel(c['level']),
          supportsProactiveSupport: c['proactive_support'] as bool,
          hasOverride: overrides.containsKey(c['id']),
          overrides: value ?? const AlertClassOverrides(),
        ),
      );
    }
  }
  result.sort((a, b) => a.id.compareTo(b.id));
  return result;
}

Map<String, Object?> _policiesOverrideMap(AlertClassOverrides value) => {
  if (value.level != null) 'level': value.level!.name.toUpperCase(),
  if (value.policy != null) 'policy': value.policy!.name.toUpperCase(),
  if (value.proactiveSupport != null)
    'proactive_support': value.proactiveSupport,
};
String _policiesOverrideProof(AlertClassOverrides value) =>
    jsonEncode(_policiesOverrideMap(value));
Map<String, Object?> _policiesMap(Map<String, AlertClassOverrides> values) => {
  for (final key in values.keys.toList()..sort())
    key: _policiesOverrideMap(values[key]!),
};
String _policiesMapProof(Map<String, AlertClassOverrides> values) =>
    jsonEncode(_policiesMap(values));
String _policiesBaseProof(AlertPoliciesInventory i) => jsonEncode([
  _deliveryBaseProof(i.readiness),
  i.configId,
  i.supportAvailable,
  i.supportEnabled,
]);
String _policiesMetadataProof(List<AlertClassPolicySnapshot> rows) =>
    jsonEncode([
      for (final c in rows)
        [
          c.id,
          c.title,
          c.categoryId,
          c.categoryTitle,
          c.defaultLevel.name,
          c.supportsProactiveSupport,
        ],
    ]);
String _policiesProof(_PoliciesRead r) => jsonEncode([
  _policiesBaseProof(r.inventory),
  _policiesMetadataProof(r.inventory.classes),
  _policiesMapProof(r.overrides),
]);
