part of 'true_nas_session_repository.dart';

abstract interface class AuthenticatedAlertsSession {
  AlertsCapabilities get alertsCapabilities;
  Future<AlertInventory> loadAlerts();
  Future<AlertReview> reviewAlert(AlertRequest request);
  Future<AlertResult> executeAlert(AlertReview review, String confirmation);
}

final class AlertsCapabilities {
  const AlertsCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.available,
    required this.canDismiss,
    required this.canRestore,
  });
  const AlertsCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false,
      canDismiss = false,
      canRestore = false;
  final bool connected, versionSupported, available, canDismiss, canRestore;
  bool get supported => connected && versionSupported && available;
  bool allows(AlertAction action) =>
      supported && (action == AlertAction.dismiss ? canDismiss : canRestore);
  String? get blockedReason => !connected
      ? 'Connect to inspect current visible alerts.'
      : !versionSupported
      ? 'Native alerts require stable TrueNAS 25.10.'
      : !available
      ? 'Public alert-list and HA-license reads are required.'
      : null;
}

/// Only validated identity, coded metadata and allowlisted numeric observations.
/// Raw alert text, HTML, key, arguments and mail never enter this model.
final class AlertSnapshot {
  AlertSnapshot({
    required this.id,
    required this.klass,
    required this.source,
    required this.node,
    required this.level,
    required this.firstSeen,
    required this.lastSeen,
    required this.dismissed,
    required this.oneShot,
    Map<String, num> metrics = const {},
  }) : metrics = Map.unmodifiable(metrics);
  final String id, klass, source, node, level;
  final DateTime firstSeen, lastSeen;
  final bool dismissed, oneShot;
  final Map<String, num> metrics;
  bool get knownClass => _alertClasses.containsKey(klass);
  bool get supported =>
      !oneShot &&
      _alertClasses[klass]?.source == source &&
      node == 'Controller A';
  String get title => alertClassTitle(klass);
  String get category => _alertClasses[klass]?.category ?? 'Other';
  String get sourceLabel => knownClass && _alertClasses[klass]?.source == source
      ? source
      : 'Other source';
  String get summary =>
      _alertClasses[klass]?.summary ??
      'This class requires the specialized TrueNAS workflow. Raw alert content is withheld.';
  String? get blockedReason => oneShot
      ? 'One-shot alerts may be permanently deleted on dismissal; use TrueNAS.'
      : !_alertClasses.containsKey(klass) ||
            _alertClasses[klass]?.source != source
      ? 'This class/source has no pinned plain-alert dismissal contract.'
      : node != 'Controller A'
      ? 'Only standalone Controller A alerts can be changed here.'
      : null;
}

final class AlertInventory {
  AlertInventory({
    required this.endpoint,
    required this.failoverLicensed,
    required List<AlertSnapshot> alerts,
  }) : alerts = List.unmodifiable(alerts);
  final String endpoint;
  final bool failoverLicensed;
  final List<AlertSnapshot> alerts;
}

enum AlertAction { dismiss, restore }

final class AlertRequest {
  const AlertRequest({
    required this.inventory,
    required this.action,
    required this.alert,
  });
  final AlertInventory inventory;
  final AlertAction action;
  final AlertSnapshot alert;
  String get target => '${action.name.toUpperCase()} ${alert.id}';
  String? get validationError => inventory.failoverLicensed
      ? 'HA alert changes require the coordinated TrueNAS workflow.'
      : !inventory.alerts.any((a) => identical(a, alert))
      ? 'Choose the exact alert from this inventory.'
      : alert.blockedReason ??
            (action == AlertAction.dismiss && alert.dismissed ||
                    action == AlertAction.restore && !alert.dismissed
                ? 'The alert already has this dismissed state.'
                : null);
}

final class AlertReview {
  AlertReview({
    required this.request,
    required this.endpoint,
    required List<String> warnings,
  }) : warnings = List.unmodifiable(warnings);
  final AlertRequest request;
  final String endpoint;
  final List<String> warnings;
  AlertAction get action => request.action;
  String get target => request.target;
}

enum AlertOutcome { succeeded, rejected, unknown }

final class AlertResult {
  const AlertResult(this.outcome, this.message);
  final AlertOutcome outcome;
  final String message;
}

