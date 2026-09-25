part of 'true_nas_session_repository.dart';

/// Read-only, bounded history queries discovered on this authenticated session.
abstract interface class AuthenticatedReportingSession {
  ReportingCapabilities get reportingCapabilities;
  Future<List<ReportingGraph>> loadReportingGraphs();
  Future<List<ReportingHistory>> loadReportingHistory(ReportingRequest request);
}

final class ReportingCapabilities {
  const ReportingCapabilities({
    required this.connected,
    required this.versionSupported,
    required this.available,
  });
  const ReportingCapabilities.disconnected()
    : connected = false,
      versionSupported = false,
      available = false;
  final bool connected;
  final bool versionSupported;
  final bool available;
  bool get supported => connected && versionSupported && available;
  String? get blockedReason => !connected
      ? 'Connect to a TrueNAS server to load reporting history.'
      : !versionSupported
      ? 'Native reporting history requires a stable TrueNAS 25.10 release.'
      : !available
      ? 'This account does not expose reporting discovery and history methods.'
      : null;
}

final class ReportingGraph {
  ReportingGraph({
    required this.name,
    required this.title,
    required this.verticalLabel,
    required List<String>? identifiers,
    this.blockedReason,
  }) : identifiers = identifiers == null
           ? null
           : List.unmodifiable(identifiers);
  final String name;
  final String title;
  final String verticalLabel;

  /// Opaque values; disk identifiers can contain model and serial information.
  final List<String>? identifiers;
  final String? blockedReason;
  bool get supported => blockedReason == null;
}

final class ReportingRequest {
  const ReportingRequest({
    required this.graph,
    required this.identifier,
    required this.start,
    required this.end,
  });
  final ReportingGraph graph;
  final String? identifier;
  final DateTime start;
  final DateTime end;
  String? get validationError {
    final duration = end.difference(start);
    if (start.millisecondsSinceEpoch <= 0 ||
        end.year > 9999 ||
        duration < const Duration(minutes: 1) ||
        duration > const Duration(days: 365)) {
      return 'Choose a reporting interval from one minute to 365 days.';
    }
    final identifiers = graph.identifiers;
    if (identifiers == null
        ? identifier != null
        : identifier == null || !identifiers.contains(identifier)) {
      return 'Choose an instance reported by this server.';
    }
    return null;
  }
}

final class ReportingPoint {
  ReportingPoint({required this.timestamp, required List<double?> values})
    : values = List.unmodifiable(values);
  final DateTime timestamp;

  /// Same order as [ReportingHistory.legend], without the timestamp column.
  final List<double?> values;
}

final class ReportingHistory {
  ReportingHistory({
    required this.graphName,
    required this.identifier,
    required this.unit,
    required List<String> legend,
    required List<ReportingPoint> points,
    required this.returnedStart,
    required this.returnedEnd,
    required Map<String, Map<String, double?>>? aggregations,
    this.truncated = false,
    this.hasGaps = false,
  }) : legend = List.unmodifiable(legend),
       points = List.unmodifiable(points),
       aggregations = aggregations == null
           ? null
           : Map.unmodifiable({
               for (final entry in aggregations.entries)
                 entry.key: Map<String, double?>.unmodifiable(entry.value),
             });
  final String graphName;
  final String? identifier;
  final String unit;
  final List<String> legend;
  final List<ReportingPoint> points;

  /// Server range metadata, not invented first/last sample timestamps.
  final DateTime returnedStart;
  final DateTime returnedEnd;
  final Map<String, Map<String, double?>>? aggregations;
  final bool truncated;

  /// Null samples or irregular missing intervals. Upstream zero-fill is opaque.
  final bool hasGaps;
}

enum ReportingExceptionReason {
  notAuthenticated,
  unsupportedVersion,
  unavailableMethod,
  staleSession,
  staleGraph,
  invalidRequest,
  invalidResponse,
  responseTooLarge,
  unavailable,
  busy,
}

