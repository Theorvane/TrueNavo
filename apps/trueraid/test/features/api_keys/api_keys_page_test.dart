import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/api_keys/api_key_review.dart';
import 'package:trueraid/features/api_keys/api_keys_controller.dart';
import 'package:trueraid/features/api_keys/api_keys_page.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'api_keys_fakes.dart';

Future<ApiKeysHarness> pumpKeys(
  WidgetTester tester, {
  ApiKeysFake? fake,
  double width = 800,
  double scale = 1,
  double keyboard = 0,
  bool disconnected = false,
  Widget Function(ApiKeysHarness)? dialog,
}) async {
  tester.view.physicalSize = Size(width, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final h = ApiKeysHarness(fake: fake);
  addTearDown(h.dispose);
  if (disconnected) h.select(null);
  if (!disconnected) {
    try {
      await h.container.read(apiKeysInventoryProvider.future);
    } on Object {
      /* Render safe error state. */
    }
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: h.container,
      child: MaterialApp(
        theme: TrueRAIDTheme.dark(),
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(context).copyWith(
            textScaler: TextScaler.linear(scale),
            viewInsets: EdgeInsets.only(bottom: keyboard),
          ),
          child: child!,
        ),
        home: dialog == null
            ? const ApiKeysPage()
            : Scaffold(
                body: Builder(
                  builder: (context) => FilledButton(
                    key: const Key('open-dialog'),
                    onPressed: () => showDialog<void>(
                      context: context,
                      barrierDismissible: false,
                      builder: (_) => dialog(h),
                    ),
                    child: const Text('Open fixture'),
                  ),
                ),
              ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  if (dialog != null) await tapKey(tester, 'open-dialog');
  return h;
}

Future<void> tapKey(WidgetTester tester, String key) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.tap(finder);
  await tester.pumpAndSettle();
}

Future<void> enterKey(WidgetTester tester, String key, String text) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, text);
  await tester.pumpAndSettle();
}

Future<void> createReview(WidgetTester tester) async {
  await tapKey(tester, 'api-keys-create');
  await enterKey(tester, 'api-key-editor-name', 'New integration');
  await tapKey(tester, 'api-key-editor-review');
}

Future<void> confirmKey(WidgetTester tester, String target) async {
  await enterKey(tester, 'api-key-review-confirmation', target);
  await tapKey(tester, 'api-key-review-ack');
  await tapKey(tester, 'api-key-review-submit');
}

Future<void> revealSecret(WidgetTester tester) async {
  await tapKey(tester, 'api-key-secret-ack');
  await tapKey(tester, 'api-key-secret-reveal');
}

void background(WidgetTester tester, AppLifecycleState target) {
  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    tester.binding.handleAppLifecycleStateChanged(state);
    if (state == target) break;
  }
}

void resume(WidgetTester tester) {
  if (tester.binding.lifecycleState == AppLifecycleState.paused) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
  }
  if (tester.binding.lifecycleState == AppLifecycleState.hidden) {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
  }
  tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
}

