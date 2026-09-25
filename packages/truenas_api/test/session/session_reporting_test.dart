import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _methods = {'reporting.graphs', 'reporting.get_data', 'reporting.graph'};
final _start = DateTime.utc(2026, 1, 1, 12);
final _end = _start.add(const Duration(hours: 1));
Matcher _reason(ReportingExceptionReason reason) =>
    isA<ReportingException>().having((e) => e.reason, 'reason', reason);

void main() {
  test(
    'one year is admitted with exact epoch bounds and unchanged response caps',
    () async {
      final h = await _connected();
      final graph = (await h.repository.loadReportingGraphs()).first;
      final end = _start.add(const Duration(days: 365));
      await h.repository.loadReportingHistory(_request(graph, end: end));
      final params = h.transport.reportingRequests.last['params'] as List;
      expect(params.last, {
        'start': _seconds(_start),
        'end': _seconds(end),
        'aggregate': true,
      });
      expect(
        ReportingRequest(
          graph: graph,
          identifier: null,
          start: _start,
          end: end.add(const Duration(seconds: 1)),
        ).validationError,
        isNotNull,
      );
    },
  );
  test(
    'disconnected capability performs no discovery or history calls',
    () async {
      final h = _Harness();
      addTearDown(h.repository.close);
      expect(h.repository.reportingCapabilities.connected, isFalse);
      await expectLater(
        h.repository.loadReportingGraphs(),
        throwsA(_reason(ReportingExceptionReason.notAuthenticated)),
      );
      expect(h.transport.requests, isEmpty);
    },
  );
  for (final version in [
    '24.10.2',
    '25.04.2',
    '26.0.1',
    '25.10-beta',
    '25.10\n',
  ]) {
    test('unsupported version $version cannot query history', () async {
      final h = await _connected(version: version);
      expect(h.repository.reportingCapabilities.supported, isFalse);
      await expectLater(
        h.repository.loadReportingGraphs(),
        throwsA(_reason(ReportingExceptionReason.unsupportedVersion)),
      );
      expect(h.transport.reportingRequests, isEmpty);
    });
  }
  for (final method in ['reporting.graphs', 'reporting.get_data']) {
    test('missing $method blocks reporting capability', () async {
      final h = await _connected(methods: _methods.difference({method}));
      expect(h.repository.reportingCapabilities.available, isFalse);
      await expectLater(
        h.repository.loadReportingGraphs(),
        throwsA(_reason(ReportingExceptionReason.unavailableMethod)),
      );
    });
  }
  test(
    'discovery is read-only, immutable and preserves exact disk identifiers',
    () async {
      final h = await _connected();
      final graphs = await h.repository.loadReportingGraphs();
      expect(graphs.map((g) => g.name), [
        'cpu',
        'memory',
        'disk',
        'demanddatahitpercentage',
      ]);
      expect(graphs[2].identifiers!.single, _diskId);
      expect(() => graphs.clear(), throwsUnsupportedError);
      expect(() => graphs[2].identifiers!.clear(), throwsUnsupportedError);
      expect(h.transport.reportingRequests.single['params'], [[], {}]);
      expect(
        h.transport.reportingRequests.single['method'],
        'reporting.graphs',
      );
    },
  );
  test(
    'CPU history sends explicit epoch range, no unit/page or job poll',
    () async {
      final h = await _connected();
      final graph = (await h.repository.loadReportingGraphs()).first;
      final history = (await h.repository.loadReportingHistory(_request(graph)))
          .single;
      expect(
        h.transport.reportingRequests.last,
        containsPair('params', [
          [
            {'name': 'cpu', 'identifier': null},
          ],
          {'start': _seconds(_start), 'end': _seconds(_end), 'aggregate': true},
        ]),
      );
      expect(history.graphName, 'cpu');
      expect(history.identifier, 'cpu');
      expect(history.unit, '%CPU');
      expect(history.legend, ['cpu', 'cpu0']);
      expect(
        history.points.first.timestamp,
        _start.add(const Duration(seconds: 10)),
      );
      expect(history.points.first.values, [12.5, 20.0]);
      expect(history.returnedStart, _start);
      expect(history.returnedEnd, _end);
      expect(history.truncated, isFalse);
      expect(history.aggregations!['mean']!['cpu'], 14.0);
      expect(
        h.transport.requests.every(
          (r) => {
            'auth.login_ex',
            'auth.me',
            'system.info',
            'core.get_methods',
            'reporting.graphs',
            'reporting.get_data',
          }.contains(r['method']),
        ),
        isTrue,
      );
    },
  );
  test(
    'one discovered disk uses exact opaque identifier, never all-disk graph',
    () async {
      final h = await _connected();
      final graph = (await h.repository.loadReportingGraphs())[2];
      final history = (await h.repository.loadReportingHistory(
        _request(graph, identifier: _diskId),
      )).single;
      expect(history.identifier, _diskId);
      expect(history.unit, 'Kibibytes/s');
      expect(
        h.transport.reportingRequests.last['method'],
        'reporting.get_data',
      );
      expect((h.transport.reportingRequests.last['params'] as List).first, [
        {'name': 'disk', 'identifier': _diskId},
      ]);
    },
  );
  test(
    'discovered system-wide new ARC names use bounded graph fallback',
    () async {
      final h = await _connected();
      final graph = (await h.repository.loadReportingGraphs()).last;
      expect(graph.supported, isTrue);
      await h.repository.loadReportingHistory(_request(graph));
      expect(h.transport.reportingRequests.last['method'], 'reporting.graph');
      expect(
        (h.transport.reportingRequests.last['params'] as List).first,
        graph.name,
      );
    },
  );
  test(
    'fallback never fetches arbitrary per-instance graphs or missing methods',
    () async {
      final h = await _connected(
        methods: _methods.difference({'reporting.graph'}),
      );
      final graph = (await h.repository.loadReportingGraphs()).last;
      expect(graph.supported, isFalse);
      await expectLater(
        h.repository.loadReportingHistory(_request(graph)),
        throwsA(_reason(ReportingExceptionReason.unavailableMethod)),
      );
      final other = await _connected();
      other.transport.graphs.last['identifiers'] = ['instance'];
      final perInstance = (await other.repository.loadReportingGraphs()).last;
      expect(perInstance.supported, isFalse);
      await expectLater(
        other.repository.loadReportingHistory(
          _request(perInstance, identifier: 'instance'),
        ),
        throwsA(_reason(ReportingExceptionReason.unavailableMethod)),
      );
    },
  );
  test('foreign and forged graph objects cannot authorize requests', () async {
    final h = await _connected();
    final other = await _connected();
    final foreign = (await other.repository.loadReportingGraphs()).first;
    final forged = ReportingGraph(
      name: 'cpu',
      title: 'CPU',
      verticalLabel: '%',
      identifiers: null,
    );
    for (final graph in [foreign, forged]) {
      await expectLater(
        h.repository.loadReportingHistory(_request(graph)),
        throwsA(_reason(ReportingExceptionReason.staleGraph)),
      );
    }
    expect(h.transport.reportingRequests, isEmpty);
  });
  test('discovery refresh invalidates previously issued graphs', () async {
    final h = await _connected();
    final old = (await h.repository.loadReportingGraphs()).first;
    await h.repository.loadReportingGraphs();
    await expectLater(
      h.repository.loadReportingHistory(_request(old)),
      throwsA(_reason(ReportingExceptionReason.staleGraph)),
    );
  });
  test(
    'invalid dates and unadvertised identifiers fail before dispatch',
    () async {
      final h = await _connected();
      final graphs = await h.repository.loadReportingGraphs();
      final requests = [
        _request(graphs.first, start: _end, end: _start),
        _request(graphs.first, end: _start.add(const Duration(seconds: 59))),
        _request(graphs.first, end: _start.add(const Duration(days: 366))),
        _request(
          graphs.first,
          start: DateTime.fromMillisecondsSinceEpoch(0),
          end: DateTime.fromMillisecondsSinceEpoch(3600000),
        ),
        _request(graphs.first, identifier: 'cpu0'),
        _request(graphs[2]),
        _request(graphs[2], identifier: 'sda'),
      ];
      for (final request in requests) {
        await expectLater(
          h.repository.loadReportingHistory(request),
          throwsA(_reason(ReportingExceptionReason.invalidRequest)),
        );
      }
      expect(h.transport.reportingRequests, hasLength(1));
    },
  );
  test(
    'nulls and missing intervals remain gaps, zero stays measured server zero',
    () async {
      final h = await _connected();
      final graph = (await h.repository.loadReportingGraphs()).first;
      h.transport.transform = (raw) => raw
        ..['data'] = [
          [_seconds(_start) + 10, 0, null],
          [_seconds(_start) + 20, 15, 16],
          [_seconds(_start) + 50, null, 20],
        ];
      final history = (await h.repository.loadReportingHistory(_request(graph)))
          .single;
      expect(history.points.first.values, [0.0, null]);
      expect(history.points.last.values, [null, 20.0]);
      expect(history.hasGaps, isTrue);
      expect(history.points, hasLength(3));
    },
  );
  test(
    'missing aggregate values are null and output collections are immutable',
    () async {
      final h = await _connected();
      final graph = (await h.repository.loadReportingGraphs()).first;
      h.transport.transform = (raw) => raw
        ..['aggregations'] = {
          'min': {'cpu': 0},
          'mean': <String, Object?>{},
          'max': {'cpu0': 40},
        };
      final history = (await h.repository.loadReportingHistory(_request(graph)))
          .single;
      expect(history.aggregations!['mean'], {'cpu': null, 'cpu0': null});
      expect(() => history.points.clear(), throwsUnsupportedError);
      expect(() => history.legend.clear(), throwsUnsupportedError);
      expect(() => history.points.first.values.clear(), throwsUnsupportedError);
      expect(
        () => history.aggregations!['min']!['cpu'] = 2,
        throwsUnsupportedError,
      );
      expect(() => history.aggregations!.clear(), throwsUnsupportedError);
    },
  );
  test(
    'empty history and missing graph results never fabricate samples',
    () async {
      final h = await _connected();
      final graph = (await h.repository.loadReportingGraphs()).first;
      h.transport.transform = (raw) => raw
        ..['data'] = []
        ..['aggregations'] = null;
      final history = (await h.repository.loadReportingHistory(_request(graph)))
          .single;
      expect(history.points, isEmpty);
      expect(history.aggregations, isNull);
      h.transport.historyOverride = <Object?>[];
      expect(await h.repository.loadReportingHistory(_request(graph)), isEmpty);
    },
  );
  test(
    'natural-points leading alignment sample is clipped without shifting time',
    () async {
      final h = await _connected();
      final graph = (await h.repository.loadReportingGraphs()).first;
      h.transport.transform = (raw) => raw
        ..['data'] = [
          [_seconds(_start) - 1, 99, 99],
          [_seconds(_start), 12, 13],
          [_seconds(_start) + 1, 14, 15],
        ];
      final history = (await h.repository.loadReportingHistory(_request(graph)))
          .single;
      expect(history.points.map((p) => p.timestamp), [
        _start,
        _start.add(const Duration(seconds: 1)),
      ]);
      expect(history.points.first.values, [12.0, 13.0]);
      expect(history.points.last.values, [14.0, 15.0]);
      expect(history.truncated, isTrue);
      expect(history.hasGaps, isFalse);
      expect(
        history.aggregations,
        isNull,
        reason: 'Server aggregates include the clipped 99 values.',
      );
    },
  );
  test('natural-points trailing alignment sample is clipped but exact endpoint is kept', () async {
    final h = await _connected();
    final graph = (await h.repository.loadReportingGraphs()).first;
    h.transport.transform = (raw) => raw
      ..['data'] = [
        [_seconds(_end) - 1, 12, 13],
        [_seconds(_end), 14, 15],
        [_seconds(_end) + 1, 99, 99],
      ];
    final history = (await h.repository.loadReportingHistory(_request(graph)))
        .single;
    expect(history.points, hasLength(2));
    expect(history.points.last.timestamp, _end);
    expect(history.points.last.values, [14.0, 15.0]);
    expect(history.truncated, isTrue);
  });
  test(
    'both boundary samples may be clipped while retained nulls and gaps remain',
    () async {
      final h = await _connected();
      final graph = (await h.repository.loadReportingGraphs()).first;
      h.transport.transform = (raw) => raw
        ..['data'] = [
          [_seconds(_start) - 1, 99, 99],
          [_seconds(_start) + 1, null, 13],
          [_seconds(_end) - 1, 14, 15],
          [_seconds(_end) + 1, 99, 99],
        ];
      final history = (await h.repository.loadReportingHistory(_request(graph)))
          .single;
      expect(history.points, hasLength(2));
      expect(history.points.first.values.first, isNull);
      expect(history.hasGaps, isTrue);
      expect(history.truncated, isTrue);
    },
  );
  test(
    'five-minute natural cadence supports one bounded alignment sample',
    () async {
      final h = await _connected();
      final graph = (await h.repository.loadReportingGraphs()).first;
      h.transport.transform = (raw) => raw
        ..['data'] = [
          [_seconds(_start) - 240, 99, 99],
          [_seconds(_start) + 60, 12, 13],
          [_seconds(_start) + 360, 14, 15],
        ];
      final history = (await h.repository.loadReportingHistory(_request(graph)))
          .single;
      expect(history.points, hasLength(2));
      expect(
        history.points.first.timestamp,
        _start.add(const Duration(seconds: 60)),
      );
      expect(history.truncated, isTrue);
      expect(history.hasGaps, isFalse);
    },
  );
  test(
    'full observed 901-row CPU boundary pattern retains 900 actual samples',
    () async {
      final h = await _connected();
      final graph = (await h.repository.loadReportingGraphs()).first;
      final end = _start.add(const Duration(minutes: 15));
      h.transport.transform = (raw) => raw
        ..['data'] = List.generate(
          901,
          (i) => [_seconds(_start) - 1 + i, i.toDouble(), null],
        );
      final history = (await h.repository.loadReportingHistory(
        _request(graph, end: end),
      )).single;
      expect(history.points, hasLength(900));
      expect(history.points.first.timestamp, _start);
      expect(history.points.first.values, [1.0, null]);
      expect(
        history.points.last.timestamp,
        end.subtract(const Duration(seconds: 1)),
      );
      expect(history.points.last.values, [900.0, null]);
      expect(history.returnedStart, _start);
      expect(history.returnedEnd, end);
    },
  );
  final malformed = <String, void Function(Map<String, Object?>)>{
    'wrong graph': (r) => r['name'] = 'memory',
    'wrong identifier': (r) => r['identifier'] = 'another-server',
    'missing time legend': (r) => r['legend'] = ['cpu', 'cpu0'],
    'duplicate legend': (r) => r['legend'] = ['time', 'cpu', 'cpu'],
    'control legend': (r) => r['legend'] = ['time', 'cpu\n', 'cpu0'],
    'row length': (r) => r['data'] = [
      [_seconds(_start) + 1, 20],
    ],
    'string measurement': (r) => r['data'] = [
      [_seconds(_start) + 1, '20', 10],
    ],
    'bool measurement': (r) => r['data'] = [
      [_seconds(_start) + 1, true, 10],
    ],
    'object row': (r) => r['data'] = [
      {'time': _seconds(_start) + 1, 'cpu': 20},
    ],
    'duplicate timestamps': (r) => r['data'] = [
      [_seconds(_start) + 1, 20, 10],
      [_seconds(_start) + 1, 21, 11],
    ],
    'out of order timestamps': (r) => r['data'] = [
      [_seconds(_start) + 2, 20, 10],
      [_seconds(_start) + 1, 21, 11],
    ],
    'out of range timestamp': (r) => r['data'] = [
      [_seconds(_start) - 1, 20, 10],
    ],
    'leading offset beyond cadence': (r) => r['data'] = [
      [_seconds(_start) - 2, 20, 10],
      [_seconds(_start), 21, 11],
      [_seconds(_start) + 1, 22, 12],
    ],
    'offset beyond hard alignment ceiling': (r) => r['data'] = [
      [_seconds(_start) - 301, 20, 10],
      [_seconds(_start) + 1, 21, 11],
      [_seconds(_start) + 303, 22, 12],
    ],
    'more than one leading alignment row': (r) => r['data'] = [
      [_seconds(_start) - 2, 20, 10],
      [_seconds(_start) - 1, 21, 11],
      [_seconds(_start), 22, 12],
    ],
    'more than one trailing alignment row': (r) => r['data'] = [
      [_seconds(_end), 20, 10],
      [_seconds(_end) + 1, 21, 11],
      [_seconds(_end) + 2, 22, 12],
    ],
    'unrelated all-before range': (r) => r['data'] = [
      [_seconds(_start) - 30, 20, 10],
      [_seconds(_start) - 29, 21, 11],
    ],
    'unrelated all-after range': (r) => r['data'] = [
      [_seconds(_end) + 1, 20, 10],
      [_seconds(_end) + 2, 21, 11],
    ],
    'invalid value in otherwise clippable leading row': (r) => r['data'] = [
      [_seconds(_start) - 1, 'unsafe', 10],
      [_seconds(_start), 21, 11],
    ],
    'duplicate timestamps in clipped rows': (r) => r['data'] = [
      [_seconds(_start) - 1, 20, 10],
      [_seconds(_start) - 1, 21, 11],
      [_seconds(_start), 22, 12],
    ],
    'out of order clipped timestamp': (r) => r['data'] = [
      [_seconds(_start), 20, 10],
      [_seconds(_start) - 1, 21, 11],
      [_seconds(_start) + 1, 22, 12],
    ],
    'wrong time unit': (r) => r['data'] = [
      [_start.millisecondsSinceEpoch, 20, 10],
    ],
    'wrong range metadata': (r) => r['end'] = _seconds(_end) + 10,
    'aggregate unknown series': (r) => r['aggregations'] = {
      'mean': {'other': 5},
    },
    'aggregate invalid value': (r) => r['aggregations'] = {
      'mean': {'cpu': 'secret'},
    },
  };
  for (final entry in malformed.entries) {
    test(
      'malformed ${entry.key} rejects history instead of guessing',
      () async {
        final h = await _connected();
        final graph = (await h.repository.loadReportingGraphs()).first;
        h.transport.transform = (raw) {
          entry.value(raw);
          return raw;
        };
        await expectLater(
          h.repository.loadReportingHistory(_request(graph)),
          throwsA(_reason(ReportingExceptionReason.invalidResponse)),
        );
      },
    );
  }
  test(
    'oversized data fails explicitly, never silently truncates plotted data',
    () async {
      final h = await _connected();
      final graph = (await h.repository.loadReportingGraphs()).first;
      h.transport.transform = (raw) => raw
        ..['data'] = List.generate(4001, (i) => [_seconds(_start) + i, 1, 2]);
      await expectLater(
        h.repository.loadReportingHistory(_request(graph)),
        throwsA(_reason(ReportingExceptionReason.responseTooLarge)),
      );
    },
  );
  for (final kind in [
    'duplicate-name',
    'control-title',
    'bad-identifier',
    'duplicate-identifier',
    'missing-identifiers',
    'oversized-identifiers',
  ]) {
    test('invalid discovery $kind is not displayed or selectable', () async {
      final h = await _connected();
      switch (kind) {
        case 'duplicate-name':
          h.transport.graphs.add({...h.transport.graphs.first});
        case 'control-title':
          h.transport.graphs.first['title'] = 'CPU\u202efake';
        case 'bad-identifier':
          h.transport.graphs[2]['identifiers'] = ['disk\n'];
        case 'duplicate-identifier':
          h.transport.graphs[2]['identifiers'] = ['same', 'same'];
        case 'missing-identifiers':
          h.transport.graphs.first.remove('identifiers');
        case 'oversized-identifiers':
          h.transport.graphs[2]['identifiers'] = List.generate(
            4097,
            (i) => 'disk$i',
          );
      }
      await expectLater(
        h.repository.loadReportingGraphs(),
        throwsA(isA<ReportingException>()),
      );
    });
  }
  test('errors and timeouts are sanitized, no automatic retries', () async {
    final h = await _connected(timeout: const Duration(milliseconds: 20));
    final graph = (await h.repository.loadReportingGraphs()).first;
    h.transport.reject = true;
    try {
      await h.repository.loadReportingHistory(_request(graph));
      fail('Expected reporting failure');
    } on ReportingException catch (e) {
      expect(e.toString(), isNot(contains('secret-remote-text')));
    }
    h.transport.reject = false;
    h.transport.suppress = true;
    await expectLater(
      h.repository.loadReportingHistory(_request(graph)),
      throwsA(_reason(ReportingExceptionReason.unavailable)),
    );
    expect(
      h.transport.reportingRequests.where(
        (r) => r['method'] == 'reporting.get_data',
      ),
      hasLength(2),
    );
  });
  test(
    'duplicate in-flight reads are bounded and disconnect invalidates graphs',
    () async {
      final h = await _connected(timeout: const Duration(milliseconds: 50));
      final graph = (await h.repository.loadReportingGraphs()).first;
      h.transport.suppress = true;
      final first = h.repository.loadReportingHistory(_request(graph));
      await expectLater(
        h.repository.loadReportingHistory(_request(graph)),
        throwsA(_reason(ReportingExceptionReason.busy)),
      );
      final firstError = expectLater(first, throwsA(isA<ReportingException>()));
      await h.repository.close();
      await firstError;
      await expectLater(
        h.repository.loadReportingHistory(_request(graph)),
        throwsA(_reason(ReportingExceptionReason.notAuthenticated)),
      );
    },
  );
}