enum AlertsExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  busy,
  staleReview,
  invalidRequest,
  invalidResponse,
  unavailable,
}

final class AlertsException implements Exception {
  const AlertsException(this.reason);
  final AlertsExceptionReason reason;
  String get userMessage => switch (reason) {
    AlertsExceptionReason.notAuthenticated =>
      'Connect again before managing alerts.',
    AlertsExceptionReason.unsupportedVersion =>
      'Native alerts require stable TrueNAS 25.10.',
    AlertsExceptionReason.unavailableMethod =>
      'Required public alert methods are unavailable.',
    AlertsExceptionReason.busy =>
      'Another operation is active or its outcome is unknown.',
    AlertsExceptionReason.staleReview => 'The alert, connection or issued review changed. Reload and review again.',
    AlertsExceptionReason.invalidRequest =>
      'Choose a supported standalone alert and a different dismissed state.',
    AlertsExceptionReason.invalidResponse =>
      'Alert safety information could not be validated.',
    AlertsExceptionReason.unavailable =>
      'Alert information is unavailable. Remote details were withheld.',
  };
  @override
  String toString() => userMessage;
}

final class _AlertClass {
  const _AlertClass(this.source, this.title, this.category, this.summary);
  final String source, title, category, summary;
}

// Pinned TS-25.10.1 classes directly inherit AlertClass: never dismiss handlers
// or persistent one-shots. Unknown/new classes are deliberately display-only.
const _alertClasses = <String, _AlertClass>{
  'VolumeStatus': _AlertClass(
    'VolumeStatus',
    'Pool health needs attention',
    'Storage',
    'Inspect pool and disk health. Dismissal does not repair storage or establish data integrity.',
  ),
  'BootPoolStatus': _AlertClass(
    'VolumeStatus',
    'Boot pool health needs attention',
    'System',
    'Inspect the boot pool before maintenance. Dismissal does not repair the boot device.',
  ),
  'ZpoolCapacityNotice': _AlertClass(
    'ZpoolCapacity',
    'Pool capacity notice',
    'Storage',
    'A pool capacity threshold was reached. Inspect capacity; dismissal does not free space.',
  ),
  'ZpoolCapacityWarning': _AlertClass(
    'ZpoolCapacity',
    'Pool capacity warning',
    'Storage',
    'A pool capacity threshold was reached. Inspect capacity; dismissal does not free space.',
  ),
  'ZpoolCapacityCritical': _AlertClass(
    'ZpoolCapacity',
    'Pool capacity critical',
    'Storage',
    'A pool capacity threshold was reached. Inspect capacity; dismissal does not free space.',
  ),
  'DiskTemperatureTooHot': _AlertClass(
    'DiskTemperatureTooHot',
    'Disk temperature warning',
    'Hardware',
    'The disk source reported a temperature threshold. Inspect hardware cooling; dismissal does not cool the disk.',
  ),
  'NTPHealthCheck': _AlertClass(
    'NTPHealthCheck',
    'Time synchronization needs attention',
    'System',
    'Inspect time service health. Dismissal does not correct time synchronization.',
  ),
  'CertificateIsExpiring': _AlertClass(
    'CertificateChecks',
    'Certificate expiry notice',
    'Certificates',
    'Inspect certificate validity. Dismissal does not renew a certificate.',
  ),
  'CertificateIsExpiringSoon': _AlertClass(
    'CertificateChecks',
    'Certificate expiry warning',
    'Certificates',
    'Inspect certificate validity. Dismissal does not renew a certificate.',
  ),
  'CertificateExpired': _AlertClass(
    'CertificateChecks',
    'Certificate expired',
    'Certificates',
    'Inspect certificate validity. Dismissal does not renew a certificate.',
  ),
  'CertificateParsingFailed': _AlertClass(
    'CertificateChecks',
    'Certificate parsing failed',
    'Certificates',
    'Inspect certificate configuration. Dismissal does not repair the certificate.',
  ),
  'SMARTUncorrectedErrors': _AlertClass(
    'SMART',
    'Disk uncorrected errors',
    'Hardware',
    'Inspect disk diagnostics. Dismissal does not repair a disk or establish data integrity.',
  ),
  'SMARTFailedSelfTest': _AlertClass(
    'SMART',
    'Disk self-test failed',
    'Hardware',
    'Inspect disk diagnostics. Dismissal does not repair a disk or run another test.',
  ),
  'SMARTSpareBlockCount': _AlertClass(
    'SMART',
    'Disk spare block reserve low',
    'Hardware',
    'Inspect disk diagnostics. Dismissal does not repair hardware.',
  ),
  'SMARTEraseCycleCount': _AlertClass(
    'SMART',
    'Disk erase cycle count high',
    'Hardware',
    'Inspect disk diagnostics. Dismissal does not repair hardware.',
  ),
};
const _alertLevels = [
  'INFO',
  'NOTICE',
  'WARNING',
  'ERROR',
  'CRITICAL',
  'ALERT',
  'EMERGENCY',
];

