import 'dashboard_capabilities.dart';

/// Deferred domains that have fixture contracts but no runtime API support.
enum DeferredObservationDomain { vdevs, disks, snapshots, apps }

/// Why a deferred observation contract cannot represent live server data.
enum DeferredObservationContractState {
  /// A documented fixture schema is available for this version family.
  fixtureOnly,

  /// Product policy has disabled use of the fixture contract.
  policyUnavailable,

  /// No documented fixture schema is selected for this version family.
  unknownVersion,
}

/// Locally-derived display status. It never preserves a server payload value.
enum DeferredObservationStatus { healthy, warning, critical, unknown }

/// A safe, bounded display record parsed from a static fixture.
final class DeferredObservation {
  const DeferredObservation({
    required this.label,
    required this.summary,
    required this.status,
  });

  final String label;
  final String summary;
  final DeferredObservationStatus status;
}

/// The safe observations represented by one fixture contract.
final class DeferredObservationFixture {
  const DeferredObservationFixture({required this.observations});

  final List<DeferredObservation> observations;
}

/// A versioned, fixture-only observation contract for a deferred dashboard domain.
///
/// This type deliberately has no RPC method or runtime loading mechanism.
final class DeferredObservationContract {
  const DeferredObservationContract._({
    required this.domain,
    required this.versionFamily,
    required this.state,
    this.fixtureId,
  });

  static const maxObservations = 50;
  static const maxDisplayCharacters = 160;

  final DeferredObservationDomain domain;
  final DashboardVersionFamily versionFamily;
  final DeferredObservationContractState state;

  /// Identifier for a static test fixture; never a runtime data source.
  final String? fixtureId;

  /// Deferred contracts are never enabled for runtime collection.
  bool get isRuntimeEnabled => false;

  /// Selects only a fixture schema, never an RPC contract.
  factory DeferredObservationContract.select({
    required DashboardVersionFamily versionFamily,
    required DeferredObservationDomain domain,
    bool fixturePolicyAvailable = true,
  }) {
    if (!fixturePolicyAvailable) {
      return DeferredObservationContract._(
        domain: domain,
        versionFamily: versionFamily,
        state: DeferredObservationContractState.policyUnavailable,
      );
    }
    if (versionFamily == DashboardVersionFamily.unknownUnsupported) {
      return DeferredObservationContract._(
        domain: domain,
        versionFamily: versionFamily,
        state: DeferredObservationContractState.unknownVersion,
      );
    }
    return DeferredObservationContract._(
      domain: domain,
      versionFamily: versionFamily,
      state: DeferredObservationContractState.fixtureOnly,
      fixtureId: '${_versionName(versionFamily)}_${_domainName(domain)}',
    );
  }

  /// Parses a static fixture into safe display-only observations.
  ///
  /// The accepted shape is exactly `{ "observations": [safe item, ...] }`,
  /// where every item is exactly `{ "label", "state", "summary" }`.
  DeferredObservationFixture parseFixture(Object? value) {
    if (state != DeferredObservationContractState.fixtureOnly) {
      throw StateError('Only fixture-only contracts can parse a fixture.');
    }
    final root = _stringObjectMap(value, 'top-level fixture', maxEntries: 1);
    _rejectSecretShapedKeys(root);
    if (root.length != 1 || !root.containsKey('observations')) {
      throw const FormatException('Fixture must contain only observations.');
    }
    final rawItems = root['observations'];
    if (rawItems is! List<Object?>) {
      throw const FormatException('Fixture observations must be a list.');
    }
    if (rawItems.length > maxObservations) {
      throw const FormatException('Fixture has too many observations.');
    }

    final observations = <DeferredObservation>[];
    for (final rawItem in rawItems) {
      final item = _stringObjectMap(
        rawItem,
        'fixture observation',
        maxEntries: 3,
      );
      _rejectSecretShapedKeys(item);
      if (item.length != 3 ||
          !item.containsKey('label') ||
          !item.containsKey('state') ||
          !item.containsKey('summary')) {
        throw const FormatException(
          'Fixture observation has an invalid shape.',
        );
      }
      final label = _displayString(item['label'], 'label', domain);
      final state = _displayString(item['state'], 'state', domain);
      final summary = _displayString(item['summary'], 'summary', domain);
      observations.add(
        DeferredObservation(
          label: label,
          summary: summary,
          status: _statusFor(state),
        ),
      );
    }
    return DeferredObservationFixture(
      observations: List.unmodifiable(observations),
    );
  }
}

