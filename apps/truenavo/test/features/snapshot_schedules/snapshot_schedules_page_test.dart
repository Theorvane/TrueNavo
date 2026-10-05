import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/sample/snapshot_schedules_preview.dart';
import 'package:truenavo/features/snapshot_schedules/snapshot_calendar_editor.dart';
import 'package:truenavo/features/snapshot_schedules/snapshot_schedule_editor.dart';
import 'package:truenavo/features/snapshot_schedules/snapshot_schedule_review.dart';
import 'package:truenavo/features/snapshot_schedules/snapshot_schedules_controller.dart';
import 'package:truenavo/features/snapshot_schedules/snapshot_schedules_page.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'snapshot_schedules_fakes.dart';

Future<SchedulesHarness> pumpSchedules(
  WidgetTester tester, {
  SchedulesFake? fake,
  bool editor = false,
  bool create = false,
  double width = 800,
  double scale = 1,
  bool light = false,
}) async {
  tester.view.physicalSize = Size(width, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final h = SchedulesHarness(fake: fake);
  addTearDown(h.dispose);
  await h.container.read(snapshotSchedulesInventoryProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: light ? TrueNavoTheme.light() : TrueNavoTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
        home: editor
            ? SnapshotScheduleEditorPage(
                session: h.session,
                inventory: h.api.inventory,
                task: create ? null : h.api.inventory.tasks.first,
              )
            : const SnapshotSchedulesPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> reveal(WidgetTester tester, Finder finder) async {
  FocusManager.instance.primaryFocus?.unfocus();
  await tester.pumpAndSettle();
  if (finder.evaluate().isEmpty) {
    final scrollable = find.byType(Scrollable).first;
    tester.state<ScrollableState>(scrollable).position.jumpTo(0);
    await tester.pumpAndSettle();
    if (finder.evaluate().isEmpty) {
      await tester.scrollUntilVisible(
        finder,
        450,
        maxScrolls: 100,
        scrollable: scrollable,
      );
    }
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
}

Future<void> tapSchedule(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await reveal(tester, finder);
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> confirmSchedule(WidgetTester tester, String target) async {
  final field = find.byKey(const Key('schedule-confirm-target'));
  await reveal(tester, field);
  await tester.enterText(field, target);
  await tester.pumpAndSettle();
  await tapSchedule(tester, 'schedule-confirm-impact');
}

void main() {
  test('calendar numeric subset preserves aliases, ranges, steps and rejects unknown modifiers', () {
    expect(calendarFieldValues('0,15,30,45', calendarFields[0]), {
      0,
      15,
      30,
      45,
    });
    expect(calendarFieldValues('1-5/2', calendarFields[4]), {1, 3, 5});
    expect(calendarFieldValues('0,7', calendarFields[4]), {0, 7});
    for (final invalid in [
      '',
      '*/0',
      '*/99',
      '5/2',
      '60',
      'MON',
      '1L',
      '5-1',
      '1,,2',
    ]) {
      expect(
        calendarFieldValues(invalid, calendarFields[0]),
        isNull,
        reason: invalid,
      );
    }
    expect(const SnapshotCalendarValue(dayOfWeek: '0').expression, '0 0 * * 0');
  });
  for (final invalid in ['*/0', '*/99']) {
    testWidgets(
      'unsupported $invalid interval remains visible without an invalid dropdown',
      (tester) async {
        var callbacks = 0;
        await tester.pumpWidget(
          MaterialApp(
            theme: TrueNavoTheme.dark(),
            home: Scaffold(
              body: SingleChildScrollView(
                child: SnapshotCalendarEditor(
                  value: SnapshotCalendarValue(minute: invalid),
                  onChanged: (_) => callbacks++,
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('Minute'));
        await tester.pumpAndSettle();
        expect(
          find.textContaining('outside the native calendar subset'),
          findsOneWidget,
        );
        expect(find.byType(DropdownButtonFormField<int>), findsNothing);
        expect(callbacks, 0);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'calendar presets are native controls and restricted day fields explain OR',
    (tester) async {
      var value = const SnapshotCalendarValue(dayOfMonth: '1', dayOfWeek: '1');
      await tester.pumpWidget(
        MaterialApp(
          theme: TrueNavoTheme.dark(),
          home: Scaffold(
            body: SingleChildScrollView(
              child: StatefulBuilder(
                builder: (context, setState) => SnapshotCalendarEditor(
                  value: value,
                  onChanged: (next) => setState(() => value = next),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        find.textContaining('day of month OR selected weekday'),
        findsOneWidget,
      );
      await tapSchedule(tester, 'schedule-preset-weekly');
      expect(value.expression, '0 2 * * 7');
      expect(find.byType(TextField), findsNothing);
    },
  );
  testWidgets(
    'inventory shows actual error/enable counts and timezone without invented next run',
    (tester) async {
      for (final (width, scale, horizontal) in [
        (430.0, 1.0, true),
        (320.0, 2.0, false),
      ]) {
        final h = await pumpSchedules(tester, width: width, scale: scale);
        expect(find.text('Reported errors'), findsOneWidget);
        expect(find.text('Enabled · 1'), findsOneWidget);
        expect(find.text('Server timezone: Asia/Seoul'), findsOneWidget);
        expect(
          find.text(
            'Next run is not calculated locally. Reload for server-reported state.',
          ),
          findsOneWidget,
        );
        final summary = tester.getRect(
          find.byKey(const Key('schedule-summary-counts')),
        );
        final total = tester.getRect(
          find.byKey(const Key('schedule-summary-total')),
        );
        final errors = tester.getRect(
          find.byKey(const Key('schedule-summary-errors')),
        );
        expect(total.width, closeTo(errors.width, .1));
        expect(total.left, closeTo(summary.left, .1));
        expect(errors.right, closeTo(summary.right, .1));
        if (horizontal) {
          expect(total.top, closeTo(errors.top, .1));
          expect(total.height, closeTo(errors.height, .1));
          expect(errors.left - total.right, closeTo(TdSpacing.related, .1));
        } else {
          expect(total.width, closeTo(summary.width, .1));
          expect(errors.top - total.bottom, closeTo(TdSpacing.related, .1));
        }
        expect(h.api.writes, isEmpty);
        expect(h.api.reviews, isEmpty);
        expect(tester.takeException(), isNull);
      }
    },
  );
  testWidgets(
    'creation captures exact dataset recursion exclusions and weekday calendar only after review',
    (tester) async {
      final h = await pumpSchedules(tester, editor: true, create: true);
      await tapSchedule(tester, 'schedule-recursive');
      await tapSchedule(tester, 'schedule-exclude-tank/media/cache');
      await tapSchedule(tester, 'schedule-preset-weekdays');
      await reveal(tester, find.byKey(const Key('schedule-lifetime')));
      await tester.enterText(find.byKey(const Key('schedule-lifetime')), '3');
      await tapSchedule(tester, 'schedule-review-draft');
      expect(h.api.writes, isEmpty);
      expect(find.byType(SnapshotScheduleReviewDialog), findsOneWidget);
      final request = h.api.reviews.single;
      expect(request.action, SnapshotScheduleAction.create);
      expect(request.settings!.dataset, 'tank/media');
      expect(request.settings!.recursive, isTrue);
      expect(request.settings!.exclude, ['tank/media/cache']);
      expect(request.settings!.lifetimeValue, 3);
      expect(request.settings!.cron.hour, '9');
      expect(request.settings!.cron.dow, '1-5');
      await confirmSchedule(tester, request.target);
      await tapSchedule(tester, 'schedule-submit-confirm');
      expect(h.api.writes.length, 1);
    },
  );
  testWidgets('unchanged and invalid retention drafts never call review', (
    tester,
  ) async {
    final h = await pumpSchedules(tester, editor: true);
    await tapSchedule(tester, 'schedule-review-draft');
    expect(find.text('Select at least one changed setting.'), findsOneWidget);
    await reveal(tester, find.byKey(const Key('schedule-lifetime')));
    await tester.enterText(find.byKey(const Key('schedule-lifetime')), '0');
    await tapSchedule(tester, 'schedule-review-draft');
    expect(h.api.reviews, isEmpty);
    expect(h.api.writes, isEmpty);
    expect(find.textContaining('zero or negative retention'), findsOneWidget);
  });
  testWidgets(
    'read-only capabilities preserve inspection but disable create update run delete',
    (tester) async {
      final fake = SchedulesFake(
        methods: scheduleMethods.difference({
          'pool.snapshottask.create',
          'pool.snapshottask.update',
          'pool.snapshottask.run',
          'pool.snapshottask.delete',
        }),
      );
      final h = await pumpSchedules(tester, fake: fake);
      await reveal(tester, find.byKey(const Key('schedules-create')));
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('schedules-create')))
            .onPressed,
        isNull,
      );
      await reveal(tester, find.byKey(const Key('schedule-run-4')));
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('schedule-run-4')))
            .onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('schedule-delete-4')))
            .onPressed,
        isNull,
      );
      await tapSchedule(tester, 'schedule-edit-4');
      await reveal(tester, find.byKey(const Key('schedule-review-draft')));
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('schedule-review-draft')),
            )
            .onPressed,
        isNull,
      );
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'deletion lists potential affected snapshots and expiry warning, cancel sends nothing',
    (tester) async {
      final h = await pumpSchedules(tester);
      await tapSchedule(tester, 'schedule-delete-4');
      expect(find.text('tank/media@auto-2026-09-12_02-00'), findsOneWidget);
      expect(
        find.textContaining('not guaranteed to retain the same future expiry'),
        findsOneWidget,
      );
      await tapSchedule(tester, 'schedule-cancel-confirm');
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'deletion requires exact untrimmed task+dataset target and impact acknowledgement',
    (tester) async {
      final h = await pumpSchedules(tester);
      await tapSchedule(tester, 'schedule-delete-4');
      await confirmSchedule(tester, 'Task 4: tank/media ');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('schedule-submit-confirm')),
            )
            .onPressed,
        isNull,
      );
      await tester.enterText(
        find.byKey(const Key('schedule-confirm-target')),
        'Task 4: tank/media',
      );
      await tester.pumpAndSettle();
      await tapSchedule(tester, 'schedule-submit-confirm');
      expect(h.api.writes.single.action, SnapshotScheduleAction.delete);
    },
  );
  testWidgets(
    'run now is separately reviewed and accepted never means completed',
    (tester) async {
      final h = await pumpSchedules(tester);
      await tapSchedule(tester, 'schedule-run-4');
      expect(h.api.writes, isEmpty);
      await confirmSchedule(tester, 'Task 4: tank/media');
      await tapSchedule(tester, 'schedule-submit-confirm');
      await reveal(tester, find.text('Run request accepted'));
      expect(
        find.textContaining(
          'Snapshot creation and completion have not been verified',
        ),
        findsOneWidget,
      );
      expect(find.text('Schedule change verified'), findsNothing);
      expect(h.api.writes.single.action, SnapshotScheduleAction.run);
      final reads = h.api.reads;
      await tester.pump(const Duration(minutes: 10));
      expect(
        h.api.reads,
        reads,
        reason: 'Accepted runs must not start periodic polling.',
      );
      expect(h.api.writes.length, 1);
    },
  );
  testWidgets('disabled task cannot run without a separate enable change', (
    tester,
  ) async {
    final h = await pumpSchedules(
      tester,
      fake: SchedulesFake(inventory: scheduleInventory(enabled: false)),
    );
    await reveal(tester, find.byKey(const Key('schedule-run-4')));
    expect(
      tester
          .widget<OutlinedButton>(find.byKey(const Key('schedule-run-4')))
          .onPressed,
      isNull,
    );
    expect(h.api.reviews, isEmpty);
    expect(h.api.writes, isEmpty);
    expect(
      find.textContaining('enabled in a separate reviewed change'),
      findsOneWidget,
    );
  });
  testWidgets(
    'read errors expose manual retry without leaked remote details or automatic retries',
    (tester) async {
      final h = await pumpSchedules(tester);
      h.api.onLoad = () => Future.error(StateError('private remote token'));
      h.container.invalidate(snapshotSchedulesInventoryProvider);
      await tester.pumpAndSettle();
      expect(find.text('Schedule inventory unavailable'), findsOneWidget);
      expect(find.textContaining('private remote token'), findsNothing);
      final reads = h.api.reads;
      await tester.pump(const Duration(minutes: 10));
      expect(h.api.reads, reads);
      h.api.onLoad = () async => h.api.inventory;
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(h.api.reads, reads + 1);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'native time-window picker fits 320px at 200% without changing cancelled values',
    (tester) async {
      final h = await pumpSchedules(tester, editor: true, width: 320, scale: 2);
      await tapSchedule(tester, 'schedule-window-begin');
      expect(find.byType(TimePickerDialog), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('Cancel').last);
      await tester.pumpAndSettle();
      expect(h.api.reviews, isEmpty);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets('connection switch hides review and old editor immediately', (
    tester,
  ) async {
    final h = await pumpSchedules(tester, editor: true);
    await tapSchedule(tester, 'schedule-enabled');
    await tapSchedule(tester, 'schedule-review-draft');
    h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('schedule-confirm-target')), findsNothing);
    expect(find.byKey(const Key('schedule-submit-confirm')), findsNothing);
    expect(find.byType(SnapshotCalendarEditor), findsNothing);
    expect(find.text('tank/media'), findsNothing);
    expect(h.api.writes, isEmpty);
  });
  testWidgets(
    'stale readonly review response cannot open dialog after session change',
    (tester) async {
      final fake = SchedulesFake();
      final pending = Completer<SnapshotScheduleReview>();
      fake.onReview = (_) => pending.future;
      final h = await pumpSchedules(tester, fake: fake);
      await reveal(tester, find.byKey(const Key('schedule-run-4')));
      await tester.tap(find.byKey(const Key('schedule-run-4')));
      await tester.pump();
      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
      await tester.pump();
      pending.complete(scheduleReview(action: SnapshotScheduleAction.run));
      await tester.pumpAndSettle();
      expect(find.byType(SnapshotScheduleReviewDialog), findsNothing);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets(
    'post-write refresh hides old issued editor until newly loaded inventory is reopened',
    (tester) async {
      final h = await pumpSchedules(tester, editor: true);
      await tapSchedule(tester, 'schedule-enabled');
      await tapSchedule(tester, 'schedule-review-draft');
      h.api.onLoad = () async => scheduleInventory(enabled: false);
      await confirmSchedule(tester, 'Task 4: tank/media');
      await tapSchedule(tester, 'schedule-submit-confirm');
      expect(find.text('Inventory changed'), findsOneWidget);
      expect(find.byType(SnapshotCalendarEditor), findsNothing);
    },
  );
  for (final light in [false, true]) {
    testWidgets(
      '320px 200% ${light ? 'light' : 'dark'} editor and keyboard review fit',
      (tester) async {
        final h = await pumpSchedules(
          tester,
          editor: true,
          width: 320,
          scale: 2,
          light: light,
        );
        await tapSchedule(tester, 'schedule-enabled');
        await tapSchedule(tester, 'schedule-review-draft');
        await confirmSchedule(tester, 'Task 4: tank/media');
        tester.view.viewInsets = const FakeViewPadding(bottom: 250);
        addTearDown(tester.view.resetViewInsets);
        await tester.pumpAndSettle();
        await reveal(tester, find.byKey(const Key('schedule-submit-confirm')));
        expect(tester.takeException(), isNull);
        await tapSchedule(tester, 'schedule-cancel-confirm');
        expect(h.api.writes, isEmpty);
      },
    );
  }
  test('const preview has isolated scheduled health cases and rejects every operation', () async {
    const preview = _Preview();
    final inventory = await preview.loadSnapshotSchedules();
    expect(inventory.tasks.any((task) => task.state == 'ERROR'), isTrue);
    expect(inventory.tasks.any((task) => !task.settings.enabled), isTrue);
    for (final action in SnapshotScheduleAction.values) {
      final request = SnapshotScheduleRequest(
        inventory: inventory,
        action: action,
        task: action == SnapshotScheduleAction.create
            ? null
            : inventory.tasks.first,
        settings:
            action == SnapshotScheduleAction.create ||
                action == SnapshotScheduleAction.update
            ? const SnapshotScheduleSettings(
                dataset: 'tank/media',
                lifetimeValue: 3,
              )
            : null,
      );
      final review = await preview.reviewSnapshotSchedule(request);
      expect(
        (await preview.executeSnapshotSchedule(review, review.target)).outcome,
        SnapshotScheduleOutcome.rejected,
      );
    }
    expect(await preview.loadSnapshotSchedules(), same(inventory));
  });
}

class _Preview with SnapshotSchedulesPreviewAdapter {
  const _Preview();
}
