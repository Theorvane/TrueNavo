import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/time_settings/time_settings_controller.dart';
import 'package:trueraid/features/time_settings/time_settings_editor.dart';
import 'package:trueraid/features/time_settings/time_settings_page.dart';
import 'package:trueraid/features/time_settings/time_settings_review.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'time_settings_fakes.dart';

Future<TimeHarness> pumpTime(
  WidgetTester tester, {
  TimeFake? fake,
  bool disconnected = false,
  double width = 800,
  double scale = 1,
  double keyboard = 0,
  bool dark = true,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final h = TimeHarness(fake: fake);
  addTearDown(h.dispose);
  if (disconnected) {
    h.select(null);
  } else {
    try {
      await h.load();
    } on Object {
      /* Fixed public UI. */
    }
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: dark ? TrueRAIDTheme.dark() : TrueRAIDTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: const TimeSettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapTime(
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

Future<void> enterTime(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> openTimeEditor(
  WidgetTester tester,
  TimeSettingsAction action, {
  bool burst = false,
}) async {
  if (action == TimeSettingsAction.timezone) {
    await tapTime(tester, 'time-edit-timezone');
    await tapTime(tester, 'time-zone-Asia/Seoul');
  }
  if (action == TimeSettingsAction.createNtp) {
    await tapTime(tester, 'time-create-ntp');
    await enterTime(tester, 'time-ntp-address', 'clock-new.example');
  }
  if (action == TimeSettingsAction.updateNtp) {
    await tapTime(tester, 'time-edit-1');
    await tapTime(tester, 'time-ntp-prefer');
  }
  if (burst) await tapTime(tester, 'time-ntp-burst');
}

Future<void> openTimeReview(
  WidgetTester tester,
  TimeSettingsAction action, {
  bool burst = false,
  bool settle = true,
}) async {
  if (action == TimeSettingsAction.deleteNtp) {
    await tapTime(tester, 'time-delete-1', settle: settle);
  } else {
    await openTimeEditor(tester, action, burst: burst);
    await tapTime(tester, 'time-editor-review', settle: settle);
  }
}

Future<void> consentTime(
  WidgetTester tester,
  String target, {
  bool burst = false,
}) async {
  await enterTime(tester, 'time-confirm-target', target);
  await tapTime(tester, 'time-confirm-impact');
  await tapTime(tester, 'time-confirm-specific');
  if (burst) await tapTime(tester, 'time-confirm-burst');
}

void background(WidgetTester tester) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
  }
}

void main() {
  testWidgets(
    'opening shows honest configured-only charts with no NTP probes or writes',
    (tester) async {
      final h = await pumpTime(tester);
      expect(h.api.reads, 1);
      expect(h.api.reviews, isEmpty);
      expect(h.api.executes, isEmpty);
      expect(h.api.mutations, 0);
      expect(
        find.text('Configured API sources only — not live synchronization.'),
        findsOneWidget,
      );
      expect(find.byKey(const Key('time-preference-ring')), findsOneWidget);
      expect(find.byKey(const Key('time-poll-min-1')), findsOneWidget);
      expect(find.text('1 Preferred'), findsOneWidget);
      expect(find.text('1 Not preferred'), findsOneWidget);
      expect(find.textContaining('DHCP'), findsWidgets);
      expect(find.textContaining('64 seconds'), findsWidgets);
      expect(find.textContaining('1024 seconds'), findsWidgets);
    },
  );
  testWidgets('disconnected reads nothing', (tester) async {
    final h = await pumpTime(tester, disconnected: true);
    expect(h.api.reads, 0);
    expect(find.text('Time configuration unavailable'), findsOneWidget);
    expect(find.byKey(const Key('time-create-ntp')), findsNothing);
  });
  testWidgets(
    'compact mobile dashboard exposes its configuration chart before long safety details',
    (tester) async {
      final h = await pumpTime(tester, width: 430);
      expect(
        tester.getBottomLeft(find.byKey(const Key('time-preference-ring'))).dy,
        lessThan(1000),
      );
      expect(find.text(timeHost), findsNothing);
      await tapTime(tester, 'time-readiness-details');
      expect(find.text(timeHost), findsOneWidget);
      await tapTime(tester, 'time-scope-details');
      expect(
        find.textContaining(
          'Opening this page only reads public configuration',
        ),
        findsOneWidget,
      );
      expect(h.api.reads, 1);
      expect(h.api.executes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('readonly inventory keeps charts but disables every mutation', (
    tester,
  ) async {
    final h = await pumpTime(
      tester,
      fake: TimeFake(inventory: timeInventory(admin: false)),
    );
    expect(find.byKey(const Key('time-preference-ring')), findsOneWidget);
    for (final key in [
      'time-edit-timezone',
      'time-create-ntp',
      'time-edit-1',
    ]) {
      expect(
        tester.widget<OutlinedButton>(find.byKey(Key(key))).onPressed,
        isNull,
      );
    }
    expect(
      tester
          .widget<TextButton>(find.byKey(const Key('time-delete-1')))
          .onPressed,
      isNull,
    );
    expect(h.api.executes, isEmpty);
  });
  testWidgets('failed read hides raw details and explicit retry recovers', (
    tester,
  ) async {
    final fake = TimeFake()
      ..onLoad = () async => throw StateError('PRIVATE-TIME');
    final h = await pumpTime(tester, fake: fake);
    expect(find.textContaining('PRIVATE-TIME'), findsNothing);
    expect(
      find.text('Time configuration could not be verified'),
      findsOneWidget,
    );
    expect(h.api.reads, 1);
    fake.onLoad = null;
    await tapTime(tester, 'time-retry');
    expect(h.api.reads, 2);
    expect(find.text('Current configuration'), findsOneWidget);
  });
  for (final action in TimeSettingsAction.values) {
    testWidgets(
      '${action.name} full editor/diff/confirmation writes once and requires explicit fresh read afterward',
      (tester) async {
        final h = await pumpTime(tester);
        await openTimeReview(tester, action);
        expect(h.api.executes, isEmpty);
        expect(h.api.reviews.single.action, action);
        expect(find.text(h.api.reviews.single.target), findsOneWidget);
        await consentTime(tester, '${h.api.reviews.single.target} ');
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('time-confirm-submit')),
              )
              .onPressed,
          isNull,
        );
        await enterTime(
          tester,
          'time-confirm-target',
          h.api.reviews.single.target,
        );
        await tapTime(tester, 'time-confirm-specific');
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('time-confirm-submit')),
              )
              .onPressed,
          isNull,
        );
        await tapTime(tester, 'time-confirm-specific');
        await tapTime(tester, 'time-confirm-submit');
        expect(h.api.executes, hasLength(1));
        expect(h.api.mutations, 1);
        expect(
          h.container.read(timeSettingsControllerProvider).status,
          TimeSettingsStatus.completed,
        );
        expect(
          find.text('Configuration verified — clock state unknown'),
          findsOneWidget,
        );
        expect(find.text('Current configuration'), findsNothing);
        expect(find.byKey(const Key('time-preference-ring')), findsNothing);
        expect(h.api.reads, 1);
        final lock = h.container.read(serverOperationLockProvider),
            owner = h.container.read(serverOperationLockProvider).acquire();
        expect(owner, isNotNull);
        lock.release(owner!);
        await tapTime(tester, 'time-refresh-after-review');
        expect(h.api.reads, 2);
        expect(find.text('Current configuration'), findsOneWidget);
        expect(h.api.executes, hasLength(1));
      },
    );
  }
  testWidgets('burst true adds mandatory controlled-server consent', (
    tester,
  ) async {
    final h = await pumpTime(tester);
    await openTimeReview(tester, TimeSettingsAction.createNtp, burst: true);
    await consentTime(tester, h.api.reviews.single.target);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('time-confirm-submit')))
          .onPressed,
      isNull,
    );
    expect(h.api.executes, isEmpty);
    await tapTime(tester, 'time-confirm-burst');
    await tapTime(tester, 'time-confirm-submit');
    expect(h.api.executes, hasLength(1));
    expect(h.api.reviews.single.settings!.burst, isTrue);
  });
  testWidgets(
    'timezone chooser only offers exact advertised values and filters locally',
    (tester) async {
      final h = await pumpTime(tester);
      await tapTime(tester, 'time-edit-timezone');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('time-editor-review')))
            .onPressed,
        isNull,
      );
      await enterTime(tester, 'time-zone-filter', 'seoul');
      expect(find.byKey(const Key('time-zone-UTC')), findsNothing);
      expect(find.byKey(const Key('time-zone-Asia/Seoul')), findsOneWidget);
      await tapTime(tester, 'time-zone-Asia/Seoul');
      await tapTime(tester, 'time-editor-review');
      expect(h.api.reviews.single.timezone, 'Asia/Seoul');
      expect(h.api.executes, isEmpty);
      expect(find.textContaining('cron'), findsWidgets);
      expect(find.textContaining('SSL'), findsWidgets);
    },
  );
  for (final rollback in ['unknown', 'zero', 'positive']) {
    testWidgets('GUI rollback $rollback disables timezone only', (
      tester,
    ) async {
      await pumpTime(
        tester,
        fake: TimeFake(
          inventory: timeInventory(
            rollbackKnown: rollback != 'unknown',
            rollback: rollback == 'zero'
                ? 0
                : rollback == 'positive'
                ? 30
                : null,
          ),
        ),
      );
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('time-edit-timezone')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('time-create-ntp')))
            .onPressed,
        isNotNull,
      );
      await tapTime(tester, 'time-readiness-details');
      expect(find.textContaining('not timezone'), findsOneWidget);
    });
  }
  testWidgets('editor validates address and exponents without a server probe', (
    tester,
  ) async {
    final h = await pumpTime(tester);
    await tapTime(tester, 'time-create-ntp');
    for (final address in [
      'https://clock.example',
      '2001:db8::1',
      'clock-one.example',
    ]) {
      await enterTime(tester, 'time-ntp-address', address);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('time-editor-review')))
            .onPressed,
        isNull,
      );
    }
    await enterTime(tester, 'time-ntp-address', 'clock-new.example');
    await enterTime(tester, 'time-ntp-min', '3');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('time-editor-review')))
          .onPressed,
      isNull,
    );
    await enterTime(tester, 'time-ntp-min', '10');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('time-editor-review')))
          .onPressed,
      isNull,
    );
    await enterTime(tester, 'time-ntp-max', '18');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('time-editor-review')))
          .onPressed,
      isNull,
    );
    await enterTime(tester, 'time-ntp-max', '17');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('time-editor-review')))
          .onPressed,
      isNotNull,
    );
    expect(find.text('Minimum interval: 1024 seconds'), findsOneWidget);
    expect(find.text('Maximum interval: 131072 seconds'), findsOneWidget);
    expect(h.api.reviews, isEmpty);
    expect(h.api.executes, isEmpty);
  });
  testWidgets(
    'last source delete is disabled and empty chart does not invent availability',
    (tester) async {
      await pumpTime(
        tester,
        fake: TimeFake(inventory: timeInventory(servers: [timeServers.first])),
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('time-delete-1')))
            .onPressed,
        isNull,
      );
      expect(find.textContaining('last configured API source'), findsOneWidget);
    },
  );
  testWidgets(
    'empty configured source charts are explicit and not a health claim',
    (tester) async {
      await pumpTime(
        tester,
        fake: TimeFake(inventory: timeInventory(servers: [])),
      );
      expect(find.text('0 Preferred'), findsOneWidget);
      expect(find.text('0 Not preferred'), findsOneWidget);
      expect(find.text('No configured polling bounds.'), findsOneWidget);
      expect(find.byKey(const Key('time-poll-min-1')), findsNothing);
    },
  );
  for (final pair in [(-4, 10), (10, 6), (6, 64)]) {
    testWidgets(
      'legacy polling ${pair.$1}/${pair.$2} keeps raw values and omits misleading bars and scale',
      (tester) async {
        final legacy = NtpServerSnapshot(
          id: 9,
          settings: NtpServerSettings(
            address: '2001:db8::1',
            minPoll: pair.$1,
            maxPoll: pair.$2,
          ),
        );
        await pumpTime(
          tester,
          fake: TimeFake(
            inventory: timeInventory(servers: [timeServers.first, legacy]),
          ),
        );
        expect(find.byKey(const Key('time-poll-min-9')), findsNothing);
        expect(find.byKey(const Key('time-poll-max-9')), findsNothing);
        expect(
          find.textContaining('raw exponents retained; bars omitted'),
          findsOneWidget,
        );
        expect(find.textContaining('Invalid exponent'), findsNothing);
        final max = tester.widget<FractionallySizedBox>(
          find.descendant(
            of: find.byKey(const Key('time-poll-max-1')),
            matching: find.byType(FractionallySizedBox),
          ),
        );
        expect(max.widthFactor, 1);
        expect(find.text('1 Preferred'), findsOneWidget);
        expect(find.text('1 Not preferred'), findsOneWidget);
      },
    );
  }
  for (final phase in ['editor', 'review']) {
    for (final cause in ['session', 'background', 'inventory', 'route']) {
      testWidgets(
        '$phase permanently expires after $cause and hides prior values',
        (tester) async {
          final h = await pumpTime(tester);
          if (phase == 'editor') {
            await openTimeEditor(tester, TimeSettingsAction.createNtp);
          } else {
            await openTimeReview(tester, TimeSettingsAction.createNtp);
          }
          if (cause == 'session') {
            h.select(h.newSession());
            h.select(h.session);
          }
          if (cause == 'background') background(tester);
          if (cause == 'inventory') {
            h.api.inventory = timeInventory();
            h.container.invalidate(timeSettingsInventoryProvider);
          }
          if (cause == 'route') {
            final navigator = tester.state<NavigatorState>(
              find.byType(Navigator),
            );
            unawaited(
              navigator.push<void>(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('Other workspace')),
                ),
              ),
            );
            await tester.pumpAndSettle();
            navigator.pop();
          }
          await tester.pumpAndSettle();
          expect(
            find.text(
              phase == 'editor'
                  ? 'Time-settings editor expired'
                  : 'Time-settings review expired',
            ),
            findsOneWidget,
          );
          expect(
            find.byKey(
              Key(
                phase == 'editor' ? 'time-ntp-address' : 'time-confirm-target',
              ),
            ),
            findsNothing,
          );
          expect(h.api.executes, isEmpty);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
  testWidgets('review expires at five minutes without automatic write', (
    tester,
  ) async {
    final h = await pumpTime(tester);
    await openTimeReview(tester, TimeSettingsAction.createNtp);
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(find.text('Time-settings review expired'), findsOneWidget);
    expect(h.api.executes, isEmpty);
  });
  for (final phase in ['review', 'execute']) {
    testWidgets(
      'covered route during $phase prevents late dispatch before rebuild',
      (tester) async {
        final h = await pumpTime(tester),
            pendingReview = Completer<TimeSettingsReview>(),
            pendingExecute = Completer<void>();
        if (phase == 'review') {
          h.api.onReview = (_) => pendingReview.future;
        } else {
          h.api.onExecute = (_, current) async {
            await pendingExecute.future;
            if (current()) h.api.mutations++;
            return const TimeSettingsResult(
              TimeSettingsOutcome.rejected,
              'stale',
            );
          };
        }
        await openTimeReview(
          tester,
          TimeSettingsAction.createNtp,
          settle: phase != 'review',
        );
        if (phase == 'execute') {
          await consentTime(tester, h.api.reviews.single.target);
          await tapTime(tester, 'time-confirm-submit', settle: false);
        }
        final navigator = tester.state<NavigatorState>(find.byType(Navigator));
        unawaited(
          navigator.push<void>(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Other workspace')),
            ),
          ),
        );
        if (phase == 'review') {
          pendingReview.complete(
            TimeSettingsReview(
              request: h.api.reviews.single,
              endpoint: timeEndpoint,
              warnings: const [],
            ),
          );
        } else {
          pendingExecute.complete();
        }
        await tester.pumpAndSettle();
        expect(h.api.mutations, 0);
        expect(find.byType(TimeSettingsReviewDialog), findsNothing);
        if (phase == 'execute') {
          expect(
            h.container.read(serverOperationLockProvider).acquire(),
            isNull,
          );
        }
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'normal modal close allows delayed review then delayed confirmed execution exactly once',
    (tester) async {
      final h = await pumpTime(tester),
          pendingReview = Completer<TimeSettingsReview>(),
          pendingExecute = Completer<void>();
      h.api.onReview = (_) => pendingReview.future;
      h.api.onExecute = (_, current) async {
        await pendingExecute.future;
        if (current()) h.api.mutations++;
        return const TimeSettingsResult(
          TimeSettingsOutcome.completed,
          'verified',
        );
      };
      await openTimeReview(tester, TimeSettingsAction.createNtp, settle: false);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(TimeSettingsEditorDialog), findsNothing);
      pendingReview.complete(
        TimeSettingsReview(
          request: h.api.reviews.single,
          endpoint: timeEndpoint,
          warnings: const [],
        ),
      );
      await tester.pumpAndSettle();
      await consentTime(tester, h.api.reviews.single.target);
      await tapTime(tester, 'time-confirm-submit', settle: false);
      await tester.pump(const Duration(seconds: 1));
      expect(
        h.container.read(timeSettingsControllerProvider).status,
        TimeSettingsStatus.executing,
      );
      expect(find.byType(TimeSettingsReviewDialog), findsNothing);
      pendingExecute.complete();
      await tester.pumpAndSettle();
      expect(h.api.mutations, 1);
      expect(h.api.executes, hasLength(1));
      expect(
        h.container.read(timeSettingsControllerProvider).status,
        TimeSettingsStatus.completed,
      );
    },
  );
  for (final outcome in [
    TimeSettingsOutcome.rejected,
    TimeSettingsOutcome.unknown,
  ]) {
    testWidgets(
      '${outcome.name} exposes fixed status and correct shared fence',
      (tester) async {
        final fake = TimeFake()
          ..onExecute = (_, _) async =>
              TimeSettingsResult(outcome, 'PRIVATE-TIME');
        final h = await pumpTime(tester, fake: fake);
        await openTimeReview(tester, TimeSettingsAction.deleteNtp);
        await consentTime(tester, h.api.reviews.single.target);
        await tapTime(tester, 'time-confirm-submit');
        expect(h.api.executes, hasLength(1));
        expect(find.textContaining('PRIVATE-TIME'), findsNothing);
        expect(
          h.container.read(timeSettingsControllerProvider).status,
          outcome == TimeSettingsOutcome.unknown
              ? TimeSettingsStatus.unknown
              : TimeSettingsStatus.rejected,
        );
        if (outcome == TimeSettingsOutcome.unknown) {
          expect(
            h.container.read(serverOperationLockProvider).acquire(),
            isNull,
          );
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          expect(
            h.container.read(serverOperationLockProvider).acquire(),
            isNull,
          );
        } else {
          final lock = h.container.read(serverOperationLockProvider),
              owner = h.container.read(serverOperationLockProvider).acquire();
          expect(owner, isNotNull);
          lock.release(owner!);
          expect(
            find.byKey(const Key('time-refresh-after-review')),
            findsOneWidget,
          );
          expect(find.text('Current configuration'), findsNothing);
        }
        expect(h.api.reads, 1);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'recovery requires fresh same-endpoint host verification and independent inspection with no replay',
    (tester) async {
      final fake = TimeFake()
        ..onExecute = (_, _) async =>
            const TimeSettingsResult(TimeSettingsOutcome.unknown, 'unknown');
      final h = await pumpTime(tester, fake: fake);
      await openTimeReview(tester, TimeSettingsAction.createNtp);
      await consentTime(tester, h.api.reviews.single.target);
      await tapTime(tester, 'time-confirm-submit');
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('time-verify-reconnected')),
            )
            .onPressed,
        isNull,
      );
      h.select(h.newSession());
      await tester.pumpAndSettle();
      expect(h.api.reads, 1);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('time-acknowledge')))
            .onPressed,
        isNull,
      );
      await tapTime(tester, 'time-verify-reconnected');
      expect(h.api.reads, 2);
      await tapTime(tester, 'time-acknowledge');
      expect(h.container.read(timeSettingsControllerProvider).locked, isFalse);
      expect(
        find.textContaining('prior operation remains unverified'),
        findsOneWidget,
      );
      expect(h.api.executes, hasLength(1));
    },
  );
  for (final width in [320.0, 430.0, 1100.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'configured charts ${width.toInt()} ${dark ? 'dark' : 'light'} at 200 percent fit',
        (tester) async {
          await pumpTime(tester, width: width, dark: dark, scale: 2);
          await tester.ensureVisible(find.byKey(const Key('time-edit-2')));
          await tester.pumpAndSettle();
          await tapTime(tester, 'time-readiness-details');
          await tapTime(tester, 'time-scope-details');
          expect(tester.takeException(), isNull);
        },
      );
      for (final action in TimeSettingsAction.values) {
        testWidgets(
          '${action.name} editor and review ${width.toInt()} ${dark ? 'dark' : 'light'} at 200 percent with keyboard',
          (tester) async {
            final h = await pumpTime(
              tester,
              width: width,
              dark: dark,
              scale: 2,
              keyboard: 300,
            );
            await openTimeReview(
              tester,
              action,
              burst:
                  action == TimeSettingsAction.createNtp ||
                  action == TimeSettingsAction.updateNtp,
            );
            await consentTime(
              tester,
              h.api.reviews.single.target,
              burst:
                  action == TimeSettingsAction.createNtp ||
                  action == TimeSettingsAction.updateNtp,
            );
            await tapTime(tester, 'time-confirm-submit');
            expect(h.api.executes, hasLength(1));
            expect(
              h.container.read(timeSettingsControllerProvider).status,
              TimeSettingsStatus.completed,
            );
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
