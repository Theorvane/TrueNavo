import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/app_shell/app_destination.dart';
import 'package:truedash/features/dashboard/dashboard_controller.dart';
import 'package:truedash/features/dashboard/dashboard_page.dart';
import 'package:truedash/features/dashboard/dashboard_repository.dart';
import 'package:truedash_design_system/truedash_design_system.dart';

void main() {
  testWidgets('home presents current health, metrics, and capacity', (
    tester,
  ) async {
    await _pumpHome(tester, const Size(800, 900));

    expect(find.text('Server health'), findsOneWidget);
    expect(find.text('Needs attention'), findsOneWidget);
    expect(find.text('Pools shown'), findsWidgets);
    expect(find.text('Active alerts'), findsOneWidget);
    expect(find.text('Datasets'), findsNothing);
    expect(find.text('Services'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsOneWidget);
    expect(find.byType(TdStatusBadge), findsWidgets);
    expect(
      find.byWidgetPredicate(
        (widget) => widget is TdButton && widget.label == 'Refresh',
      ),
      findsOneWidget,
    );
  });

  testWidgets('home metric cards wrap without a narrow viewport overflow', (
    tester,
  ) async {
    await _pumpHome(tester, const Size(320, 900));

    expect(find.text('Pools shown'), findsWidgets);
    expect(tester.takeException(), isNull);
  });

  testWidgets('alerts refresh their own load state', (tester) async {
    await _expectSecondaryRefresh(
      tester,
      AppDestination.alerts,
      const <DashboardAlert>[],
    );
  });

  testWidgets('alerts constrain a long unknown status on a narrow viewport', (
    tester,
  ) async {
    final status = 'Unknown-${List.filled(25, 'status').join()}--';
    await _pumpDashboard(tester, AppDestination.alerts, [
      DashboardAlert(
        level: status,
        message: 'The server provided an unknown alert level.',
        status: DashboardStatus.info,
      ),
    ]);

    expect(find.text(status), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('manage refreshes its own load state', (tester) async {
    await _expectSecondaryRefresh(
      tester,
      AppDestination.manage,
      const DashboardManage(pools: [], datasets: [], services: []),
    );
  });

  testWidgets('jobs refresh their own load state', (tester) async {
    await _expectSecondaryRefresh(
      tester,
      AppDestination.jobs,
      const DashboardJobs([]),
    );
  });

  testWidgets('jobs constrain a long unknown status on a narrow viewport', (
    tester,
  ) async {
    final status = 'Unknown-${List.filled(25, 'status').join()}--';
    await _pumpDashboard(
      tester,
      AppDestination.jobs,
      DashboardJobs([
        DashboardJob(
          id: '42',
          name: 'storage.scrub',
          status: status,
          statusKind: DashboardStatus.info,
        ),
      ]),
    );

    expect(find.text(status), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _pumpDashboard(
  WidgetTester tester,
  AppDestination destination,
  Object? value,
) async {
  await tester.binding.setSurfaceSize(const Size(320, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dashboardLoadProvider(destination.name)
            .overrideWith((ref) async => DashboardData<Object?>(value)),
      ],
      child: MaterialApp(
        theme: TrueDashTheme.light(),
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: DashboardPage(destination: destination),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _expectSecondaryRefresh(
  WidgetTester tester,
  AppDestination destination,
  Object? value,
) async {
  var loadCount = 0;
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dashboardLoadProvider(destination.name).overrideWith((ref) async {
          loadCount++;
          return DashboardData<Object?>(value);
        }),
      ],
      child: MaterialApp(
        theme: TrueDashTheme.light(),
        home: Scaffold(body: DashboardPage(destination: destination)),
      ),
    ),
  );
  await tester.pumpAndSettle();

  final refresh = find.byWidgetPredicate(
    (widget) => widget is TdButton && widget.label == 'Refresh',
  );
  expect(refresh, findsOneWidget);
  expect(loadCount, 1);

  await tester.tap(refresh);
  await tester.pumpAndSettle();
  expect(loadCount, 2);
}

Future<void> _pumpHome(WidgetTester tester, Size size) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  const home = DashboardHome(
    serverName: 'Atlas',
    version: 'TrueNAS 24.10',
    pools: [
      DashboardPool(
        name: 'tank',
        status: 'Healthy',
        statusKind: DashboardStatus.success,
        capacity: '72%',
        capacityPercent: 72,
      ),
    ],
    alerts: [
      DashboardAlert(
        level: 'Critical',
        message: 'A disk needs attention',
        status: DashboardStatus.critical,
      ),
    ],
    poolsAvailable: true,
    alertsAvailable: true,
    activeAlertCount: 1,
    criticalAlertCount: 1,
    warningAlertCount: 0,
    criticalPoolCount: 0,
    warningPoolCount: 0,
  );
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dashboardLoadProvider('home')
            .overrideWith((ref) async => const DashboardData(home)),
      ],
      child: MaterialApp(
        theme: TrueDashTheme.light(),
        home: const Scaffold(
          body: SingleChildScrollView(
            padding: EdgeInsets.all(16),
            child: DashboardPage(destination: AppDestination.home),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