/// Coded display title only; unknown or malicious class input is never echoed.
String alertClassTitle(String klass) =>
    _alertClasses[klass]?.title ?? 'Other alert class';

final class _AlertLease {
  const _AlertLease(this.created, this.fingerprint);
  final DateTime created;
  final String fingerprint;
}

final class _SessionAlerts {
  _SessionAlerts({
    required this.client,
    required ServerSummary summary,
    required Object? metadata,
    required this.nextId,
    required this.isCurrent,
    required this.isOtherMutationBusy,
    required this.requestTimeout,
  }) : _version =
           _managementVersion(summary.version) == _ManagementVersion.v2510,
       _endpoint = summary.endpointUri.toString(),
       _metadata = metadata is Map ? Map.of(metadata) : const {};
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent, isOtherMutationBusy;
  final Duration requestTimeout;
  final bool _version;
  final String _endpoint;
  final Map _metadata;
  bool _calling = false, _uncertain = false;
  final Set<AlertInventory> _inventories = {};
  final Map<AlertReview, _AlertLease> _reviews = {};
  bool get isBusy => _calling || _uncertain;
  bool _method(String name) {
    final row = _metadata[name];
    return row is Map &&
        row['job'] == false &&
        row['uploadable'] == false &&
        row['downloadable'] == false &&
        row['private'] != true &&
        row['_private'] != true &&
        row['no_auth_required'] == false;
  }

