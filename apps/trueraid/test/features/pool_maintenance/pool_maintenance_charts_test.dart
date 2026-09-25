import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/pool_maintenance/pool_maintenance_charts.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

void main() {
  for (final width in [320.0, 430.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'schedule chart $width dark=$dark keeps matching legends at 200 percent',
        (tester) async {
          tester.view.physicalSize = Size(width, 900);
          tester.view.devicePixelRatio = 1;
          addTearDown(tester.view.resetPhysicalSize);
          addTearDown(tester.view.resetDevicePixelRatio);
          await tester.pumpWidget(
            MaterialApp(
              theme: dark ? TrueRAIDTheme.dark() : TrueRAIDTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const Scaffold(
                body: SingleChildScrollView(
                  padding: EdgeInsets.all(20),
                  child: PoolScheduleChart(enabled: 2, disabled: 1),
                ),
              ),
            ),
          );
          final enabled = tester
              .widget<Icon>(
                find.byKey(const Key('pool-maintenance-enabled-color')),
              )
              .color!;
          final disabled = tester
              .widget<Icon>(
                find.byKey(const Key('pool-maintenance-disabled-color')),
              )
              .color!;
          expect(enabled, isNot(disabled));
          final ring = tester.widget<CustomPaint>(
            find.byKey(const Key('pool-maintenance-schedule-donut')),
          );
          final canvas = _ScheduleCanvas();
          ring.painter!.paint(canvas, const Size(124, 124));
          expect(canvas.colors, [enabled.toARGB32(), disabled.toARGB32()]);
          expect(
            canvas.sweeps.first / canvas.sweeps.reduce((a, b) => a + b),
            closeTo(2 / 3, .00001),
          );
          expect(find.text('2 Enabled schedules'), findsOneWidget);
          expect(find.text('1 Disabled schedules'), findsOneWidget);
          expect(find.textContaining('not running jobs'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('empty schedule inventory draws no fabricated active segment', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TrueRAIDTheme.dark(),
        home: const Scaffold(body: PoolScheduleChart(enabled: 0, disabled: 0)),
      ),
    );
    final ring = tester.widget<CustomPaint>(
      find.byKey(const Key('pool-maintenance-schedule-donut')),
    );
    final canvas = _ScheduleCanvas();
    ring.painter!.paint(canvas, const Size(124, 124));
    expect(canvas.colors, isEmpty);
    expect(find.text('0 Enabled schedules'), findsOneWidget);
    expect(find.text('0 Disabled schedules'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

class _ScheduleCanvas implements Canvas {
  final colors = <int>[];
  final sweeps = <double>[];
  @override
  void drawOval(Rect rect, Paint paint) {}
  @override
  void drawArc(
    Rect rect,
    double startAngle,
    double sweepAngle,
    bool useCenter,
    Paint paint,
  ) {
    colors.add(paint.color.toARGB32());
    sweeps.add(sweepAngle);
  }

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw UnsupportedError('Unexpected chart operation');
}
