import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/init_shutdown_tasks/init_shutdown_tasks_controller.dart';
import 'package:truenavo/features/init_shutdown_tasks/init_shutdown_tasks_editor.dart';
import 'package:truenavo/features/init_shutdown_tasks/init_shutdown_tasks_page.dart';
import 'package:truenavo/features/init_shutdown_tasks/init_shutdown_tasks_review.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'init_shutdown_tasks_fakes.dart';

Future<InitHarness> pumpInit(
  WidgetTester tester, {
  InitFake? fake,
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
  final h = InitHarness(fake: fake);
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
        theme: dark ? TrueNavoTheme.dark() : TrueNavoTheme.light(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: const InitShutdownTasksPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapInit(
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

Future<void> enterInit(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> openInitEditor(
  WidgetTester t,
  InitShutdownTasksAction action, {
  InitShutdownTaskPhase phase = InitShutdownTaskPhase.shutdown,
}) async {
  await tapInit(
    t,
    action == InitShutdownTasksAction.create ? 'init-create' : 'init-replace-1',
  );
  expect(
    t.widget<TextField>(find.byKey(const Key('init-command'))).controller!.text,
    isEmpty,
  );
  await enterInit(t, 'init-command', initBody);
  await enterInit(t, 'init-timeout', '30');
  await tapInit(t, 'init-phase-${phase.name}');
}

Future<void> openInitReview(
  WidgetTester t,
  InitShutdownTasksAction action, {
  bool settle = true,
  InitShutdownTaskPhase phase = InitShutdownTaskPhase.shutdown,
}) async {
  if (action == InitShutdownTasksAction.create ||
      action == InitShutdownTasksAction.replace) {
    await openInitEditor(t, action, phase: phase);
    await tapInit(t, 'init-editor-review', settle: settle);
  } else {
    await tapInit(t, switch (action) {
      InitShutdownTasksAction.enable => 'init-toggle-1',
      InitShutdownTasksAction.disable => 'init-toggle-2',
      _ => 'init-delete-1',
    }, settle: settle);
  }
}

Future<void> consentInit(
  WidgetTester t,
  String target,
  InitShutdownTasksAction action,
) async {
  await enterInit(t, 'init-confirm-target', target);
  await tapInit(t, 'init-confirm-impact');
  if (action != InitShutdownTasksAction.create &&
      action != InitShutdownTasksAction.replace) {
    await tapInit(t, 'init-confirm-specific');
  }
  if (action == InitShutdownTasksAction.enable) {
    await tapInit(t, 'init-confirm-body');
    await tapInit(t, 'init-confirm-budget');
  }
}

void background(WidgetTester t) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    t.binding.handleAppLifecycleStateChanged(state);
  }
}

void expectLocked(InitHarness h) =>
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
void expectUnlocked(InitHarness h) {
  final lock = h.container.read(serverOperationLockProvider),
      owner = lock.acquire();
  expect(owner, isNotNull);
  lock.release(owner!);
}

void main() {
  testWidgets(
    'normal editor reverse animation preserves held review authorization',
    (t) async {
      final h = await pumpInit(t),
          pending = Completer<InitShutdownTasksReview>();
      h.api.onReview = (_) => pending.future;
      await openInitEditor(t, InitShutdownTasksAction.create);
      final input = t
          .widget<TextField>(find.byKey(const Key('init-command')))
          .controller!;
      await tapInit(t, 'init-editor-review', settle: false);
      final request = h.api.reviews.single;
      for (var frame = 0; frame < 3; frame++) {
        await t.pump(const Duration(milliseconds: 40));
        expect(input.text, isEmpty);
        expect(request.command!.isDisposed, isFalse);
        expect(
          h.container.read(initShutdownTasksControllerProvider).status,
          InitShutdownTasksStatus.reviewing,
        );
      }
      pending.complete(
        InitShutdownTasksReview(
          request: request,
          endpoint: initEndpoint,
          warnings: const [],
          commandReference: 'f' * 64,
        ),
      );
      await t.pumpAndSettle();
      expect(find.text('Task review expired'), findsNothing);
      await consentInit(t, request.target, InitShutdownTasksAction.create);
      expect(
        t
            .widget<FilledButton>(find.byKey(const Key('init-confirm-submit')))
            .onPressed,
        isNotNull,
      );
      await tapInit(t, 'init-review-cancel');
      expect(request.command!.isDisposed, isTrue);
      expect(h.api.executes, isEmpty);
    },
  );
  testWidgets(
    'normal review reverse animation preserves held execution callback',
    (t) async {
      final h = await pumpInit(t),
          pending = Completer<InitShutdownTasksResult>();
      bool Function()? current;
      h.api.onExecute = (_, isCurrent) {
        current = isCurrent;
        return pending.future;
      };
      await openInitReview(t, InitShutdownTasksAction.create);
      final request = h.api.reviews.single;
      await consentInit(t, request.target, InitShutdownTasksAction.create);
      await tapInit(t, 'init-confirm-submit', settle: false);
      expect(h.api.executes, hasLength(1));
      for (var frame = 0; frame < 3; frame++) {
        await t.pump(const Duration(milliseconds: 40));
        expect(current?.call(), isTrue);
        expect(request.command!.isDisposed, isFalse);
        expect(
          h.container.read(initShutdownTasksControllerProvider).status,
          InitShutdownTasksStatus.executing,
        );
      }
      pending.complete(
        const InitShutdownTasksResult(
          InitShutdownTasksOutcome.completed,
          'synthetic',
        ),
      );
      await t.pumpAndSettle();
      expect(
        h.container.read(initShutdownTasksControllerProvider).status,
        InitShutdownTasksStatus.completed,
      );
      expect(request.command!.isDisposed, isTrue);
      expectUnlocked(h);
    },
  );
  for (final width in [320.0, 430.0, 1100.0]) {
    for (final dark in [false, true]) {
      testWidgets('dashboard $width dark=$dark 200% configured-only charts', (
        t,
      ) async {
        final h = await pumpInit(t, width: width, dark: dark, scale: 2);
        expect(find.byKey(const Key('init-enablement-ring')), findsOneWidget);
        expect(
          t
              .widget<FractionallySizedBox>(
                find.byKey(const Key('init-count-Phase-PREINIT')),
              )
              .widthFactor,
          1 / 3,
        );
        expect(
          find.textContaining(
            'Command bodies, script paths and comments are withheld.',
          ),
          findsOneWidget,
        );
        await tapInit(t, 'init-readiness-details');
        expect(find.textContaining('The NAS stores task rows'), findsOneWidget);
        expect(find.textContaining(initBody), findsNothing);
        expect(h.api.executes, isEmpty);
        expect(h.api.reads, 1);
        expect(t.takeException(), isNull);
      });
      for (final action in InitShutdownTasksAction.values) {
        testWidgets('${action.name} review $width dark=$dark 200% keyboard', (
          t,
        ) async {
          final h = await pumpInit(
            t,
            width: width,
            dark: dark,
            scale: 2,
            keyboard: 300,
          );
          await openInitReview(t, action);
          expect(find.byType(InitShutdownTasksReviewDialog), findsOneWidget);
          expect(find.textContaining(initBody), findsNothing);
          await tapInit(t, 'init-review-details');
          expect(find.textContaining('Synthetic supplemental'), findsOneWidget);
          expect(find.text('Task review expired'), findsNothing);
          final request = h.api.reviews.single;
          await consentInit(t, request.target, action);
          await t.ensureVisible(find.byKey(const Key('init-confirm-submit')));
          await t.pumpAndSettle();
          expect(
            t
                .widget<FilledButton>(
                  find.byKey(const Key('init-confirm-submit')),
                )
                .onPressed,
            isNotNull,
          );
          await tapInit(t, 'init-review-cancel');
          expect(h.api.executes, isEmpty);
          expect(request.command?.isDisposed, isNot(false));
          expect(t.takeException(), isNull);
        });
      }
    }
  }
  for (final action in InitShutdownTasksAction.values) {
    for (final outcome in InitShutdownTasksOutcome.values) {
      testWidgets(
        'ordinary modal submit ${action.name} ${outcome.name} exactly once',
        (t) async {
          final fake = InitFake();
          fake.onExecute = (_, current) async {
            if (current()) fake.mutations++;
            return InitShutdownTasksResult(outcome, 'PRIVATE REMOTE');
          };
          final h = await pumpInit(t, fake: fake);
          await openInitReview(t, action);
          final request = fake.reviews.single;
          await consentInit(t, request.target, action);
          await tapInit(t, 'init-confirm-submit');
          expect(fake.executes, hasLength(1));
          expect(fake.mutations, 1);
          expect(fake.reads, 1);
          expect(request.command?.isDisposed, isNot(false));
          expect(find.textContaining('PRIVATE REMOTE'), findsNothing);
          expect(find.byKey(const Key('init-enablement-ring')), findsNothing);
          if (outcome == InitShutdownTasksOutcome.unknown) {
            expectLocked(h);
          } else {
            expectUnlocked(h);
            await tapInit(t, 'init-refresh-after-review');
            expect(fake.reads, 2);
          }
          expect(t.takeException(), isNull);
        },
      );
    }
  }
  for (final missing in ['impact', 'specific', 'body', 'budget', 'target']) {
    testWidgets('enable missing $missing cannot execute', (t) async {
      final h = await pumpInit(t);
      await openInitReview(t, InitShutdownTasksAction.enable);
      if (missing != 'target') {
        await enterInit(t, 'init-confirm-target', h.api.reviews.single.target);
      }
      for (final key in ['impact', 'specific', 'body', 'budget']) {
        if (key != missing) await tapInit(t, 'init-confirm-$key');
      }
      expect(
        t
            .widget<FilledButton>(find.byKey(const Key('init-confirm-submit')))
            .onPressed,
        isNull,
      );
      expect(h.api.executes, isEmpty);
      await tapInit(t, 'init-review-cancel');
    });
  }
  for (final phase in InitShutdownTaskPhase.values) {
    testWidgets(
      'inline ${phase.name} selection preserves typed command until handoff',
      (t) async {
        final h = await pumpInit(t);
        await openInitEditor(t, InitShutdownTasksAction.create, phase: phase);
        final field = t.widget<TextField>(
              find.byKey(const Key('init-command')),
            ),
            buffer = field.controller!;
        expect(field.obscureText, true);
        expect(field.enableSuggestions, false);
        expect(field.enableIMEPersonalizedLearning, false);
        expect(field.autofillHints, isEmpty);
        expect(buffer.text, initBody);
        await tapInit(t, 'init-editor-review');
        expect(buffer.text, isEmpty);
        expect(h.api.reviews.single.settings!.phase, phase);
        expect(find.textContaining(initBody), findsNothing);
        await tapInit(t, 'init-review-cancel');
      },
    );
  }
  for (final phase in ['editor', 'review']) {
    for (final cause in ['background', 'session', 'inventory', 'cover']) {
      testWidgets('$phase $cause clears actual private buffer and capsule', (
        t,
      ) async {
        final h = await pumpInit(t);
        if (phase == 'editor') {
          await openInitEditor(t, InitShutdownTasksAction.create);
        } else {
          await openInitReview(t, InitShutdownTasksAction.create);
          await consentInit(
            t,
            h.api.reviews.single.target,
            InitShutdownTasksAction.create,
          );
        }
        final field = phase == 'editor'
                ? 'init-command'
                : 'init-confirm-target',
            buffer = t.widget<TextField>(find.byKey(Key(field))).controller!;
        expect(buffer.text, isNotEmpty);
        final command = phase == 'review' ? h.api.reviews.single.command : null;
        NavigatorState? nav;
        if (cause == 'background') background(t);
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'inventory') {
          h.api.inventory = initInventory();
          h.container.invalidate(initShutdownTasksInventoryProvider);
        }
        if (cause == 'cover') {
          nav = Navigator.of(
            t.element(
              find.byType(
                phase == 'editor'
                    ? InitShutdownTasksEditorDialog
                    : InitShutdownTasksReviewDialog,
              ),
            ),
          );
          unawaited(
            nav.push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Other route')),
              ),
            ),
          );
        }
        await t.pumpAndSettle();
        expect(buffer.text, isEmpty);
        expect(command?.isDisposed, isNot(false));
        expect(h.api.executes, isEmpty);
        if (nav != null) {
          nav.pop();
          await t.pumpAndSettle();
        }
        expect(
          find.text(
            phase == 'editor' ? 'Task editor expired' : 'Task review expired',
          ),
          findsOneWidget,
        );
        await tapInit(
          t,
          phase == 'editor' ? 'init-editor-cancel' : 'init-review-cancel',
        );
        expect(t.takeException(), isNull);
      });
    }
  }
  for (final phase in ['review', 'execute']) {
    for (final cause in ['cover', 'background', 'session', 'inventory']) {
      testWidgets('held $phase $cause no late command authorization', (
        t,
      ) async {
        final h = await pumpInit(t), pending = Completer<void>();
        if (phase == 'review') {
          h.api.onReview = (r) async {
            await pending.future;
            return InitShutdownTasksReview(
              request: r,
              endpoint: r.inventory.endpoint,
              warnings: const [],
              commandReference: 'f' * 64,
            );
          };
        }
        if (phase == 'execute') {
          h.api.onExecute = (_, current) async {
            await pending.future;
            if (current()) h.api.mutations++;
            return const InitShutdownTasksResult(
              InitShutdownTasksOutcome.rejected,
              'late',
            );
          };
        }
        await openInitReview(
          t,
          InitShutdownTasksAction.create,
          settle: phase != 'review',
        );
        if (phase == 'execute') {
          await consentInit(
            t,
            h.api.reviews.single.target,
            InitShutdownTasksAction.create,
          );
          await tapInit(t, 'init-confirm-submit', settle: false);
        }
        final command = h.api.reviews.single.command;
        NavigatorState? nav;
        if (cause == 'background') background(t);
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'inventory') {
          h.api.inventory = initInventory();
          h.container.invalidate(initShutdownTasksInventoryProvider);
        }
        if (cause == 'cover') {
          nav = Navigator.of(t.element(find.byType(InitShutdownTasksPage)));
          unawaited(
            nav.push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Other route')),
              ),
            ),
          );
        }
        await t.pump();
        pending.complete();
        await t.pumpAndSettle();
        expect(h.api.mutations, 0);
        expect(command!.isDisposed, true);
        expect(find.byType(InitShutdownTasksReviewDialog), findsNothing);
        if (phase == 'execute') expectLocked(h);
        if (nav != null) {
          nav.pop();
          await t.pumpAndSettle();
        }
        expect(t.takeException(), isNull);
      });
    }
  }
  testWidgets('expiry destroys held command without execution', (t) async {
    final h = await pumpInit(t);
    await openInitReview(t, InitShutdownTasksAction.create);
    final c = h.api.reviews.single.command!;
    await consentInit(
      t,
      h.api.reviews.single.target,
      InitShutdownTasksAction.create,
    );
    final buffer = t
        .widget<TextField>(find.byKey(const Key('init-confirm-target')))
        .controller!;
    await t.pump(const Duration(minutes: 6));
    await t.pumpAndSettle();
    expect(buffer.text, isEmpty);
    expect(c.isDisposed, true);
    expect(h.api.executes, isEmpty);
    await tapInit(t, 'init-review-cancel');
  });
  testWidgets('empty task graph has no invented percentage or execution', (
    t,
  ) async {
    await pumpInit(
      t,
      fake: InitFake(inventory: initInventory(tasks: [])),
    );
    expect(
      find.textContaining('No configured tasks; no percentage'),
      findsOneWidget,
    );
    expect(
      find.textContaining('No configured lifecycle tasks.'),
      findsOneWidget,
    );
  });
  testWidgets('SCRIPT has no native action and no body or path display', (
    t,
  ) async {
    final h = await pumpInit(t);
    expect(find.text('Task #3'), findsOneWidget);
    expect(find.byKey(const Key('init-toggle-3')), findsNothing);
    expect(find.byKey(const Key('init-replace-3')), findsNothing);
    expect(h.api.executes, isEmpty);
  });
  testWidgets('enabled COMMAND cannot be replaced or deleted implicitly', (
    t,
  ) async {
    await pumpInit(t);
    expect(
      t
          .widget<OutlinedButton>(find.byKey(const Key('init-replace-2')))
          .onPressed,
      isNull,
    );
    expect(
      t.widget<TextButton>(find.byKey(const Key('init-delete-2'))).onPressed,
      isNull,
    );
  });
  for (final budget in [0, 301]) {
    testWidgets('legacy wait budget $budget display-only enable gate', (
      t,
    ) async {
      await pumpInit(
        t,
        fake: InitFake(
          inventory: initInventory(
            tasks: [
              InitShutdownTaskSnapshot(
                id: 1,
                type: 'COMMAND',
                phase: InitShutdownTaskPhase.shutdown,
                enabled: false,
                timeoutSeconds: budget,
              ),
            ],
          ),
        ),
      );
      expect(
        t
            .widget<OutlinedButton>(find.byKey(const Key('init-toggle-1')))
            .onPressed,
        isNull,
      );
      expect(
        t.widget<TextButton>(find.byKey(const Key('init-delete-1'))).onPressed,
        isNotNull,
      );
    });
  }
  for (final item in <String, InitShutdownTasksInventory>{
    'HA': initInventory(ha: true),
    'admin': initInventory(admin: false),
    'jobs': initInventory(jobs: true),
    'boot': initInventory(healthy: false),
    'state': initInventory(state: 'BOOTING'),
  }.entries) {
    testWidgets('${item.key} visible readonly reason', (t) async {
      final h = await pumpInit(t, fake: InitFake(inventory: item.value));
      expect(find.text(item.value.blockedReason!), findsOneWidget);
      expect(
        t
            .widget<OutlinedButton>(find.byKey(const Key('init-create')))
            .onPressed,
        isNull,
      );
      expect(h.api.executes, isEmpty);
    });
  }
  testWidgets('bad command and wait budget cannot open review', (t) async {
    await pumpInit(t);
    await tapInit(t, 'init-create');
    await enterInit(t, 'init-command', '********');
    await enterInit(t, 'init-timeout', '0');
    expect(
      t
          .widget<FilledButton>(find.byKey(const Key('init-editor-review')))
          .onPressed,
      isNull,
    );
    await tapInit(t, 'init-editor-cancel');
  });
  testWidgets('disconnected never loads or mutates', (t) async {
    final h = await pumpInit(t, disconnected: true);
    expect(h.api.reads, 0);
    expect(find.text('Task configuration unavailable'), findsOneWidget);
  });
  testWidgets('read error details withheld and retry explicit', (t) async {
    final h = await pumpInit(
      t,
      fake: InitFake()..onLoad = () async => throw StateError(initBody),
    );
    expect(find.textContaining(initBody), findsNothing);
    expect(find.byKey(const Key('init-retry')), findsOneWidget);
    expect(h.api.executes, isEmpty);
  });
}