const _diskId = 'sda | Type: HDD | Model: Example | Serial: fixture';
int _seconds(DateTime value) => value.millisecondsSinceEpoch ~/ 1000;
ReportingRequest _request(
  ReportingGraph graph, {
  String? identifier,
  DateTime? start,
  DateTime? end,
}) => ReportingRequest(
  graph: graph,
  identifier: identifier,
  start: start ?? _start,
  end: end ?? _end,
);
Future<_Harness> _connected({
  String version = '25.10.1',
  Set<String> methods = _methods,
  Duration timeout = const Duration(seconds: 1),
}) async {
  final h = _Harness(version: version, methods: methods, timeout: timeout);
  addTearDown(h.repository.close);
  await h.repository.connect(
    serverInput: 'https://nas.example',
    apiKey: 'fixture-key',
    username: 'admin',
  );
  return h;
}

final class _Harness {
  _Harness({
    String version = '25.10.1',
    Set<String> methods = _methods,
    Duration timeout = const Duration(seconds: 1),
  }) {
    transport = _Transport(version, methods);
    repository = TrueNasSessionRepository(
      connector: _Connector(transport),
      managementRequestTimeout: timeout,
    );
  }
  late final _Transport transport;
  late final TrueNasSessionRepository repository;
}

final class _Connector implements RpcConnector {
  const _Connector(this.transport);
  final RpcTransport transport;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => transport;
}

