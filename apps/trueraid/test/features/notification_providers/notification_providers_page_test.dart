import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/notification_providers/notification_providers_controller.dart';
import 'package:trueraid/features/notification_providers/notification_providers_editor.dart';
import 'package:trueraid/features/notification_providers/notification_providers_page.dart';
import 'package:trueraid/features/notification_providers/notification_providers_review.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'notification_providers_fakes.dart';

Future<ProvidersHarness> pumpProviders(
  WidgetTester tester, {
  ProvidersFake? fake,
  NotificationProviderType provider = NotificationProviderType.slack,
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
  final h = ProvidersHarness(
    fake:
        fake ??
        ProvidersFake(
          inventory: providersInventory(
            services: [
              NotificationProviderSnapshot(
                id: 1,
                name: 'Provider one',
                type: provider.wireName,
                level: AlertDeliveryLevel.warning,
                enabled: false,
              ),
              NotificationProviderSnapshot(
                id: 2,
                name: 'Provider two',
                type: provider.wireName,
                level: AlertDeliveryLevel.critical,
                enabled: true,
              ),
              const NotificationProviderSnapshot(
                id: 3,
                name: 'Separate email',
                type: 'Mail',
                level: AlertDeliveryLevel.error,
                enabled: true,
              ),
            ],
          ),
        ),
  );
  addTearDown(h.dispose);
  if (disconnected) {
    h.select(null);
  } else {
    try {
      await h.load();
    } on Object {
      /* Fixed public result. */
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
        home: const NotificationProvidersPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapProvider(
  WidgetTester tester,
  String key, {
  bool settle = true,
}) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.tap(f);
  if (settle) {
    await tester.pumpAndSettle();
  } else {
    await tester.pump();
  }
}

Future<void> enterProvider(
  WidgetTester tester,
  String key,
  String value,
) async {
  final f = find.byKey(Key(key));
  await tester.ensureVisible(f);
  await tester.pumpAndSettle();
  await tester.enterText(f, value);
  await tester.pumpAndSettle();
}

Future<void> openProviderEditor(
  WidgetTester tester,
  NotificationProvidersAction action, {
  NotificationProviderType provider = NotificationProviderType.slack,
}) async {
  await tapProvider(
    tester,
    action == NotificationProvidersAction.create
        ? 'provider-create'
        : 'provider-replace-1',
  );
  if (action == NotificationProvidersAction.create &&
      provider != NotificationProviderType.slack) {
    await tapProvider(tester, 'provider-kind-${provider.name}');
  }
  await enterProvider(tester, 'provider-name', 'Reviewed provider');
  final values = <String, Object?>{
    ...providerFields(provider),
    ...providerSecrets(provider),
  };
  for (final field in notificationProviderFields(provider)) {
    final value = values[field.key];
    await enterProvider(
      tester,
      'provider-field-${field.key}',
      value is List ? value.join(', ') : '$value',
    );
  }
  await tapProvider(tester, 'provider-level-critical');
}

Future<void> openProviderReview(
  WidgetTester tester,
  NotificationProvidersAction action, {
  NotificationProviderType provider = NotificationProviderType.slack,
  bool settle = true,
}) async {
  if (action == NotificationProvidersAction.create ||
      action == NotificationProvidersAction.replace) {
    await openProviderEditor(tester, action, provider: provider);
    await tapProvider(tester, 'provider-editor-review', settle: settle);
  } else {
    await tapProvider(tester, switch (action) {
      NotificationProvidersAction.enable => 'provider-toggle-1',
      NotificationProvidersAction.disable => 'provider-toggle-2',
      _ => 'provider-delete-1',
    }, settle: settle);
  }
}

Future<void> consentProvider(
  WidgetTester tester,
  NotificationProvidersReview review,
) async {
  await enterProvider(tester, 'provider-confirm-target', review.target);
  await tapProvider(tester, 'provider-confirm-impact');
  if (review.action != NotificationProvidersAction.create &&
      review.action != NotificationProvidersAction.replace) {
    await tapProvider(tester, 'provider-confirm-specific');
  }
  if (review.action == NotificationProvidersAction.enable &&
      review.unencrypted) {
    await tapProvider(tester, 'provider-confirm-unencrypted');
  }
}

void background(WidgetTester tester) {
  for (final s in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.inactive,
    AppLifecycleState.resumed,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(s);
  }
}

NotificationProvidersReview currentReview(WidgetTester tester) => tester
    .widget<NotificationProvidersReviewDialog>(
      find.byType(NotificationProvidersReviewDialog),
    )
    .review;
void expectLocked(ProvidersHarness h) =>
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
void expectUnlocked(ProvidersHarness h) {
  final lock = h.container.read(serverOperationLockProvider),
      owner = lock.acquire();
  expect(owner, isNotNull);
  lock.release(owner!);
}

void main() {
  testWidgets(
    'compact dashboard uses header counts, never secret or delivery measurements',
    (tester) async {
      final h = await pumpProviders(tester, width: 430);
      expect(h.api.reads, 1);
      expect(h.api.reviews, isEmpty);
      expect(h.api.executes, isEmpty);
      expect(find.byKey(const Key('provider-enablement-ring')), findsOneWidget);
      expect(
        tester
            .getBottomLeft(find.byKey(const Key('provider-enablement-ring')))
            .dy,
        lessThan(1000),
      );
      expect(find.text('2 Enabled'), findsOneWidget);
      expect(find.text('1 Disabled'), findsOneWidget);
      expect(find.text('Provider · Slack: 2'), findsOneWidget);
      expect(find.text(providersHost), findsNothing);
      expect(find.textContaining(providersSecret), findsNothing);
      expect(find.byKey(const Key('provider-replace-3')), findsNothing);
      await tapProvider(tester, 'provider-readiness-details');
      expect(find.text(providersHost), findsOneWidget);
      await tapProvider(tester, 'provider-scope-details');
      expect(find.textContaining('SNMP v3 and unknown/masked'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('empty header inventory never invents delivery percentages', (
    tester,
  ) async {
    await pumpProviders(
      tester,
      fake: ProvidersFake(inventory: providersInventory(services: const [])),
    );
    expect(
      find.textContaining('no percentage or delivery status is inferred'),
      findsOneWidget,
    );
    expect(
      find.textContaining('does not establish that all TrueNAS notification'),
      findsOneWidget,
    );
  });
  testWidgets('disconnected never reads or connects automatically', (
    tester,
  ) async {
    final h = await pumpProviders(tester, disconnected: true);
    expect(h.api.reads, 0);
    expect(find.byKey(const Key('provider-create')), findsNothing);
  });
  testWidgets(
    'read-only configuration keeps charts without write buttons enabled',
    (tester) async {
      final h = await pumpProviders(
        tester,
        fake: ProvidersFake(inventory: providersInventory(admin: false)),
      );
      for (final key in [
        'provider-create',
        'provider-replace-1',
        'provider-toggle-1',
      ]) {
        expect(
          tester.widget<OutlinedButton>(find.byKey(Key(key))).onPressed,
          isNull,
        );
      }
      expect(h.api.executes, isEmpty);
    },
  );
  testWidgets('read failure is sanitized and only explicit refresh retries', (
    tester,
  ) async {
    final fake = ProvidersFake()
      ..onLoad = () async => throw StateError(providersSecret);
    final h = await pumpProviders(tester, fake: fake);
    expect(find.textContaining(providersSecret), findsNothing);
    expect(h.api.reads, 1);
    fake.onLoad = null;
    await tapProvider(tester, 'provider-retry');
    expect(h.api.reads, 2);
  });
  for (final provider in NotificationProviderType.values) {
    testWidgets(
      '${provider.name} every protected field is obscured, never prefilled and discarded at handoff',
      (tester) async {
        final h = await pumpProviders(tester, provider: provider);
        await tapProvider(tester, 'provider-replace-1');
        for (final field in notificationProviderFields(
          provider,
        ).where((f) => f.secret)) {
          final widget = tester.widget<TextField>(
            find.byKey(Key('provider-field-${field.key}')),
          );
          expect(widget.controller!.text, isEmpty);
          expect(widget.obscureText, isTrue);
          expect(widget.enableSuggestions, isFalse);
          expect(widget.enableIMEPersonalizedLearning, isFalse);
          expect(widget.autofillHints, isEmpty);
        }
        await tapProvider(tester, 'provider-editor-cancel');
        await tapProvider(tester, 'provider-refresh-after-review');
        await openProviderEditor(
          tester,
          NotificationProvidersAction.replace,
          provider: provider,
        );
        final captured = [
          for (final field in notificationProviderFields(
            provider,
          ).where((f) => f.secret))
            tester
                .widget<TextField>(
                  find.byKey(Key('provider-field-${field.key}')),
                )
                .controller!,
        ];
        await tapProvider(tester, 'provider-editor-review');
        for (final field in captured) {
          expect(field.text, isEmpty);
        }
        final r = currentReview(tester);
        expect(r.request.credentials!.isDisposed, isFalse);
        expect(find.textContaining(providersSecret), findsNothing);
        await tapProvider(tester, 'provider-review-cancel');
        expect(r.request.credentials!.isDisposed, isTrue);
        expect(h.api.executes, isEmpty);
      },
    );
  }
  testWidgets(
    'changing provider clears and disposes actual secret controller before new form',
    (tester) async {
      await pumpProviders(tester);
      await openProviderEditor(tester, NotificationProvidersAction.create);
      final old = tester
          .widget<TextField>(find.byKey(const Key('provider-field-url')))
          .controller!;
      await tapProvider(tester, 'provider-kind-telegram');
      expect(old.text, isEmpty);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('provider-field-bot_token')),
            )
            .controller!
            .text,
        isEmpty,
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('provider-name')))
            .controller!
            .text,
        isEmpty,
      );
      expect(find.text('Provider editor expired'), findsNothing);
      expect(tester.takeException(), isNull);
      await tapProvider(tester, 'provider-editor-cancel');
    },
  );
  for (final cause in ['session', 'background', 'route', 'cancel']) {
    testWidgets('editor $cause clears actual credential input without review', (
      tester,
    ) async {
      final h = await pumpProviders(tester);
      await openProviderEditor(tester, NotificationProvidersAction.create);
      final field = tester
          .widget<TextField>(find.byKey(const Key('provider-field-url')))
          .controller!;
      if (cause == 'session') h.select(h.newSession());
      if (cause == 'background') background(tester);
      if (cause == 'route') {
        Navigator.of(
          tester.element(find.byType(NotificationProvidersEditorDialog)),
        ).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Other route')),
          ),
        );
      }
      if (cause == 'cancel') {
        await tapProvider(tester, 'provider-editor-cancel');
      }
      await tester.pumpAndSettle();
      expect(field.text, isEmpty);
      expect(h.api.reviews, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }
  for (final cause in [
    'session',
    'background',
    'route',
    'inventory',
    'timeout',
  ]) {
    testWidgets(
      'review $cause destroys capsule and clears exact target permanently',
      (tester) async {
        final h = await pumpProviders(tester);
        await openProviderReview(tester, NotificationProvidersAction.create);
        final r = currentReview(tester);
        await consentProvider(tester, r);
        final target = tester
            .widget<TextField>(find.byKey(const Key('provider-confirm-target')))
            .controller!;
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background(tester);
        if (cause == 'inventory') {
          h.api.inventory = providersInventory();
          h.container.invalidate(notificationProvidersInventoryProvider);
        }
        if (cause == 'route') {
          final nav = Navigator.of(
            tester.element(find.byType(NotificationProvidersReviewDialog)),
          );
          nav.push(
            MaterialPageRoute<void>(
              builder: (_) => const Scaffold(body: Text('Other route')),
            ),
          );
          await tester.pumpAndSettle();
          nav.pop();
        }
        if (cause == 'timeout') await tester.pump(const Duration(minutes: 5));
        await tester.pumpAndSettle();
        expect(r.request.credentials!.isDisposed, isTrue);
        expect(target.text, isEmpty);
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('provider-confirm-submit')),
              )
              .onPressed,
          isNull,
        );
        expect(h.api.executes, isEmpty);
        await tapProvider(tester, 'provider-review-cancel');
      },
    );
  }
  for (final provider in [
    NotificationProviderType.influxDb,
    NotificationProviderType.snmpTrap,
  ]) {
    testWidgets(
      '${provider.name} plaintext enable requires distinct consent beyond general destination approval',
      (tester) async {
        final h = await pumpProviders(tester, provider: provider);
        await openProviderReview(
          tester,
          NotificationProvidersAction.enable,
          provider: provider,
        );
        final r = currentReview(tester);
        await enterProvider(tester, 'provider-confirm-target', r.target);
        await tapProvider(tester, 'provider-confirm-impact');
        await tapProvider(tester, 'provider-confirm-specific');
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('provider-confirm-submit')),
              )
              .onPressed,
          isNull,
        );
        await tapProvider(tester, 'provider-confirm-unencrypted');
        await tapProvider(tester, 'provider-confirm-submit');
        expect(h.api.executes, hasLength(1));
      },
    );
  }
  for (final stage in ['review', 'execute']) {
    for (final covered in [false, true]) {
      testWidgets(
        '$stage held normal dialog close covered=$covered has correct final authorization',
        (tester) async {
          final h = await pumpProviders(tester),
              heldReview = Completer<NotificationProvidersReview>(),
              heldExecute = Completer<void>();
          if (stage == 'review') h.api.onReview = (_) => heldReview.future;
          if (stage == 'execute') {
            h.api.onExecute = (_, current) async {
              await heldExecute.future;
              if (current()) h.api.mutations++;
              return const NotificationProvidersResult(
                NotificationProvidersOutcome.completed,
                'complete',
              );
            };
          }
          await openProviderReview(
            tester,
            NotificationProvidersAction.create,
            settle: stage != 'review',
          );
          if (stage == 'execute') {
            await consentProvider(tester, currentReview(tester));
            await tapProvider(tester, 'provider-confirm-submit', settle: false);
          }
          await tester.pump(const Duration(milliseconds: 400));
          if (covered) {
            Navigator.of(tester.element(find.byType(NotificationProvidersPage)))
                .push(
                  MaterialPageRoute<void>(
                    builder: (_) => const Scaffold(body: Text('Other route')),
                  ),
                );
          }
          if (stage == 'review') {
            heldReview.complete(
              NotificationProvidersReview(
                request: h.api.reviews.single,
                endpoint: providersEndpoint,
                warnings: const [],
                destinationSummary: 'Synthetic destination',
                publicFields: const {},
                unencrypted: false,
              ),
            );
          }
          if (stage == 'execute') heldExecute.complete();
          await tester.pumpAndSettle();
          if (!covered && stage == 'review') {
            await consentProvider(tester, currentReview(tester));
            await tapProvider(tester, 'provider-confirm-submit');
          }
          expect(h.api.mutations, covered ? 0 : 1);
          expect(h.api.reviews.single.credentials!.isDisposed, isTrue);
          if (covered && stage == 'execute') {
            expectLocked(h);
          } else if (!covered) {
            expectUnlocked(h);
          }
        },
      );
    }
  }
  testWidgets(
    'peer lock refusal after accepted modal destroys credential capsule',
    (tester) async {
      final h = await pumpProviders(tester);
      await openProviderReview(tester, NotificationProvidersAction.create);
      final r = currentReview(tester);
      final lock = h.container.read(serverOperationLockProvider),
          owner = lock.acquire()!;
      await consentProvider(tester, r);
      await tapProvider(tester, 'provider-confirm-submit');
      expect(r.request.credentials!.isDisposed, isTrue);
      expect(h.api.executes, isEmpty);
      expect(find.byKey(const Key('provider-enablement-ring')), findsNothing);
      lock.release(owner);
    },
  );
  for (final result in NotificationProvidersOutcome.values) {
    testWidgets(
      '$result is sanitized, hides consumed inventory and never automatically repeats',
      (tester) async {
        final fake = ProvidersFake()
          ..onExecute = (_, _) async =>
              NotificationProvidersResult(result, providersSecret);
        final h = await pumpProviders(tester, fake: fake);
        await openProviderReview(tester, NotificationProvidersAction.create);
        final r = currentReview(tester);
        await consentProvider(tester, r);
        await tapProvider(tester, 'provider-confirm-submit');
        expect(r.request.credentials!.isDisposed, isTrue);
        expect(h.api.executes, hasLength(1));
        expect(h.api.reads, 1);
        expect(find.textContaining(providersSecret), findsNothing);
        expect(find.byKey(const Key('provider-enablement-ring')), findsNothing);
        if (result == NotificationProvidersOutcome.unknown) {
          expectLocked(h);
          await tester.pumpWidget(const SizedBox());
          await tester.pump();
          expectLocked(h);
        } else {
          expectUnlocked(h);
          await tapProvider(tester, 'provider-refresh-after-review');
          expect(h.api.reads, 2);
        }
      },
    );
  }
  testWidgets(
    'unknown needs explicit fresh original-host verification and independent ACK',
    (tester) async {
      final fake = ProvidersFake()
        ..onExecute = (_, _) async => const NotificationProvidersResult(
          NotificationProvidersOutcome.unknown,
          'unknown',
        );
      final h = await pumpProviders(tester, fake: fake);
      await openProviderReview(tester, NotificationProvidersAction.enable);
      await consentProvider(tester, currentReview(tester));
      await tapProvider(tester, 'provider-confirm-submit');
      h.select(h.newSession());
      await tester.pumpAndSettle();
      expect(h.api.reads, 1);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('provider-acknowledge')),
            )
            .onPressed,
        isNull,
      );
      await tapProvider(tester, 'provider-verify-reconnected');
      expect(h.api.reads, 2);
      expectLocked(h);
      await tapProvider(tester, 'provider-acknowledge');
      expectUnlocked(h);
      expect(h.api.executes, hasLength(1));
    },
  );
  for (final width in [320.0, 430.0, 1100.0]) {
    for (final dark in [false, true]) {
      for (final provider in NotificationProviderType.values) {
        testWidgets(
          '${provider.name} create width=$width dark=$dark 200% keyboard private fields and inline review fit',
          (tester) async {
            final h = await pumpProviders(
              tester,
              width: width,
              dark: dark,
              scale: 2,
              keyboard: 300,
            );
            await openProviderReview(
              tester,
              NotificationProvidersAction.create,
              provider: provider,
            );
            final r = currentReview(tester);
            expect(find.textContaining(providersSecret), findsNothing);
            await tapProvider(tester, 'provider-review-details');
            expect(
              h.container
                  .read(notificationProvidersControllerProvider.notifier)
                  .isReviewCurrent(r),
              isTrue,
            );
            await tapProvider(tester, 'provider-review-details');
            await consentProvider(tester, r);
            await tapProvider(tester, 'provider-confirm-submit');
            expect(h.api.executes, hasLength(1));
            expect(r.request.credentials!.isDisposed, isTrue);
            expect(tester.takeException(), isNull);
          },
        );
      }
      for (final action in [
        NotificationProvidersAction.replace,
        NotificationProvidersAction.enable,
        NotificationProvidersAction.disable,
        NotificationProvidersAction.delete,
      ]) {
        testWidgets(
          '$action width=$width dark=$dark 200% keyboard review reaches one fake dispatch',
          (tester) async {
            final h = await pumpProviders(
              tester,
              width: width,
              dark: dark,
              scale: 2,
              keyboard: 300,
            );
            await openProviderReview(tester, action);
            await consentProvider(tester, currentReview(tester));
            await tapProvider(tester, 'provider-confirm-submit');
            expect(h.api.executes, hasLength(1));
            expect(h.api.mutations, 1);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
