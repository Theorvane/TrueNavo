import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/connection/connection_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/reporting/reporting_chart.dart';
import 'package:truenavo/features/reporting/reporting_controller.dart';
import 'package:truenavo/features/reporting/reporting_page.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  testWidgets('custom dates load inclusive UTC days capped at current time', (
    tester,
  ) async {
    final fixture = await _pump(tester, autoLoad: true);
    await _tap(tester, 'reporting-custom-range');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(fixture.api.requests, hasLength(2));
    expect(
      fixture.api.requests.last.start,
      DateTime.utc(
        _now.year,
        _now.month,
        _now.day,
      ).subtract(const Duration(days: 6)),
    );
    expect(fixture.api.requests.last.end, _now);
    expect(
      fixture.container.read(reportingControllerProvider).window,
      isNotNull,
    );
  });
  testWidgets(
    'saving a date dialog after disconnect cannot send stale selection',
    (tester) async {
      final fixture = await _pump(tester, autoLoad: true);
      await _tap(tester, 'reporting-custom-range');
      fixture.container.read(_sessionProvider.notifier).select(null);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(fixture.api.requests, hasLength(1));
      expect(find.text('Connect to load reporting'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('long ranges and period controls send exact requests', (
    tester,
  ) async {
    final fixture = await _pump(tester, autoLoad: true);
    await _tap(tester, 'reporting-range-year');
    expect(
      fixture.api.requests.last.start,
      _now.subtract(const Duration(days: 365)),
    );
    await _tap(tester, 'reporting-previous-period');
    expect(
      fixture.api.requests.last.end,
      _now.subtract(const Duration(days: 365)),
    );
    expect(find.byKey(const Key('reporting-latest-period')), findsOneWidget);
    await _tap(tester, 'reporting-latest-period');
    expect(fixture.api.requests.last.end, _now);
  });
  testWidgets('custom dates dialog can be cancelled without another read', (
    tester,
  ) async {
    final fixture = await _pump(tester, autoLoad: true);
    await _tap(tester, 'reporting-custom-range');
    expect(find.byType(DateRangePickerDialog), findsOneWidget);
    await tester.tap(find.byTooltip('Close'));
    await tester.pumpAndSettle();
    expect(fixture.api.requests, hasLength(1));
  });
  testWidgets('entry automatically loads a supported CPU graph once', (
    tester,
  ) async {
    final fixture = await _pump(tester, autoLoad: true);
    expect(fixture.api.requests, hasLength(1));
    expect(fixture.api.requests.single.graph.name, 'cpu');
    expect(find.byType(ReportingChart), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(
      fixture.api.requests,
      hasLength(1),
      reason: 'No timer or rebuild causes repeated history calls.',
    );
  });
  testWidgets('preferred load history opens the discovered load graph', (
    tester,
  ) async {
    final fixture = await _pump(
      tester,
      autoLoad: true,
      initialGraphName: 'load',
    );
    expect(fixture.api.requests, hasLength(1));
    expect(fixture.api.requests.single.graph.name, 'load');
    expect(find.byType(ReportingChart), findsOneWidget);
  });

  testWidgets('missing preferred load graph never falls back to CPU', (
    tester,
  ) async {
    final fixture = await _pump(
      tester,
      autoLoad: true,
      initialGraphName: 'load',
      includeLoad: false,
    );
    expect(fixture.api.requests, isEmpty);
    expect(find.text('Requested metric unavailable'), findsOneWidget);
  });

  testWidgets('offline never fabricates data or queries history', (
    tester,
  ) async {
    final fixture = await _pump(tester, connected: false);
    expect(find.text('Connect to load reporting'), findsOneWidget);
    expect(find.byType(ReportingChart), findsNothing);
    expect(fixture.api.graphReads, 0);
    expect(fixture.api.requests, isEmpty);
  });

  testWidgets(
    'discovery exposes server metrics but does not load history implicitly',
    (tester) async {
      final fixture = await _pump(tester);
      expect(find.text('Choose a metric to begin'), findsOneWidget);
      expect(fixture.api.graphReads, 1);
      expect(fixture.api.requests, isEmpty);
      expect(find.text('Unavailable graphs (1)'), findsOneWidget);
      await tester.tap(_metric());
      await tester.pumpAndSettle();
      expect(find.text('CPU utilization'), findsOneWidget);
      expect(find.text('Network instance'), findsOneWidget);
      expect(find.text('No sensor instances · unavailable'), findsOneWidget);
    },
  );

  testWidgets(
    'metric choice uses exact discovered identity and one-hour UTC interval',
    (tester) async {
      final fixture = await _pump(tester);
      await _choose(tester, 'CPU utilization');
      final request = fixture.api.requests.single;
      expect(identical(request.graph, fixture.api.graphs.first), isTrue);
      expect(request.identifier, isNull);
      expect(request.end, _now);
      expect(request.start, _now.subtract(const Duration(hours: 1)));
      expect(find.byType(ReportingChart), findsOneWidget);
      expect(find.textContaining('latest 20'), findsOneWidget);
    },
  );

  testWidgets('range and refresh request actual intervals without mutation', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    await _choose(tester, 'CPU utilization');
    await _tap(tester, 'reporting-range-week');
    expect(
      fixture.api.requests.last.end.difference(fixture.api.requests.last.start),
      const Duration(days: 7),
    );
    await _tap(tester, 'reporting-refresh');
    expect(fixture.api.requests, hasLength(3));
    expect(find.textContaining('History is a snapshot'), findsOneWidget);
  });

  testWidgets(
    'opaque instance IDs are visible and passed without normalization',
    (tester) async {
      final fixture = await _pump(tester);
      await _choose(tester, 'Network instance');
      expect(fixture.api.requests.single.identifier, 'enp0s1');
      final instance = find.byWidgetPredicate(
        (widget) =>
            widget is DropdownButtonFormField<String> &&
            widget.decoration.labelText == 'Instance',
      );
      await tester.ensureVisible(instance);
      await tester.pumpAndSettle();
      await tester.tap(instance);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Opaque device / NIC:2').last);
      await tester.pumpAndSettle();
      expect(fixture.api.requests.last.identifier, 'Opaque device / NIC:2');
      expect(find.text('Network Opaque device / NIC:2'), findsOneWidget);
    },
  );

  testWidgets('in-flight history disables selectors until completion', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    final result = Completer<List<ReportingHistory>>();
    fixture.api.pending = result;
    await _choose(tester, 'CPU utilization', settle: false);
    expect(find.text('Loading server measurements'), findsOneWidget);
    expect(
      tester.widget<DropdownButtonFormField<String>>(_metric()).onChanged,
      isNull,
    );
    expect(
      tester
          .widget<ChoiceChip>(find.byKey(const ValueKey('reporting-range-day')))
          .onSelected,
      isNull,
    );
    result.complete(fixture.api.history(fixture.api.requests.single));
    await tester.pumpAndSettle();
    expect(find.byType(ReportingChart), findsOneWidget);
  });

  testWidgets('empty server history is unavailable, not zero utilization', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    fixture.api.empty = true;
    await _choose(tester, 'CPU utilization');
    expect(find.text('No usable samples'), findsOneWidget);
    expect(find.byType(ReportingChart), findsNothing);
    expect(find.textContaining('not displayed as zero'), findsOneWidget);
  });

  testWidgets('session switch removes previous connection history', (
    tester,
  ) async {
    final fixture = await _pump(tester);
    await _choose(tester, 'CPU utilization');
    fixture.container.read(_sessionProvider.notifier).select(null);
    await tester.pumpAndSettle();
    expect(find.byType(ReportingChart), findsNothing);
    expect(find.text('Connect to load reporting'), findsOneWidget);
  });

  testWidgets('320px 2x text supports metric selection and native graph', (
    tester,
  ) async {
    await _pump(tester, width: 320, scale: 2);
    expect(tester.takeException(), isNull);
    await _choose(tester, 'CPU utilization');
    expect(tester.takeException(), isNull);
    await _reveal(tester, find.byType(ReportingChart));
    expect(find.byKey(const Key('reporting-line-chart')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Finder _metric() => find.byWidgetPredicate(
  (widget) =>
      widget is DropdownButtonFormField<String> &&
      widget.decoration.labelText == 'Metric',
);
Future<void> _choose(
  WidgetTester tester,
  String title, {
  bool settle = true,
}) async {
  await _reveal(tester, _metric());
  await tester.tap(_metric());
  await tester.pumpAndSettle();
  await tester.tap(find.text(title).last);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }
}

Future<void> _tap(WidgetTester tester, String key) async {
  await _reveal(tester, find.byKey(ValueKey(key)));
  await tester.tap(find.byKey(ValueKey(key)));
  await tester.pumpAndSettle();
}

Future<void> _reveal(WidgetTester tester, Finder target) async {
  if (target.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      target,
      350,
      scrollable: find.byType(Scrollable).first,
    );
  }
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
}

final _now = DateTime.utc(2026, 9, 12, 12);
final _sessionProvider = NotifierProvider<_Session, AuthenticatedSession?>(
  _Session.new,
);

class _Session extends Notifier<AuthenticatedSession?> {
  _Session([this.initial]);
  final AuthenticatedSession? initial;
  @override
  AuthenticatedSession? build() => initial;
  void select(AuthenticatedSession? session) => state = session;
}

Future<_Fixture> _pump(
  WidgetTester tester, {
  bool connected = true,
  double width = 800,
  double scale = 1,
  bool autoLoad = false,
  String? initialGraphName,
  bool includeLoad = true,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final fixture = _Fixture();
  if (!includeLoad) {
    fixture.api.graphs.removeWhere((graph) => graph.name == 'load');
  }
  final session = AuthenticatedSession(
    profileId: 'nas',
    repository: fixture.api,
    availableMethodNames: const {},
    version: '25.10.1',
    endpoint: 'wss://nas.example/api/current',
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        _sessionProvider.overrideWith(
          () => _Session(connected ? session : null),
        ),
        dashboardActiveSessionProvider.overrideWith(
          (ref) => ref.watch(_sessionProvider),
        ),
        reportingClockProvider.overrideWithValue(() => _now),
      ],
      child: MaterialApp(
        theme: TrueNavoTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: ReportingPage(
          autoLoad: autoLoad,
          initialGraphName: initialGraphName,
        ),
      ),
    ),
  );
  fixture.container = ProviderScope.containerOf(
    tester.element(find.byType(ReportingPage)),
  );
  await tester.pumpAndSettle();
  return fixture;
}

class _Fixture {
  final api = _Reporting();
  late ProviderContainer container;
}

class _Reporting implements SessionRepository, AuthenticatedReportingSession {
  final graphs = [
    ReportingGraph(
      name: 'cpu',
      title: 'CPU utilization',
      verticalLabel: '%CPU',
      identifiers: null,
    ),
    ReportingGraph(
      name: 'load',
      title: 'System load',
      verticalLabel: 'Load',
      identifiers: null,
    ),
    ReportingGraph(
      name: 'interface',
      title: 'Network {identifier}',
      verticalLabel: 'Kilobits/s',
      identifiers: ['enp0s1', 'Opaque device / NIC:2'],
    ),
    ReportingGraph(
      name: 'disktemp',
      title: 'No sensor instances',
      verticalLabel: 'Celsius',
      identifiers: [],
    ),
  ];
  final requests = <ReportingRequest>[];
  var graphReads = 0;
  var empty = false;
  Completer<List<ReportingHistory>>? pending;
  @override
  ReportingCapabilities get reportingCapabilities =>
      const ReportingCapabilities(
        connected: true,
        versionSupported: true,
        available: true,
      );
  @override
  Future<List<ReportingGraph>> loadReportingGraphs() async {
    graphReads++;
    return graphs;
  }

  @override
  Future<List<ReportingHistory>> loadReportingHistory(
    ReportingRequest request,
  ) async {
    requests.add(request);
    return pending != null
        ? pending!.future
        : empty
        ? []
        : history(request);
  }

  List<ReportingHistory> history(ReportingRequest request) => [
    ReportingHistory(
      graphName: request.graph.name,
      identifier: request.identifier,
      unit: request.graph.verticalLabel,
      legend: const ['cpu'],
      points: [
        ReportingPoint(timestamp: request.start, values: const [10]),
        ReportingPoint(timestamp: request.end, values: const [20]),
      ],
      returnedStart: request.start,
      returnedEnd: request.end,
      aggregations: null,
    ),
  ];
  @override
  Future<void> close() async {}
  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw StateError('Reporting fixtures never connect to a real NAS');
}
