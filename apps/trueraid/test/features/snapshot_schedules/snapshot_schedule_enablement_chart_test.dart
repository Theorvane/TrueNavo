import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/snapshot_schedules/snapshot_schedule_enablement_chart.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

const _tasks = [
  SnapshotScheduleTask(
    id: 1,
    state: 'FINISHED',
    settings: SnapshotScheduleSettings(dataset: 'tank/one'),
  ),
  SnapshotScheduleTask(
    id: 2,
    state: 'ERROR',
    settings: SnapshotScheduleSettings(dataset: 'tank/two'),
  ),
  SnapshotScheduleTask(
    id: 3,
    state: 'ERROR',
    settings: SnapshotScheduleSettings(dataset: 'tank/three', enabled: false),
  ),
];

Future<void> _pump(
  WidgetTester tester,
  List<SnapshotScheduleTask> tasks, {
  double width = 430,
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(Size(width, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: TrueRAIDTheme.dark(),
      builder: (_, child) => MediaQuery(
        data: MediaQueryData(
          size: Size(width, 1100),
          textScaler: TextScaler.linear(scale),
        ),
        child: child!,
      ),
      home: Scaffold(
        body: SingleChildScrollView(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: SnapshotScheduleEnablementChart(tasks: tasks),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  for (final width in [320.0, 430.0, 1000.0]) {
    for (final scale in [1.0, 2.0]) {
      testWidgets('enablement chart fits $width at ${scale * 100}% text', (
        tester,
      ) async {
        await _pump(tester, _tasks, width: width, scale: scale);
        expect(find.text('Enabled · 2'), findsOneWidget);
        expect(find.text('Disabled · 1'), findsOneWidget);
        expect(find.text('3'), findsOneWidget);
        final ring = tester.getRect(
          find.byKey(const Key('schedule-enablement-ring')),
        );
        final legend = tester.getRect(find.text('Enabled · 2'));
        if (width == 430 && scale == 1) {
          expect(legend.left, greaterThan(ring.right));
          expect(legend.top, lessThan(ring.bottom));
        }
        if (width == 320 && scale == 2) {
          expect(legend.top, greaterThanOrEqualTo(ring.bottom));
        }
        expect(tester.takeException(), isNull);
      });
    }
  }
  testWidgets(
    'semantic counts do not classify enabled failures as successful backups',
    (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        await _pump(tester, _tasks);
        expect(
          tester
              .getSemantics(
                find.byKey(const Key('schedule-enablement-semantics')),
              )
              .label,
          'Schedule configuration: 2 enabled, 1 disabled, 3 total. Not snapshot success or backup coverage.',
        );
      } finally {
        semantics.dispose();
      }
    },
  );
  testWidgets('empty inventory draws no percentage or indeterminate progress', (
    tester,
  ) async {
    await _pump(tester, const [], width: 320, scale: 2);
    expect(find.text('Enabled · 0'), findsOneWidget);
    expect(find.text('Disabled · 0'), findsOneWidget);
    expect(
      find.text('No schedules returned; no percentage is inferred.'),
      findsOneWidget,
    );
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'fresh task configuration updates both legend and painted counts',
    (tester) async {
      await _pump(tester, _tasks);
      final before = tester
          .widget<CustomPaint>(
            find.byKey(const Key('schedule-enablement-ring')),
          )
          .painter!;
      await _pump(tester, [_tasks[2]]);
      final after = tester
          .widget<CustomPaint>(
            find.byKey(const Key('schedule-enablement-ring')),
          )
          .painter!;
      expect(after.shouldRepaint(before), isTrue);
      expect(find.text('Enabled · 0'), findsOneWidget);
      expect(find.text('Disabled · 1'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