final class _Transport implements RpcTransport {
  _Transport(this.version, this.methods);
  final String version;
  final Set<String> methods;
  final _inbound = StreamController<String>();
  final requests = <Map<String, Object?>>[];
  final graphs = <Map<String, Object?>>[
    {
      'name': 'cpu',
      'title': 'CPU Usage',
      'vertical_label': '%CPU',
      'identifiers': null,
    },
    {
      'name': 'memory',
      'title': 'Physical memory available',
      'vertical_label': 'Bytes',
      'identifiers': null,
    },
    {
      'name': 'disk',
      'title': 'Disk I/O ({identifier})',
      'vertical_label': 'Kibibytes/s',
      'identifiers': [_diskId],
    },
    {
      'name': 'demanddatahitpercentage',
      'title': 'Demand Data Hit Percentage',
      'vertical_label': 'hit%',
      'identifiers': null,
    },
  ];
  Map<String, Object?> Function(Map<String, Object?>)? transform;
  Object? historyOverride;
  bool reject = false;
  bool suppress = false;
  bool closed = false;
  Iterable<Map<String, Object?>> get reportingRequests =>
      requests.where((r) => (r['method'] as String).startsWith('reporting.'));
  @override
  Stream<String> get inboundFrames => _inbound.stream;
  @override
  Future<void> send(String frame) async {
    final r = Map<String, Object?>.from(jsonDecode(frame) as Map);
    requests.add(r);
    final method = r['method'] as String;
    if (method.startsWith('reporting.') && suppress) return;
    if (method.startsWith('reporting.') && reject) {
      _inbound.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': r['id'],
          'error': {'code': -32001, 'message': 'secret-remote-text'},
        }),
      );
      return;
    }
    Object? result;
    switch (method) {
      case 'auth.login_ex':
        result = {'response_type': 'SUCCESS'};
      case 'auth.me':
        result = {'username': 'admin'};
      case 'system.info':
        result = {'version': version};
      case 'core.get_methods':
        result = {
          for (final name in methods) name: {'job': false},
        };
      case 'reporting.graphs':
        result = graphs;
      case 'reporting.get_data':
      case 'reporting.graph':
        final params = r['params'] as List;
        final batch = method == 'reporting.get_data';
        final selection = batch ? (params.first as List).single as Map : null;
        final name = batch
            ? selection!['name'] as String
            : params.first as String;
        final identifier = selection?['identifier'] ?? name;
        final query = params.last as Map;
        final raw = <String, Object?>{
          'name': name,
          'identifier': identifier,
          'start': query['start'],
          'end': query['end'],
          'legend': ['time', 'cpu', 'cpu0'],
          'data': [
            [(query['start'] as int) + 10, 12.5, 20],
            [(query['end'] as int) - 10, 15.5, 22],
          ],
          'aggregations': {
            'min': {'cpu': 12.5, 'cpu0': 20},
            'mean': {'cpu': 14, 'cpu0': 21},
            'max': {'cpu': 15.5, 'cpu0': 22},
          },
        };
        result = historyOverride ?? [transform?.call(raw) ?? raw];
      default:
        throw StateError('Unexpected RPC: $method');
    }
    _inbound.add(
      jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _inbound.close();
  }
}
