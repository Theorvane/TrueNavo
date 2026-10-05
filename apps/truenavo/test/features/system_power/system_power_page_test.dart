import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/system_power/system_power_controller.dart';
import 'package:truenavo/features/system_power/system_power_page.dart';
import 'package:truenavo/features/system_power/system_power_reason.dart';
import 'package:truenavo/features/system_power/system_power_review.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'system_power_fakes.dart';

Future<PowerHarness> pumpPower(
  WidgetTester tester, {
  PowerFake? fake,
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
  final h = PowerHarness(fake: fake);
  addTearDown(h.dispose);
  if (disconnected) {
    h.select(null);
  } else {
    try {
      await h.load();
    } on Object {
      /* Fixed readiness error UI. */
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
        home: const SystemPowerPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapPower(
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

Future<void> enterPower(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> reviewPower(
  WidgetTester tester, {
  SystemPowerAction action = SystemPowerAction.reboot,
}) async {
  await tapPower(tester, 'power-${action.name}');
  await enterPower(tester, 'power-reason', 'Planned maintenance');
  await tapPower(tester, 'power-reason-review');
}

Future<void> confirmPower(
  WidgetTester tester,
  String target, {
  bool settle = true,
}) async {
  await enterPower(tester, 'power-confirm-target', target);
  await tapPower(tester, 'power-confirm-impact');
  await tapPower(tester, 'power-confirm-submit', settle: settle);
}

void expectDisabled(WidgetTester tester, String key) => expect(
  tester.widget<OutlinedButton>(find.byKey(Key(key))).onPressed,
  isNull,
);
void backgroundAndResume(WidgetTester tester) {
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
    'opening and explicit refresh only read public readiness without polling',
    (tester) async {
      final h = await pumpPower(tester);
      expect(find.text('Ready for a manual review'), findsOneWidget);
      expect(find.text('System state: READY'), findsOneWidget);
      expect(find.text(powerHost), findsOneWidget);
      expect(find.text('Running environment: 25.10.1'), findsOneWidget);
      await tester.pump(const Duration(minutes: 5));
      expect(h.api.reads, 1);
      expect(h.api.reviews, isEmpty);
      expect(h.api.writes, isEmpty);
      await tapPower(tester, 'power-refresh');
      expect(h.api.reads, 2);
    },
  );
  testWidgets('disconnected page makes no read', (tester) async {
    final h = await pumpPower(tester, disconnected: true);
    expect(find.text('System power unavailable'), findsOneWidget);
    expect(h.api.reads, 0);
  });
  testWidgets('wrong endpoint never shows another server public identity', (
    tester,
  ) async {
    final h = await pumpPower(
      tester,
      fake: PowerFake(
        inventory: powerInventory(endpoint: 'wss://other.example/api/current'),
      ),
    );
    expect(find.text('Power readiness unavailable'), findsOneWidget);
    expect(find.text(powerHost), findsNothing);
    expect(find.textContaining('25.10.1'), findsNothing);
    expect(h.api.writes, isEmpty);
  });
  testWidgets('read failures are redacted and manual retry only', (
    tester,
  ) async {
    final h = await pumpPower(
      tester,
      fake: PowerFake()
        ..onLoad = () async => throw StateError('PRIVATE-POWER-FIXTURE'),
    );
    expect(find.text('Power readiness unavailable'), findsOneWidget);
    expect(find.textContaining('PRIVATE-POWER-FIXTURE'), findsNothing);
    await tester.pump(const Duration(minutes: 5));
    expect(h.api.reads, 1);
    await tapPower(tester, 'power-retry');
    expect(h.api.reads, 2);
    expect(h.api.writes, isEmpty);
  });
  for (final guard in [
    'ha',
    'jobs',
    'unhealthy',
    'booting',
    'different-next',
    'empty',
    'nonbootable',
  ]) {
    testWidgets('$guard blocks both power actions', (tester) async {
      final h = await pumpPower(
        tester,
        fake: PowerFake(
          inventory: powerInventory(
            ha: guard == 'ha',
            jobs: guard == 'jobs',
            healthy: guard != 'unhealthy',
            state: guard == 'booting' ? 'BOOTING' : 'READY',
            differentNext: guard == 'different-next',
            empty: guard == 'empty',
            bootable: guard != 'nonbootable',
          ),
        ),
      );
      expect(find.text('Power actions blocked'), findsOneWidget);
      for (final action in SystemPowerAction.values) {
        expectDisabled(tester, 'power-${action.name}');
      }
      expect(h.api.writes, isEmpty);
      expect(h.api.reviews, isEmpty);
    });
  }
  for (final action in SystemPowerAction.values) {
    testWidgets(
      '$action requires reason, full exact host target and impact acknowledgement',
      (tester) async {
        final h = await pumpPower(tester);
        await tapPower(tester, 'power-${action.name}');
        await tapPower(tester, 'power-reason-review');
        expect(h.api.reviews, isEmpty);
        await enterPower(tester, 'power-reason', ' Maintenance ');
        await tapPower(tester, 'power-reason-review');
        expect(h.api.reviews, isEmpty);
        await enterPower(tester, 'power-reason', 'Planned maintenance');
        await tapPower(tester, 'power-reason-review');
        expect(find.byType(SystemPowerReviewDialog), findsOneWidget);
        expect(h.api.writes, isEmpty);
        final target = h.api.reviews.single.target;
        expect(target, '${action.name.toUpperCase()} $powerHost');
        await enterPower(tester, 'power-confirm-target', '$target ');
        await tapPower(tester, 'power-confirm-impact');
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('power-confirm-submit')),
              )
              .onPressed,
          isNull,
        );
        await enterPower(tester, 'power-confirm-target', target);
        await tapPower(tester, 'power-confirm-submit');
        expect(h.api.writes, hasLength(1));
        expect(h.api.writes.single.action, action);
        expect(h.container.read(systemPowerControllerProvider).locked, isFalse);
      },
    );
  }
  testWidgets(
    'shutdown draft explicitly requires independent power-on access',
    (tester) async {
      final h = await pumpPower(tester);
      await tapPower(tester, 'power-shutdown');
      expect(
        find.textContaining('This app cannot turn it back on'),
        findsOneWidget,
      );
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(h.api.reviews, isEmpty);
      expect(h.api.writes, isEmpty);
    },
  );
  testWidgets('cancelled review sends no power command', (tester) async {
    final h = await pumpPower(tester);
    await reviewPower(tester);
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.api.reviews, hasLength(1));
    expect(h.api.writes, isEmpty);
  });
  for (final form in ['reason', 'review']) {
    for (final cause in ['session', 'inventory', 'background']) {
      testWidgets('$form permanently expires on $cause and hides old details', (
        tester,
      ) async {
        final h = await pumpPower(tester);
        if (form == 'reason') {
          await tapPower(tester, 'power-reboot');
          await enterPower(tester, 'power-reason', 'DRAFT-POWER-FIXTURE');
        } else {
          await reviewPower(tester);
          await enterPower(
            tester,
            'power-confirm-target',
            h.api.reviews.single.target,
          );
        }
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'inventory') {
          h.api.inventory = powerInventory();
          h.container.invalidate(systemPowerInventoryProvider);
        }
        if (cause == 'background') backgroundAndResume(tester);
        await tester.pumpAndSettle();
        expect(
          find.text(
            form == 'reason' ? 'Power draft expired' : 'Power review expired',
          ),
          findsOneWidget,
        );
        final dialog = find.byType(
          form == 'reason' ? SystemPowerReasonDialog : SystemPowerReviewDialog,
        );
        expect(
          find.descendant(of: dialog, matching: find.textContaining(powerHost)),
          findsNothing,
        );
        expect(find.textContaining('DRAFT-POWER-FIXTURE'), findsNothing);
        expect(h.api.writes, isEmpty);
      });
    }
  }
  for (final cause in ['session', 'inventory', 'background', 'dispose']) {
    testWidgets('late review after $cause never opens confirmation', (
      tester,
    ) async {
      final pending = Completer<SystemPowerReview>();
      final h = await pumpPower(
        tester,
        fake: PowerFake()..onReview = (_) => pending.future,
      );
      await reviewPower(tester);
      if (cause == 'session') h.select(h.newSession());
      if (cause == 'inventory') {
        h.api.inventory = powerInventory();
        h.container.invalidate(systemPowerInventoryProvider);
      }
      if (cause == 'background') backgroundAndResume(tester);
      if (cause == 'dispose') await tester.pumpWidget(const SizedBox());
      pending.complete(
        SystemPowerReview(
          request: h.api.reviews.single,
          endpoint: powerEndpoint,
          warnings: [],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(SystemPowerReviewDialog), findsNothing);
      expect(h.api.writes, isEmpty);
    });
  }
  testWidgets('duplicate review activation cannot open a second draft', (
    tester,
  ) async {
    final h = await pumpPower(tester);
    final callback = tester
        .widget<OutlinedButton>(find.byKey(const Key('power-reboot')))
        .onPressed!;
    callback();
    callback();
    await tester.pumpAndSettle();
    expect(find.byType(SystemPowerReasonDialog), findsOneWidget);
    expect(h.api.reviews, isEmpty);
    expect(h.api.writes, isEmpty);
  });
  for (final mismatch in ['endpoint', 'request']) {
    testWidgets(
      '$mismatch mismatch from review is hidden and never submitted',
      (tester) async {
        final fake = PowerFake();
        fake.onReview = (request) async => SystemPowerReview(
          request: mismatch == 'request'
              ? powerRequest(request.inventory)
              : request,
          endpoint: mismatch == 'endpoint'
              ? 'wss://other.example/api/current'
              : powerEndpoint,
          warnings: ['PRIVATE-POWER-FIXTURE'],
        );
        final h = await pumpPower(tester, fake: fake);
        await reviewPower(tester);
        expect(find.byType(SystemPowerReviewDialog), findsNothing);
        expect(find.textContaining('PRIVATE-POWER-FIXTURE'), findsNothing);
        expect(h.api.writes, isEmpty);
      },
    );
  }
  testWidgets(
    'accepted power retains lock and no automatic checks or reads after reconnect',
    (tester) async {
      final h = await pumpPower(
        tester,
        fake: PowerFake()
          ..onExecute = (_) async => const SystemPowerResult(
            SystemPowerOutcome.accepted,
            'Queued',
            jobId: 80,
          ),
      );
      await reviewPower(tester);
      await confirmPower(tester, h.api.reviews.single.target);
      expect(find.text('Accepted — completion unverified'), findsOneWidget);
      expect(find.text('Accepted job: 80'), findsOneWidget);
      expectDisabled(tester, 'power-reboot');
      expectDisabled(tester, 'power-shutdown');
      expectDisabled(tester, 'power-acknowledge');
      expectDisabled(tester, 'power-verify-reconnected');
      await tester.pump(const Duration(minutes: 5));
      expect(h.api.reads, 1);
      h.select(h.newSession());
      await tester.pumpAndSettle();
      expect(find.text('Original operation needs attention'), findsOneWidget);
      expect(find.text(powerHost), findsNothing);
      expect(h.api.reads, 1);
      expectDisabled(tester, 'power-acknowledge');
      await tapPower(tester, 'power-verify-reconnected');
      expect(h.api.reads, 2);
      await tapPower(tester, 'power-acknowledge');
      expect(h.container.read(systemPowerControllerProvider).locked, isFalse);
      expect(h.api.writes, hasLength(1));
    },
  );
  testWidgets('unknown outcome hides raw error and locks refresh and retries', (
    tester,
  ) async {
    final h = await pumpPower(
      tester,
      fake: PowerFake()
        ..onExecute = (_) async => throw StateError('PRIVATE-POWER-FIXTURE'),
    );
    await reviewPower(tester);
    await confirmPower(tester, h.api.reviews.single.target);
    expect(find.text('Inspect the original server'), findsOneWidget);
    expect(find.textContaining('PRIVATE-POWER-FIXTURE'), findsNothing);
    expectDisabled(tester, 'power-reboot');
    expectDisabled(tester, 'power-shutdown');
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('power-refresh')))
          .onPressed,
      isNull,
    );
    await tester.pump(const Duration(minutes: 5));
    expect(h.api.writes, hasLength(1));
  });
  testWidgets('late old inventory cannot overwrite a replacement session', (
    tester,
  ) async {
    final h = await pumpPower(tester),
        pending = Completer<SystemPowerInventory>();
    final original = h.api.inventory;
    h.api.onLoad = () => pending.future;
    await tapPower(tester, 'power-refresh', settle: false);
    final current = powerInventory(
      endpoint: 'wss://other.example/api/current',
      hostId:
          'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789',
    );
    h.api.onLoad = () async => current;
    h.select(h.newSession(endpoint: current.endpoint));
    await tester.pumpAndSettle();
    pending.complete(original);
    await tester.pumpAndSettle();
    expect(
      h.container.read(systemPowerInventoryProvider).asData?.value,
      same(current),
    );
    expect(find.text(powerHost), findsNothing);
    expect(h.api.writes, isEmpty);
  });
  for (final width in [320.0, 430.0, 1100.0]) {
    for (final dark in [false, true]) {
      for (final form in ['page', 'reason', 'review']) {
        testWidgets(
          '$form width=$width dark=$dark at 200 percent with keyboard does not overflow',
          (tester) async {
            final h = await pumpPower(
              tester,
              width: width,
              dark: dark,
              scale: 2,
              keyboard: form == 'page' ? 0 : 300,
            );
            if (form == 'reason') {
              await tapPower(tester, 'power-shutdown');
              await enterPower(tester, 'power-reason', 'Narrow maintenance');
              await tapPower(tester, 'power-reason-review');
              expect(find.byType(SystemPowerReviewDialog), findsOneWidget);
            }
            if (form == 'review') {
              await reviewPower(tester);
              await confirmPower(tester, h.api.reviews.single.target);
              expect(h.api.writes, hasLength(1));
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