void main() {
  testWidgets(
    'open and manual refresh are read-only and show chart breakdown',
    (tester) async {
      final h = await pumpKeys(tester);
      expect(find.byType(ApiKeyStatusChart), findsOneWidget);
      expect(find.text('2 Not expired'), findsOneWidget);
      expect(find.text('Recorded key status'), findsOneWidget);
      expect(find.textContaining('this device’s clock'), findsOneWidget);
      expect(
        find.textContaining('not proof of authentication validity'),
        findsOneWidget,
      );
      expect(find.text('1 Expired'), findsOneWidget);
      expect(find.text('1 Revoked'), findsOneWidget);
      await tapKey(tester, 'api-keys-refresh');
      expect(h.api.reads, 2);
      expect(h.api.reviews, isEmpty);
      expect(h.api.writes, isEmpty);
    },
  );

  testWidgets('disconnected page performs no reads or changes', (tester) async {
    final h = await pumpKeys(tester, disconnected: true);
    expect(find.text('API-key management unavailable'), findsOneWidget);
    expect(h.api.reads, 0);
    expect(h.api.writes, isEmpty);
  });

  testWidgets('stored current API key is protected for every action', (
    tester,
  ) async {
    final h = await pumpKeys(tester);
    for (final action in ['edit', 'rotate', 'delete']) {
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(Key('api-key-$action-1')))
            .onPressed,
        isNull,
      );
    }
    expect(h.api.writes, isEmpty);
  });

  testWidgets('missing capabilities disable create and all key changes', (
    tester,
  ) async {
    final h = await pumpKeys(
      tester,
      fake: ApiKeysFake(
        caps: const ApiKeysCapabilities(
          connected: true,
          versionSupported: true,
          available: true,
          canCreate: false,
          canUpdate: false,
          canDelete: false,
        ),
      ),
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('api-keys-create')))
          .onPressed,
      isNull,
    );
    for (final action in ['edit', 'rotate', 'delete']) {
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(Key('api-key-$action-2')))
            .onPressed,
        isNull,
      );
    }
    expect(h.api.writes, isEmpty);
  });

  testWidgets('STIG explains and disables mutation controls', (tester) async {
    await pumpKeys(
      tester,
      fake: ApiKeysFake(inventory: keyInventory(stig: true)),
    );
    expect(find.textContaining('GPOS STIG'), findsWidgets);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('api-keys-create')))
          .onPressed,
      isNull,
    );
  });

  testWidgets('empty inventory has useful empty state', (tester) async {
    await pumpKeys(
      tester,
      fake: ApiKeysFake(inventory: keyInventory(empty: true)),
    );
    expect(find.text('No API keys'), findsOneWidget);
    expect(find.text('0 Not expired'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'remote inventory errors are withheld and only manually retried',
    (tester) async {
      final api = ApiKeysFake()
        ..onLoad = () => Future.error(StateError(syntheticApiKey));
      final h = await pumpKeys(tester, fake: api);
      expect(find.text('Key inventory unavailable'), findsOneWidget);
      expect(find.textContaining(syntheticApiKey), findsNothing);
      expect(h.api.reads, 1);
      await tapKey(tester, 'api-keys-retry');
      expect(h.api.reads, 2);
      expect(h.api.writes, isEmpty);
    },
  );

  testWidgets(
    'create requires valid name then exact target and impact acknowledgement',
    (tester) async {
      final h = await pumpKeys(tester);
      await tapKey(tester, 'api-keys-create');
      await tapKey(tester, 'api-key-editor-review');
      expect(h.api.reviews, isEmpty);
      await enterKey(tester, 'api-key-editor-name', 'New integration');
      await tapKey(tester, 'api-key-editor-review');
      expect(h.api.reviews.length, 1);
      expect(h.api.writes, isEmpty);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('api-key-review-submit')),
            )
            .onPressed,
        isNull,
      );
      await enterKey(
        tester,
        'api-key-review-confirmation',
        'CREATE New integration ',
      );
      await tapKey(tester, 'api-key-review-ack');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('api-key-review-submit')),
            )
            .onPressed,
        isNull,
      );
      await enterKey(
        tester,
        'api-key-review-confirmation',
        'CREATE New integration',
      );
      await tapKey(tester, 'api-key-review-submit');
      expect(h.api.writes.length, 1);
      expect(find.text('Synthetic operation confirmed.'), findsOneWidget);
    },
  );

  testWidgets('invalid UTC date cannot be normalized into a different expiry', (
    tester,
  ) async {
    final h = await pumpKeys(tester);
    await tapKey(tester, 'api-keys-create');
    await enterKey(tester, 'api-key-editor-name', 'New integration');
    final now = DateTime.now().toUtc();
    final year = now.month >= 3 ? now.year + 1 : now.year;
    await enterKey(tester, 'api-key-editor-expiry', '$year-02-30T12:00:00Z');
    await tapKey(tester, 'api-key-editor-review');
    expect(h.api.reviews, isEmpty);
    expect(find.byType(ApiKeyEditor), findsOneWidget);
  });

  testWidgets('no expiry requires explicit checkbox and sends null', (
    tester,
  ) async {
    final h = await pumpKeys(tester);
    await tapKey(tester, 'api-keys-create');
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const Key('api-key-editor-never')),
          )
          .value,
      isFalse,
    );
    await enterKey(tester, 'api-key-editor-name', 'New integration');
    await tapKey(tester, 'api-key-editor-never');
    await tapKey(tester, 'api-key-editor-review');
    expect(h.api.reviews.single.expiresAt, isNull);
    expect(h.api.writes, isEmpty);
  });

  testWidgets(
    'session change permanently expires editor and clears local fields',
    (tester) async {
      final h = await pumpKeys(tester);
      await tapKey(tester, 'api-key-edit-2');
      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
      await tester.pumpAndSettle();
      h.select(h.session);
      await tester.pumpAndSettle();
      expect(find.text('Editor is no longer current'), findsOneWidget);
      expect(find.byKey(const Key('api-key-editor-name')), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('api-key-editor-review')),
            )
            .onPressed,
        isNull,
      );
      expect(h.api.writes, isEmpty);
    },
  );

  testWidgets('inventory reload permanently expires exact-target review', (
    tester,
  ) async {
    final h = await pumpKeys(tester);
    await createReview(tester);
    await enterKey(
      tester,
      'api-key-review-confirmation',
      'CREATE New integration',
    );
    await tapKey(tester, 'api-key-review-ack');
    h.container.invalidate(apiKeysInventoryProvider);
    await tester.pumpAndSettle();
    expect(find.text('Review is no longer current'), findsOneWidget);
    expect(find.byKey(const Key('api-key-review-confirmation')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('api-key-review-submit')))
          .onPressed,
      isNull,
    );
    expect(h.api.writes, isEmpty);
  });

  testWidgets('late review after session switch never opens confirmation', (
    tester,
  ) async {
    final pending = Completer<ApiKeyReview>();
    final api = ApiKeysFake()..onReview = (_) => pending.future;
    final h = await pumpKeys(tester, fake: api);
    await createReview(tester);
    h.select(h.newSession());
    pending.complete(
      ApiKeyReview(
        request: api.reviews.single,
        endpoint: apiKeyEndpoint,
        warnings: [],
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(ApiKeyReviewDialog), findsNothing);
    expect(h.api.writes, isEmpty);
  });

  testWidgets('unknown result locks refresh/create and does not retry', (
    tester,
  ) async {
    final api = ApiKeysFake()
      ..onExecute = () async =>
          const ApiKeyResult(ApiKeyOutcome.unknown, 'Unverified');
    final h = await pumpKeys(tester, fake: api);
    await createReview(tester);
    await confirmKey(tester, 'CREATE New integration');
    expect(h.container.read(apiKeysControllerProvider).unknown, isTrue);
    expect(
      tester
          .widget<IconButton>(find.byKey(const Key('api-keys-refresh')))
          .onPressed,
      isNull,
    );
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('api-keys-create')))
          .onPressed,
      isNull,
    );
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
    expect(h.api.writes.length, 1);
  });

  testWidgets(
    'secret remains hidden until separate private-place acknowledgement',
    (tester) async {
      final secret = ApiKeyOneTimeSecret(syntheticApiKey);
      await pumpKeys(
        tester,
        dialog: (h) => ApiKeySecretDialog(session: h.session, secret: secret),
      );
      expect(find.text(syntheticApiKey), findsNothing);
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('api-key-secret-reveal')),
            )
            .onPressed,
        isNull,
      );
      await revealSecret(tester);
      expect(find.text(syntheticApiKey), findsOneWidget);
      expect(secret.take(), isNull);
      expect(find.byKey(const Key('api-key-secret-reveal')), findsNothing);
    },
  );

  testWidgets(
    'system clipboard receives secret only after explicit copy button',
    (tester) async {
      final calls = <MethodCall>[];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          calls.add(call);
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      final secret = ApiKeyOneTimeSecret(syntheticApiKey);
      await pumpKeys(
        tester,
        dialog: (h) => ApiKeySecretDialog(session: h.session, secret: secret),
      );
      await revealSecret(tester);
      expect(calls.where((c) => c.method == 'Clipboard.setData'), isEmpty);
      await tapKey(tester, 'api-key-secret-copy');
      final clipboard = calls
          .where((c) => c.method == 'Clipboard.setData')
          .toList();
      expect(clipboard.length, 1);
      expect(clipboard.single.arguments, {'text': syntheticApiKey});
      expect(
        find.textContaining('clipboard history may retain it'),
        findsOneWidget,
      );
    },
  );

  for (final revealed in [false, true]) {
    testWidgets('closing secret dialog discards value; revealed=$revealed', (
      tester,
    ) async {
      final secret = ApiKeyOneTimeSecret(syntheticApiKey);
      await pumpKeys(
        tester,
        dialog: (h) => ApiKeySecretDialog(session: h.session, secret: secret),
      );
      if (revealed) await revealSecret(tester);
      await tapKey(tester, 'api-key-secret-close');
      expect(find.text(syntheticApiKey), findsNothing);
      expect(secret.take(), isNull);
    });
    testWidgets(
      'session change discards secret permanently; revealed=$revealed',
      (tester) async {
        final secret = ApiKeyOneTimeSecret(syntheticApiKey);
        final h = await pumpKeys(
          tester,
          dialog: (h) => ApiKeySecretDialog(session: h.session, secret: secret),
        );
        if (revealed) await revealSecret(tester);
        h.select(null);
        await tester.pumpAndSettle();
        h.select(h.session);
        await tester.pumpAndSettle();
        expect(find.text(syntheticApiKey), findsNothing);
        expect(find.byKey(const Key('api-key-secret-reveal')), findsNothing);
        expect(secret.take(), isNull);
      },
    );
  }

  for (final state in [
    AppLifecycleState.inactive,
    AppLifecycleState.paused,
    AppLifecycleState.hidden,
    AppLifecycleState.detached,
  ]) {
    testWidgets('$state permanently discards revealed secret', (tester) async {
      resume(tester);
      addTearDown(() => resume(tester));
      final secret = ApiKeyOneTimeSecret(syntheticApiKey);
      await pumpKeys(
        tester,
        dialog: (h) => ApiKeySecretDialog(session: h.session, secret: secret),
      );
      await revealSecret(tester);
      background(tester, state);
      resume(tester);
      await tester.pumpAndSettle();
      expect(find.text(syntheticApiKey), findsNothing);
      expect(find.byKey(const Key('api-key-secret-reveal')), findsNothing);
      expect(secret.take(), isNull);
    });
  }

  for (final state in [AppLifecycleState.inactive]) {
    testWidgets(
      'dialog created while already $state cannot later reveal secret',
      (tester) async {
        resume(tester);
        background(tester, state);
        addTearDown(() => resume(tester));
        final secret = ApiKeyOneTimeSecret(syntheticApiKey);
        await pumpKeys(
          tester,
          dialog: (h) => ApiKeySecretDialog(session: h.session, secret: secret),
        );
        resume(tester);
        await tester.pumpAndSettle();
        expect(find.byKey(const Key('api-key-secret-reveal')), findsNothing);
        expect(secret.take(), isNull);
      },
    );
  }

  testWidgets(
    'secret returned by pending change while paused is never delivered',
    (tester) async {
      resume(tester);
      addTearDown(() => resume(tester));
      final pending = Completer<ApiKeyResult>(),
          secret = ApiKeyOneTimeSecret(syntheticApiKey);
      final api = ApiKeysFake()..onExecute = () => pending.future;
      final h = await pumpKeys(tester, fake: api);
      await createReview(tester);
      await enterKey(
        tester,
        'api-key-review-confirmation',
        'CREATE New integration',
      );
      await tapKey(tester, 'api-key-review-ack');
      final submit = find.byKey(const Key('api-key-review-submit'));
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(h.api.writes.length, 1);
      background(tester, AppLifecycleState.paused);
      pending.complete(
        ApiKeyResult(ApiKeyOutcome.succeeded, 'Confirmed', secret: secret),
      );
      await tester.pump();
      resume(tester);
      await tester.pumpAndSettle();
      expect(find.byType(ApiKeySecretDialog), findsNothing);
      expect(secret.take(), isNull);
      expect(
        h.container.read(apiKeysControllerProvider).result!.secret,
        isNull,
      );
      final result = h.container.read(apiKeysControllerProvider).result!;
      expect(result.outcome, ApiKeyOutcome.succeeded);
      expect(result.message, contains('no longer holds its one-time value'));
      expect(result.message, contains('do not repeat the original request'));
      expect(h.api.writes.length, 1);
    },
  );

  testWidgets('route disposal without revealing discards secret', (
    tester,
  ) async {
    final secret = ApiKeyOneTimeSecret(syntheticApiKey);
    await pumpKeys(
      tester,
      dialog: (h) => ApiKeySecretDialog(session: h.session, secret: secret),
    );
    await tester.pumpWidget(const SizedBox());
    expect(secret.take(), isNull);
  });

  for (final width in [320.0, 430.0]) {
    testWidgets(
      '$width px at 200 percent keeps workspace editor and review usable',
      (tester) async {
        final h = await pumpKeys(tester, width: width, scale: 2, keyboard: 280);
        expect(tester.takeException(), isNull);
        await createReview(tester);
        expect(tester.takeException(), isNull);
        await confirmKey(tester, 'CREATE New integration');
        expect(h.api.writes.length, 1);
        expect(tester.takeException(), isNull);
      },
    );
    testWidgets('$width px at 200 percent keeps one-time delivery usable', (
      tester,
    ) async {
      final secret = ApiKeyOneTimeSecret(syntheticApiKey);
      await pumpKeys(
        tester,
        width: width,
        scale: 2,
        dialog: (h) => ApiKeySecretDialog(session: h.session, secret: secret),
      );
      await revealSecret(tester);
      expect(tester.takeException(), isNull);
      await tapKey(tester, 'api-key-secret-close');
      expect(secret.take(), isNull);
      expect(tester.takeException(), isNull);
    });
  }
}