Map<String, Object?> _stringObjectMap(
  Object? value,
  String description, {
  required int maxEntries,
}) {
  if (value is! Map<Object?, Object?>) {
    throw FormatException('$description must be an object.');
  }
  if (value.length > maxEntries) {
    throw FormatException('$description has too many entries.');
  }
  final result = <String, Object?>{};
  for (final entry in value.entries) {
    if (entry.key is! String) {
      throw FormatException('$description keys must be strings.');
    }
    result[entry.key as String] = entry.value;
  }
  return result;
}

void _rejectSecretShapedKeys(Map<String, Object?> value) {
  for (final key in value.keys) {
    if (RegExp(
      r'(pass(word)?|secret|token|api[_-]?key|credential|private[_-]?key|certificate|serial)',
      caseSensitive: false,
    ).hasMatch(key)) {
      throw FormatException('Secret-shaped fixture key is not allowed: $key');
    }
  }
}

String _displayString(
  Object? value,
  String field,
  DeferredObservationDomain domain,
) {
  if (value is! String) {
    throw FormatException('Fixture $field must be a string.');
  }
  if (!_isAllowedFixtureDisplayValue(domain, field, value)) {
    throw const FormatException('Fixture display value is not allowed.');
  }
  return value.length <= DeferredObservationContract.maxDisplayCharacters
      ? value
      : value.substring(0, DeferredObservationContract.maxDisplayCharacters);
}

bool _isAllowedFixtureDisplayValue(
  DeferredObservationDomain domain,
  String field,
  String value,
) => switch ((domain, field)) {
  (DeferredObservationDomain.vdevs, 'label') => const <String>{
    'tank / mirror-0',
    'tank / cache',
    'Example pool / data',
  }.contains(value),
  (DeferredObservationDomain.vdevs, 'state') => const <String>{
    'ONLINE',
    'DEGRADED',
  }.contains(value),
  (DeferredObservationDomain.vdevs, 'summary') => const <String>{
    'Two-way mirror is online',
    'Example cache device needs review',
    'Documented display-schema example',
  }.contains(value),
  (DeferredObservationDomain.disks, 'label') => const <String>{
    'Example disk bay 1',
  }.contains(value),
  (DeferredObservationDomain.disks, 'state') => const <String>{
    'ONLINE',
  }.contains(value),
  (DeferredObservationDomain.disks, 'summary') => const <String>{
    'Documented display-schema example',
  }.contains(value),
  (DeferredObservationDomain.snapshots, 'label') => const <String>{
    'Example snapshot schedule',
  }.contains(value),
  (DeferredObservationDomain.snapshots, 'state') => const <String>{
    'ACTIVE',
  }.contains(value),
  (DeferredObservationDomain.snapshots, 'summary') => const <String>{
    'Documented display-schema example',
  }.contains(value),
  (DeferredObservationDomain.apps, 'label') => const <String>{
    'Example application',
  }.contains(value),
  (DeferredObservationDomain.apps, 'state') => const <String>{
    'RUNNING',
  }.contains(value),
  (DeferredObservationDomain.apps, 'summary') => const <String>{
    'Documented display-schema example',
  }.contains(value),
  _ => false,
};

DeferredObservationStatus _statusFor(String state) {
  switch (state.toUpperCase()) {
    case 'ONLINE':
    case 'HEALTHY':
    case 'RUNNING':
    case 'ACTIVE':
    case 'SUCCESS':
      return DeferredObservationStatus.healthy;
    case 'DEGRADED':
    case 'WARNING':
    case 'PENDING':
      return DeferredObservationStatus.warning;
    case 'FAULTED':
    case 'OFFLINE':
    case 'FAILED':
    case 'CRITICAL':
      return DeferredObservationStatus.critical;
    default:
      return DeferredObservationStatus.unknown;
  }
}

String _versionName(DashboardVersionFamily family) => switch (family) {
  DashboardVersionFamily.v25_04 => 'v25_04',
  DashboardVersionFamily.v25_10 => 'v25_10',
  DashboardVersionFamily.v26Plus => 'v26_plus',
  DashboardVersionFamily.unknownUnsupported => 'unknown_unsupported',
};

String _domainName(DeferredObservationDomain domain) => switch (domain) {
  DeferredObservationDomain.vdevs => 'vdevs',
  DeferredObservationDomain.disks => 'disks',
  DeferredObservationDomain.snapshots => 'snapshots',
  DeferredObservationDomain.apps => 'apps',
};