final class ReportingException implements Exception {
  const ReportingException(this.reason);
  final ReportingExceptionReason reason;
  String get userMessage => switch (reason) {
    ReportingExceptionReason.notAuthenticated =>
      'Connect to a TrueNAS server to load reporting history.',
    ReportingExceptionReason.unsupportedVersion =>
      'This TrueNAS version has not been verified for native reporting.',
    ReportingExceptionReason.unavailableMethod =>
      'The required reporting method is unavailable for this graph or account.',
    ReportingExceptionReason.staleSession =>
      'The connection changed. Reload reporting on the selected server.',
    ReportingExceptionReason.staleGraph =>
      'Reload the graph list from the current connection.',
    ReportingExceptionReason.invalidRequest =>
      'Choose a discovered graph and an interval from one minute to 365 days.',
    ReportingExceptionReason.invalidResponse =>
      'The reporting response could not be interpreted safely.',
    ReportingExceptionReason.responseTooLarge => 'The reporting response is too large. Choose a narrower interval or instance.',
    ReportingExceptionReason.unavailable =>
      'Reporting history is unavailable. No values have been substituted.',
    ReportingExceptionReason.busy =>
      'A reporting request is already in progress.',
  };
  @override
  String toString() => userMessage;
}

// The verified 25.10 get_data name enum is narrower than graph discovery.
const _reportingBatchGraphs = {
  'cpu',
  'cputemp',
  'disk',
  'interface',
  'load',
  'processes',
  'memory',
  'uptime',
  'arcactualrate',
  'arcrate',
  'arcsize',
  'arcresult',
  'disktemp',
  'upscharge',
  'upsruntime',
  'upsvoltage',
  'upscurrent',
  'upsfrequency',
  'upsload',
  'upstemperature',
};

final class _SessionReporting {
  _SessionReporting({
    required this.client,
    required ServerSummary summary,
    required this.nextId,
    required this.isCurrent,
    required this.requestTimeout,
  }) : versionSupported =
           _managementVersion(summary.version) == _ManagementVersion.v2510,
       methods = Set.unmodifiable(summary.availableMethodNames);
  final JsonRpcClient client;
  final String Function() nextId;
  final bool Function() isCurrent;
  final Duration requestTimeout;
  final bool versionSupported;
  final Set<String> methods;
  Set<ReportingGraph> _graphs = {};
  bool _calling = false;
  ReportingCapabilities get capabilities => ReportingCapabilities(
    connected: isCurrent(),
    versionSupported: versionSupported,
    available: methods.containsAll({'reporting.graphs', 'reporting.get_data'}),
  );
  void _guard() {
    if (!isCurrent()) {
      throw const ReportingException(ReportingExceptionReason.staleSession);
    }
    if (!versionSupported) {
      throw const ReportingException(
        ReportingExceptionReason.unsupportedVersion,
      );
    }
    if (!capabilities.available) {
      throw const ReportingException(
        ReportingExceptionReason.unavailableMethod,
      );
    }
  }

  Future<Object?> _call(String method, List<Object?> arguments) async {
    _guard();
    final value = await client
        .call(method, id: nextId(), params: arguments)
        .timeout(requestTimeout);
    _guard();
    return value;
  }