  AlertsCapabilities get capabilities => AlertsCapabilities(
    connected: isCurrent(),
    versionSupported: _version,
    available: _method('alert.list') && _method('failover.licensed'),
    canDismiss: _method('alert.dismiss'),
    canRestore: _method('alert.restore'),
  );
  void _guard([AlertAction? action]) {
    if (!isCurrent()) {
      throw const AlertsException(AlertsExceptionReason.notAuthenticated);
    }
    if (!_version) {
      throw const AlertsException(AlertsExceptionReason.unsupportedVersion);
    }
    if (!capabilities.supported ||
        action != null && !capabilities.allows(action)) {
      throw const AlertsException(AlertsExceptionReason.unavailableMethod);
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

  Future<AlertInventory> _read() async {
    final licensed = await _call('failover.licensed', const []);
    final raw = await _call('alert.list', const []);
    if (licensed is! bool || raw is! List || raw.length > 512) _alertInvalid();
    final alerts = raw.map(_alertParse).toList();
    if (alerts.map((a) => a.id).toSet().length != alerts.length) {
      _alertInvalid();
    }
    alerts.sort((a, b) {
      final severity = _alertLevels
          .indexOf(b.level)
          .compareTo(_alertLevels.indexOf(a.level));
      return severity != 0 ? severity : a.id.compareTo(b.id);
    });
    return AlertInventory(
      endpoint: _endpoint,
      failoverLicensed: licensed,
      alerts: alerts,
    );
  }

  Future<AlertInventory> load() async {
    _guard();
    if (_calling) throw const AlertsException(AlertsExceptionReason.busy);
    _calling = true;
    _reviews.clear();
    _inventories.clear();
    try {
      final inventory = await _read();
      _inventories.add(inventory);
      return inventory;
    } on AlertsException {
      rethrow;
    } on Object {
      throw const AlertsException(AlertsExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<AlertReview> review(AlertRequest request) async {
    _guard(request.action);
    if (isBusy || isOtherMutationBusy()) {
      throw const AlertsException(AlertsExceptionReason.busy);
    }
    if (!_inventories.contains(request.inventory) ||
        request.inventory.endpoint != _endpoint) {
      throw const AlertsException(AlertsExceptionReason.staleReview);
    }
    if (request.validationError != null) {
      throw const AlertsException(AlertsExceptionReason.invalidRequest);
    }
    _calling = true;
    try {
      final fresh = await _read(), fingerprint = _alertProof(request.alert);
      if (fresh.failoverLicensed ||
          !_matches(fresh, request.alert.id, fingerprint) ||
          isOtherMutationBusy()) {
        throw const AlertsException(AlertsExceptionReason.staleReview);
      }
      final review = AlertReview(
        request: request,
        endpoint: _endpoint,
        warnings: [
          '${request.alert.title} · ${request.alert.level} · ${request.alert.node}. Exact alert UUID: ${request.alert.id}.',
          request.action == AlertAction.dismiss
              ? 'Dismiss marks this plain alert dismissed for ordinary alert-service filtering. It does not guarantee silence, resolve the underlying condition, repair hardware, delete data or stop a task.'
              : 'Restore marks this existing alert active again. It does not recover a deleted one-shot alert or guarantee an immediate notification.',
          'Only this explicitly audited plain alert is targeted. One-shot, class-specific dismissal handlers and HA workflows are unsupported; no bulk action is performed.',
          'Raw descriptions, HTML, argument strings, keys and mail details are withheld. Inspect the relevant TrueNAS subsystem before acknowledging an alert.',
          'UUID, class, source, node, timestamps, severity and safe observations are rechecked before submission. The desired dismissed state must also be observed afterward; a null RPC receipt alone proves nothing.',
          'Another administrator or alert refresh can race after preflight. No automatic retry occurs. Visible counts exclude product-filtered or NEVER-policy classes and are not a complete system health assessment.',
          'The server changes an in-memory flag and persists alerts periodically. Readback is not a guarantee that this change will survive an immediate crash.',
        ],
      );
      _reviews.clear();
      _reviews[review] = _AlertLease(DateTime.now(), fingerprint);
      return review;
    } on AlertsException {
      rethrow;
    } on Object {
      throw const AlertsException(AlertsExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  bool _matches(AlertInventory inventory, String id, String proof) => inventory
      .alerts
      .where((a) => a.id == id)
      .any((a) => _alertProof(a) == proof);
  Future<AlertResult> execute(AlertReview review, String confirmation) async {
    var sent = false, owns = false;
    try {
      _guard(review.action);
      if (isBusy || isOtherMutationBusy()) {
        throw const AlertsException(AlertsExceptionReason.busy);
      }
      final lease = _reviews.remove(review);
      if (lease == null ||
          review.endpoint != _endpoint ||
          confirmation != review.target ||
          DateTime.now().difference(lease.created) >
              const Duration(minutes: 5) ||
          review.request.validationError != null) {
        throw const AlertsException(AlertsExceptionReason.staleReview);
      }
      _calling = true;
      owns = true;
      final fresh = await _read(), target = review.request.alert;
      if (fresh.failoverLicensed ||
          !_matches(fresh, target.id, lease.fingerprint) ||
          isOtherMutationBusy()) {
        throw const AlertsException(AlertsExceptionReason.staleReview);
      }
      sent = true;
      final receipt = await _call('alert.${review.action.name}', [target.id]);
      _reviews.clear();
      _inventories.clear();
      if (receipt != null) return _unknown();
      final after = await _read(),
          match = after.alerts.where((a) => a.id == target.id).singleOrNull;
      if (after.failoverLicensed ||
          match == null ||
          match.dismissed != (review.action == AlertAction.dismiss) ||
          _alertProof(match, includeDismissed: false) !=
              _alertProof(target, includeDismissed: false)) {
        return _unknown();
      }
      return const AlertResult(
        AlertOutcome.succeeded,
        'TrueNAS now reports the requested dismissed state for this exact alert. The underlying condition and notification delivery are not verified.',
      );
    } on Object catch (error) {
      if (sent) return _unknown();
      return AlertResult(
        AlertOutcome.rejected,
        error is AlertsException
            ? error.userMessage
            : 'Preflight failed. Nothing was submitted.',
      );
    } finally {
      if (owns) _calling = false;
    }
  }

  AlertResult _unknown() {
    _uncertain = true;
    _reviews.clear();
    _inventories.clear();
    return const AlertResult(
      AlertOutcome.unknown,
      'This alert change may have taken effect, but its exact result could not be verified. Inspect the original server and reconnect before further changes. Do not repeat it.',
    );
  }
}

AlertSnapshot _alertParse(Object? raw) {
  if (raw is! Map ||
      raw['id'] is! String ||
      !RegExp(r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$')
          .hasMatch(raw['id'] as String) ||
      raw['uuid'] != raw['id'] ||
      !_alertToken(raw['klass']) ||
      !_alertToken(raw['source'], empty: true) ||
      raw['node'] is! String ||
      !_alertNode(raw['node'] as String) ||
      !_alertLevels.contains(raw['level']) ||
      raw['dismissed'] is! bool ||
      raw['one_shot'] is! bool) {
    _alertInvalid();
  }
  DateTime first, last;
  try {
    first = _apiKeyDate(raw['datetime'], naiveUtc: true)!;
    last = _apiKeyDate(raw['last_occurrence'], naiveUtc: true)!;
  } on Object {
    _alertInvalid();
  }
  if (first.year < 1970 ||
      first.year > 2100 ||
      last.year < 1970 ||
      last.year > 2100 ||
      last.isBefore(first)) {
    _alertInvalid();
  }
  final metrics = <String, num>{},
      klass = raw['klass'] as String,
      args = raw['args'];
  if (args is Map) {
    void metric(String field, String label, num min, num max) {
      final value = args[field];
      if (value is num && value.isFinite && value >= min && value <= max) {
        metrics[label] = value;
      }
    }

    if (klass.startsWith('ZpoolCapacity') && _alertClasses.containsKey(klass)) {
      metric('capacity', 'Reported pool capacity (%)', 0, 100);
    }
    if (klass == 'DiskTemperatureTooHot') {
      metric('temp', 'Reported temperature (°C)', -40, 200);
      metric('crit_threshold', 'Critical threshold (°C)', 1, 200);
    }
    if (klass == 'CertificateIsExpiring' ||
        klass == 'CertificateIsExpiringSoon') {
      metric('days', 'Reported days until expiry', 0, 3660);
    }
    if (klass == 'SMARTUncorrectedErrors') {
      metric('ue', 'Reported uncorrected errors', 0, 9007199254740991);
    }
    if (klass == 'SMARTSpareBlockCount') {
      metric('sb', 'Reported spare block reserve', 0, 1000000000);
    }
  }
  return AlertSnapshot(
    id: raw['id'] as String,
    klass: klass,
    source: raw['source'] as String,
    node: raw['node'] as String,
    level: raw['level'] as String,
    firstSeen: first,
    lastSeen: last,
    dismissed: raw['dismissed'] as bool,
    oneShot: raw['one_shot'] as bool,
    metrics: metrics,
  );
}

bool _alertToken(Object? value, {bool empty = false}) =>
    value is String &&
    (empty && value.isEmpty ||
        RegExp(r'^[A-Za-z][A-Za-z0-9_]{0,95}$').hasMatch(value));
bool _alertNode(String value) => const {
  'Controller A',
  'Controller B',
  'Active Controller (A)',
  'Active Controller (B)',
  'Standby Controller (A)',
  'Standby Controller (B)',
  'Backup Controller (A)',
  'Backup Controller (B)',
  'Single Controller (A)',
  'Single Controller (B)',
  'Fault Controller (A)',
  'Fault Controller (B)',
  'Init Controller (A)',
  'Init Controller (B)',
  'Unknown Controller (A)',
  'Unknown Controller (B)',
}.contains(value);
String _alertProof(AlertSnapshot a, {bool includeDismissed = true}) =>
    jsonEncode([
      a.id,
      a.klass,
      a.source,
      a.node,
      a.level,
      a.firstSeen.toIso8601String(),
      a.lastSeen.toIso8601String(),
      a.oneShot,
      if (includeDismissed) a.dismissed,
      a.metrics,
    ]);
Never _alertInvalid() =>
    throw const AlertsException(AlertsExceptionReason.invalidResponse);
