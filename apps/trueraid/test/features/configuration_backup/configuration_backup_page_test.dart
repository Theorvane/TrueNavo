import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/configuration_backup/configuration_backup_controller.dart';
import 'package:trueraid/features/configuration_backup/configuration_backup_file.dart';
import 'package:trueraid/features/configuration_backup/configuration_backup_page.dart';
import 'package:trueraid/features/configuration_restore/configuration_restore_page.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'configuration_backup_fakes.dart';

Future<BackupHarness> pumpBackup(
  WidgetTester tester, {
  BackupFake? fake,
  BackupSaverFake? saver,
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
  final h = BackupHarness(fake: fake, saver: saver);
  addTearDown(h.dispose);
  if (disconnected) {
    h.select(null);
  } else {
    try {
      await h.load();
    } on Object {
      /* Fixed metadata error. */
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
        home: const ConfigurationBackupPage(),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return h;
}

Future<void> tapBackup(
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

Future<void> enterBackup(WidgetTester tester, String key, String value) async {
  final finder = find.byKey(Key(key));
  await tester.ensureVisible(finder);
  await tester.pumpAndSettle();
  await tester.enterText(finder, value);
  await tester.pumpAndSettle();
}

Future<void> reviewBackup(
  WidgetTester tester, {
  bool seed = false,
  bool keys = false,
}) async {
  if (seed) {
    await tapBackup(tester, 'backup-secret-seed');
    await tapBackup(tester, 'backup-seed-consent');
  }
  if (keys) await tapBackup(tester, 'backup-authorized-keys');
  await tapBackup(tester, 'backup-export-consent');
  await tapBackup(tester, 'backup-review');
}

Future<void> confirmBackup(
  WidgetTester tester,
  ConfigurationBackupRequest request, {
  bool settle = true,
}) async {
  await enterBackup(tester, 'backup-confirm-target', request.target);
  if (request.includeSecretSeed) await tapBackup(tester, 'backup-confirm-seed');
  await tapBackup(tester, 'backup-confirm-consent');
  await tapBackup(tester, 'backup-confirm-submit', settle: settle);
}

void expectReviewDisabled(WidgetTester tester) => expect(
  tester.widget<FilledButton>(find.byKey(const Key('backup-review'))).onPressed,
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
  testWidgets('restore link navigates without exporting or submitting', (
    tester,
  ) async {
    final h = await pumpBackup(tester);
    await tapBackup(tester, 'backup-open-restore');
    expect(find.byType(ConfigurationRestorePage), findsOneWidget);
    expect(h.api.reviews, isEmpty);
    expect(h.api.exports, isEmpty);
    expect(h.saver.saves, 0);
    expect(tester.takeException(), isNull);
  });
  testWidgets(
    'opening reads public metadata only and defaults both sensitive options off',
    (tester) async {
      final h = await pumpBackup(tester);
      for (final key in [
        'backup-secret-seed',
        'backup-authorized-keys',
        'backup-export-consent',
      ]) {
        expect(
          tester.widget<CheckboxListTile>(find.byKey(Key(key))).value,
          isFalse,
        );
      }
      expectReviewDisabled(tester);
      expect(
        find.text('Every configuration backup is sensitive'),
        findsOneWidget,
      );
      expect(
        find.text('Restoration is a separate recovery workflow'),
        findsOneWidget,
      );
      await tester.pump(const Duration(minutes: 5));
      expect(h.api.reads, 1);
      expect(h.api.reviews, isEmpty);
      expect(h.api.exports, isEmpty);
      expect(h.saver.saves, 0);
      await tapBackup(tester, 'backup-refresh');
      expect(h.api.reads, 2);
    },
  );
  testWidgets('disconnected makes no readiness read or export', (tester) async {
    final h = await pumpBackup(tester, disconnected: true);
    expect(find.text('Configuration backup unavailable'), findsOneWidget);
    expect(h.api.reads, 0);
    expect(h.api.exports, isEmpty);
  });
  for (final unsupported in ['picker', 'transport']) {
    testWidgets('unsupported $unsupported is explicit and never exports', (
      tester,
    ) async {
      final h = await pumpBackup(
        tester,
        fake: BackupFake(
          caps: unsupported == 'transport'
              ? const ConfigurationBackupCapabilities(
                  connected: true,
                  versionSupported: true,
                  available: true,
                )
              : backupCaps,
        ),
        saver: BackupSaverFake(supported: unsupported != 'picker'),
      );
      expect(
        find.textContaining('supported Android document picker'),
        findsOneWidget,
      );
      expectReviewDisabled(tester);
      expect(h.api.exports, isEmpty);
      expect(h.saver.saves, 0);
    });
  }
  testWidgets('wrong endpoint hides the other host and version', (
    tester,
  ) async {
    final h = await pumpBackup(
      tester,
      fake: BackupFake(
        inventory: backupInventory(endpoint: 'wss://other.example/api/current'),
      ),
    );
    expect(find.text('Backup readiness unavailable'), findsOneWidget);
    expect(find.text(backupHost), findsNothing);
    expect(find.textContaining('Version: 25.10.1'), findsNothing);
    expect(h.api.exports, isEmpty);
  });
  testWidgets('read failures are redacted and only retry explicitly', (
    tester,
  ) async {
    final h = await pumpBackup(
      tester,
      fake: BackupFake()
        ..onLoad = () async => throw StateError('PRIVATE-READ-FIXTURE'),
    );
    expect(find.text('Backup readiness unavailable'), findsOneWidget);
    expect(find.textContaining('PRIVATE-READ-FIXTURE'), findsNothing);
    await tester.pump(const Duration(minutes: 5));
    expect(h.api.reads, 1);
    await tapBackup(tester, 'backup-retry');
    expect(h.api.reads, 2);
    expect(h.saver.saves, 0);
  });
  for (final guard in ['role', 'ha', 'jobs', 'state']) {
    testWidgets('$guard blocks review and export', (tester) async {
      final h = await pumpBackup(
        tester,
        fake: BackupFake(
          inventory: backupInventory(
            fullAdmin: guard != 'role',
            ha: guard == 'ha',
            jobs: guard == 'jobs',
            state: guard == 'state' ? 'BOOTING' : 'READY',
          ),
        ),
      );
      expect(find.text('Export blocked'), findsOneWidget);
      expectReviewDisabled(tester);
      expect(h.api.reviews, isEmpty);
      expect(h.api.exports, isEmpty);
    });
  }
  for (final seed in [false, true]) {
    for (final keys in [false, true]) {
      testWidgets(
        'seed=$seed keys=$keys requires exact target and confidentiality confirmations',
        (tester) async {
          final h = await pumpBackup(tester);
          await reviewBackup(tester, seed: seed, keys: keys);
          expect(find.byType(ConfigurationBackupReviewDialog), findsOneWidget);
          expect(h.api.exports, isEmpty);
          expect(h.saver.saves, 0);
          final request = h.api.reviews.single;
          expect(request.includeSecretSeed, seed);
          expect(request.includeAuthorizedKeys, keys);
          expect(request.target, 'BACKUP $backupHost');
          await enterBackup(
            tester,
            'backup-confirm-target',
            '${request.target} ',
          );
          await tapBackup(tester, 'backup-confirm-consent');
          if (seed) await tapBackup(tester, 'backup-confirm-seed');
          expect(
            tester
                .widget<FilledButton>(
                  find.byKey(const Key('backup-confirm-submit')),
                )
                .onPressed,
            isNull,
          );
          await enterBackup(tester, 'backup-confirm-target', request.target);
          await tapBackup(tester, 'backup-confirm-submit');
          expect(h.api.exports, hasLength(1));
          expect(h.saver.saves, 1);
          expect(find.text('Provider reported file saved'), findsOneWidget);
          expect(h.api.artifacts.single.isDisposed, isTrue);
          expect(h.saver.received.single.every((b) => b == 0), isTrue);
        },
      );
    }
  }
  testWidgets(
    'including seed requires separate pre-review credential warning consent',
    (tester) async {
      final h = await pumpBackup(tester);
      await tapBackup(tester, 'backup-secret-seed');
      await tapBackup(tester, 'backup-export-consent');
      expectReviewDisabled(tester);
      expect(h.api.reviews, isEmpty);
      expect(find.textContaining('seed enables decryption'), findsOneWidget);
      await tapBackup(tester, 'backup-seed-consent');
      await tapBackup(tester, 'backup-review');
      await enterBackup(
        tester,
        'backup-confirm-target',
        h.api.reviews.single.target,
      );
      await tapBackup(tester, 'backup-confirm-consent');
      expect(
        tester
            .widget<FilledButton>(
              find.byKey(const Key('backup-confirm-submit')),
            )
            .onPressed,
        isNull,
      );
      expect(h.api.exports, isEmpty);
    },
  );
  testWidgets('cancel review never downloads or opens a picker', (
    tester,
  ) async {
    final h = await pumpBackup(tester);
    await reviewBackup(tester);
    await tester.ensureVisible(find.text('Cancel'));
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(h.api.exports, isEmpty);
    expect(h.saver.saves, 0);
    expectReviewDisabled(tester);
  });
  for (final cause in ['session', 'inventory', 'background']) {
    testWidgets(
      'review permanently expires on $cause and hides prior server details',
      (tester) async {
        final h = await pumpBackup(tester);
        await reviewBackup(tester, seed: true);
        await enterBackup(
          tester,
          'backup-confirm-target',
          h.api.reviews.single.target,
        );
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'inventory') {
          h.api.inventory = backupInventory();
          h.container.invalidate(configurationBackupInventoryProvider);
        }
        if (cause == 'background') backgroundAndResume(tester);
        await tester.pumpAndSettle();
        expect(find.text('Backup review expired'), findsOneWidget);
        expect(
          find.descendant(
            of: find.byType(ConfigurationBackupReviewDialog),
            matching: find.textContaining(backupHost),
          ),
          findsNothing,
        );
        expect(find.byKey(const Key('backup-confirm-target')), findsNothing);
        expect(h.api.exports, isEmpty);
        expect(h.saver.saves, 0);
      },
    );
  }
  testWidgets('background discards draft flags and all preliminary consents', (
    tester,
  ) async {
    final h = await pumpBackup(tester);
    await tapBackup(tester, 'backup-secret-seed');
    await tapBackup(tester, 'backup-seed-consent');
    await tapBackup(tester, 'backup-authorized-keys');
    await tapBackup(tester, 'backup-export-consent');
    backgroundAndResume(tester);
    await tester.pumpAndSettle();
    for (final key in [
      'backup-secret-seed',
      'backup-authorized-keys',
      'backup-export-consent',
    ]) {
      expect(
        tester.widget<CheckboxListTile>(find.byKey(Key(key))).value,
        isFalse,
      );
    }
    expectReviewDisabled(tester);
    expect(h.api.reviews, isEmpty);
  });
  for (final cause in ['session', 'inventory', 'background', 'dispose']) {
    testWidgets('late review after $cause never opens confirmation or picker', (
      tester,
    ) async {
      final pending = Completer<ConfigurationBackupReview>();
      final h = await pumpBackup(
        tester,
        fake: BackupFake()..onReview = (_) => pending.future,
      );
      await reviewBackup(tester);
      if (cause == 'session') h.select(h.newSession());
      if (cause == 'inventory') {
        h.api.inventory = backupInventory();
        h.container.invalidate(configurationBackupInventoryProvider);
      }
      if (cause == 'background') backgroundAndResume(tester);
      if (cause == 'dispose') await tester.pumpWidget(const SizedBox());
      pending.complete(
        ConfigurationBackupReview(
          request: h.api.reviews.single,
          endpoint: backupEndpoint,
          warnings: [],
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ConfigurationBackupReviewDialog), findsNothing);
      expect(h.api.exports, isEmpty);
      expect(h.saver.saves, 0);
    });
  }
  for (final mismatch in ['request', 'endpoint', 'error']) {
    testWidgets(
      'review $mismatch mismatch or failure withholds remote details',
      (tester) async {
        final fake = BackupFake();
        fake.onReview = (request) async {
          if (mismatch == 'error') throw StateError('PRIVATE-REVIEW-FIXTURE');
          return ConfigurationBackupReview(
            request: mismatch == 'request'
                ? ConfigurationBackupRequest(inventory: request.inventory)
                : request,
            endpoint: mismatch == 'endpoint'
                ? 'wss://other.example/api/current'
                : backupEndpoint,
            warnings: ['PRIVATE-REVIEW-FIXTURE'],
          );
        };
        final h = await pumpBackup(tester, fake: fake);
        await reviewBackup(tester);
        expect(find.byType(ConfigurationBackupReviewDialog), findsNothing);
        expect(find.textContaining('PRIVATE-REVIEW-FIXTURE'), findsNothing);
        expect(h.api.exports, isEmpty);
        expect(h.saver.saves, 0);
      },
    );
  }
  testWidgets('duplicate review callback cannot issue a second review', (
    tester,
  ) async {
    final h = await pumpBackup(tester);
    await tapBackup(tester, 'backup-export-consent');
    final callback = tester
        .widget<FilledButton>(find.byKey(const Key('backup-review')))
        .onPressed!;
    callback();
    callback();
    await tester.pumpAndSettle();
    expect(h.api.reviews, hasLength(1));
    expect(find.byType(ConfigurationBackupReviewDialog), findsOneWidget);
    expect(h.saver.saves, 0);
  });
  for (final outcome in [
    ConfigurationBackupSaveOutcome.cancelled,
    ConfigurationBackupSaveOutcome.failed,
    ConfigurationBackupSaveOutcome.unsupported,
  ]) {
    testWidgets(
      'save $outcome is not success and warns selected file may be partial',
      (tester) async {
        final h = await pumpBackup(
          tester,
          saver: BackupSaverFake()..onSave = (_, _) async => outcome,
        );
        await reviewBackup(tester);
        await confirmBackup(tester, h.api.reviews.single);
        expect(find.text('Provider reported file saved'), findsNothing);
        expect(find.textContaining('not confirmed saved'), findsOneWidget);
        expect(find.textContaining('empty or partial'), findsWidgets);
        await tester.pump(const Duration(minutes: 5));
        expect(h.saver.saves, 1);
        expect(h.api.exports, hasLength(1));
        expect(h.saver.received.single.every((byte) => byte == 0), isTrue);
      },
    );
  }
  testWidgets(
    'unknown export offers no file, locks refresh, and requires explicit host verification',
    (tester) async {
      final h = await pumpBackup(
        tester,
        fake: BackupFake()
          ..onExecute = (_) async => const ConfigurationBackupResult(
            ConfigurationBackupOutcome.unknown,
            'PRIVATE-RESULT-FIXTURE',
            jobId: 80,
          ),
      );
      await reviewBackup(tester);
      await confirmBackup(tester, h.api.reviews.single);
      expect(find.text('Inspect before continuing'), findsOneWidget);
      expect(find.textContaining('PRIVATE-RESULT-FIXTURE'), findsNothing);
      expectReviewDisabled(tester);
      expect(
        tester
            .widget<IconButton>(find.byKey(const Key('backup-refresh')))
            .onPressed,
        isNull,
      );
      await tester.pump(const Duration(minutes: 5));
      expect(h.api.reads, 1);
      expect(h.saver.saves, 0);
      h.select(h.newSession());
      await tester.pumpAndSettle();
      expect(find.text('Original export needs attention'), findsOneWidget);
      expect(find.text(backupHost), findsNothing);
      expect(h.api.reads, 1);
      expect(
        tester
            .widget<OutlinedButton>(find.byKey(const Key('backup-acknowledge')))
            .onPressed,
        isNull,
      );
      await tapBackup(tester, 'backup-verify-reconnected');
      expect(h.api.reads, 2);
      await tapBackup(tester, 'backup-acknowledge');
      expect(
        h.container.read(configurationBackupControllerProvider).locked,
        isFalse,
      );
      expect(h.api.exports, hasLength(1));
      expect(h.saver.saves, 0);
    },
  );
  testWidgets(
    'malformed completed artifact never exposes bytes, filename or picker',
    (tester) async {
      final fake = BackupFake();
      fake.onExecute = (review) async =>
          fake.completed(review, filename: '../PRIVATE-ARTIFACT-TOKEN.db');
      final h = await pumpBackup(tester, fake: fake);
      await reviewBackup(tester);
      await confirmBackup(tester, h.api.reviews.single);
      expect(find.text('Inspect before continuing'), findsOneWidget);
      expect(find.textContaining('PRIVATE-ARTIFACT-TOKEN'), findsNothing);
      expect(h.saver.saves, 0);
      expect(h.api.sourceBuffers.single.every((byte) => byte == 0), isTrue);
    },
  );
  testWidgets(
    'background during export discards a late artifact without showing picker',
    (tester) async {
      final pending = Completer<ConfigurationBackupResult>();
      final h = await pumpBackup(
        tester,
        fake: BackupFake()..onExecute = (_) => pending.future,
      );
      await reviewBackup(tester);
      await confirmBackup(tester, h.api.reviews.single, settle: false);
      backgroundAndResume(tester);
      pending.complete(h.api.completed(h.api.exports.single));
      await tester.pumpAndSettle();
      expect(h.saver.saves, 0);
      expect(h.api.artifacts.single.isDisposed, isTrue);
      expect(h.api.sourceBuffers.single.every((b) => b == 0), isTrue);
      expect(find.text('Inspect before continuing'), findsOneWidget);
    },
  );
  testWidgets('late old readiness cannot overwrite a replacement session', (
    tester,
  ) async {
    final h = await pumpBackup(tester),
        pending = Completer<ConfigurationBackupInventory>();
    final original = h.api.inventory;
    h.api.onLoad = () => pending.future;
    await tapBackup(tester, 'backup-refresh', settle: false);
    final current = backupInventory(
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
      h.container.read(configurationBackupInventoryProvider).asData?.value,
      same(current),
    );
    expect(find.text(backupHost), findsNothing);
    expect(h.saver.saves, 0);
  });
  for (final width in [320.0, 430.0, 1100.0]) {
    for (final dark in [false, true]) {
      for (final form in ['page', 'review']) {
        testWidgets(
          '$form width=$width dark=$dark at 200 percent with keyboard has no overflow',
          (tester) async {
            final h = await pumpBackup(
              tester,
              width: width,
              dark: dark,
              scale: 2,
              keyboard: form == 'page' ? 0 : 300,
            );
            if (form == 'review') {
              await reviewBackup(tester, seed: true, keys: true);
              await confirmBackup(tester, h.api.reviews.single);
              expect(h.saver.saves, 1);
              expect(h.api.exports, hasLength(1));
            }
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}
