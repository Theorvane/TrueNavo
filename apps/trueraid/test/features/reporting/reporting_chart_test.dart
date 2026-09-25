import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/reporting/reporting_chart.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  testWidgets('aligned edge clipping is explained without inventing samples', (
    tester,
  ) async {
    final history = _history([
      _point(0, [10]),
      _point(1, [11]),
    ], truncated: true);
    await _pump(tester, history);
    expect(
      find.text(
        'Samples outside the requested interval were omitted. '
        'Remaining timestamps and values are unchanged.',
      ),
      findsOneWidget,
    );
    expect(history.points.first.timestamp, _time);
    expect(history.points.length, 2);
    expect(tester.takeException(), isNull);
  });
  test(
    'long-range axis shows dates instead of identical clock-only labels',
    () {
      expect(
        reportingAxisTimestamp(_time, const Duration(days: 365)),
        '2026-09-12 UTC',
      );
      expect(
        reportingAxisTimestamp(
          _time.subtract(const Duration(days: 365)),
          const Duration(days: 365),
        ),
        '2025-09-12 UTC',
      );
      expect(
        reportingAxisTimestamp(_time, const Duration(hours: 1)),
        '12:00 UTC',
      );
    },
  );
  test(
    'viewport uses time rather than sample index and preserves missing rows',
    () {
      final history = _history([
        _point(0, [1]),
        _point(1, [null]),
        _point(10, [0]),
      ]);
      expect(
        reportingViewportTime(history, .5),
        _time.add(const Duration(minutes: 5)),
      );
      expect(reportingNearestSample(history, .1), 1);
      expect(reportingNearestSample(history, 1), 2);
      expect(reportingNearestSample(_history([]), .5), isNull);
      expect(reportingViewportTime(history, -1), _time);
      expect(
        reportingViewportTime(history, 2),
        _time.add(const Duration(minutes: 10)),
      );
    },
  );
  test('negative-only axes include zero for truthful bars and areas', () {
    final axis = reportingAxisScale([-40, -20]);
    expect(axis.minimum * axis.normalizer, -40);
    expect(axis.maximum, 0);
  });
  testWidgets('zoom and reset change only viewport, not measurements', (
    tester,
  ) async {
    final history = _history([
      for (var i = 0; i < 10; i++) _point(i, [i.toDouble()]),
    ]);
    await _pump(tester, history);
    await _tools(tester);
    await _control(tester, 'reporting-zoom-in');
    final viewport = tester.widget<RangeSlider>(
      find.byKey(const Key('reporting-viewport')),
    );
    expect(viewport.values.end - viewport.values.start, .5);
    expect(history.points.length, 10);
    await _control(tester, 'reporting-zoom-reset');
    expect(
      tester
          .widget<RangeSlider>(find.byKey(const Key('reporting-viewport')))
          .values,
      const RangeValues(0, 1),
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('line area and bars retain nulls zero precision and gaps', (
    tester,
  ) async {
    final history = _history([
      _point(0, [-1e308]),
      _point(1, [null]),
      _point(2, [0]),
      _point(8, [1e308]),
    ], hasGaps: true);
    await _pump(tester, history);
    await _tools(tester);
    for (final style in ['area', 'bar', 'line']) {
      await _control(tester, 'reporting-style-$style');
      expect(
        tester
            .widget<ChoiceChip>(find.byKey(ValueKey('reporting-style-$style')))
            .selected,
        isTrue,
      );
      expect(reportingLineSegments(history, 0).map((s) => s.length), [1, 1, 1]);
      expect(tester.takeException(), isNull);
    }
  });
  testWidgets(
    'accessible sample controls expose exact values including missing',
    (tester) async {
      await _pump(
        tester,
        _history([
          _point(0, [0.123456789]),
          _point(1, [null]),
          _point(2, [0]),
        ]),
      );
      await _tools(tester);
      await _control(tester, 'reporting-sample-next');
      expect(find.textContaining('cpu: 0.123456789 %CPU'), findsOneWidget);
      await _control(tester, 'reporting-sample-next');
      expect(find.textContaining('cpu: Missing %CPU'), findsOneWidget);
      await _control(tester, 'reporting-sample-next');
      expect(find.textContaining('cpu: 0 %CPU'), findsOneWidget);
    },
  );
  testWidgets('tapping plot selects a real sample rather than interpolation', (
    tester,
  ) async {
    await _pump(
      tester,
      _history([
        _point(0, [1]),
        _point(1, [2]),
        _point(10, [8]),
      ]),
    );
    final chart = find.byKey(const Key('reporting-line-chart'));
    await tester.tapAt(tester.getTopLeft(chart) + const Offset(80, 80));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('reporting-selected-sample')), findsOneWidget);
    expect(find.textContaining('cpu: 1 %CPU'), findsOneWidget);
  });
  testWidgets('expanded tools fit 320px at 200 percent text', (tester) async {
    await _pump(
      tester,
      _history([
        _point(0, [1]),
        _point(1, [2]),
        _point(2, [3]),
      ]),
      width: 320,
      scale: 2,
    );
    await _tools(tester);
    await _control(tester, 'reporting-style-bar');
    await _control(tester, 'reporting-zoom-in');
    expect(tester.takeException(), isNull);
  });
  test('zero-only chart has a sensible zero-to-one axis, and extremes remain finite', () {
    expect(reportingAxisScale([0, 0]), (
      minimum: 0.0,
      maximum: 1.0,
      normalizer: 1.0,
    ));
    final extremes = reportingAxisScale([-1e308, 1e308]);
    expect((extremes.maximum - extremes.minimum).isFinite, isTrue);
    expect(extremes.minimum * extremes.normalizer, -1e308);
    expect(extremes.maximum * extremes.normalizer, 1e308);
  });
  test(
    'null and irregular timestamp gaps split line segments without zero fill',
    () {
      final history = _history([
        _point(0, [1]),
        _point(1, [null]),
        _point(2, [0]),
        _point(10, [3]),
      ], hasGaps: true);
      final segments = reportingLineSegments(history, 0);
      expect(segments.map((segment) => segment.length), [1, 1, 1]);
      expect(
        segments
            .expand((segment) => segment)
            .map((point) => point.values.single),
        [1, 0, 3],
      );
      expect(
        segments.last.single.timestamp,
        _time.add(const Duration(minutes: 10)),
      );
    },
  );

  test('adjacent finite values retain original points and timestamps', () {
    final first = _point(0, [1]);
    final second = _point(1, [2]);
    final segments = reportingLineSegments(_history([first, second]), 0);
    expect(segments, [
      [first, second],
    ]);
    expect(identical(segments.single.first, first), isTrue);
  });

  test(
    'missing series and non-finite samples cannot become plotted values',
    () {
      final history = _history([
        _point(0, [double.nan]),
        _point(1, [2]),
      ]);
      expect(reportingLineSegments(history, 0).single.single.values, [2]);
      expect(reportingLineSegments(history, 8), isEmpty);
    },
  );

  test(
    'sample values retain round-trip precision and distinguish null from zero',
    () {
      expect(reportingValue(null), 'Missing');
      expect(reportingValue(0), '0');
      expect(reportingValue(0.12345678912345), '0.12345678912345');
      expect(reportingValue(1e308), '1e+308');
      expect(reportingValue(double.infinity), 'Missing');
    },
  );

  testWidgets('CPU uses independent lines with honest units and gap footnote', (
    tester,
  ) async {
    await _pump(
      tester,
      _history(
        [
          _point(0, [10, 30]),
          _point(1, [20, null]),
        ],
        legend: ['cpu', 'cpu0'],
        hasGaps: true,
      ),
    );
    expect(find.byKey(const Key('reporting-line-chart')), findsOneWidget);
    expect(
      find.textContaining('CPU aggregate and individual cores overlap'),
      findsOneWidget,
    );
    expect(find.textContaining('cpu0 · latest unavailable'), findsOneWidget);
    expect(find.textContaining('sample min 30 · max 30 %CPU'), findsOneWidget);
    expect(
      find.textContaining('Lines break across missing intervals'),
      findsOneWidget,
    );
    expect(
      find.text('TrueNAS may fill missing upstream samples with zero.'),
      findsOneWidget,
    );
  });

  testWidgets('all-zero measured history is plotted, missing history is not', (
    tester,
  ) async {
    await _pump(
      tester,
      _history([
        _point(0, [0]),
        _point(1, [0]),
      ]),
    );
    expect(find.byKey(const Key('reporting-line-chart')), findsOneWidget);
    expect(find.textContaining('latest 0'), findsOneWidget);
    await _pump(
      tester,
      _history([
        _point(0, [null]),
        _point(1, [null]),
      ]),
    );
    expect(find.byKey(const Key('reporting-line-chart')), findsNothing);
    expect(find.textContaining('Missing data is not zero'), findsOneWidget);
  });

  testWidgets('available memory is not presented as a used/free breakdown', (
    tester,
  ) async {
    await _pump(
      tester,
      _history(
        [
          _point(0, [1000]),
        ],
        name: 'memory',
        unit: 'Bytes',
      ),
    );
    expect(find.textContaining('available memory measurement'), findsOneWidget);
    expect(find.textContaining('not a used/free breakdown'), findsOneWidget);
    expect(find.textContaining('1000 Bytes'), findsOneWidget);
  });

  testWidgets('native table exposes missing and exact high-precision values', (
    tester,
  ) async {
    await _pump(
      tester,
      _history(
        [
          _point(0, [0.123456789, null]),
        ],
        legend: ['read', 'write'],
      ),
    );
    await tester.ensureVisible(find.byKey(const Key('reporting-sample-table')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View exact samples'));
    await tester.pumpAndSettle();
    expect(find.byType(DataTable), findsOneWidget);
    expect(find.text('0.123456789'), findsOneWidget);
    expect(find.text('Missing'), findsOneWidget);
    expect(find.text(reportingTimestamp(_time)), findsOneWidget);
  });

  testWidgets('sample table paginates without inventing or dropping rows', (
    tester,
  ) async {
    await _pump(
      tester,
      _history([
        for (var i = 0; i < 25; i++) _point(i, [i.toDouble()]),
      ]),
    );
    await tester.ensureVisible(find.byKey(const Key('reporting-sample-table')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('View exact samples'));
    await tester.pumpAndSettle();
    expect(find.text('Rows 1–20 of 25'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('reporting-next-samples')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('reporting-next-samples')));
    await tester.pumpAndSettle();
    expect(find.text('Rows 21–25 of 25'), findsOneWidget);
    expect(tester.widget<DataTable>(find.byType(DataTable)).rows, hasLength(5));
  });

  testWidgets(
    'series beyond the first eight are selectable and remain in the table',
    (tester) async {
      await _pump(
        tester,
        _history([
          _point(0, List.generate(10, (i) => i.toDouble())),
        ], legend: List.generate(10, (i) => 'cpu$i')),
      );
      expect(find.text('Series · 8 of 10 visible'), findsOneWidget);
      expect(
        tester
            .widget<FilterChip>(
              find.byKey(const ValueKey('reporting-series-9')),
            )
            .onSelected,
        isNull,
      );
      await tester.ensureVisible(
        find.byKey(const ValueKey('reporting-series-0')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reporting-series-0')));
      await tester.pumpAndSettle();
      await tester.ensureVisible(
        find.byKey(const ValueKey('reporting-series-9')),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reporting-series-9')));
      await tester.pumpAndSettle();
      expect(find.textContaining('cpu9 · latest 9'), findsOneWidget);
      expect(find.textContaining('all 10 series'), findsOneWidget);
    },
  );

  testWidgets('extreme finite values do not overflow canvas coordinates', (
    tester,
  ) async {
    await _pump(
      tester,
      _history([
        _point(0, [-1e308]),
        _point(1, [1e308]),
      ]),
    );
    expect(find.byKey(const Key('reporting-line-chart')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final dark in [false, true]) {
    testWidgets(
      'chart and summaries fit 320px at 2x text in ${dark ? 'dark' : 'light'}',
      (tester) async {
        await _pump(
          tester,
          _history(
            [
              _point(0, [10, 20]),
              _point(1, [12, 23]),
            ],
            legend: ['read', 'write'],
          ),
          width: 320,
          scale: 2,
          dark: dark,
        );
        expect(tester.takeException(), isNull);
        expect(find.byKey(const Key('reporting-line-chart')), findsOneWidget);
      },
    );
  }
}

final _time = DateTime.utc(2026, 9, 12, 12);
Future<void> _tools(WidgetTester tester) async {
  await tester.ensureVisible(find.byKey(const Key('reporting-chart-tools')));
  await tester.pumpAndSettle();
  await tester.tap(find.text('Explore chart'));
  await tester.pumpAndSettle();
}

Future<void> _control(WidgetTester tester, String key) async {
  await tester.ensureVisible(find.byKey(Key(key)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(Key(key)));
  await tester.pumpAndSettle();
}

ReportingPoint _point(int minute, List<double?> values) => ReportingPoint(
  timestamp: _time.add(Duration(minutes: minute)),
  values: values,
);
ReportingHistory _history(
  List<ReportingPoint> points, {
  List<String> legend = const ['cpu'],
  String name = 'cpu',
  String unit = '%CPU',
  bool hasGaps = false,
  bool truncated = false,
}) => ReportingHistory(
  graphName: name,
  identifier: null,
  unit: unit,
  legend: legend,
  points: points,
  returnedStart: _time,
  returnedEnd: _time.add(const Duration(hours: 1)),
  aggregations: null,
  hasGaps: hasGaps,
  truncated: truncated,
);
Future<void> _pump(
  WidgetTester tester,
  ReportingHistory history, {
  double width = 800,
  double scale = 1,
  bool dark = true,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? TrueRAIDTheme.dark() : TrueRAIDTheme.light(),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context)
            .copyWith(textScaler: TextScaler.linear(scale)),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: ReportingChart(history: history, title: 'Server history'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
