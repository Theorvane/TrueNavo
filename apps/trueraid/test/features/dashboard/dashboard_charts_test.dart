import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/dashboard/dashboard_charts.dart';
import 'package:trueraid/features/dashboard/dashboard_repository.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

void main() {
  testWidgets('pool percentages retain their own denominators', (tester) async {
    final semantics = tester.ensureSemantics();
    await _pump(
      tester,
      _home(pools: [_pool('archive', 25), _pool('media', 75)]),
    );

    expect(
      find.bySemanticsLabel('archive: 25% used, 75% available. Online.'),
      findsOneWidget,
    );
    expect(
      find.bySemanticsLabel('media: 75% used, 25% available. Online.'),
      findsOneWidget,
    );
    expect(find.text('50%'), findsNothing);
    semantics.dispose();
  });

  testWidgets('severity distribution uses full counts, not visible alerts', (
    tester,
  ) async {
    final semantics = tester.ensureSemantics();
    await _pump(tester, _home(total: 9, critical: 2, warning: 3));

    expect(find.text('9 active alerts'), findsOneWidget);
    expect(find.text('2 critical'), findsOneWidget);
    expect(find.text('3 warning'), findsOneWidget);
    expect(find.text('4 other'), findsOneWidget);
    expect(
      find.bySemanticsLabel('9 active alerts: 2 critical, 3 warning, 4 other.'),
      findsOneWidget,
    );
    semantics.dispose();
  });

  testWidgets('unknown and invalid capacity do not become an empty pool', (
    tester,
  ) async {
    await _pump(
      tester,
      _home(
        pools: [
          _pool('missing', null),
          _pool('invalid', double.nan),
          _pool('out-of-range', 101),
          _pool('negative', -1),
        ],
      ),
    );

    expect(find.text('Capacity unavailable'), findsNWidgets(4));
    expect(find.text('0% used'), findsNothing);
    expect(find.text('100% available'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('measured zero and full pools keep accurate endpoints', (
    tester,
  ) async {
    await _pump(tester, _home(pools: [_pool('empty', 0), _pool('full', 100)]));

    expect(find.text('0% used'), findsOneWidget);
    expect(find.text('100% available'), findsOneWidget);
    expect(find.text('100% used'), findsOneWidget);
    expect(find.text('0% available'), findsOneWidget);
    expect(find.text('Capacity unavailable'), findsNothing);
  });

  testWidgets('supported empty data differs from unavailable data', (
    tester,
  ) async {
    await _pump(tester, _home(total: 0, critical: 0, warning: 0));
    expect(find.text('No active alerts'), findsOneWidget);
    expect(
      find.text('No storage pools were provided by the server.'),
      findsOneWidget,
    );

    await _pump(tester, _home(poolsAvailable: false, alertsAvailable: false));
    expect(find.text('No active alerts'), findsNothing);
    expect(
      find.text('Pool capacity is unavailable on this server.'),
      findsOneWidget,
    );
    expect(find.text('Alerts are unavailable on this server.'), findsOneWidget);
  });

  for (final counts in [
    (total: null, critical: 0, warning: 0),
    (total: 3, critical: null, warning: 0),
    (total: 1, critical: 2, warning: 0),
    (total: -1, critical: 0, warning: 0),
  ]) {
    testWidgets('incomplete or inconsistent counts stay unavailable: $counts', (
      tester,
    ) async {
      await _pump(
        tester,
        _home(
          total: counts.total,
          critical: counts.critical,
          warning: counts.warning,
        ),
      );

      expect(find.text('Alert severity is unavailable.'), findsOneWidget);
      expect(find.text('No active alerts'), findsNothing);
      expect(find.text('0 critical'), findsNothing);
    });
  }

  for (final width in [320.0, 1440.0]) {
    for (final dark in [false, true]) {
      testWidgets('charts fit width $width with 200% text, dark=$dark', (
        tester,
      ) async {
        await _pump(
          tester,
          _home(
            pools: [_pool('archive-${'data' * 32}', 99.9)],
            total: 1200,
            critical: 15,
            warning: 17,
          ),
          size: Size(width, 1000),
          textScale: 2,
          dark: dark,
        );

        expect(find.text('99.9% used'), findsOneWidget);
        expect(find.text('0.1% available'), findsOneWidget);
        expect(find.text('1168 other'), findsOneWidget);
        expect(tester.takeException(), isNull);
      });
    }
  }
}

DashboardPool _pool(String name, double? used) => DashboardPool(
  name: name,
  status: 'Online',
  statusKind: DashboardStatus.success,
  capacityPercent: used,
);

DashboardHome _home({
  List<DashboardPool> pools = const [],
  bool poolsAvailable = true,
  bool alertsAvailable = true,
  int? total = 1,
  int? critical = 1,
  int? warning = 0,
}) => DashboardHome(
  serverName: 'Atlas',
  version: 'TrueNAS',
  pools: pools,
  // Deliberately display-bounded; chart values must never come from this list.
  alerts: const [
    DashboardAlert(
      level: 'Critical',
      message: 'A disk needs attention',
      status: DashboardStatus.critical,
    ),
  ],
  poolsAvailable: poolsAvailable,
  alertsAvailable: alertsAvailable,
  activeAlertCount: total,
  criticalAlertCount: critical,
  warningAlertCount: warning,
  criticalPoolCount: 0,
  warningPoolCount: 0,
);

Future<void> _pump(
  WidgetTester tester,
  DashboardHome home, {
  Size size = const Size(1440, 1200),
  double textScale = 1,
  bool dark = false,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: dark ? TrueRAIDTheme.dark() : TrueRAIDTheme.light(),
      home: MediaQuery(
        data: MediaQueryData(
          size: size,
          textScaler: TextScaler.linear(textScale),
        ),
        child: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: DashboardCharts(home: home),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
