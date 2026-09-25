import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/alert_policies/alert_policies_controller.dart';
import 'package:trueraid/features/alert_policies/alert_policies_page.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'alert_policies_fakes.dart';

Future<PoliciesHarness> pumpPolicies(
  WidgetTester tester, {
  PoliciesFake? fake,
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
  final h = PoliciesHarness(fake: fake);
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
        home: const AlertPoliciesPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapPolicy(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  if (finder.evaluate().isEmpty) {
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find.byType(Scrollable).first,
      maxScrolls: 40,
    );
  }
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> enterPolicy(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> openReview(
  WidgetTester tester, {
  bool reset = false,
  bool never = false,
  bool support = false,
}) async {
  await tapPolicy(tester, 'policy-class-DiskTemp');
  await tapPolicy(
    tester,
    reset ? 'policy-reset-DiskTemp' : 'policy-edit-DiskTemp',
  );
  if (!reset) {
    await tapPolicy(tester, 'policy-level-error');
    if (never) await tapPolicy(tester, 'policy-frequency-never');
    if (support) await tapPolicy(tester, 'policy-support-true');
  }
  if (reset || support) {
    await tapPolicy(tester, 'policy-editor-support-consent');
  }
  await tapPolicy(tester, 'policy-editor-review');
  expect(find.text('Review alert policy'), findsOneWidget);
}

Future<void> confirm(
  WidgetTester tester,
  PoliciesHarness h, {
  bool never = false,
  bool support = false,
}) async {
  await enterPolicy(tester, 'policy-confirm-target', h.api.reviews.last.target);
  await tapPolicy(tester, 'policy-confirm-impact');
  if (never) await tapPolicy(tester, 'policy-confirm-visibility');
  if (support) await tapPolicy(tester, 'policy-confirm-support');
  await tapPolicy(tester, 'policy-confirm-submit');
}

void main() {
  for (final dark in [false, true]) {
    for (final width in [360.0, 800.0]) {
      for (final scale in [1.0, 2.0]) {
        testWidgets('configuration charts/layout $dark/$width/$scale', (
          tester,
        ) async {
          final h = await pumpPolicies(
            tester,
            dark: dark,
            width: width,
            scale: scale,
          );
          if (find
              .byKey(const Key('policy-override-ring'))
              .evaluate()
              .isEmpty) {
            await tester.scrollUntilVisible(
              find.byKey(const Key('policy-override-ring')),
              300,
              scrollable: find.byType(Scrollable).first,
            );
          }
          expect(find.byKey(const Key('policy-override-ring')), findsOneWidget);
          expect(find.text('Policy HOURLY: 1'), findsOneWidget);
          expect(h.api.reads, 1);
          expect(h.api.executes, isEmpty);
          expect(tester.takeException(), isNull);
          await enterPolicy(tester, 'policy-filter', 'not-present');
          expect(find.text('No classes match this filter.'), findsOneWidget);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }
  for (final mode in ['configure', 'reset', 'never', 'support']) {
    testWidgets('$mode through normal closing modals dispatches once', (
      tester,
    ) async {
      final h = await pumpPolicies(tester);
      await openReview(
        tester,
        reset: mode == 'reset',
        never: mode == 'never',
        support: mode == 'support',
      );
      expect(h.api.executes, isEmpty);
      expect(find.text('Policy review expired'), findsNothing);
      await tapPolicy(tester, 'policy-review-details');
      expect(find.text('Policy review expired'), findsNothing);
      await confirm(
        tester,
        h,
        never: mode == 'never',
        support: mode == 'reset' || mode == 'support',
      );
      expect(h.api.executes, hasLength(1));
      expect(h.api.mutations, 1);
      expect(
        h.container.read(alertPoliciesControllerProvider).status,
        AlertPoliciesStatus.completed,
      );
      expect(tester.takeException(), isNull);
    });
  }
  testWidgets('empty class inventory has readable no-data state', (
    tester,
  ) async {
    await pumpPolicies(
      tester,
      fake: PoliciesFake(inventory: policiesInventory(classes: const [])),
    );
    expect(find.text('No editable alert classes'), findsOneWidget);
    expect(
      find.text(
        'No listed classes; no percentages or delivery status inferred.',
      ),
      findsOneWidget,
    );
    expect(tester.takeException(), isNull);
  });
  testWidgets('failed read withheld and no automatic retry', (tester) async {
    final fake = PoliciesFake()
      ..onLoad = () => Future.error(StateError('PRIVATE_REMOTE_ERROR'));
    final h = await pumpPolicies(tester, fake: fake);
    expect(find.text('Policy configuration unavailable'), findsOneWidget);
    expect(find.textContaining('PRIVATE_REMOTE_ERROR'), findsNothing);
    await tester.pump(const Duration(seconds: 20));
    expect(h.api.reads, 1);
  });
  testWidgets('disconnected view never calls SDK', (tester) async {
    final h = await pumpPolicies(tester, disconnected: true);
    expect(h.api.reads, 0);
    expect(h.api.reviews, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('read-only inventory renders but actions disabled', (
    tester,
  ) async {
    final h = await pumpPolicies(
      tester,
      fake: PoliciesFake(inventory: policiesInventory(admin: false)),
    );
    await tapPolicy(tester, 'policy-class-DiskTemp');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('policy-edit-DiskTemp')))
          .onPressed,
      isNull,
    );
    expect(h.api.reviews, isEmpty);
  });
  testWidgets(
    'support reset cannot proceed without eligibility or disclosure',
    (tester) async {
      final h = await pumpPolicies(
        tester,
        fake: PoliciesFake(
          inventory: policiesInventory(available: false, enabled: false),
        ),
      );
      await tapPolicy(tester, 'policy-class-DiskTemp');
      await tapPolicy(tester, 'policy-reset-DiskTemp');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('policy-editor-review')))
            .onPressed,
        isNull,
      );
      await tapPolicy(tester, 'policy-editor-support-consent');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('policy-editor-review')))
            .onPressed,
        isNull,
      );
      expect(h.api.reviews, isEmpty);
      await tapPolicy(tester, 'policy-editor-cancel');
    },
  );
  testWidgets('severity edit remains usable when support eligibility unknown', (
    tester,
  ) async {
    final h = await pumpPolicies(
      tester,
      fake: PoliciesFake(
        inventory: policiesInventory(available: null, enabled: null),
      ),
    );
    await openReview(tester);
    await confirm(tester, h);
    expect(h.api.mutations, 1);
  });
  testWidgets('NEVER and proactive require separate final checkboxes', (
    tester,
  ) async {
    final h = await pumpPolicies(tester);
    await openReview(tester, never: true, support: true);
    await enterPolicy(
      tester,
      'policy-confirm-target',
      h.api.reviews.last.target,
    );
    await tapPolicy(tester, 'policy-confirm-impact');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('policy-confirm-submit')))
          .onPressed,
      isNull,
    );
    await tapPolicy(tester, 'policy-confirm-visibility');
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('policy-confirm-submit')))
          .onPressed,
      isNull,
    );
    await tapPolicy(tester, 'policy-confirm-support');
    await tapPolicy(tester, 'policy-confirm-submit');
    expect(h.api.mutations, 1);
  });
  for (final phase in ['editor', 'review']) {
    for (final cause in ['background', 'session', 'cover']) {
      testWidgets('$phase $cause expires without write', (tester) async {
        final h = await pumpPolicies(tester);
        if (phase == 'editor') {
          await tapPolicy(tester, 'policy-class-DiskTemp');
          await tapPolicy(tester, 'policy-edit-DiskTemp');
          await tapPolicy(tester, 'policy-level-error');
        } else {
          await openReview(tester);
        }
        if (cause == 'background') {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          await tester.pump();
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        } else if (cause == 'session') {
          h.select(h.newSession());
        } else {
          final context = tester.element(
            find.byKey(
              Key(
                phase == 'editor'
                    ? 'policy-editor-review'
                    : 'policy-confirm-submit',
              ),
            ),
          );
          final navigator = Navigator.of(context);
          unawaited(
            navigator.push(
              MaterialPageRoute<void>(
                builder: (_) => const Scaffold(body: Text('Covered route')),
              ),
            ),
          );
          await tester.pumpAndSettle();
          navigator.pop();
        }
        await tester.pumpAndSettle();
        expect(h.api.executes, isEmpty);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(
                  Key(
                    phase == 'editor'
                        ? 'policy-editor-review'
                        : 'policy-confirm-submit',
                  ),
                ),
              )
              .onPressed,
          isNull,
        );
        expect(tester.takeException(), isNull);
        await tapPolicy(
          tester,
          phase == 'editor' ? 'policy-editor-cancel' : 'policy-review-cancel',
        );
      });
    }
  }
  testWidgets('review timeout expires and no popup controls required', (
    tester,
  ) async {
    final h = await pumpPolicies(tester);
    await openReview(tester);
    await tester.pump(const Duration(minutes: 5));
    await tester.pumpAndSettle();
    expect(find.text('Policy review expired'), findsOneWidget);
    expect(h.api.executes, isEmpty);
    await tapPolicy(tester, 'policy-review-cancel');
  });
  testWidgets('keyboard and large text keep review scrollable', (tester) async {
    final h = await pumpPolicies(tester, width: 360, scale: 2, keyboard: 280);
    await openReview(tester, never: true);
    await confirm(tester, h, never: true);
    expect(h.api.mutations, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('uncertain result persists lock across leaving route', (
    tester,
  ) async {
    final fake = PoliciesFake()
      ..onExecute = (_, _) async =>
          const AlertPoliciesResult(AlertPoliciesOutcome.unknown, 'PRIVATE');
    final h = await pumpPolicies(tester, fake: fake);
    await openReview(tester);
    await confirm(tester, h);
    expect(find.text('Inspect the original server'), findsOneWidget);
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    expect(find.textContaining('PRIVATE'), findsNothing);
    expect(h.api.executes, hasLength(1));
  });
}