  Future<List<ReportingGraph>> graphs() async {
    _guard();
    if (_calling) {
      throw const ReportingException(ReportingExceptionReason.busy);
    }
    _calling = true;
    // A discovery reload invalidates old selection objects, even if it fails.
    _graphs = {};
    try {
      final result = await _call('reporting.graphs', [
        <Object?>[],
        <String, Object?>{},
      ]);
      if (result is! List) _reportingInvalid();
      if (result.length > 256) _reportingTooLarge();
      final graphs = <ReportingGraph>[];
      final names = <String>{};
      var totalIdentifiers = 0;
      for (final raw in result) {
        if (raw is! Map ||
            !_reportingText(raw['name'], 64) ||
            !RegExp(r'^[a-z][a-z0-9_]*$').hasMatch(raw['name'] as String) ||
            !names.add(raw['name'] as String) ||
            !_reportingText(raw['title'], 256) ||
            !_reportingText(raw['vertical_label'], 64) ||
            !raw.containsKey('identifiers')) {
          _reportingInvalid();
        }
        final identifiers = raw['identifiers'];
        if (identifiers != null && identifiers is! List) _reportingInvalid();
        if (identifiers is List) {
          totalIdentifiers += identifiers.length;
          if (identifiers.length > 4096 || totalIdentifiers > 16384) {
            _reportingTooLarge();
          }
          if (identifiers.any((i) => !_reportingText(i, 1024)) ||
              identifiers.toSet().length != identifiers.length) {
            _reportingInvalid();
          }
        }
        final name = raw['name'] as String;
        final supported =
            _reportingBatchGraphs.contains(name) ||
            (identifiers == null && methods.contains('reporting.graph'));
        graphs.add(
          ReportingGraph(
            name: name,
            title: raw['title'] as String,
            verticalLabel: raw['vertical_label'] as String,
            identifiers: identifiers == null
                ? null
                : (identifiers as List).cast<String>(),
            blockedReason: supported
                ? null
                : 'This graph needs a verified per-instance reporting adapter.',
          ),
        );
      }
      _graphs = graphs.toSet();
      return List.unmodifiable(graphs);
    } on ReportingException {
      rethrow;
    } on Object {
      throw const ReportingException(ReportingExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }

  Future<List<ReportingHistory>> history(ReportingRequest request) async {
    _guard();
    if (_calling) {
      throw const ReportingException(ReportingExceptionReason.busy);
    }
    if (!_graphs.contains(request.graph)) {
      throw const ReportingException(ReportingExceptionReason.staleGraph);
    }
    if (request.validationError != null) {
      throw const ReportingException(ReportingExceptionReason.invalidRequest);
    }
    if (!request.graph.supported) {
      throw const ReportingException(
        ReportingExceptionReason.unavailableMethod,
      );
    }
    _calling = true;
    try {
      final query = <String, Object?>{
        'start': request.start.millisecondsSinceEpoch ~/ 1000,
        'end': request.end.millisecondsSinceEpoch ~/ 1000,
        'aggregate': true,
      };
      final batch = _reportingBatchGraphs.contains(request.graph.name);
      final result = await _call(
        batch ? 'reporting.get_data' : 'reporting.graph',
        batch
            ? [
                [
                  {
                    'name': request.graph.name,
                    'identifier': request.identifier,
                  },
                ],
                query,
              ]
            : [request.graph.name, query],
      );
      if (result is! List) _reportingInvalid();
      // A request selects exactly one instance, including system-wide fallbacks.
      if (result.length > 1) _reportingInvalid();
      return List.unmodifiable([
        for (final raw in result) _reportingParseHistory(raw, request),
      ]);
    } on ReportingException {
      rethrow;
    } on Object {
      throw const ReportingException(ReportingExceptionReason.unavailable);
    } finally {
      _calling = false;
    }
  }
}

ReportingHistory _reportingParseHistory(Object? raw, ReportingRequest request) {
  if (raw is! Map || raw['name'] != request.graph.name) _reportingInvalid();
  final identifier = raw['identifier'];
  // Middleware substitutes the graph name for a null system-wide identifier.
  if (request.identifier == null
      ? identifier != null && identifier != request.graph.name
      : identifier != request.identifier) {
    _reportingInvalid();
  }
  final start = _reportingTimestamp(raw['start']);
  final end = _reportingTimestamp(raw['end']);
  if (!start.isBefore(end)) _reportingInvalid();
  // Metadata is the requested range, not the actual first/last sample extent.
  if (start.millisecondsSinceEpoch ~/ 1000 !=
          request.start.millisecondsSinceEpoch ~/ 1000 ||
      end.millisecondsSinceEpoch ~/ 1000 !=
          request.end.millisecondsSinceEpoch ~/ 1000) {
    _reportingInvalid();
  }
  final legend = raw['legend'];
  final data = raw['data'];
  if (legend is! List ||
      legend.isEmpty ||
      legend.first != 'time' ||
      legend.any((v) => !_reportingText(v, 128)) ||
      legend.toSet().length != legend.length ||
      data is! List) {
    _reportingInvalid();
  }
  if (legend.length > 513 ||
      data.length > 4000 ||
      legend.length * data.length > 1100000) {
    _reportingTooLarge();
  }
  final labels = legend.skip(1).cast<String>().toList();
  final receivedPoints = <ReportingPoint>[];
  final receivedIntervals = <int>[];
  DateTime? previous;
  for (final row in data) {
    if (row is! List || row.length != legend.length) _reportingInvalid();
    final time = _reportingTimestamp(row.first);
    if (previous != null && !time.isAfter(previous)) {
      _reportingInvalid();
    }
    if (previous != null) {
      receivedIntervals.add(time.difference(previous).inMilliseconds);
    }
    previous = time;
    // Validate measurements even on alignment rows that will not be plotted.
    final values = row.skip(1).map(_reportingNumber).toList();
    receivedPoints.add(ReportingPoint(timestamp: time, values: values));
  }
  final points = receivedPoints
      .where((p) => !p.timestamp.isBefore(start) && !p.timestamp.isAfter(end))
      .toList();
  final clipped = points.length != receivedPoints.length;
  if (clipped) {
    // TrueNAS requests Netdata's natural-points, whose database/group alignment
    // may extend the sample window beyond the exact metadata range. Admit only
    // one adjacent alignment sample per edge, within one observed interval and
    // an explicit five-minute ceiling. Never reinterpret an unrelated range as
    // empty history, move a timestamp, or silently skip malformed rows.
    if (points.isEmpty || receivedIntervals.isEmpty) _reportingInvalid();
    var alignmentMilliseconds = const Duration(minutes: 5).inMilliseconds;
    for (final interval in receivedIntervals) {
      if (interval < alignmentMilliseconds) alignmentMilliseconds = interval;
    }
    var beforeCount = 0;
    var afterCount = 0;
    for (final point in receivedPoints) {
      if (point.timestamp.isBefore(start)) {
        beforeCount++;
        if (beforeCount > 1 ||
            start.difference(point.timestamp).inMilliseconds >
                alignmentMilliseconds) {
          _reportingInvalid();
        }
      } else if (point.timestamp.isAfter(end)) {
        afterCount++;
        if (afterCount > 1 ||
            point.timestamp.difference(end).inMilliseconds >
                alignmentMilliseconds) {
          _reportingInvalid();
        }
      }
    }
  }
  final intervals = <int>[
    for (var i = 1; i < points.length; i++)
      points[i].timestamp.difference(points[i - 1].timestamp).inMilliseconds,
  ];
  var hasGaps = points.any(
    (point) => point.values.any((value) => value == null),
  );
  if (intervals.length > 1) {
    final sorted = [...intervals]..sort();
    final typical = sorted[(sorted.length - 1) ~/ 2];
    if (intervals.any((value) => value > typical * 1.5)) hasGaps = true;
  }
  final aggregates = raw['aggregations'];
  Map<String, Map<String, double?>>? parsedAggregates;
  if (aggregates != null) {
    if (aggregates is! Map ||
        aggregates.keys.toSet().difference({'min', 'mean', 'max'}).isNotEmpty) {
      _reportingInvalid();
    }
    parsedAggregates = {};
    for (final entry in aggregates.entries) {
      if (entry.value is! Map) _reportingInvalid();
      final values = entry.value as Map;
      if (values.keys.any((key) => !labels.contains(key))) _reportingInvalid();
      parsedAggregates[entry.key as String] = {
        for (final label in labels)
          label: values.containsKey(label)
              ? _reportingNumber(values[label])
              : null,
      };
    }
  }
  return ReportingHistory(
    graphName: request.graph.name,
    identifier: identifier as String?,
    unit: request.graph.verticalLabel,
    legend: labels,
    points: points,
    returnedStart: start,
    returnedEnd: end,
    // Server aggregates include the clipped samples. Publishing them as the
    // visible window's statistics would be misleading; callers may explicitly
    // calculate statistics from retained samples instead.
    aggregations: clipped ? null : parsedAggregates,
    truncated: clipped,
    hasGaps: hasGaps,
  );
}

DateTime _reportingTimestamp(Object? value) {
  if (value is! int || value <= 0 || value > 253402300799) _reportingInvalid();
  return DateTime.fromMillisecondsSinceEpoch(value * 1000, isUtc: true);
}

double? _reportingNumber(Object? value) {
  if (value == null) return null;
  if (value is! num || !value.isFinite) _reportingInvalid();
  return value.toDouble();
}

bool _reportingText(Object? value, int max) =>
    value is String &&
    value.isNotEmpty &&
    value.length <= max &&
    !RegExp(
      r'[\x00-\x1f\x7f-\x9f\u200b-\u200f\u202a-\u202e\u2060-\u206f\ufeff]',
    ).hasMatch(value);
Never _reportingInvalid() =>
    throw const ReportingException(ReportingExceptionReason.invalidResponse);
Never _reportingTooLarge() =>
    throw const ReportingException(ReportingExceptionReason.responseTooLarge);
