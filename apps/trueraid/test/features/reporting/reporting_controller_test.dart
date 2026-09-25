import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/reporting/reporting_controller.dart';
import 'package:truenas_api/truenas_api.dart';

final _time = DateTime.utc(2026, 9, 12, 12);
const _endpoint = 'wss://metrics.example/api/current';

void main() {
  test('month and year use exact bounded UTC intervals', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    for (final range in [ReportingRange.month, ReportingRange.year]) {
      await h.load(range: range);
      expect(h.api.requests.last.start, _time.subtract(range.duration));
      expect(h.api.requests.last.end, _time);
      expect(h.state.window, isNull);
      expect(h.state.requestedWindow!.duration, range.duration);
    }
  });
  test(
    'custom window is retained by refresh even after clock advances',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      final window = ReportingWindow(
        start: _time.subtract(const Duration(days: 30)),
        end: _time.subtract(const Duration(days: 20)),
      );
      await h.load(window: window);
      h.now = _time.add(const Duration(days: 2));
      await h.controller.refresh();
      expect(h.api.requests.last.start, window.start);
      expect(h.api.requests.last.end, window.end);
      expect(h.state.window, same(window));
    },
  );
  test(
    'earlier and later navigate disjoint intervals and latest resets anchor',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.load(range: ReportingRange.day);
      await h.controller.movePeriod(forward: false);
      expect(
        h.api.requests.last.start,
        _time.subtract(const Duration(days: 2)),
      );
      expect(h.api.requests.last.end, _time.subtract(const Duration(days: 1)));
      await h.controller.movePeriod(forward: true);
      expect(h.api.requests.last.end, _time);
      expect(h.state.window, isNotNull);
      final count = h.api.requests.length;
      await h.controller.movePeriod(forward: true);
      expect(h.api.requests.length, count);
      h.now = _time.add(const Duration(hours: 2));
      await h.controller.returnToLatest();
      expect(h.state.window, isNull);
      expect(h.api.requests.last.end, h.now);
    },
  );
  test(
    'invalid future and oversized windows cannot query or replace history',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.load();
      for (final window in [
        ReportingWindow(start: _time, end: _time.add(const Duration(hours: 1))),
        ReportingWindow(
          start: _time.subtract(const Duration(days: 366)),
          end: _time,
        ),
        ReportingWindow(start: _time, end: _time),
      ]) {
        await h.load(window: window);
      }
      expect(h.api.requests, hasLength(1));
      expect(h.state.phase, ReportingPhase.ready);
    },
  );
  test('custom window response is cleared on account replacement', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    await h.load(
      window: ReportingWindow(
        start: _time.subtract(const Duration(days: 3)),
        end: _time,
      ),
    );
    h.select(_session(_Reporting()));
    expect(h.state.window, isNull);
    expect(h.state.requestedWindow, isNull);
    await h.controller.movePeriod(forward: false);
    expect(h.api.requests, hasLength(1));
  });
  test(
    'rapid selections coalesce to the latest without overlapping SDK reads',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      final response = Completer<List<ReportingHistory>>();
      h.api.onHistory = (_) => response.future;
      final first = h.load();
      final middle = h.load(range: ReportingRange.day);
      final latest = h.load(range: ReportingRange.week);
      await middle; // Replaced queued selection completes without a request.
      expect(h.api.requests, hasLength(1));
      h.api.onHistory = (_) async => [
        _history([30.0]),
      ];
      response.complete([
        _history([10.0]),
      ]);
      await first;
      await latest;
      expect(h.api.requests, hasLength(2));
      expect(
        h.api.requests.last.end.difference(h.api.requests.last.start),
        const Duration(days: 7),
      );
      expect(h.state.range, ReportingRange.week);
      expect(h.state.histories.single.points.single.values.single, 30.0);
    },
  );

  test(
    'history request preserves opaque disk identity and selected UTC range',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      final disk = ReportingGraph(
        name: 'disk',
        title: 'Disk I/O',
        verticalLabel: 'Kibibytes/s',
        identifiers: ['sda | Model: Sample | Serial: 123'],
      );
      await h.load(
        graph: disk,
        identifier: disk.identifiers!.single,
        range: ReportingRange.week,
      );
      final request = h.api.requests.single;
      expect(request.graph, same(disk));
      expect(request.identifier, disk.identifiers!.single);
      expect(request.start, _time.subtract(const Duration(days: 7)));
      expect(request.end, _time);
      expect(h.state.serverLabel, _endpoint);
    },
  );

  test('zero is a real returned value, not an unavailable graph', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.api.onHistory = (_) async => [
      _history([0, 0]),
    ];
    await h.load();
    expect(h.state.phase, ReportingPhase.ready);
    expect(h.state.histories.single.points.first.values, [0.0]);
  });

  test('null samples remain gaps and all-null history is empty', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.api.onHistory = (_) async => [
      _history([null, null]),
    ];
    await h.load();
    expect(h.state.phase, ReportingPhase.empty);
    expect(h.state.histories.single.points.first.values, [null]);
    expect(h.state.message, contains('not displayed as zero'));
  });

  test('empty server response never invents a chart', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.api.onHistory = (_) async => [];
    await h.load();
    expect(h.state.phase, ReportingPhase.empty);
    expect(h.state.histories, isEmpty);
  });

  test('mixed gaps preserve the available samples without filling', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.api.onHistory = (_) async => [
      _history([12.0, null, 15.0]),
    ];
    await h.load();
    expect(h.state.phase, ReportingPhase.ready);
    expect(h.state.histories.single.points.map((p) => p.values.single), [
      12.0,
      null,
      15.0,
    ]);
  });

  test('late data from a replaced session is discarded', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final response = Completer<List<ReportingHistory>>();
    h.api.onHistory = (_) => response.future;
    final pending = h.load();
    h.select(_session(_Reporting()));
    response.complete([
      _history([90.0]),
    ]);
    await pending;
    expect(h.state.phase, ReportingPhase.idle);
    expect(h.state.histories, isEmpty);
    expect(h.state.graph, isNull);
  });

  test(
    'explicit metric entry clears stale history and fences its old read',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      final response = Completer<List<ReportingHistory>>();
      h.api.onHistory = (_) => response.future;
      final older = h.load();
      h.controller.clearSelection();
      expect(h.state.phase, ReportingPhase.idle);
      expect(h.state.histories, isEmpty);

      final loadGraph = ReportingGraph(
        name: 'load',
        title: 'System load',
        verticalLabel: 'Load',
        identifiers: null,
      );
      h.api.onHistory = (_) async => [
        _history([2.0], name: 'load'),
      ];
      final newer = h.load(graph: loadGraph);
      response.complete([
        _history([80.0]),
      ]);
      await older;
      await newer;
      expect(h.state.graph, same(loadGraph));
      expect(h.state.histories.single.graphName, 'load');
      expect(h.api.requests, hasLength(2));
    },
  );

  test('older graph response cannot overwrite a newer selection', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    final response = Completer<List<ReportingHistory>>();
    h.api.onHistory = (_) => response.future;
    final older = h.load();
    final newerGraph = ReportingGraph(
      name: 'memory',
      title: 'Available memory',
      verticalLabel: 'Bytes',
      identifiers: null,
    );
    h.api.onHistory = (_) async => [
      _history([100.0], name: 'memory'),
    ];
    final newer = h.load(graph: newerGraph);
    expect(h.api.requests, hasLength(1), reason: 'SDK reads are serialized.');
    response.complete([
      _history([80.0]),
    ]);
    await older;
    await newer;
    expect(h.state.graph, same(newerGraph));
    expect(h.state.histories.single.graphName, 'memory');
  });

  test(
    'completed data disappears after same-endpoint account replacement',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.load();
      expect(h.state.histories, isNotEmpty);
      h.select(_session(_Reporting()));
      expect(h.state.histories, isEmpty);
      expect(h.state.graph, isNull);
      await h.controller.refresh();
      expect(h.api.requests, hasLength(1));
    },
  );

  test('stale explicit session cannot start a history request', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.select(null);
    await h.load();
    expect(h.api.requests, isEmpty);
  });

  test(
    'manual refresh advances time while retaining graph and range',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      await h.load(range: ReportingRange.day);
      h.now = _time.add(const Duration(minutes: 5));
      await h.controller.refresh();
      expect(h.api.requests, hasLength(2));
      expect(h.api.requests.last.graph, same(h.api.graph));
      expect(h.api.requests.last.end, h.now);
      expect(
        h.api.requests.last.end.difference(h.api.requests.last.start),
        const Duration(days: 1),
      );
    },
  );

  test('raw server errors are never exposed', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.api.onHistory = (_) async => throw StateError('private token detail');
    await h.load();
    expect(h.state.phase, ReportingPhase.failed);
    expect(h.state.message, isNot(contains('private token')));
    expect(h.state.histories, isEmpty);
  });

  test('safe adapter errors give the specific recovery action', () async {
    final h = _Harness();
    addTearDown(h.dispose);
    h.api.onHistory = (_) async => throw const ReportingException(
      ReportingExceptionReason.responseTooLarge,
    );
    await h.load();
    expect(h.state.message, contains('narrower interval'));
  });

  test(
    'graph discovery is read-only and never starts history on its own',
    () async {
      final h = _Harness();
      addTearDown(h.dispose);
      expect(await h.container.read(reportingGraphsProvider.future), [
        h.api.graph,
      ]);
      expect(h.api.requests, isEmpty);
    },
  );
}

