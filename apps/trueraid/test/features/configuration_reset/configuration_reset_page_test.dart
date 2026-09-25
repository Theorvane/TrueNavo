import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/configuration_reset/configuration_reset_controller.dart';
import 'package:trueraid/features/configuration_reset/configuration_reset_page.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'configuration_reset_fakes.dart';

Future<ResetHarness> pumpReset(
  WidgetTester tester, {
  ResetFake? fake,
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
  final h = ResetHarness(fake: fake);
  addTearDown(h.dispose);
  if (disconnected) {
    h.select(null);
  } else {
    try {
      await h.load();
    } on Object {
      /* Fixed UI. */
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
        home: const ConfigurationResetPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapReset(
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

Future<void> enterReset(WidgetTester tester, String text) async {
  final finder = find.byKey(const Key('reset-confirm-target'));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, text);
  await tester.pumpAndSettle();
}

Future<void> consentReset(WidgetTester tester, String target) async {
  await enterReset(tester, target);
  for (var i = 0; i < 6; i++) {
    await tapReset(tester, 'reset-confirm-ack-$i');
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

void main() {
  testWidgets(
    'opening only reads public readiness and gives loss, staged restore and no secure erasure warnings',
    (tester) async {
      final h = await pumpReset(tester);
      expect(h.api.reads, 1);
      expect(h.api.reviews, isEmpty);
      expect(h.api.executes, isEmpty);
      expect(
        find.text('Destructive configuration replacement'),
        findsOneWidget,
      );
      expect(find.textContaining('not secure erasure'), findsOneWidget);
      expect(
        find.textContaining('previously staged restore can supersede'),
        findsOneWidget,
      );
      expect(find.text('Boot identity'), findsOneWidget);
      expect(find.text(resetHost), findsOneWidget);
      expect(
        find.textContaining('Automatic reboot is fixed on'),
        findsOneWidget,
      );
    },
  );
  testWidgets('disconnected page reads nothing and has no enabled reset', (
    tester,
  ) async {
    final h = await pumpReset(tester, disconnected: true);
    expect(h.api.reads, 0);
    expect(find.text('Factory reset unavailable'), findsOneWidget);
    expect(find.byKey(const Key('reset-review')), findsNothing);
  });
  testWidgets('unsupported capabilities prevent native action', (tester) async {
    final h = await pumpReset(
      tester,
      fake: ResetFake(
        caps: const ConfigurationResetCapabilities(
          connected: true,
          versionSupported: false,
          available: true,
        ),
      ),
    );
    expect(find.text('Factory reset unavailable'), findsOneWidget);
    expect(find.byKey(const Key('reset-review')), findsNothing);
    expect(h.api.executes, isEmpty);
  });
  for (final entry in <String, ConfigurationResetInventory>{
    'HA': resetInventory(ha: true),
    'admin': resetInventory(admin: false),
    'jobs': resetInventory(jobs: true),
    'boot': resetInventory(healthy: false),
    'state': resetInventory(state: 'BOOTING'),
    'nextboot': resetInventory(nextChanged: true),
  }.entries) {
    testWidgets('${entry.key} readiness displays a disabled review', (
      tester,
    ) async {
      final h = await pumpReset(
        tester,
        fake: ResetFake(inventory: entry.value),
      );
      expect(find.text('Factory reset blocked'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('reset-review')))
            .onPressed,
        isNull,
      );
      expect(h.api.reviews, isEmpty);
    });
  }
  testWidgets(
    'failed readiness hides raw server details and retry is explicit',
    (tester) async {
      final fake = ResetFake()
        ..onLoad = () async => throw StateError('PRIVATE-RESET');
      final h = await pumpReset(tester, fake: fake);
      expect(find.text('Reset readiness unavailable'), findsOneWidget);
      expect(find.textContaining('PRIVATE-RESET'), findsNothing);
      expect(h.api.reads, 1);
      fake.onLoad = null;
      await tapReset(tester, 'reset-retry');
      expect(h.api.reads, 2);
      expect(find.byKey(const Key('reset-review')), findsOneWidget);
      expect(h.api.executes, isEmpty);
    },
  );
  testWidgets(
    'review requires exact full target and all six independent recovery consents',
    (tester) async {
      final h = await pumpReset(tester);
      await tapReset(tester, 'reset-review');
      expect(h.api.executes, isEmpty);
      expect(find.text('RESET $resetHost'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('reset-confirm-submit')))
            .onPressed,
        isNull,
      );
      await enterReset(tester, 'RESET $resetHost ');
      for (var i = 0; i < 6; i++) {
        await tapReset(tester, 'reset-confirm-ack-$i');
      }
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('reset-confirm-submit')))
            .onPressed,
        isNull,
      );
      await enterReset(tester, 'RESET $resetHost');
      await tapReset(tester, 'reset-confirm-ack-5');
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('reset-confirm-submit')))
            .onPressed,
        isNull,
      );
      await tapReset(tester, 'reset-confirm-ack-5');
      await tapReset(tester, 'reset-confirm-submit');
      expect(h.api.executes, hasLength(1));
      expect(h.api.mutations, 1);
      expect(
        h.container.read(configurationResetControllerProvider).status,
        ConfigurationResetStatus.rejected,
      );
      final lock = h.container.read(serverOperationLockProvider),
          owner = h.container.read(serverOperationLockProvider).acquire();
      expect(owner, isNotNull);
      lock.release(owner!);
      expect(find.byType(ConfigurationResetReviewDialog), findsNothing);
      expect(
        find.textContaining('reviewed reset was rejected'),
        findsOneWidget,
      );
    },
  );
  testWidgets('cancel consumes UI authorization without reset or refresh', (
    tester,
  ) async {
    final h = await pumpReset(tester);
    await tapReset(tester, 'reset-review');
    await tapReset(tester, 'reset-cancel');
    expect(h.api.executes, isEmpty);
    expect(h.api.reads, 1);
    expect(find.byType(ConfigurationResetReviewDialog), findsNothing);
  });
  for (final cause in ['session', 'background', 'inventory', 'timeout']) {
    testWidgets(
      '$cause permanently expires open review and hides original details',
      (tester) async {
        final h = await pumpReset(tester);
        await tapReset(tester, 'reset-review');
        await consentReset(tester, 'RESET $resetHost');
        if (cause == 'session') {
          h.select(h.newSession());
          h.select(h.session);
        }
        if (cause == 'background') background(tester);
        if (cause == 'inventory') {
          h.api.inventory = resetInventory();
          h.container.invalidate(configurationResetInventoryProvider);
        }
        if (cause == 'timeout') await tester.pump(const Duration(minutes: 5));
        await tester.pumpAndSettle();
        expect(find.text('Factory-reset review expired'), findsOneWidget);
        expect(find.byKey(const Key('reset-confirm-target')), findsNothing);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('reset-confirm-submit')),
              )
              .onPressed,
          isNull,
        );
        expect(h.api.executes, isEmpty);
      },
    );
  }
  for (final phase in ['review', 'execute']) {
    testWidgets(
      'another route pushed during $phase blocks late review or reset dispatch before rebuild',
      (tester) async {
        final h = await pumpReset(tester),
            pendingReview = Completer<ConfigurationResetReview>(),
            pendingExecute = Completer<void>();
        if (phase == 'review') {
          h.api.onReview = (_) => pendingReview.future;
        } else {
          h.api.onExecute = (_, current) async {
            await pendingExecute.future;
            if (current()) h.api.mutations++;
            return const ConfigurationResetResult(
              ConfigurationResetOutcome.rejected,
              'Synthetic stale rejection',
            );
          };
        }
        await tapReset(tester, 'reset-review', settle: phase != 'review');
        if (phase == 'execute') {
          await consentReset(tester, 'RESET $resetHost');
          await tapReset(tester, 'reset-confirm-submit', settle: false);
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
            ConfigurationResetReview(
              request: h.api.reviews.single,
              endpoint: resetEndpoint,
              warnings: const [],
            ),
          );
        } else {
          pendingExecute.complete();
        }
        await tester.pumpAndSettle();
        expect(h.api.mutations, 0);
        expect(find.byType(ConfigurationResetReviewDialog), findsNothing);
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
    'covering the owned review dialog expires it rather than authorizing another route',
    (tester) async {
      final h = await pumpReset(tester);
      await tapReset(tester, 'reset-review');
      await consentReset(tester, 'RESET $resetHost');
      final navigator = tester.state<NavigatorState>(find.byType(Navigator));
      unawaited(
        navigator.push<void>(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Other workspace')),
          ),
        ),
      );
      await tester.pumpAndSettle();
      navigator.pop();
      await tester.pumpAndSettle();
      expect(find.text('Factory-reset review expired'), findsOneWidget);
      expect(
        tester
            .widget<FilledButton>(find.byKey(const Key('reset-confirm-submit')))
            .onPressed,
        isNull,
      );
      expect(h.api.executes, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );
  for (final outcome in [
    ConfigurationResetOutcome.accepted,
    ConfigurationResetOutcome.unknown,
  ]) {
    testWidgets(
      '${outcome.name} remains unresolved and route teardown cannot release shared fence',
      (tester) async {
        final fake = ResetFake()
          ..onExecute = (_, _) async =>
              ConfigurationResetResult(outcome, 'PRIVATE-RESET', jobId: 41);
        final h = await pumpReset(tester, fake: fake);
        await tapReset(tester, 'reset-review');
        await consentReset(tester, 'RESET $resetHost');
        await tapReset(tester, 'reset-confirm-submit');
        expect(
          h.container.read(configurationResetControllerProvider).unresolved,
          isTrue,
        );
        expect(
          h.container.read(configurationResetControllerProvider).status,
          outcome == ConfigurationResetOutcome.accepted
              ? ConfigurationResetStatus.accepted
              : ConfigurationResetStatus.unknown,
        );
        expect(
          h.container.read(configurationResetControllerProvider).jobId,
          outcome == ConfigurationResetOutcome.accepted ? 41 : null,
        );
        expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
        expect(find.textContaining('PRIVATE-RESET'), findsNothing);
        expect(h.api.reads, 1);
        expect(h.api.executes, hasLength(1));
        expect(
          tester
              .widget<OutlinedButton>(
                find.byKey(const Key('reset-verify-reconnected')),
              )
              .onPressed,
          isNull,
        );
        await tester.pumpWidget(const SizedBox());
        await tester.pump();
        expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
        expect(tester.takeException(), isNull);
      },
    );
  }
  testWidgets(
    'explicit confirmation permits delayed normal preflight after its own modal closes',
    (tester) async {
      final pending = Completer<void>(), fake = ResetFake();
      fake.onExecute = (_, current) async {
        await pending.future;
        if (current()) fake.mutations++;
        return const ConfigurationResetResult(
          ConfigurationResetOutcome.accepted,
          'Synthetic acceptance',
          jobId: 41,
        );
      };
      final h = await pumpReset(tester, fake: fake);
      await tapReset(tester, 'reset-review');
      await consentReset(tester, 'RESET $resetHost');
      final button = tester.widget<FilledButton>(
            find.byKey(const Key('reset-confirm-submit')),
          ),
          context = tester.element(
            find.byKey(const Key('reset-confirm-submit')),
          );
      expect(
        button.style!.backgroundColor!.resolve({}),
        Theme.of(context).colorScheme.error,
      );
      expect(
        button.style!.foregroundColor!.resolve({}),
        Theme.of(context).colorScheme.onError,
      );
      await tapReset(tester, 'reset-confirm-submit', settle: false);
      await tester.pump(const Duration(seconds: 1));
      expect(find.byType(ConfigurationResetReviewDialog), findsNothing);
      expect(
        h.container.read(configurationResetControllerProvider).status,
        ConfigurationResetStatus.executing,
      );
      pending.complete();
      await tester.pumpAndSettle();
      expect(fake.mutations, 1);
      expect(fake.executes, hasLength(1));
      expect(
        h.container.read(configurationResetControllerProvider).status,
        ConfigurationResetStatus.accepted,
      );
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    },
  );
  testWidgets(
    'manual changed address recovery needs matching host and separate ownership and inspection acknowledgment',
    (tester) async {
      final fake = ResetFake()
        ..onExecute = (_, _) async => const ConfigurationResetResult(
          ConfigurationResetOutcome.accepted,
          'accepted',
          jobId: 41,
        );
      final h = await pumpReset(tester, fake: fake);
      await tapReset(tester, 'reset-review');
      await consentReset(tester, 'RESET $resetHost');
      await tapReset(tester, 'reset-confirm-submit');
      h.api.inventory = resetInventory(
        endpoint: 'wss://recovered.example/api/current',
      );
      h.select(h.newSession(endpoint: h.api.inventory.endpoint));
      await tester.pumpAndSettle();
      expect(h.api.reads, 1);
      await tapReset(tester, 'reset-verify-reconnected');
      expect(h.api.reads, 2);
      expect(find.textContaining('Manually connected address'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('reset-acknowledge')))
            .onPressed,
        isNull,
      );
      await tapReset(tester, 'reset-changed-address');
      await tapReset(tester, 'reset-acknowledge');
      expect(
        h.container.read(configurationResetControllerProvider).locked,
        isFalse,
      );
      expect(h.api.executes, hasLength(1));
      expect(
        find.textContaining('prior reset remains unverified'),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
    },
  );
  for (final width in [320.0, 430.0, 1100.0]) {
    for (final dark in [false, true]) {
      testWidgets(
        'page ${width.toInt()} ${dark ? 'dark' : 'light'} at 200 percent has readable responsive layout',
        (tester) async {
          await pumpReset(tester, width: width, dark: dark, scale: 2);
          await tester.ensureVisible(find.byKey(const Key('reset-review')));
          await tester.pumpAndSettle();
          expect(tester.takeException(), isNull);
        },
      );
      testWidgets(
        'review ${width.toInt()} ${dark ? 'dark' : 'light'} at 200 percent with keyboard can reach all consents and submit',
        (tester) async {
          final h = await pumpReset(
            tester,
            width: width,
            dark: dark,
            scale: 2,
            keyboard: 300,
          );
          await tapReset(tester, 'reset-review');
          await consentReset(tester, 'RESET $resetHost');
          await tapReset(tester, 'reset-confirm-submit');
          expect(h.api.executes, hasLength(1));
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
