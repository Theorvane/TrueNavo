import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/configuration_restore/configuration_restore_controller.dart';
import 'package:trueraid/features/configuration_restore/configuration_restore_page.dart';
import 'package:trueraid/features/configuration_reset/configuration_reset_page.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'configuration_restore_fakes.dart';

Future<RestoreHarness> pumpRestore(
  WidgetTester tester, {
  RestoreFake? fake,
  RestorePickerFake? picker,
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
  final h = RestoreHarness(fake: fake, picker: picker);
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
        home: const ConfigurationRestorePage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapRestore(
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

Future<void> enterRestore(WidgetTester tester, String key, String text) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, text);
  await tester.pumpAndSettle();
}

Future<void> selectRestore(WidgetTester tester) async {
  await tapRestore(tester, 'restore-read-consent');
  await tapRestore(tester, 'restore-choose-file');
}

Future<void> reviewRestore(WidgetTester tester) async {
  await selectRestore(tester);
  await tapRestore(tester, 'restore-review');
}

Future<void> confirmRestore(
  WidgetTester tester,
  ConfigurationRestoreRequest request, {
  bool settle = true,
}) async {
  await enterRestore(tester, 'restore-confirm-target', request.target);
  for (var i = 0; i < 6; i++) {
    await tapRestore(tester, 'restore-confirm-ack-$i');
  }
  await tapRestore(tester, 'restore-confirm-submit', settle: settle);
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
    'opening does not choose or upload and warns automatic reboot and missing material loss',
    (tester) async {
      final h = await pumpRestore(tester);
      expect(
        find.text('This replaces configuration and automatically reboots'),
        findsOneWidget,
      );
      expect(
        find.textContaining('removed from their destination'),
        findsOneWidget,
      );
      expect(
        find.text('Factory reset is a separate recovery workflow'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<CheckboxListTile>(
              find.byKey(const Key('restore-read-consent')),
            )
            .value,
        isFalse,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('restore-choose-file')),
            )
            .onPressed,
        isNull,
      );
      await tester.pump(const Duration(minutes: 5));
      expect(h.api.reads, 1);
      expect(h.picker.picks, 0);
      expect(h.api.executes, isEmpty);
    },
  );
  testWidgets('disconnected performs no reads', (tester) async {
    final h = await pumpRestore(tester, disconnected: true);
    expect(h.api.reads, 0);
    expect(find.text('Configuration restore unavailable'), findsOneWidget);
  });
  testWidgets('unsupported picker blocks all file reading and upload', (
    tester,
  ) async {
    final h = await pumpRestore(
      tester,
      picker: RestorePickerFake(supported: false),
    );
    expect(
      find.textContaining('supported Android document picker'),
      findsOneWidget,
    );
    expect(h.picker.picks, 0);
  });
  testWidgets('wrong endpoint readiness hides identity', (tester) async {
    final h = await pumpRestore(
      tester,
      fake: RestoreFake(
        inventory: restoreInventory(
          endpoint: 'wss://other.example/api/current',
        ),
      ),
    );
    expect(find.text('Restore readiness unavailable'), findsOneWidget);
    expect(find.text(restoreHost), findsNothing);
    expect(h.api.uploads, 0);
  });
  for (final guard in ['admin', 'ha', 'jobs', 'healthy', 'state', 'next']) {
    testWidgets('$guard readiness blocks choosing a file', (tester) async {
      final h = await pumpRestore(
        tester,
        fake: RestoreFake(
          inventory: restoreInventory(
            admin: guard != 'admin',
            ha: guard == 'ha',
            jobs: guard == 'jobs',
            healthy: guard != 'healthy',
            state: guard == 'state' ? 'BOOTING' : 'READY',
            nextChanged: guard == 'next',
          ),
        ),
      );
      expect(find.text('Restore blocked'), findsOneWidget);
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('restore-choose-file')),
            )
            .onPressed,
        isNull,
      );
      expect(h.picker.picks, 0);
    });
  }
  testWidgets(
    'local file inspection exposes only envelope fingerprint and no upload',
    (tester) async {
      final h = await pumpRestore(tester);
      await selectRestore(tester);
      expect(find.text('Format: database'), findsOneWidget);
      expect(find.text('Size: 512 bytes'), findsOneWidget);
      expect(find.textContaining('source version'), findsOneWidget);
      expect(h.api.uploads, 0);
      expect(h.api.reviews, isEmpty);
      await tapRestore(tester, 'restore-discard-file');
      expect(h.api.files.single.isDisposed, isTrue);
      expect(find.text('Format: database'), findsNothing);
    },
  );
  testWidgets('reset link discards selected restore file and only navigates', (
    tester,
  ) async {
    final h = await pumpRestore(tester);
    await selectRestore(tester);
    await tapRestore(tester, 'restore-open-reset');
    expect(find.byType(ConfigurationResetPage), findsOneWidget);
    expect(h.api.files.single.isDisposed, isTrue);
    expect(h.api.uploads, 0);
    expect(h.api.reviews, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'exact server target fingerprint comparison and all consents required',
    (tester) async {
      final h = await pumpRestore(tester);
      await reviewRestore(tester);
      final request = h.api.reviews.single;
      await enterRestore(
        tester,
        'restore-confirm-target',
        '${request.target} ',
      );
      expect(find.text(request.file.sha256), findsWidgets);
      expect(find.byKey(const Key('restore-confirm-hash')), findsNothing);
      for (var i = 0; i < 6; i++) {
        await tapRestore(tester, 'restore-confirm-ack-$i');
      }
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('restore-confirm-submit')),
            )
            .onPressed,
        isNull,
      );
      await enterRestore(tester, 'restore-confirm-target', request.target);
      await tapRestore(tester, 'restore-confirm-ack-5');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('restore-confirm-submit')),
            )
            .onPressed,
        isNull,
      );
      await tapRestore(tester, 'restore-confirm-ack-5');
      await tapRestore(tester, 'restore-confirm-ack-4');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('restore-confirm-submit')),
            )
            .onPressed,
        isNull,
      );
      await tapRestore(tester, 'restore-confirm-ack-4');
      await tapRestore(tester, 'restore-confirm-submit');
      expect(h.api.executes, hasLength(1));
      expect(h.api.files.single.isDisposed, isTrue);
    },
  );
  testWidgets('cancel review destroys selected capsule', (tester) async {
    final h = await pumpRestore(tester);
    await reviewRestore(tester);
    await tester.ensureVisible(find.text('Cancel and discard file'));
    await tester.tap(find.text('Cancel and discard file'));
    await tester.pumpAndSettle();
    expect(h.api.files.single.isDisposed, isTrue);
    expect(h.api.executes, isEmpty);
    expect(find.text('Format: database'), findsNothing);
  });
  testWidgets(
    'normal confirmation preserves authorization through delayed preflight',
    (tester) async {
      final pending = Completer<void>();
      final fake = RestoreFake();
      fake.onExecute = (_, current) async {
        await pending.future;
        if (current()) fake.uploads++;
        return const ConfigurationRestoreResult(
          ConfigurationRestoreOutcome.accepted,
          'Synthetic acceptance only',
          jobId: 71,
        );
      };
      final h = await pumpRestore(tester, fake: fake);
      await reviewRestore(tester);
      await confirmRestore(tester, h.api.reviews.single, settle: false);
      await tester.pump(const Duration(milliseconds: 600));
      expect(h.api.executes, hasLength(1));
      expect(h.api.files.single.isDisposed, isFalse);
      pending.complete();
      await tester.pumpAndSettle();
      expect(fake.uploads, 1);
      expect(
        h.container.read(configurationRestoreControllerProvider).status,
        ConfigurationRestoreStatus.accepted,
      );
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
      expect(tester.takeException(), isNull);
    },
  );
  for (final cause in ['session', 'inventory', 'background']) {
    testWidgets('review expires on $cause and hides original file details', (
      tester,
    ) async {
      final h = await pumpRestore(tester);
      await reviewRestore(tester);
      if (cause == 'session') h.select(h.newSession());
      if (cause == 'inventory') {
        h.container.invalidate(configurationRestoreInventoryProvider);
      }
      if (cause == 'background') background(tester);
      await tester.pumpAndSettle();
      expect(find.text('Restore review expired'), findsOneWidget);
      expect(
        find.descendant(
          of: find.byType(ConfigurationRestoreReviewDialog),
          matching: find.textContaining('SHA-256'),
        ),
        findsNothing,
      );
      expect(h.api.executes, isEmpty);
    });
  }
  for (final cause in ['session', 'background', 'route']) {
    testWidgets('late review after $cause never shows confirmation', (
      tester,
    ) async {
      final pending = Completer<ConfigurationRestoreReview>();
      final h = await pumpRestore(
        tester,
        fake: RestoreFake()..onReview = (_) => pending.future,
      );
      await selectRestore(tester);
      await tapRestore(tester, 'restore-review', settle: false);
      if (cause == 'session') h.select(h.newSession());
      if (cause == 'background') background(tester);
      if (cause == 'route') await tester.pumpWidget(const SizedBox());
      pending.complete(
        ConfigurationRestoreReview(
          request: h.api.reviews.single,
          endpoint: restoreEndpoint,
          warnings: [],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ConfigurationRestoreReviewDialog), findsNothing);
      expect(h.api.files.single.isDisposed, isTrue);
      expect(h.api.executes, isEmpty);
    });
  }
  testWidgets(
    'route disposal destroys ready file without modifying providers during build',
    (tester) async {
      final h = await pumpRestore(tester);
      await selectRestore(tester);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(h.api.files.single.isDisposed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
  testWidgets('covering route destroys a selected file', (tester) async {
    final h = await pumpRestore(tester);
    await selectRestore(tester);
    final context = tester.element(find.byType(ConfigurationRestorePage));
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('Other workspace')),
      ),
    );
    await tester.pumpAndSettle();
    expect(h.api.files.single.isDisposed, isTrue);
    expect(h.api.executes, isEmpty);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'accepted restore remains fenced on route removal and never polls',
    (tester) async {
      final h = await pumpRestore(
        tester,
        fake: RestoreFake()
          ..onExecute = (_, _) async => const ConfigurationRestoreResult(
            ConfigurationRestoreOutcome.accepted,
            'Queued',
            jobId: 80,
          ),
      );
      await reviewRestore(tester);
      await confirmRestore(tester, h.api.reviews.single);
      expect(find.text('Accepted — completion unverified'), findsOneWidget);
      await tester.pump(const Duration(minutes: 5));
      expect(h.api.reads, 1);
      await tester.pumpWidget(const SizedBox());
      await tester.pumpAndSettle();
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
      expect(h.api.executes, hasLength(1));
    },
  );
  testWidgets(
    'changed-address recovery requires separate ownership acknowledgement',
    (tester) async {
      final h = await pumpRestore(
        tester,
        fake: RestoreFake()
          ..onExecute = (_, _) async => const ConfigurationRestoreResult(
            ConfigurationRestoreOutcome.unknown,
            'Unverified',
          ),
      );
      await reviewRestore(tester);
      await confirmRestore(tester, h.api.reviews.single);
      h.api.inventory = restoreInventory(
        endpoint: 'wss://new.example/api/current',
      );
      h.select(h.newSession(endpoint: h.api.inventory.endpoint));
      await tester.pumpAndSettle();
      expect(h.api.reads, 1);
      await tapRestore(tester, 'restore-verify-reconnected');
      expect(
        find.text('Manually connected address: wss://new.example/api/current'),
        findsOneWidget,
      );
      expect(
        tester
            .widget<OutlinedButton>(
              find.byKey(const Key('restore-acknowledge')),
            )
            .onPressed,
        isNull,
      );
      await tapRestore(tester, 'restore-changed-address');
      await tapRestore(tester, 'restore-acknowledge');
      expect(
        h.container.read(configurationRestoreControllerProvider).locked,
        isFalse,
      );
      expect(h.api.executes, hasLength(1));
    },
  );
  for (final phase in ['review', 'execute']) {
    testWidgets(
      'covering route during pending $phase destroys authorization before any late upload',
      (tester) async {
        final pendingReview = Completer<ConfigurationRestoreReview>();
        final pendingExecute = Completer<void>();
        final fake = RestoreFake();
        if (phase == 'review') fake.onReview = (_) => pendingReview.future;
        if (phase == 'execute') {
          fake.onExecute = (_, current) async {
            await pendingExecute.future;
            if (current()) fake.uploads++;
            return const ConfigurationRestoreResult(
              ConfigurationRestoreOutcome.rejected,
              'Guarded',
            );
          };
        }
        final h = await pumpRestore(tester, fake: fake);
        await selectRestore(tester);
        if (phase == 'review') {
          await tapRestore(tester, 'restore-review', settle: false);
        } else {
          await tapRestore(tester, 'restore-review');
          await confirmRestore(tester, h.api.reviews.single, settle: false);
        }
        final context = tester.element(find.byType(ConfigurationRestorePage));
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => const Scaffold(body: Text('Another workspace')),
          ),
        );
        if (phase == 'review') {
          pendingReview.complete(
            ConfigurationRestoreReview(
              request: h.api.reviews.single,
              endpoint: restoreEndpoint,
              warnings: [],
            ),
          );
        }
        if (phase == 'execute') pendingExecute.complete();
        await tester.pumpAndSettle();
        expect(h.api.uploads, 0);
        expect(h.api.files.single.isDisposed, isTrue);
        expect(find.byType(ConfigurationRestoreReviewDialog), findsNothing);
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
  for (final width in [320.0, 430.0, 1100.0]) {
    for (final dark in [false, true]) {
      for (final form in ['page', 'review']) {
        testWidgets(
          '$form width=$width dark=$dark at 200 percent with keyboard',
          (tester) async {
            final h = await pumpRestore(
              tester,
              width: width,
              dark: dark,
              scale: 2,
              keyboard: form == 'page' ? 0 : 300,
            );
            if (form == 'review') {
              await reviewRestore(tester);
              await confirmRestore(tester, h.api.reviews.single);
              expect(h.api.executes, hasLength(1));
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
