import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/app_shell/app_destination.dart';
import 'package:truenavo/features/dashboard/dashboard_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_layout.dart';
import 'package:truenavo/features/dashboard/dashboard_layout_controller.dart';
import 'package:truenavo/features/dashboard/dashboard_layout_editor.dart';
import 'package:truenavo/features/dashboard/dashboard_page.dart';
import 'package:truenavo/features/dashboard/dashboard_repository.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import 'dashboard_layout_test.dart'
    show MemoryLayoutStore, firstIdentity, secondIdentity, testIdentityProvider;

void main() {
  testWidgets('saved visibility loads before an optional live widget mounts', (
    tester,
  ) async {
    final store = MemoryLayoutStore()..readGate = Completer<void>();
    store.values[firstIdentity.storageKey] = DashboardLayout.defaults()
        .toggle(DashboardSection.liveMetrics, false)
        .encode();
    await _pumpHome(tester, store);
    expect(find.text('Server health'), findsOneWidget);
    expect(
      find.byKey(const Key('dashboard-section-liveMetrics')),
      findsNothing,
    );
    expect(find.byKey(const Key('dashboard-section-charts')), findsNothing);
    store.readGate!.complete();
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('dashboard-section-liveMetrics')),
      findsNothing,
    );
    expect(find.byKey(const Key('dashboard-section-charts')), findsOneWidget);
  });

  testWidgets('editor changes visibility and order only after save', (
    tester,
  ) async {
    final store = MemoryLayoutStore();
    await _pumpEditor(tester, store);
    await tester.tap(find.byKey(const Key('dashboard-layout-visible-metrics')));
    await tester.tap(find.byKey(const Key('dashboard-layout-up-liveMetrics')));
    await tester.pump();
    expect(store.writes, 0);
    final rows = tester
        .widgetList<Padding>(
          find.byWidgetPredicate(
            (widget) =>
                widget is Padding &&
                widget.key.toString().contains('dashboard-layout-row'),
          ),
        )
        .map((widget) => widget.key.toString())
        .toList();
    expect(rows.first, contains('liveMetrics'));
    await tester.ensureVisible(find.byKey(const Key('dashboard-layout-save')));
    await tester.tap(find.byKey(const Key('dashboard-layout-save')));
    await tester.pumpAndSettle();
    final saved = DashboardLayout.decode(
      store.values[firstIdentity.storageKey]!,
    )!;
    expect(saved.order.first, DashboardSection.liveMetrics);
    expect(saved.hidden, {DashboardSection.metrics});
    expect(find.byType(DashboardLayoutEditor), findsNothing);
  });

  testWidgets('cancel leaves persisted layout untouched', (tester) async {
    final store = MemoryLayoutStore();
    await _pumpEditor(tester, store);
    await tester.tap(find.byKey(const Key('dashboard-layout-visible-metrics')));
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(store.writes, 0);
    expect(find.byType(DashboardLayoutEditor), findsNothing);
  });

  testWidgets('defaults restore hidden sections and order on save', (
    tester,
  ) async {
    final store = MemoryLayoutStore();
    final previous = DashboardLayout.defaults()
        .move(DashboardSection.charts, -1)
        .toggle(DashboardSection.metrics, false);
    store.values[firstIdentity.storageKey] = previous.encode();
    await _pumpEditor(tester, store, initial: previous);
    await tester.ensureVisible(find.byKey(const Key('dashboard-layout-reset')));
    await tester.tap(find.byKey(const Key('dashboard-layout-reset')));
    await tester.pump();
    expect(
      find.text('Default layout selected. Save layout to apply.'),
      findsOneWidget,
    );
    await tester.ensureVisible(find.byKey(const Key('dashboard-layout-save')));
    await tester.tap(find.byKey(const Key('dashboard-layout-save')));
    await tester.pumpAndSettle();
    final saved = DashboardLayout.decode(
      store.values[firstIdentity.storageKey]!,
    )!;
    expect(saved.order, DashboardSection.values);
    expect(saved.hidden, isEmpty);
  });

  testWidgets(
    'server change disables an open editor and cannot save elsewhere',
    (tester) async {
      final store = MemoryLayoutStore();
      final container = await _pumpEditor(tester, store);
      container.read(testIdentityProvider.notifier).select(secondIdentity);
      await tester.pump();
      expect(find.byKey(const Key('dashboard-layout-stale')), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('dashboard-layout-save')),
            )
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('dashboard-layout-visible-metrics')),
            )
            .onChanged,
        isNull,
      );
      expect(store.writes, 0);
    },
  );

  testWidgets(
    'save failure retains editable draft and shows sanitized feedback',
    (tester) async {
      final store = MemoryLayoutStore()..failWrite = true;
      await _pumpEditor(tester, store);
      await tester.tap(
        find.byKey(const Key('dashboard-layout-visible-metrics')),
      );
      await tester.ensureVisible(
        find.byKey(const Key('dashboard-layout-save')),
      );
      await tester.tap(find.byKey(const Key('dashboard-layout-save')));
      await tester.pumpAndSettle();
      expect(find.byType(DashboardLayoutEditor), findsOneWidget);
      expect(find.textContaining('Layout was not saved'), findsOneWidget);
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('dashboard-layout-visible-metrics')),
            )
            .value,
        isFalse,
      );
      expect(find.textContaining('secret'), findsNothing);
    },
  );

  for (final dark in [false, true]) {
    testWidgets(
      '320px 200% editor is scrollable, accessible and bounded ${dark ? 'dark' : 'light'}',
      (tester) async {
        final semantics = tester.ensureSemantics();
        await _pumpEditor(
          tester,
          MemoryLayoutStore(),
          size: const Size(320, 800),
          scale: 2,
          dark: dark,
        );
        expect(find.byTooltip('Move Summary down'), findsOneWidget);
        expect(
          tester
              .getSize(find.byKey(const Key('dashboard-layout-down-metrics')))
              .shortestSide,
          greaterThanOrEqualTo(48),
        );
        await tester.ensureVisible(
          find.byKey(const Key('dashboard-layout-save')),
        );
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.bySemanticsLabel('Save layout'), findsOneWidget);
        semantics.dispose();
      },
    );
  }

  testWidgets(
    'dashboard applies order, keeps health and unmounts hidden widgets',
    (tester) async {
      final store = MemoryLayoutStore();
      store.values[firstIdentity.storageKey] = DashboardLayout.defaults()
          .toggle(DashboardSection.liveMetrics, false)
          .toggle(DashboardSection.charts, false)
          .move(DashboardSection.performanceHistory, -3)
          .encode();
      final container = await _pumpHome(tester, store);
      expect(find.text('Server health'), findsOneWidget);
      expect(find.byKey(const Key('dashboard-section-charts')), findsNothing);
      expect(
        find.byKey(const Key('dashboard-section-liveMetrics')),
        findsNothing,
      );
      expect(
        tester
            .getTopLeft(
              find.byKey(const Key('dashboard-section-performanceHistory')),
            )
            .dy,
        lessThan(
          tester
              .getTopLeft(find.byKey(const Key('dashboard-section-metrics')))
              .dy,
        ),
      );
      await container
          .read(dashboardLayoutControllerProvider(firstIdentity).notifier)
          .reset();
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('dashboard-section-charts')), findsOneWidget);
      expect(
        find.byKey(const Key('dashboard-section-liveMetrics')),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'dashboard defaults safely after malformed saved layout at 320px 200%',
    (tester) async {
      final store = MemoryLayoutStore();
      store.values[firstIdentity.storageKey] = '{bad';
      await _pumpHome(tester, store, size: const Size(320, 800), scale: 2);
      expect(
        find.textContaining('Saved layout could not be read'),
        findsOneWidget,
      );
      expect(find.text('Storage capacity'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'all optional sections can hide while health and recovery remain',
    (tester) async {
      final store = MemoryLayoutStore();
      store.values[firstIdentity.storageKey] = DashboardLayout(
        order: DashboardSection.values,
        hidden: DashboardSection.values.toSet(),
      ).encode();
      await _pumpHome(tester, store);
      expect(find.text('Server health'), findsOneWidget);
      expect(find.text('Your dashboard, your way'), findsOneWidget);
      expect(find.byKey(const Key('dashboard-customize')), findsOneWidget);
      expect(
        find.byKey(const Key('dashboard-section-liveMetrics')),
        findsNothing,
      );
    },
  );
}

Future<ProviderContainer> _pumpEditor(
  WidgetTester tester,
  MemoryLayoutStore store, {
  DashboardLayout? initial,
  Size size = const Size(800, 1100),
  double scale = 1,
  bool dark = false,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dashboardLayoutStoreProvider.overrideWithValue(store),
        dashboardLayoutIdentityProvider.overrideWith(
          (ref) => ref.watch(testIdentityProvider),
        ),
      ],
      child: MaterialApp(
        theme: dark ? TrueNavoTheme.dark() : TrueNavoTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                context: context,
                builder: (_) => DashboardLayoutEditor(
                  identity: firstIdentity,
                  serverName: 'NAS workshop',
                  initial: initial ?? DashboardLayout.defaults(),
                ),
              ),
              child: const Text('Open editor'),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('Open editor'));
  await tester.pumpAndSettle();
  return ProviderScope.containerOf(
    tester.element(find.byType(DashboardLayoutEditor)),
  );
}

Future<ProviderContainer> _pumpHome(
  WidgetTester tester,
  MemoryLayoutStore store, {
  Size size = const Size(800, 1200),
  double scale = 1,
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        dashboardLayoutStoreProvider.overrideWithValue(store),
        dashboardLayoutIdentityProvider.overrideWith(
          (ref) => ref.watch(testIdentityProvider),
        ),
        dashboardLoadProvider('home')
            .overrideWith((ref) async => const DashboardData(_home)),
      ],
      child: MaterialApp(
        theme: TrueNavoTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
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
  return ProviderScope.containerOf(tester.element(find.byType(DashboardPage)));
}

const _home = DashboardHome(
  serverName: 'NAS workshop',
  version: 'TrueNAS 25.10.1',
  pools: [],
  alerts: [],
  poolsAvailable: true,
  alertsAvailable: true,
  activeAlertCount: 0,
  criticalAlertCount: 0,
  warningAlertCount: 0,
  criticalPoolCount: 0,
  warningPoolCount: 0,
);
