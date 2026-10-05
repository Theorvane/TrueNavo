import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/rsync/rsync_charts.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

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
              theme: dark ? TrueNavoTheme.dark() : TrueNavoTheme.light(),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(textScaler: const TextScaler.linear(2)),
                child: child!,
              ),
              home: const Scaffold(
                body: SingleChildScrollView(
                  padding: EdgeInsets.all(20),
                  child: RsyncConfigurationChart(enabled: 2, disabled: 1),
                ),
              ),
            ),
          );
          final enabled = tester
              .widget<Icon>(find.byKey(const Key('rsync-enabled-color')))
              .color!;
          final disabled = tester
              .widget<Icon>(find.byKey(const Key('rsync-disabled-color')))
              .color!;
          expect(enabled, isNot(disabled));
          final ring = tester.widget<CustomPaint>(
            find.byKey(const Key('rsync-schedule-donut')),
          );
          final canvas = _ScheduleCanvas();
          ring.painter!.paint(canvas, const Size(124, 124));
          expect(canvas.colors, [enabled.toARGB32(), disabled.toARGB32()]);
          expect(
            canvas.sweeps.first / canvas.sweeps.reduce((a, b) => a + b),
            closeTo(2 / 3, .00001),
          );
          expect(find.text('2 Enabled tasks'), findsOneWidget);
          expect(find.text('1 Disabled tasks'), findsOneWidget);
          expect(find.textContaining('not running transfers'), findsOneWidget);
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
        theme: TrueNavoTheme.dark(),
        home: const Scaffold(
          body: RsyncConfigurationChart(enabled: 0, disabled: 0),
        ),
      ),
    );
    final ring = tester.widget<CustomPaint>(
      find.byKey(const Key('rsync-schedule-donut')),
    );
    final canvas = _ScheduleCanvas();
    ring.painter!.paint(canvas, const Size(124, 124));
    expect(canvas.colors, isEmpty);
    expect(find.text('0 Enabled tasks'), findsOneWidget);
    expect(find.text('0 Disabled tasks'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'recorded state bars include unknown and exact bounded fractions',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: const Scaffold(
            body: SingleChildScrollView(
              child: RsyncReportedStates(
                states: {
                  RsyncReportedState.succeeded: 2,
                  RsyncReportedState.unknown: 1,
                },
              ),
            ),
          ),
        ),
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const Key('rsync-state-succeeded')),
            )
            .value,
        closeTo(2 / 3, .00001),
      );
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const Key('rsync-state-unknown')),
            )
            .value,
        closeTo(1 / 3, .00001),
      );
      expect(find.byKey(const Key('rsync-state-running')), findsNothing);
      expect(find.textContaining('may be stale'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('empty recorded states never fabricate success', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: TrueNavoTheme.dark(),
        home: const Scaffold(body: RsyncReportedStates(states: {})),
      ),
    );
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(
      find.text('No task states in the loaded inventory.'),
      findsOneWidget,
    );
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