ReportingHistory _history(List<double?> values, {String name = 'cpu'}) =>
    ReportingHistory(
      graphName: name,
      identifier: name,
      unit: '%CPU',
      legend: const ['cpu'],
      points: [
        for (var i = 0; i < values.length; i++)
          ReportingPoint(
            timestamp: _time.subtract(Duration(minutes: values.length - i)),
            values: [values[i]],
          ),
      ],
      returnedStart: _time.subtract(const Duration(hours: 1)),
      returnedEnd: _time,
      aggregations: null,
      hasGaps: values.contains(null),
    );

AuthenticatedSession _session(_Reporting api) => AuthenticatedSession(
  profileId: 'nas',
  repository: api,
  availableMethodNames: const {},
  version: '25.10.1',
  endpoint: _endpoint,
);

final class _Harness {
  _Harness() {
    session = _session(api);
    active = session;
    container = ProviderContainer(
      overrides: [
        dashboardActiveSessionProvider.overrideWith((ref) => active),
        reportingClockProvider.overrideWithValue(() => now),
      ],
    );
  }
  final api = _Reporting();
  late final AuthenticatedSession session;
  AuthenticatedSession? active;
  DateTime now = _time;
  late final ProviderContainer container;
  ReportingController get controller =>
      container.read(reportingControllerProvider.notifier);
  ReportingState get state => container.read(reportingControllerProvider);
  Future<void> load({
    ReportingGraph? graph,
    String? identifier,
    ReportingRange range = ReportingRange.hour,
    ReportingWindow? window,
  }) => controller.load(
    expectedSession: session,
    graph: graph ?? api.graph,
    identifier: identifier,
    range: range,
    window: window,
  );
  void select(AuthenticatedSession? next) {
    active = next;
    container.invalidate(dashboardActiveSessionProvider);
    container.read(dashboardActiveSessionProvider);
  }

  void dispose() => container.dispose();
}

final class _Reporting
    implements SessionRepository, AuthenticatedReportingSession {
  final graph = ReportingGraph(
    name: 'cpu',
    title: 'CPU usage',
    verticalLabel: '%CPU',
    identifiers: null,
  );
  final requests = <ReportingRequest>[];
  Future<List<ReportingHistory>> Function(ReportingRequest)? onHistory;
  @override
  ReportingCapabilities get reportingCapabilities =>
      const ReportingCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
      );
  @override
  Future<List<ReportingGraph>> loadReportingGraphs() async => [graph];
  @override
  Future<List<ReportingHistory>> loadReportingHistory(
    ReportingRequest request,
  ) async {
    requests.add(request);
    return onHistory != null
        ? onHistory!(request)
        : [
            _history([12.0, 15.0]),
          ];
  }

  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) async => throw UnimplementedError();
}
