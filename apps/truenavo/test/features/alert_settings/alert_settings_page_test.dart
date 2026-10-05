import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/alert_settings/alert_settings_controller.dart';
import 'package:truenavo/features/alert_settings/alert_settings_editor.dart';
import 'package:truenavo/features/alert_settings/alert_settings_page.dart';
import 'package:truenavo/features/alert_settings/alert_settings_review.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'alert_settings_fakes.dart';

Future<AlertHarness> pumpAlert(
  WidgetTester tester, {
  AlertFake? fake,
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
  final h = AlertHarness(fake: fake);
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
        home: const AlertSettingsPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapAlert(
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

Future<void> enterAlert(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> openAlertEditor(
  WidgetTester tester,
  AlertSettingsAction action,
) async {
  await tapAlert(
    tester,
    action == AlertSettingsAction.createEmail ? 'alert-create' : 'alert-edit-1',
  );
  await enterAlert(tester, 'alert-name', 'Reviewed alerts');
  await enterAlert(tester, 'alert-recipient', 'reviewed@example.test');
  await tapAlert(tester, 'alert-level-critical');
}

Future<void> openAlertReview(
  WidgetTester tester,
  AlertSettingsAction action, {
  bool settle = true,
}) async {
  if (action == AlertSettingsAction.createEmail ||
      action == AlertSettingsAction.editEmail) {
    await openAlertEditor(tester, action);
    await tapAlert(tester, 'alert-editor-review', settle: settle);
  } else {
    await tapAlert(tester, switch (action) {
      AlertSettingsAction.enableEmail => 'alert-toggle-1',
      AlertSettingsAction.disableEmail => 'alert-toggle-2',
      _ => 'alert-delete-1',
    }, settle: settle);
  }
}

Future<void> consentAlert(
  WidgetTester tester,
  String target,
  AlertSettingsAction action,
) async {
  await enterAlert(tester, 'alert-confirm-target', target);
  await tapAlert(tester, 'alert-confirm-impact');
  if (action != AlertSettingsAction.createEmail &&
      action != AlertSettingsAction.editEmail) {
    await tapAlert(tester, 'alert-confirm-specific');
  }
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

void expectLocked(AlertHarness h) =>
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
void expectUnlocked(AlertHarness h) {
  final lock = h.container.read(serverOperationLockProvider),
      owner = lock.acquire();
  expect(owner, isNotNull);
  lock.release(owner!);
}

void main() {
  testWidgets('opening has configuration-only charts and no mutation or test', (
    tester,
  ) async {
    final h = await pumpAlert(tester, width: 430);
    expect(h.api.reads, 1);
    expect(h.api.reviews, isEmpty);
    expect(h.api.executes, isEmpty);
    expect(h.api.mutations, 0);
    expect(
      find.text('Configured services only — not delivery measurements.'),
      findsOneWidget,
    );
    expect(find.byKey(const Key('alert-enablement-ring')), findsOneWidget);
    expect(
      tester.getBottomLeft(find.byKey(const Key('alert-enablement-ring'))).dy,
      lessThan(1000),
    );
    expect(find.text('2 Enabled'), findsOneWidget);
    expect(find.text('1 Disabled'), findsOneWidget);
    expect(find.text('Provider · Mail: 2'), findsOneWidget);
    expect(find.text('Threshold · CRITICAL: 1'), findsOneWidget);
    final thresholdLabels = tester
        .widgetList<Text>(find.byType(Text))
        .map((text) => text.data)
        .whereType<String>()
        .where((text) => text.startsWith('Threshold ·'))
        .toList();
    expect(thresholdLabels, [
      'Threshold · WARNING: 1',
      'Threshold · ERROR: 1',
      'Threshold · CRITICAL: 1',
    ]);
    expect(find.text(alertHost), findsNothing);
    await tapAlert(tester, 'alert-readiness-details');
    expect(find.text(alertHost), findsOneWidget);
    await tapAlert(tester, 'alert-scope-details');
    expect(
      find.textContaining('Other independent default alert mail may continue.'),
      findsOneWidget,
    );
    expect(h.api.reads, 1);
    expect(h.api.executes, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets('empty chart infers neither percentage nor global disabled mail', (
    tester,
  ) async {
    final h = await pumpAlert(
      tester,
      fake: AlertFake(inventory: alertInventory(services: const [])),
    );
    expect(
      find.text(
        'No configured services; no percentage or delivery status is inferred.',
      ),
      findsOneWidget,
    );
    expect(
      find.text('No configured provider or threshold counts.'),
      findsOneWidget,
    );
    expect(
      find.textContaining(
        'This does not mean all TrueNAS alert mail is disabled.',
      ),
      findsOneWidget,
    );
    expect(h.api.mutations, 0);
  });
  testWidgets('disconnected performs no reads', (tester) async {
    final h = await pumpAlert(tester, disconnected: true);
    expect(h.api.reads, 0);
    expect(find.text('Notification configuration unavailable'), findsOneWidget);
    expect(find.byKey(const Key('alert-create')), findsNothing);
  });
  for (final entry in <String, AlertSettingsInventory>{
    'readonly': alertInventory(admin: false),
    'HA': alertInventory(ha: true),
    'busy': alertInventory(jobs: true),
  }.entries) {
    testWidgets('${entry.key} keeps charts but disables writes', (
      tester,
    ) async {
      final h = await pumpAlert(
        tester,
        fake: AlertFake(inventory: entry.value),
      );
      expect(find.byKey(const Key('alert-enablement-ring')), findsOneWidget);
      for (final key in [
        'alert-create',
        'alert-edit-1',
        'alert-toggle-1',
        'alert-toggle-2',
      ]) {
        expect(
          tester.widget<OutlinedButton>(find.byKey(Key(key))).onPressed,
          isNull,
        );
      }
      expect(
        tester
            .widget<TextButton>(find.byKey(const Key('alert-delete-1')))
            .onPressed,
        isNull,
      );
      expect(h.api.executes, isEmpty);
    });
  }
  testWidgets('non-Mail provider metadata is readonly without attributes', (
    tester,
  ) async {
    final h = await pumpAlert(tester);
    expect(find.text('Service 3 · Slack · Enabled'), findsOneWidget);
    expect(find.byKey(const Key('alert-edit-3')), findsNothing);
    expect(
      find.textContaining('No credentials, provider test or conversion'),
      findsOneWidget,
    );
    expect(h.api.executes, isEmpty);
  });
  for (final recipient in ['', 'one@example.test,two@example.test']) {
    testWidgets(
      'legacy recipient $recipient can be disabled or repaired without implicit enable',
      (tester) async {
        final h = await pumpAlert(
          tester,
          fake: AlertFake(
            inventory: alertInventory(
              services: [
                AlertServiceSnapshot(
                  id: 1,
                  name: 'Legacy disabled',
                  type: 'Mail',
                  level: AlertDeliveryLevel.warning,
                  enabled: false,
                  recipient: recipient,
                  emailAttributesSupported: true,
                ),
                AlertServiceSnapshot(
                  id: 2,
                  name: 'Legacy enabled',
                  type: 'Mail',
                  level: AlertDeliveryLevel.warning,
                  enabled: true,
                  recipient: recipient,
                  emailAttributesSupported: true,
                ),
              ],
            ),
          ),
        );
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(const Key('alert-toggle-1')))
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(const Key('alert-toggle-2')))
              .onPressed,
          isNotNull,
        );
        expect(
          tester
              .widget<OutlinedButton>(find.byKey(const Key('alert-edit-1')))
              .onPressed,
          isNotNull,
        );
        await openAlertReview(tester, AlertSettingsAction.disableEmail);
        expect(find.text(alertNoRecallWarning), findsOneWidget);
        expect(h.api.executes, isEmpty);
        await tapAlert(tester, 'alert-review-cancel');
      },
    );
  }
  testWidgets('failed read hides raw details and explicit retry recovers', (
    tester,
  ) async {
    final fake = AlertFake()
      ..onLoad = () async => throw StateError('PRIVATE-ALERT');
    final h = await pumpAlert(tester, fake: fake);
    expect(find.textContaining('PRIVATE-ALERT'), findsNothing);
    expect(
      find.text('Notification configuration could not be verified'),
      findsOneWidget,
    );
    fake.onLoad = null;
    await tapAlert(tester, 'alert-retry');
    expect(h.api.reads, 2);
    expect(find.byKey(const Key('alert-enablement-ring')), findsOneWidget);
  });
  for (final action in AlertSettingsAction.values) {
    testWidgets(
      '${action.name} exact target and independent consent gates one fake write',
      (tester) async {
        final h = await pumpAlert(tester);
        await openAlertReview(tester, action);
        final dialog = tester.widget<AlertSettingsReviewDialog>(
              find.byType(AlertSettingsReviewDialog),
            ),
            target = dialog.review.target;
        expect(h.api.executes, isEmpty);
        expect(find.text(alertSettingsImpact(action)), findsOneWidget);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('alert-confirm-submit')),
              )
              .onPressed,
          isNull,
        );
        await enterAlert(tester, 'alert-confirm-target', target);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('alert-confirm-submit')),
              )
              .onPressed,
          isNull,
        );
        await tapAlert(tester, 'alert-confirm-impact');
        if (action != AlertSettingsAction.createEmail &&
            action != AlertSettingsAction.editEmail) {
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const Key('alert-confirm-submit')),
                )
                .onPressed,
            isNull,
          );
          await tapAlert(tester, 'alert-confirm-specific');
        }
        await tapAlert(tester, 'alert-confirm-submit');
        expect(h.api.executes, hasLength(1));
        expect(h.api.mutations, 1);
        expectUnlocked(h);
        expect(
          find.text('Configuration verified — delivery not established'),
          findsOneWidget,
        );
        expect(find.byKey(const Key('alert-enablement-ring')), findsNothing);
        expect(h.api.reads, 1);
        await tapAlert(tester, 'alert-refresh-after-review');
        expect(h.api.reads, 2);
        expect(find.byKey(const Key('alert-enablement-ring')), findsOneWidget);
      },
    );
  }
  testWidgets(
    'editor inline threshold selection and validation never covers its route',
    (tester) async {
      final h = await pumpAlert(tester);
      await tapAlert(tester, 'alert-create');
      for (final level in AlertDeliveryLevel.values) {
        await tapAlert(tester, 'alert-level-${level.name}');
        expect(find.text('Notification-service editor expired'), findsNothing);
      }
      await enterAlert(tester, 'alert-name', 'Reviewed alerts');
      await enterAlert(
        tester,
        'alert-recipient',
        'one@example.test,two@example.test',
      );
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('alert-editor-review')))
            .onPressed,
        isNull,
      );
      await enterAlert(tester, 'alert-recipient', 'reviewed@example.test');
      await tapAlert(tester, 'alert-editor-review');
      expect(
        h.api.reviews.single.settings!.level,
        AlertDeliveryLevel.emergency,
      );
      expect(h.api.executes, isEmpty);
      await tapAlert(tester, 'alert-review-cancel');
    },
  );
  for (final cause in ['session', 'background', 'route', 'cancel']) {
    testWidgets(
      'editor $cause clears actual recipient input and prevents handoff',
      (tester) async {
        final h = await pumpAlert(tester);
        await openAlertEditor(tester, AlertSettingsAction.createEmail);
        final field = tester
            .widget<TextField>(find.byKey(const Key('alert-recipient')))
            .controller!;
        expect(field.text, 'reviewed@example.test');
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background(tester);
        if (cause == 'route') {
          Navigator.of(tester.element(find.byType(AlertSettingsEditorDialog)))
              .push(
                MaterialPageRoute<void>(
                  builder: (_) => const Scaffold(body: Text('Covered route')),
                ),
              );
        }
        if (cause == 'cancel') await tapAlert(tester, 'alert-editor-cancel');
        await tester.pumpAndSettle();
        if (cause != 'cancel') expect(field.text, isEmpty);
        expect(h.api.reviews, isEmpty);
        expect(h.api.executes, isEmpty);
        expect(tester.takeException(), isNull);
      },
    );
  }
  for (final cause in [
    'session',
    'background',
    'inventory',
    'route',
    'timeout',
  ]) {
    testWidgets('review $cause expires confirmation permanently', (
      tester,
    ) async {
      final h = await pumpAlert(tester);
      await openAlertReview(tester, AlertSettingsAction.enableEmail);
      final r = tester
          .widget<AlertSettingsReviewDialog>(
            find.byType(AlertSettingsReviewDialog),
          )
          .review;
      await consentAlert(tester, r.target, r.action);
      final targetField = tester
          .widget<TextField>(find.byKey(const Key('alert-confirm-target')))
          .controller!;
      if (cause == 'session') {
        h.select(h.newSession());
        h.select(h.session);
      }
      if (cause == 'background') background(tester);
      if (cause == 'inventory') {
        h.api.inventory = alertInventory();
        h.container.invalidate(alertSettingsInventoryProvider);
      }
      if (cause == 'route') {
        final navigator = Navigator.of(
          tester.element(find.byType(AlertSettingsReviewDialog)),
        );
        navigator.push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Covered route')),
          ),
        );
        await tester.pumpAndSettle();
        navigator.pop();
      }
      if (cause == 'timeout') await tester.pump(const Duration(minutes: 5));
      await tester.pumpAndSettle();
      expect(find.text('Notification-service review expired'), findsOneWidget);
      expect(targetField.text, isEmpty);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('alert-confirm-submit')))
            .onPressed,
        isNull,
      );
      expect(h.api.executes, isEmpty);
      await tapAlert(tester, 'alert-review-cancel');
    });
  }
  for (final stage in ['review', 'execute']) {
    testWidgets(
      'covering page during held $stage prevents late fake mutation',
      (tester) async {
        final h = await pumpAlert(tester),
            heldReview = Completer<AlertSettingsReview>(),
            heldExecute = Completer<void>();
        if (stage == 'review') h.api.onReview = (_) => heldReview.future;
        h.api.onExecute = (_, current) async {
          await heldExecute.future;
          if (current()) h.api.mutations++;
          return const AlertSettingsResult(
            AlertSettingsOutcome.rejected,
            'stale',
          );
        };
        await openAlertReview(
          tester,
          AlertSettingsAction.enableEmail,
          settle: stage != 'review',
        );
        if (stage == 'execute') {
          final r = tester
              .widget<AlertSettingsReviewDialog>(
                find.byType(AlertSettingsReviewDialog),
              )
              .review;
          await consentAlert(tester, r.target, r.action);
          await tapAlert(tester, 'alert-confirm-submit', settle: false);
        }
        Navigator.of(tester.element(find.byType(AlertSettingsPage))).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Covered route')),
          ),
        );
        if (stage == 'review') {
          heldReview.complete(
            AlertSettingsReview(
              request: h.api.reviews.single,
              endpoint: alertEndpoint,
              warnings: const [],
            ),
          );
        }
        if (stage == 'execute') heldExecute.complete();
        await tester.pumpAndSettle();
        expect(h.api.mutations, 0);
        expect(find.byType(AlertSettingsReviewDialog), findsNothing);
        if (stage == 'execute') expectLocked(h);
      },
    );
  }
  for (final stage in ['review', 'execute']) {
    testWidgets(
      'normal modal close permits held $stage without expiring authorization',
      (tester) async {
        final h = await pumpAlert(tester),
            heldReview = Completer<AlertSettingsReview>(),
            heldExecute = Completer<void>();
        if (stage == 'review') h.api.onReview = (_) => heldReview.future;
        if (stage == 'execute') {
          h.api.onExecute = (_, current) async {
            await heldExecute.future;
            expect(current(), isTrue);
            h.api.mutations++;
            return const AlertSettingsResult(
              AlertSettingsOutcome.completed,
              'verified',
            );
          };
        }
        await openAlertReview(
          tester,
          AlertSettingsAction.createEmail,
          settle: stage != 'review',
        );
        if (stage == 'review') {
          await tester.pump(const Duration(milliseconds: 400));
          heldReview.complete(
            AlertSettingsReview(
              request: h.api.reviews.single,
              endpoint: alertEndpoint,
              warnings: const [],
            ),
          );
          await tester.pumpAndSettle();
        }
        final r = tester
            .widget<AlertSettingsReviewDialog>(
              find.byType(AlertSettingsReviewDialog),
            )
            .review;
        await consentAlert(tester, r.target, r.action);
        await tapAlert(
          tester,
          'alert-confirm-submit',
          settle: stage != 'execute',
        );
        if (stage == 'execute') {
          await tester.pump(const Duration(milliseconds: 400));
          heldExecute.complete();
          await tester.pumpAndSettle();
        }
        expect(h.api.executes, hasLength(1));
        expect(h.api.mutations, 1);
        expectUnlocked(h);
        expect(
          find.text('Configuration verified — delivery not established'),
          findsOneWidget,
        );
      },
    );
  }
  testWidgets(
    'unmounting unresolved page preserves global fence and never replays',
    (tester) async {
      final fake = AlertFake()
        ..onExecute = (_, _) async =>
            const AlertSettingsResult(AlertSettingsOutcome.unknown, 'unknown');
      final h = await pumpAlert(tester, fake: fake);
      await openAlertReview(tester, AlertSettingsAction.enableEmail);
      final r = tester
          .widget<AlertSettingsReviewDialog>(
            find.byType(AlertSettingsReviewDialog),
          )
          .review;
      await consentAlert(tester, r.target, r.action);
      await tapAlert(tester, 'alert-confirm-submit');
      await tester.pumpWidget(const SizedBox());
      await tester.pump();
      expectLocked(h);
      expect(h.api.executes, hasLength(1));
      expect(h.api.reads, 1);
      expect(
        h.container.read(alertSettingsControllerProvider).unresolved,
        isTrue,
      );
    },
  );
  for (final outcome in AlertSettingsOutcome.values) {
    testWidgets(
      'confirmed $outcome result reaches controller exactly once without automatic reads',
      (tester) async {
        final fake = AlertFake()
          ..onExecute = (_, _) async =>
              AlertSettingsResult(outcome, 'PRIVATE-ALERT');
        final h = await pumpAlert(tester, fake: fake);
        await openAlertReview(tester, AlertSettingsAction.enableEmail);
        final r = tester
            .widget<AlertSettingsReviewDialog>(
              find.byType(AlertSettingsReviewDialog),
            )
            .review;
        await consentAlert(tester, r.target, r.action);
        await tapAlert(tester, 'alert-confirm-submit');
        expect(h.api.executes, hasLength(1));
        expect(h.api.reads, 1);
        expect(find.textContaining('PRIVATE-ALERT'), findsNothing);
        if (outcome == AlertSettingsOutcome.unknown) {
          expectLocked(h);
        } else {
          expectUnlocked(h);
        }
        expect(find.byKey(const Key('alert-enablement-ring')), findsNothing);
      },
    );
  }
  testWidgets(
    'unknown requires explicit same-host recovery and never replays',
    (tester) async {
      final fake = AlertFake()
        ..onExecute = (_, _) async =>
            const AlertSettingsResult(AlertSettingsOutcome.unknown, 'unknown');
      final h = await pumpAlert(tester, fake: fake);
      await openAlertReview(tester, AlertSettingsAction.enableEmail);
      final r = tester
          .widget<AlertSettingsReviewDialog>(
            find.byType(AlertSettingsReviewDialog),
          )
          .review;
      await consentAlert(tester, r.target, r.action);
      await tapAlert(tester, 'alert-confirm-submit');
      expectLocked(h);
      h.select(h.newSession());
      await tester.pumpAndSettle();
      expect(h.api.reads, 1);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('alert-acknowledge')))
            .onPressed,
        isNull,
      );
      await tapAlert(tester, 'alert-verify-reconnected');
      expect(h.api.reads, 2);
      expectLocked(h);
      await tapAlert(tester, 'alert-acknowledge');
      expectUnlocked(h);
      expect(h.api.executes, hasLength(1));
      expect(
        find.textContaining('prior operation remains unverified'),
        findsOneWidget,
      );
    },
  );
  for (final width in [320.0, 430.0, 1100.0]) {
    for (final dark in [false, true]) {
      testWidgets('dashboard $width dark=$dark 200% details and charts fit', (
        tester,
      ) async {
        await pumpAlert(tester, width: width, dark: dark, scale: 2);
        await tapAlert(tester, 'alert-readiness-details');
        await tapAlert(tester, 'alert-scope-details');
        await tester.ensureVisible(find.byKey(const Key('alert-delete-1')));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
      });
      for (final action in AlertSettingsAction.values) {
        testWidgets(
          '${action.name} $width dark=$dark 200% keyboard inline detail expansion preserves confirmation',
          (tester) async {
            final h = await pumpAlert(
              tester,
              width: width,
              dark: dark,
              scale: 2,
              keyboard: 300,
            );
            await openAlertReview(tester, action);
            final r = tester
                .widget<AlertSettingsReviewDialog>(
                  find.byType(AlertSettingsReviewDialog),
                )
                .review;
            expect(
              find.text(
                'Synthetic supplemental details. No live provider or SMTP contact.',
              ),
              findsNothing,
            );
            await tapAlert(tester, 'alert-review-details');
            expect(
              find.text(
                'Synthetic supplemental details. No live provider or SMTP contact.',
              ),
              findsOneWidget,
            );
            expect(
              h.container
                  .read(alertSettingsControllerProvider.notifier)
                  .isReviewCurrent(r),
              isTrue,
            );
            await tapAlert(tester, 'alert-review-details');
            expect(find.text(alertSettingsImpact(action)), findsOneWidget);
            await consentAlert(tester, r.target, action);
            await tapAlert(tester, 'alert-confirm-submit');
            expect(h.api.executes, hasLength(1));
            expect(h.api.mutations, 1);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
