import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/pool_maintenance/pool_maintenance_controller.dart';
import 'package:truenavo/features/pool_maintenance/pool_maintenance_editor.dart';
import 'package:truenavo/features/pool_maintenance/pool_maintenance_page.dart';
import 'package:truenavo/features/pool_maintenance/pool_maintenance_review.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'pool_maintenance_fakes.dart';

Future<PmHarness> pumpPm(
  WidgetTester tester, {
  PmFake? fake,
  bool disconnected = false,
  double width = 800,
  double scale = 1,
  double keyboard = 0,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final h = PmHarness(fake: fake);
  addTearDown(h.dispose);
  if (disconnected) {
    h.select(null);
  } else {
    try {
      await h.container.read(poolMaintenanceInventoryProvider.future);
    } on Object {
      /* Fixed error UI. */
    }
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: TrueNavoTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: const PoolMaintenancePage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapPm(
  WidgetTester tester,
  String key, {
  bool settle = true,
}) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> enterPm(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> confirmPm(
  WidgetTester tester,
  String target, {
  bool settle = true,
}) async {
  await enterPm(tester, 'pool-maintenance-confirm-target', target);
  await tapPm(tester, 'pool-maintenance-confirm-impact');
  await tapPm(tester, 'pool-maintenance-confirm-submit', settle: settle);
}

void expectActionDisabled(WidgetTester tester, String key) => expect(
  tester.widget<OutlinedButton>(find.byKey(Key(key))).onPressed,
  isNull,
);

void main() {
  testWidgets(
    'opening and manual refresh only read metadata, no polling or job check',
    (tester) async {
      final h = await pumpPm(tester);
      expect(find.text('1 Enabled schedules'), findsOneWidget);
      expect(find.text('0 Disabled schedules'), findsOneWidget);
      expect(
        tester
            .widget<LinearProgressIndicator>(
              find.byKey(const Key('pool-maintenance-scan-1')),
            )
            .value,
        .425,
      );
      await tester.pump(const Duration(minutes: 5));
      expect(h.api.reads, 1);
      expect(h.api.checks, isEmpty);
      expect(h.api.writes, isEmpty);
      await tapPm(tester, 'pool-maintenance-refresh');
      expect(h.api.reads, 2);
    },
  );
  testWidgets('disconnected page performs no read', (tester) async {
    final h = await pumpPm(tester, disconnected: true);
    expect(h.api.reads, 0);
    expect(find.text('Pool maintenance unavailable'), findsOneWidget);
  });
  testWidgets('empty inventory is distinct from unreadable inventory', (
    tester,
  ) async {
    await pumpPm(tester, fake: PmFake(inventory: pmInventory(empty: true)));
    expect(find.text('No supported data pools'), findsOneWidget);
    expect(find.text('0 Enabled schedules'), findsOneWidget);
  });
  testWidgets(
    'unreadable inventory hides raw details and retries only manually',
    (tester) async {
      final h = await pumpPm(
        tester,
        fake: PmFake()
          ..onLoad = () async => throw StateError('PRIVATE-SYNTHETIC-DETAIL'),
      );
      expect(find.textContaining('PRIVATE-SYNTHETIC-DETAIL'), findsNothing);
      expect(
        find.text('Pool maintenance inventory unavailable'),
        findsOneWidget,
      );
      expect(find.text('0 Enabled schedules'), findsNothing);
      await tester.pump(const Duration(minutes: 1));
      expect(h.api.reads, 1);
      await tapPm(tester, 'pool-maintenance-retry');
      expect(h.api.reads, 2);
      expect(h.api.writes, isEmpty);
    },
  );
  for (final guard in ['HA', 'degraded', 'other-job', 'resilver', 'scrub']) {
    testWidgets('$guard blocks new scrub and schedule creation', (
      tester,
    ) async {
      final h = await pumpPm(
        tester,
        fake: PmFake(
          inventory: pmInventory(
            ha: guard == 'HA',
            unhealthy: guard == 'degraded',
            jobs: guard == 'other-job',
            active: guard == 'resilver' || guard == 'scrub',
            function: guard == 'resilver' ? 'RESILVER' : 'SCRUB',
          ),
        ),
      );
      expectActionDisabled(tester, 'pool-maintenance-startScrub-1');
      if (guard != 'degraded') {
        expectActionDisabled(tester, 'pool-maintenance-createSchedule-2');
      }
      if (guard == 'resilver') {
        expectActionDisabled(tester, 'pool-maintenance-stopScrub-1');
      }
      expect(h.api.writes, isEmpty);
    });
  }
  testWidgets('missing stop scan identity stays disabled', (tester) async {
    await pumpPm(
      tester,
      fake: PmFake(inventory: pmInventory(active: true, unknownStart: true)),
    );
    expectActionDisabled(tester, 'pool-maintenance-stopScrub-1');
  });
  testWidgets(
    'unknown progress is not fabricated as zero or indeterminate activity',
    (tester) async {
      await pumpPm(
        tester,
        fake: PmFake(inventory: pmInventory(active: true, percentage: null)),
      );
      expect(find.text('Scan progress unknown'), findsOneWidget);
      expect(find.byKey(const Key('pool-maintenance-scan-1')), findsNothing);
    },
  );
  testWidgets('missing capabilities block matching controls', (tester) async {
    final h = await pumpPm(
      tester,
      fake: PmFake(
        caps: const PoolMaintenanceCapabilities(
          connected: true,
          versionSupported: true,
          available: true,
          canScrub: false,
          canCreateSchedule: false,
          canUpdateSchedule: false,
          canDeleteSchedule: false,
        ),
      ),
    );
    for (final key in [
      'startScrub-1',
      'createSchedule-2',
      'updateSchedule-11',
      'disableSchedule-11',
      'deleteSchedule-11',
    ]) {
      expectActionDisabled(tester, 'pool-maintenance-$key');
    }
    expect(h.api.reviews, isEmpty);
  });
  testWidgets(
    'manual start requires exact target and explicit impact acknowledgement',
    (tester) async {
      final h = await pumpPm(tester);
      await tapPm(tester, 'pool-maintenance-startScrub-1');
      expect(h.api.reviews, hasLength(1));
      expect(find.text('Review: Start scrub'), findsOneWidget);
      expect(find.text('Review startScrub'), findsNothing);
      expect(h.api.writes, isEmpty);
      expect(find.byType(PoolMaintenanceEditor), findsNothing);
      await enterPm(
        tester,
        'pool-maintenance-confirm-target',
        '${h.api.reviews.single.target} ',
      );
      await tapPm(tester, 'pool-maintenance-confirm-impact');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('pool-maintenance-confirm-submit')),
            )
            .onPressed,
        isNull,
      );
      await enterPm(
        tester,
        'pool-maintenance-confirm-target',
        h.api.reviews.single.target,
      );
      await tapPm(tester, 'pool-maintenance-confirm-submit');
      expect(h.api.writes, hasLength(1));
    },
  );
  testWidgets(
    'active scrub stop uses exact scan target without schedule editor',
    (tester) async {
      final h = await pumpPm(
        tester,
        fake: PmFake(inventory: pmInventory(active: true)),
      );
      await tapPm(tester, 'pool-maintenance-stopScrub-1');
      expect(h.api.reviews.single.target, contains('2026-09-14T01:00:00.000Z'));
      await confirmPm(tester, h.api.reviews.single.target);
      expect(h.api.writes.single.action, PoolMaintenanceAction.stopScrub);
    },
  );
  testWidgets(
    'schedule creation starts disabled and reviews all explicit settings',
    (tester) async {
      final h = await pumpPm(tester);
      await tapPm(tester, 'pool-maintenance-createSchedule-2');
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('pool-maintenance-enabled')),
            )
            .value,
        isFalse,
      );
      await enterPm(
        tester,
        'pool-maintenance-description',
        'Archive weekly scrub',
      );
      await enterPm(tester, 'pool-maintenance-threshold', '14');
      await enterPm(tester, 'pool-maintenance-hour', '3');
      await tapPm(tester, 'pool-maintenance-enabled');
      await tapPm(tester, 'pool-maintenance-editor-review');
      expect(find.text('Description: Archive weekly scrub'), findsOneWidget);
      expect(find.text('Threshold: 14 days'), findsOneWidget);
      expect(find.text('Cron: 0 3 * * 7'), findsOneWidget);
      expect(find.text('Enabled: Yes'), findsOneWidget);
      expect(h.api.reviews.single.settings!.enabled, isTrue);
      await confirmPm(tester, h.api.reviews.single.target);
      expect(h.api.writes, hasLength(1));
    },
  );
  testWidgets('schedule edit preserves fields unless explicitly changed', (
    tester,
  ) async {
    final h = await pumpPm(tester);
    await tapPm(tester, 'pool-maintenance-updateSchedule-11');
    expect(
      tester
          .widget<TextField>(
            find.byKey(const Key('pool-maintenance-description')),
          )
          .controller!
          .text,
      'Weekly pool scrub',
    );
    await enterPm(tester, 'pool-maintenance-threshold', '21');
    await tapPm(tester, 'pool-maintenance-editor-review');
    final request = h.api.reviews.single;
    expect(request.schedule!.id, 11);
    expect(request.settings!.description, 'Weekly pool scrub');
    expect(request.settings!.cron.hour, '2');
    expect(request.settings!.enabled, isTrue);
    expect(request.settings!.threshold, 21);
    await confirmPm(tester, request.target);
    expect(h.api.writes, hasLength(1));
  });
  for (final invalid in ['cron', 'threshold', 'unchanged']) {
    testWidgets(
      '$invalid schedule is rejected locally without review dispatch',
      (tester) async {
        final h = await pumpPm(tester);
        await tapPm(tester, 'pool-maintenance-updateSchedule-11');
        if (invalid == 'cron') {
          await enterPm(tester, 'pool-maintenance-minute', '99');
        }
        if (invalid == 'threshold') {
          await enterPm(tester, 'pool-maintenance-threshold', '9999');
        }
        await tapPm(tester, 'pool-maintenance-editor-review');
        expect(h.api.reviews, isEmpty);
        expect(h.api.writes, isEmpty);
      },
    );
  }
  for (final action in [
    PoolMaintenanceAction.disableSchedule,
    PoolMaintenanceAction.deleteSchedule,
  ]) {
    testWidgets(
      '${action.name} is separate exact-target operation, not an editor or scrub',
      (tester) async {
        final h = await pumpPm(tester);
        await tapPm(tester, 'pool-maintenance-${action.name}-11');
        expect(find.byType(PoolMaintenanceEditor), findsNothing);
        expect(h.api.reviews.single.settings, isNull);
        await confirmPm(tester, h.api.reviews.single.target);
        expect(h.api.writes.single.action, action);
      },
    );
  }
  testWidgets('disabled schedule exposes explicit enable only', (tester) async {
    final base = pmInventory();
    final api = PmFake(
      inventory: PoolMaintenanceInventory(
        endpoint: pmEndpoint,
        pools: base.pools,
        timezone: base.timezone,
        failoverLicensed: false,
        schedules: [
          const PoolScrubSchedule(
            id: 11,
            poolId: 1,
            poolName: 'tank',
            settings: PoolScrubScheduleSettings(enabled: false),
          ),
        ],
      ),
    );
    final h = await pumpPm(tester, fake: api);
    await tapPm(tester, 'pool-maintenance-enableSchedule-11');
    await confirmPm(tester, h.api.reviews.single.target);
    expect(h.api.writes.single.action, PoolMaintenanceAction.enableSchedule);
  });
  for (final transition in ['background', 'connection', 'refresh']) {
    testWidgets(
      '$transition permanently expires open editor and clears settings',
      (tester) async {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        addTearDown(
          () => tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          ),
        );
        final h = await pumpPm(tester);
        await tapPm(tester, 'pool-maintenance-createSchedule-2');
        await enterPm(
          tester,
          'pool-maintenance-description',
          'Unsubmitted settings',
        );
        final field = tester
            .widget<TextField>(
              find.byKey(const Key('pool-maintenance-description')),
            )
            .controller!;
        if (transition == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        } else if (transition == 'connection') {
          h.select(h.newSession());
        } else {
          h.container.invalidate(poolMaintenanceInventoryProvider);
        }
        await tester.pumpAndSettle();
        expect(field.text, isEmpty);
        expect(find.text('Maintenance editor expired'), findsOneWidget);
        expect(h.api.reviews, isEmpty);
        expect(h.api.writes, isEmpty);
      },
    );
  }
  for (final transition in ['background', 'connection', 'refresh']) {
    testWidgets('$transition expires exact-target review', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final h = await pumpPm(tester);
      await tapPm(tester, 'pool-maintenance-startScrub-1');
      await enterPm(
        tester,
        'pool-maintenance-confirm-target',
        h.api.reviews.single.target,
      );
      if (transition == 'background') {
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      } else if (transition == 'connection') {
        h.select(h.newSession());
      } else {
        h.container.invalidate(poolMaintenanceInventoryProvider);
      }
      await tester.pumpAndSettle();
      expect(find.text('Review expired'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('pool-maintenance-confirm-submit')),
            )
            .onPressed,
        isNull,
      );
      expect(h.api.writes, isEmpty);
    });
  }
  testWidgets(
    'late review after background is ignored without opening confirmation',
    (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      addTearDown(
        () => tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        ),
      );
      final pending = Completer<PoolMaintenanceReview>();
      final api = PmFake()..onReview = (_) => pending.future;
      final h = await pumpPm(tester, fake: api);
      await tapPm(tester, 'pool-maintenance-startScrub-1');
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      pending.complete(
        PoolMaintenanceReview(
          request: api.reviews.single,
          endpoint: pmEndpoint,
          warnings: [],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(PoolMaintenanceReviewDialog), findsNothing);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'accepted scrub keeps other actions locked and checks only on button press',
    (tester) async {
      final api = PmFake();
      api.onExecute = (_) async {
        api.inventory = pmInventory(active: true);
        return PoolMaintenanceResult(
          PoolMaintenanceOutcome.accepted,
          'Queued, not completed',
          job: pmJob(),
        );
      };
      final h = await pumpPm(tester, fake: api);
      await tapPm(tester, 'pool-maintenance-startScrub-1');
      await confirmPm(tester, api.reviews.single.target);
      expect(find.text('Owned scrub job needs verification'), findsOneWidget);
      expect(find.text('Job 80 · Start scrub · tank'), findsOneWidget);
      expect(find.text('Job 80 · startScrub · tank'), findsNothing);
      expectActionDisabled(tester, 'pool-maintenance-createSchedule-2');
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('pool-maintenance-stopScrub-1')),
            )
            .onPressed,
        isNotNull,
      );
      await tester.pump(const Duration(minutes: 2));
      expect(api.checks, isEmpty);
      api.onCheck = (_) async {
        api.inventory = pmInventory();
        return const PoolMaintenanceResult(
          PoolMaintenanceOutcome.succeeded,
          'Terminal observed, not an integrity proof',
        );
      };
      await tapPm(tester, 'pool-maintenance-check-job');
      expect(api.checks, hasLength(1));
      expect(api.writes, hasLength(1));
      expect(
        h.container.read(poolMaintenanceControllerProvider).locked,
        isFalse,
      );
    },
  );
  testWidgets(
    'owned START can submit reviewed same-pool STOP without releasing its lock',
    (tester) async {
      final api = PmFake();
      api.onExecute = (review) async {
        api.inventory = pmInventory(active: true);
        return PoolMaintenanceResult(
          PoolMaintenanceOutcome.accepted,
          'Queued',
          job: pmJob(
            id: review.action == PoolMaintenanceAction.startScrub ? 80 : 81,
            action: review.action,
          ),
        );
      };
      final h = await pumpPm(tester, fake: api);
      await tapPm(tester, 'pool-maintenance-startScrub-1');
      await confirmPm(tester, api.reviews.last.target);
      await tapPm(tester, 'pool-maintenance-stopScrub-1');
      await confirmPm(tester, api.reviews.last.target);
      expect(api.writes, hasLength(2));
      expect(h.container.read(poolMaintenanceControllerProvider).job!.id, 81);
      expectActionDisabled(tester, 'pool-maintenance-stopScrub-1');
    },
  );
  testWidgets('unknown result cannot be refreshed away or repeated', (
    tester,
  ) async {
    final h = await pumpPm(
      tester,
      fake: PmFake()
        ..onExecute = (_) async => const PoolMaintenanceResult(
          PoolMaintenanceOutcome.unknown,
          'Verify original server',
        ),
    );
    await tapPm(tester, 'pool-maintenance-startScrub-1');
    await confirmPm(tester, h.api.reviews.single.target);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('pool-maintenance-refresh')))
          .onPressed,
      isNull,
    );
    expectActionDisabled(tester, 'pool-maintenance-startScrub-1');
    expect(h.api.writes, hasLength(1));
  });
  for (final width in [320.0, 430.0]) {
    for (final kind in ['manual', 'create', 'edit']) {
      testWidgets('$width px 200 percent keyboard: $kind review is reachable', (
        tester,
      ) async {
        final h = await pumpPm(tester, width: width, scale: 2, keyboard: 280);
        if (kind == 'manual') {
          await tapPm(tester, 'pool-maintenance-startScrub-1');
        } else {
          await tapPm(
            tester,
            kind == 'create'
                ? 'pool-maintenance-createSchedule-2'
                : 'pool-maintenance-updateSchedule-11',
          );
          await enterPm(
            tester,
            'pool-maintenance-description',
            'Narrow screen change',
          );
          await tapPm(tester, 'pool-maintenance-editor-review');
        }
        await confirmPm(tester, h.api.reviews.single.target);
        expect(h.api.writes, hasLength(1));
        expect(tester.takeException(), isNull);
      });
    }
  }
}
