import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/configuration_backup/configuration_backup_controller.dart';
import 'package:truenavo/features/configuration_backup/configuration_backup_file.dart';
import 'package:truenavo/features/management/server_operation_lock.dart';
import 'package:truenas_api/truenas_api.dart';

import 'configuration_backup_fakes.dart';

ConfigurationBackupController controller(BackupHarness h) =>
    h.container.read(configurationBackupControllerProvider.notifier);
ConfigurationBackupState state(BackupHarness h) =>
    h.container.read(configurationBackupControllerProvider);
Future<void> run(
  BackupHarness h,
  ConfigurationBackupReview review, {
  String? confirmation,
  bool consent = true,
  bool seedConsent = true,
}) => controller(h).execute(
  expectedSession: h.session,
  review: review,
  confirmation: confirmation ?? review.target,
  confidentialityAccepted: consent,
  secretSeedAccepted: seedConsent,
);
void expectWiped(BackupHarness h) {
  for (final artifact in h.api.artifacts) {
    expect(artifact.isDisposed, isTrue);
  }
  for (final bytes in [...h.api.sourceBuffers, ...h.saver.received]) {
    expect(bytes.every((byte) => byte == 0), isTrue);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final seed in [false, true]) {
    for (final keys in [false, true]) {
      test(
        'seed=$seed keys=$keys saves exact reviewed artifact once and wipes ownership',
        () async {
          final h = BackupHarness();
          addTearDown(h.dispose);
          await h.load();
          final review = backupReview(h.api.inventory, seed: seed, keys: keys);
          await run(h, review);
          await run(h, review);
          expect(h.api.exports, hasLength(1));
          expect(h.saver.saves, 1);
          expect(
            h.saver.filenames.single,
            seed || keys
                ? 'truenas-configuration.tar'
                : 'truenas-configuration.db',
          );
          expect(state(h).status, ConfigurationBackupStatus.saved);
          expect(state(h).locked, isFalse);
          expectWiped(h);
          expect(
            h.container.read(serverOperationLockProvider).acquire(),
            isNotNull,
          );
          await Future<void>.delayed(const Duration(milliseconds: 10));
          expect(h.api.reads, 1);
          expect(h.saver.saves, 1);
        },
      );
    }
  }
  for (final guard in [
    'consent',
    'seed-consent',
    'confirmation',
    'endpoint',
    'inventory',
    'session',
    'role',
    'ha',
    'jobs',
    'transport',
    'saver',
    'background',
  ]) {
    test('$guard guard makes zero export and save calls', () async {
      final h = BackupHarness(
        fake: BackupFake(
          inventory: backupInventory(
            fullAdmin: guard != 'role',
            ha: guard == 'ha',
            jobs: guard == 'jobs',
          ),
        ),
        saver: BackupSaverFake(supported: guard != 'saver'),
      );
      addTearDown(h.dispose);
      await h.load();
      var review = backupReview(h.api.inventory, seed: guard == 'seed-consent');
      if (guard == 'endpoint') {
        review = ConfigurationBackupReview(
          request: review.request,
          endpoint: 'wss://other.example/api/current',
          warnings: [],
        );
      }
      if (guard == 'inventory') review = backupReview(backupInventory());
      if (guard == 'session') h.select(h.newSession());
      if (guard == 'transport') {
        h.api.caps = const ConfigurationBackupCapabilities(
          connected: true,
          versionSupported: true,
          available: true,
        );
      }
      if (guard == 'background') {
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
      }
      try {
        await run(
          h,
          review,
          confirmation: guard == 'confirmation' ? '${review.target} ' : null,
          consent: guard != 'consent',
          seedConsent: guard != 'seed-consent',
        );
        expect(h.api.exports, isEmpty);
        expect(h.saver.saves, 0);
      } finally {
        if (guard == 'background') {
          WidgetsBinding.instance.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
      }
    });
  }
  test(
    'another global operation prevents export without consuming review',
    () async {
      final h = BackupHarness();
      addTearDown(h.dispose);
      await h.load();
      final lock = h.container.read(serverOperationLockProvider),
          review = backupReview(h.api.inventory);
      final owner = lock.acquire()!;
      await run(h, review);
      expect(h.api.exports, isEmpty);
      lock.release(owner);
      await run(h, review);
      expect(h.api.exports, hasLength(1));
    },
  );
  test(
    'duplicate in-flight export and cross-workflow lock are guarded',
    () async {
      final pending = Completer<ConfigurationBackupResult>();
      final h = BackupHarness(
        fake: BackupFake()..onExecute = (_) => pending.future,
      );
      addTearDown(h.dispose);
      await h.load();
      final review = backupReview(h.api.inventory);
      final first = run(h, review);
      await run(h, review);
      expect(state(h).status, ConfigurationBackupStatus.exporting);
      expect(h.api.exports, hasLength(1));
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
      pending.complete(h.api.completed(review));
      await first;
      expectWiped(h);
    },
  );
  for (final outcome in [
    ConfigurationBackupOutcome.rejected,
    ConfigurationBackupOutcome.unknown,
  ]) {
    test(
      '$outcome offers no saver or automatic retry and handles attached bytes safely',
      () async {
        final h = BackupHarness();
        addTearDown(h.dispose);
        await h.load();
        h.api.onExecute = (review) async => ConfigurationBackupResult(
          outcome,
          'PRIVATE-RESULT-FIXTURE',
          jobId: 80,
          artifact: h.api.completed(review).artifact,
        );
        final review = backupReview(h.api.inventory);
        await run(h, review);
        await run(h, review);
        expect(h.saver.saves, 0);
        expectWiped(h);
        expect(h.api.exports, hasLength(1));
        expect(state(h).unknown, outcome == ConfigurationBackupOutcome.unknown);
        expect(state(h).message, isNot(contains('PRIVATE-RESULT-FIXTURE')));
      },
    );
  }
  for (final malformed in [
    'missing-artifact',
    'missing-job',
    'negative-job',
    'unsafe-job',
    'short',
    'oversize',
    'filename',
    'seed',
    'keys',
    'disposed',
  ]) {
    test('malformed $malformed completion is discarded and fenced', () async {
      final h = BackupHarness();
      addTearDown(h.dispose);
      await h.load();
      h.api.onExecute = (review) async {
        if (malformed == 'missing-artifact') {
          return const ConfigurationBackupResult(
            ConfigurationBackupOutcome.completed,
            'Missing',
            jobId: 80,
          );
        }
        return h.api.completed(
          review,
          jobId: malformed == 'missing-job'
              ? null
              : malformed == 'negative-job'
              ? -1
              : malformed == 'unsafe-job'
              ? 9007199254740992
              : 80,
          size: malformed == 'short'
              ? 511
              : malformed == 'oversize'
              ? 16 * 1024 * 1024 + 1
              : null,
          filename: malformed == 'filename' ? '../private-token.db' : null,
          seed: malformed == 'seed' ? true : null,
          keys: malformed == 'keys' ? true : null,
          disposed: malformed == 'disposed',
        );
      };
      await run(h, backupReview(h.api.inventory));
      expect(state(h).unknown, isTrue);
      expect(h.saver.saves, 0);
      expectWiped(h);
      expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
      expect(state(h).message, isNot(contains('private-token')));
    });
  }
  for (final result in ConfigurationBackupSaveOutcome.values) {
    test(
      'save $result is accurately reported with no retained bytes or retry',
      () async {
        final h = BackupHarness(
          saver: BackupSaverFake()..onSave = (_, _) async => result,
        );
        addTearDown(h.dispose);
        await h.load();
        await run(h, backupReview(h.api.inventory));
        expect(state(h).status, switch (result) {
          ConfigurationBackupSaveOutcome.saved =>
            ConfigurationBackupStatus.saved,
          ConfigurationBackupSaveOutcome.cancelled =>
            ConfigurationBackupStatus.cancelled,
          _ => ConfigurationBackupStatus.failed,
        });
        expect(state(h).locked, isFalse);
        expectWiped(h);
        expect(h.saver.saves, 1);
        if (result != ConfigurationBackupSaveOutcome.saved) {
          expect(state(h).message, contains('empty or partial'));
        }
      },
    );
  }
  for (final typed in [true, false]) {
    test(
      'typed=$typed export exception is redacted and fenced appropriately',
      () async {
        final h = BackupHarness(
          fake: BackupFake()
            ..onExecute = (_) async {
              if (typed) {
                throw const ConfigurationBackupException(
                  ConfigurationBackupExceptionReason.staleReview,
                );
              }
              throw StateError('PRIVATE-EXPORT-FIXTURE');
            },
        );
        addTearDown(h.dispose);
        await h.load();
        await run(h, backupReview(h.api.inventory));
        expect(state(h).unknown, isTrue);
        expect(state(h).message, isNot(contains('PRIVATE-EXPORT-FIXTURE')));
        expect(h.saver.saves, 0);
      },
    );
  }
  test(
    'saver exception wipes the transferred buffer and warns partial file',
    () async {
      final h = BackupHarness(
        saver: BackupSaverFake()
          ..onSave = (_, _) async => throw StateError('PRIVATE-DESTINATION'),
      );
      addTearDown(h.dispose);
      await h.load();
      await run(h, backupReview(h.api.inventory));
      expect(state(h).unknown, isTrue);
      expectWiped(h);
      expect(state(h).message, contains('empty or partial'));
      expect(state(h).message, isNot(contains('PRIVATE-DESTINATION')));
    },
  );
  for (final cause in ['session', 'inventory', 'background', 'dispose']) {
    test(
      'late downloaded artifact after $cause is wiped and never saved',
      () async {
        final pending = Completer<ConfigurationBackupResult>();
        final h = BackupHarness(
          fake: BackupFake()..onExecute = (_) => pending.future,
        );
        if (cause != 'dispose') addTearDown(h.dispose);
        await h.load();
        final review = backupReview(h.api.inventory);
        final first = run(h, review);
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'inventory') {
          h.container.invalidate(configurationBackupInventoryProvider);
          h.container.read(configurationBackupInventoryProvider);
        }
        if (cause == 'background') {
          WidgetsBinding.instance.handleAppLifecycleStateChanged(
            AppLifecycleState.inactive,
          );
          WidgetsBinding.instance.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        }
        if (cause == 'dispose') h.dispose();
        pending.complete(h.api.completed(review));
        await first;
        expect(h.saver.saves, 0);
        expectWiped(h);
        if (cause != 'dispose') {
          expect(state(h).unknown, isTrue);
          expect(
            h.container.read(serverOperationLockProvider).acquire(),
            isNull,
          );
        }
      },
    );
  }
  test(
    'expected document-picker background is allowed only during saving',
    () async {
      final h = BackupHarness(
        saver: BackupSaverFake()
          ..onSave = (_, current) async {
            WidgetsBinding.instance.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
            WidgetsBinding.instance.handleAppLifecycleStateChanged(
              AppLifecycleState.hidden,
            );
            WidgetsBinding.instance.handleAppLifecycleStateChanged(
              AppLifecycleState.paused,
            );
            expect(current(), isTrue);
            WidgetsBinding.instance.handleAppLifecycleStateChanged(
              AppLifecycleState.hidden,
            );
            WidgetsBinding.instance.handleAppLifecycleStateChanged(
              AppLifecycleState.inactive,
            );
            WidgetsBinding.instance.handleAppLifecycleStateChanged(
              AppLifecycleState.resumed,
            );
            return ConfigurationBackupSaveOutcome.saved;
          },
      );
      addTearDown(h.dispose);
      await h.load();
      await run(h, backupReview(h.api.inventory));
      expect(state(h).status, ConfigurationBackupStatus.saved);
      expect(h.saver.cancellations, 0);
      expectWiped(h);
    },
  );
  for (final cause in ['session', 'dispose']) {
    test(
      '$cause during picker cancels native selection and rejects late save',
      () async {
        final pending = Completer<ConfigurationBackupSaveOutcome>();
        bool Function()? current;
        final h = BackupHarness(
          saver: BackupSaverFake()
            ..onSave = (_, check) {
              current = check;
              return pending.future;
            },
        );
        if (cause != 'dispose') addTearDown(h.dispose);
        await h.load();
        final future = run(h, backupReview(h.api.inventory));
        await Future<void>.delayed(Duration.zero);
        expect(state(h).status, ConfigurationBackupStatus.saving);
        expect(current!(), isTrue);
        if (cause == 'session') {
          h.select(h.newSession());
        } else {
          h.dispose();
        }
        expect(current!(), isFalse);
        expect(h.saver.cancellations, 1);
        pending.complete(ConfigurationBackupSaveOutcome.saved);
        await future;
        expectWiped(h);
        if (cause != 'dispose') {
          expect(state(h).unknown, isTrue);
          expect(state(h).message, contains('empty or partial'));
        }
      },
    );
  }
  for (final phase in ['export', 'save']) {
    test(
      'verified recovery cannot acknowledge while old $phase is pending',
      () async {
        final pendingExport = Completer<ConfigurationBackupResult>();
        final pendingSave = Completer<ConfigurationBackupSaveOutcome>();
        final h = BackupHarness();
        addTearDown(h.dispose);
        await h.load();
        if (phase == 'export') h.api.onExecute = (_) => pendingExport.future;
        if (phase == 'save') h.saver.onSave = (_, _) => pendingSave.future;
        final review = backupReview(h.api.inventory);
        final first = run(h, review);
        await Future<void>.delayed(Duration.zero);
        h.select(h.newSession());
        await controller(h).verifyReconnectedServer();
        expect(state(h).hostVerified, isTrue);
        expect(controller(h).canAcknowledge, isFalse);
        controller(h).acknowledgeAfterReconnect();
        expect(state(h).locked, isTrue);
        expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
        if (phase == 'export') pendingExport.complete(h.api.completed(review));
        if (phase == 'save') {
          pendingSave.complete(ConfigurationBackupSaveOutcome.saved);
        }
        await first;
        expectWiped(h);
        expect(controller(h).canAcknowledge, isTrue);
        controller(h).acknowledgeAfterReconnect();
        expect(state(h).locked, isFalse);
      },
    );
  }
  test('unknown requires fresh original endpoint and explicit host verification plus inspection', () async {
    final h = BackupHarness(
      fake: BackupFake()
        ..onExecute = (_) async => const ConfigurationBackupResult(
          ConfigurationBackupOutcome.unknown,
          'Unverified',
        ),
    );
    addTearDown(h.dispose);
    await h.load();
    await run(h, backupReview(h.api.inventory));
    final lock = h.container.read(serverOperationLockProvider);
    for (final session in [
      null,
      h.session,
      h.newSession(endpoint: 'wss://other.example/api/current'),
    ]) {
      h.select(session);
      await controller(h).verifyReconnectedServer();
      expect(controller(h).canAcknowledge, isFalse);
      expect(lock.acquire(), isNull);
    }
    expect(h.api.reads, 1);
    h.select(h.newSession());
    expect(controller(h).canAcknowledge, isFalse);
    await controller(h).verifyReconnectedServer();
    expect(h.api.reads, 2);
    expect(controller(h).canAcknowledge, isTrue);
    expect(lock.acquire(), isNull);
    controller(h).acknowledgeAfterReconnect();
    expect(state(h).locked, isFalse);
    expect(state(h).message, contains('remains unverified'));
    expect(h.api.exports, hasLength(1));
    expect(h.saver.saves, 0);
  });
  for (final mismatch in ['host', 'endpoint', 'error']) {
    test(
      'reconnected $mismatch mismatch cannot release unknown export fence',
      () async {
        final h = BackupHarness(
          fake: BackupFake()
            ..onExecute = (_) async => const ConfigurationBackupResult(
              ConfigurationBackupOutcome.unknown,
              'Unverified',
            ),
        );
        addTearDown(h.dispose);
        await h.load();
        await run(h, backupReview(h.api.inventory));
        h.select(h.newSession());
        h.api.onLoad = () async {
          if (mismatch == 'error') throw StateError('PRIVATE-HOST-FIXTURE');
          return backupInventory(
            endpoint: mismatch == 'endpoint'
                ? 'wss://other.example/api/current'
                : backupEndpoint,
            hostId: mismatch == 'host'
                ? 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'
                : backupHost,
          );
        };
        await controller(h).verifyReconnectedServer();
        controller(h).acknowledgeAfterReconnect();
        expect(state(h).locked, isTrue);
        expect(controller(h).canAcknowledge, isFalse);
        expect(
          state(h).verificationMessage,
          isNot(contains('PRIVATE-HOST-FIXTURE')),
        );
      },
    );
  }
  for (final cause in ['session', 'background', 'dispose']) {
    test('late verification after $cause cannot unlock export', () async {
      final h = BackupHarness(
        fake: BackupFake()
          ..onExecute = (_) async => const ConfigurationBackupResult(
            ConfigurationBackupOutcome.unknown,
            'Unverified',
          ),
      );
      if (cause != 'dispose') addTearDown(h.dispose);
      await h.load();
      await run(h, backupReview(h.api.inventory));
      h.select(h.newSession());
      final pending = Completer<ConfigurationBackupInventory>();
      h.api.onLoad = () => pending.future;
      final future = controller(h).verifyReconnectedServer();
      await controller(h).verifyReconnectedServer();
      expect(h.api.reads, 2);
      if (cause == 'session') h.select(h.newSession());
      if (cause == 'background') {
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.inactive,
        );
        WidgetsBinding.instance.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
      }
      if (cause == 'dispose') h.dispose();
      pending.complete(h.api.inventory);
      await future;
      if (cause != 'dispose') {
        expect(controller(h).canAcknowledge, isFalse);
        expect(state(h).locked, isTrue);
      }
    });
  }
  test(
    'verified host proof expires on background without automatic reread',
    () async {
      final h = BackupHarness(
        fake: BackupFake()
          ..onExecute = (_) async => const ConfigurationBackupResult(
            ConfigurationBackupOutcome.unknown,
            'Unverified',
          ),
      );
      addTearDown(h.dispose);
      await h.load();
      await run(h, backupReview(h.api.inventory));
      h.select(h.newSession());
      await controller(h).verifyReconnectedServer();
      expect(controller(h).canAcknowledge, isTrue);
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.inactive,
      );
      WidgetsBinding.instance.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      expect(controller(h).canAcknowledge, isFalse);
      expect(h.api.reads, 2);
    },
  );
}
