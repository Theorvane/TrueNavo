import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/cron_tasks/cron_tasks_controller.dart';
import 'package:trueraid/features/cron_tasks/cron_tasks_page.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'cron_tasks_fakes.dart';

Future<CronHarness> pumpCron(
  WidgetTester tester, {
  CronFake? fake,
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
  final h = CronHarness(fake: fake);
  addTearDown(h.dispose);
  if (disconnected) {
    h.select(null);
  } else {
    try {
      await h.load();
    } on Object {
      /* Fixed safe UI. */
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
        home: const CronTasksPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapCron(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 40,
    );
  }
  final checkbox = find.descendant(of: finder, matching: find.byType(Checkbox));
  final target = checkbox.evaluate().isNotEmpty ? checkbox : finder;
  await tester.ensureVisible(target);
  await tester.pumpAndSettle();
  await tester.tap(target);
  await tester.pumpAndSettle();
}

Future<void> enterCron(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> openReview(
  WidgetTester tester, {
  CronTasksAction action = CronTasksAction.edit,
  bool replace = false,
}) async {
  if (action == CronTasksAction.create || action == CronTasksAction.edit) {
    await tapCron(
      tester,
      action == CronTasksAction.create ? 'cron-create' : 'cron-edit-1',
    );
    await enterCron(tester, 'cron-description', 'Changed maintenance');
    if (action == CronTasksAction.create) await tapCron(tester, 'cron-user-1');
    if (replace && action == CronTasksAction.edit) {
      await tapCron(tester, 'cron-replace-command');
    }
    if (replace || action == CronTasksAction.create) {
      await enterCron(
        tester,
        'cron-command',
        'printf SYNTHETIC_PRIVATE_COMMAND',
      );
    }
    await tapCron(tester, 'cron-editor-next');
  } else {
    await tapCron(
      tester,
      'cron-${action.name}-${(action == CronTasksAction.disable || action == CronTasksAction.run) ? 2 : 1}',
    );
  }
  expect(find.text('Review cron ${action.name}'), findsOneWidget);
}

Future<void> confirm(WidgetTester tester, CronHarness h) async {
  final action = h.api.reviews.last.action;
  await enterCron(tester, 'cron-confirmation', h.api.reviews.last.target);
  await tapCron(tester, 'cron-consent-impact');
  if (action == CronTasksAction.create ||
      action == CronTasksAction.edit ||
      action == CronTasksAction.enable ||
      action == CronTasksAction.run) {
    await tapCron(tester, 'cron-consent-command');
  }
  if (action == CronTasksAction.enable || action == CronTasksAction.run) {
    await tapCron(tester, 'cron-consent-execution');
    await tapCron(tester, 'cron-consent-disclosure');
  }
  await tapCron(tester, 'cron-submit');
}

void main() {
  for (final dark in [false, true]) {
    for (final width in [320.0, 800.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('configured task charts $dark/$width/$scale', (
          tester,
        ) async {
          final h = await pumpCron(
            tester,
            dark: dark,
            width: width,
            scale: scale,
          );
          await tester.scrollUntilVisible(
            find.byKey(const Key('cron-task-ring')),
            200,
            scrollable: find.byType(Scrollable).first,
          );
          expect(find.text('1 enabled\n1 disabled'), findsOneWidget);
          expect(h.api.reads, 1);
          expect(h.api.executes, isEmpty);
          expect(tester.takeException(), isNull);
          await enterCron(tester, 'cron-filter', 'not-present');
          expect(find.text('No tasks match this filter.'), findsOneWidget);
          expect(
            find.textContaining('SYNTHETIC_PRIVATE_COMMAND'),
            findsNothing,
          );
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
  for (final action in CronTasksAction.values) {
    testWidgets('$action normal modal transitions submit once', (tester) async {
      final h = await pumpCron(tester);
      await openReview(tester, action: action);
      expect(h.api.executes, isEmpty);
      await confirm(tester, h);
      expect(h.api.mutations, 1);
      expect(h.api.executes, hasLength(1));
      expect(find.text('Configuration verified'), findsOneWidget);
      if (action == CronTasksAction.create) {
        expect(h.api.reviews.last.command!.isDisposed, isTrue);
      }
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('write-only replacement remains private and is disposed', (
    tester,
  ) async {
    final h = await pumpCron(tester);
    await openReview(tester, replace: true);
    expect(find.textContaining('SYNTHETIC_PRIVATE_COMMAND'), findsNothing);
    expect(h.api.reviews.last.command!.isDisposed, isFalse);
    await confirm(tester, h);
    expect(h.api.reviews.last.command!.isDisposed, isTrue);
    expect(h.api.mutations, 1);
  });
  for (final action in [CronTasksAction.create, CronTasksAction.enable]) {
    testWidgets('small high-text keyboard $action complete flow', (
      tester,
    ) async {
      final h = await pumpCron(tester, width: 320, scale: 2, keyboard: 260);
      await openReview(tester, action: action);
      expect(tester.takeException(), isNull);
      await confirm(tester, h);
      expect(h.api.mutations, 1);
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('enable needs all four independent consents', (tester) async {
    final h = await pumpCron(tester);
    await openReview(tester, action: CronTasksAction.enable);
    await enterCron(tester, 'cron-confirmation', h.api.reviews.last.target);
    for (final key in [
      'cron-consent-impact',
      'cron-consent-command',
      'cron-consent-execution',
    ]) {
      await tapCron(tester, key);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('cron-submit')))
            .onPressed,
        isNull,
      );
    }
    await tapCron(tester, 'cron-consent-disclosure');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('cron-submit')))
          .onPressed,
      isNotNull,
    );
    expect(h.api.executes, isEmpty);
  });
  testWidgets('create requires explicit account and command', (tester) async {
    final h = await pumpCron(tester);
    await tapCron(tester, 'cron-create');
    await enterCron(tester, 'cron-description', 'Draft');
    await enterCron(tester, 'cron-command', 'printf sample');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('cron-editor-next')))
          .onPressed,
      isNull,
    );
    await tapCron(tester, 'cron-user-1');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('cron-editor-next')))
          .onPressed,
      isNotNull,
    );
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('cron-command')))
          .obscureText,
      isTrue,
    );
    expect(h.api.reviews, isEmpty);
  });
  testWidgets('unchanged edit and invalid schedule block review', (
    tester,
  ) async {
    final h = await pumpCron(tester);
    await tapCron(tester, 'cron-edit-1');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('cron-editor-next')))
          .onPressed,
      isNull,
    );
    await enterCron(tester, 'cron-description', 'Changed');
    await enterCron(tester, 'cron-minute', '99');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('cron-editor-next')))
          .onPressed,
      isNull,
    );
    expect(h.api.reviews, isEmpty);
  });
  testWidgets('inline presets do not expire modal authority', (tester) async {
    final h = await pumpCron(tester);
    await tapCron(tester, 'cron-edit-1');
    await tapCron(tester, 'cron-preset-hourly');
    await tapCron(tester, 'cron-editor-next');
    expect(find.text('Review cron edit'), findsOneWidget);
    expect(h.api.reviews.last.settings!.schedule.hour, '*');
    await confirm(tester, h);
    expect(h.api.mutations, 1);
  });
  for (final phase in ['editor', 'review']) {
    for (final reason in ['background', 'disconnect', 'covered']) {
      testWidgets('$phase $reason expires actual buffers and capsule', (
        tester,
      ) async {
        final h = await pumpCron(tester);
        if (phase == 'editor') {
          await tapCron(tester, 'cron-create');
          await enterCron(tester, 'cron-command', 'PRIVATE_DRAFT');
        } else {
          await openReview(tester, replace: true);
          await enterCron(
            tester,
            'cron-confirmation',
            h.api.reviews.last.target,
          );
          await tapCron(tester, 'cron-consent-impact');
        }
        final controllers = find
            .byType(TextField)
            .evaluate()
            .map((e) => (e.widget as TextField).controller)
            .whereType<TextEditingController>()
            .toList();
        if (reason == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        } else if (reason == 'disconnect') {
          h.select(null);
        } else {
          Navigator.of(tester.element(find.byType(Dialog))).push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Covered')),
            ),
          );
        }
        await tester.pumpAndSettle();
        for (final c in controllers) {
          expect(c.text, isEmpty);
        }
        if (phase == 'review') {
          expect(h.api.reviews.last.command!.isDisposed, isTrue);
        }
        expect(h.api.executes, isEmpty);
        expect(tester.takeException(), isNull);
        if (reason == 'covered') {
          Navigator.of(tester.element(find.text('Covered'))).pop();
          await tester.pumpAndSettle();
        }
        expect(
          find.text(
            phase == 'editor' ? 'Cron draft expired' : 'Cron review expired',
          ),
          findsOneWidget,
        );
      });
    }
  }
  testWidgets('review timer wipes capsule and target after five minutes', (
    tester,
  ) async {
    final h = await pumpCron(tester);
    await openReview(tester, replace: true);
    await enterCron(tester, 'cron-confirmation', h.api.reviews.last.target);
    await tester.pump(const Duration(minutes: 5, seconds: 1));
    expect(find.text('Cron review expired'), findsOneWidget);
    expect(h.api.reviews.last.command!.isDisposed, isTrue);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('cron-confirmation')))
          .controller!
          .text,
      isEmpty,
    );
    expect(h.api.executes, isEmpty);
  });
  testWidgets('command replacement toggle clears typed buffer', (tester) async {
    final h = await pumpCron(tester);
    await tapCron(tester, 'cron-edit-1');
    await tapCron(tester, 'cron-replace-command');
    await enterCron(tester, 'cron-command', 'SECRET_TO_CLEAR');
    final c = tester
        .widget<TextField>(find.byKey(const Key('cron-command')))
        .controller!;
    await tapCron(tester, 'cron-replace-command');
    expect(c.text, isEmpty);
    expect(find.byKey(const Key('cron-command')), findsNothing);
    expect(h.api.reviews, isEmpty);
  });
  testWidgets('cancel editor never invokes SDK review', (tester) async {
    final h = await pumpCron(tester);
    await tapCron(tester, 'cron-create');
    await enterCron(tester, 'cron-command', 'PRIVATE_DRAFT');
    await tapCron(tester, 'cron-editor-cancel');
    expect(h.api.reviews, isEmpty);
    expect(h.api.executes, isEmpty);
  });
  testWidgets('cancel review disposes protected capsule', (tester) async {
    final h = await pumpCron(tester);
    await openReview(tester, replace: true);
    await tapCron(tester, 'cron-review-cancel');
    expect(h.api.reviews.last.command!.isDisposed, isTrue);
    expect(h.api.executes, isEmpty);
  });
  testWidgets(
    'empty tasks are readable and create remains disabled-by-design',
    (tester) async {
      final h = await pumpCron(
        tester,
        fake: CronFake(inventory: cronInventory(tasks: const [])),
      );
      await tester.scrollUntilVisible(
        find.text(
          'No configured cron tasks. Create a disabled draft to begin; nothing executes automatically from this page.',
        ),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(
        find.text(
          'No configured cron tasks. Create a disabled draft to begin; nothing executes automatically from this page.',
        ),
        findsOneWidget,
      );
      expect(h.api.executes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('directory profile prevents mutation', (tester) async {
    final h = await pumpCron(
      tester,
      fake: CronFake(inventory: cronInventory(directory: true)),
    );
    await tester.scrollUntilVisible(
      find.byKey(const Key('cron-create')),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('cron-create')))
          .onPressed,
      isNull,
    );
    expect(h.api.executes, isEmpty);
  });
  testWidgets('read error sanitizes details without retry', (tester) async {
    final fake = CronFake()
      ..onLoad = () => Future.error(StateError('PRIVATE_COMMAND'));
    final h = await pumpCron(tester, fake: fake);
    expect(find.text('Cron tasks unavailable'), findsOneWidget);
    expect(find.textContaining('PRIVATE_COMMAND'), findsNothing);
    expect(h.api.reads, 1);
  });
  testWidgets('disconnected page performs no reads', (tester) async {
    final h = await pumpCron(tester, disconnected: true);
    expect(find.text('Scheduled cron tasks'), findsOneWidget);
    expect(h.api.reads, 0);
  });
  testWidgets('unknown keeps shared lock and no auto read', (tester) async {
    final h = await pumpCron(tester);
    h.api.onExecute = (_, _) async =>
        const CronTasksResult(CronTasksOutcome.unknown, 'PRIVATE_COMMAND');
    await openReview(tester);
    await confirm(tester, h);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    expect(h.api.reads, 1);
    expect(find.byKey(const Key('cron-create')), findsNothing);
    expect(find.textContaining('PRIVATE_COMMAND'), findsNothing);
  });
  testWidgets('background during held submission remains unknown', (
    tester,
  ) async {
    final h = await pumpCron(tester), held = Completer<CronTasksResult>();
    h.api.onExecute = (_, _) => held.future;
    await openReview(tester, replace: true);
    await confirm(tester, h);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(h.api.reviews.last.command!.isDisposed, isTrue);
    held.complete(const CronTasksResult(CronTasksOutcome.completed, 'late'));
    await tester.pumpAndSettle();
    expect(
      h.container.read(cronTasksControllerProvider).status,
      CronTasksStatus.unknown,
    );
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
  });
}
