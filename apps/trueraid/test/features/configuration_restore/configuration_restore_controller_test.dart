import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/configuration_restore/configuration_restore_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:truenas_api/truenas_api.dart';

import 'configuration_restore_fakes.dart';

ConfigurationRestoreController controller(RestoreHarness h) =>
    h.container.read(configurationRestoreControllerProvider.notifier);
ConfigurationRestoreState state(RestoreHarness h) =>
    h.container.read(configurationRestoreControllerProvider);
Future<void> choose(RestoreHarness h) => controller(h).chooseFile(
  expectedSession: h.session,
  sensitiveReadAccepted: true,
  isRouteCurrent: () => true,
);
Future<ConfigurationRestoreReview> review(RestoreHarness h) async {
  await choose(h);
  return (await controller(h).review(
    expectedSession: h.session,
    inventory: h.api.inventory,
    isRouteCurrent: () => true,
  ))!;
}

Future<void> execute(
  RestoreHarness h,
  ConfigurationRestoreReview review, {
  String? target,
  String? hash,
  int? omittedConsent,
}) => controller(h).execute(
  expectedSession: h.session,
  review: review,
  confirmation: target ?? review.target,
  fileHashConfirmation: hash ?? review.request.file.sha256,
  recoveryAccessAccepted: omittedConsent != 0,
  independentBackupAccepted: omittedConsent != 1,
  trustedFileAccepted: omittedConsent != 2,
  replacementAndRebootAccepted: omittedConsent != 3,
  missingMaterialLossAccepted: omittedConsent != 4,
  isRouteCurrent: () => true,
);
void background() {
  WidgetsBinding.instance.handleAppLifecycleStateChanged(
    AppLifecycleState.inactive,
  );
  WidgetsBinding.instance.handleAppLifecycleStateChanged(
    AppLifecycleState.resumed,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'local selection keeps public metadata only and consumes mutable input',
    () async {
      final h = RestoreHarness();
      addTearDown(h.dispose);
      await h.load();
      await choose(h);
      expect(state(h).selection!.byteLength, 512);
      expect(h.api.uploads, 0);
      expect(h.api.reviews, isEmpty);
      expect(h.picker.delivered.single.every((v) => v == 0), isTrue);
      final hash = state(h).selection!.sha256;
      h.picker.delivered.single[100] = 99;
      expect(state(h).selection!.sha256, hash);
      controller(h).discardSelection();
      expect(h.api.files.single.isDisposed, isTrue);
      expect(state(h).selection, isNull);
    },
  );
  test('replacement discards previous capsule', () async {
    final h = RestoreHarness();
    addTearDown(h.dispose);
    await h.load();
    await choose(h);
    await choose(h);
    expect(h.api.files.first.isDisposed, isTrue);
    expect(h.api.files.last.isDisposed, isFalse);
  });
  for (final kind in [
    'cancel',
    'invalid',
    'failure',
    'unsupported',
    'consent',
  ]) {
    test('file $kind never prepares a retained capsule or uploads', () async {
      final picker = RestorePickerFake(supported: kind != 'unsupported');
      if (kind == 'cancel') picker.onPick = (_, _) async => null;
      if (kind == 'invalid') {
        picker.onPick = (_, read) async {
          read?.call();
          return Uint8List(513);
        };
      }
      if (kind == 'failure') {
        picker.onPick = (_, _) async =>
            throw StateError('PRIVATE-FILE-FIXTURE');
      }
      final h = RestoreHarness(picker: picker);
      addTearDown(h.dispose);
      await h.load();
      await controller(h).chooseFile(
        expectedSession: h.session,
        sensitiveReadAccepted: kind != 'consent',
        isRouteCurrent: () => true,
      );
      expect(state(h).selection, isNull);
      expect(h.api.uploads, 0);
      expect(state(h).message, isNot(contains('PRIVATE-FILE-FIXTURE')));
    });
  }
  for (final phase in ['picker', 'read', 'prepare']) {
    for (final cause in ['session', 'background', 'route']) {
      test(
        '$phase late result after $cause is discarded with picker-only lifecycle exception',
        () async {
          final pick = Completer<Uint8List?>(),
              prepare = Completer<ConfigurationRestoreFile>();
          final h = RestoreHarness();
          addTearDown(h.dispose);
          await h.load();
          h.picker.onPick = (_, read) {
            if (phase != 'picker') read?.call();
            return pick.future;
          };
          if (phase == 'prepare') h.api.onPrepare = (_) => prepare.future;
          final future = choose(h);
          if (phase == 'prepare') {
            pick.complete(restoreBytes());
            await Future<void>.delayed(Duration.zero);
          }
          if (cause == 'session') h.select(h.newSession());
          if (cause == 'background') background();
          if (cause == 'route') controller(h).discardSelection();
          if (phase == 'prepare') {
            prepare.complete(
              ConfigurationRestoreFile.fromBytes(restoreBytes()),
            );
          } else {
            pick.complete(restoreBytes());
          }
          await future;
          final expected = phase == 'picker' && cause == 'background';
          expect(state(h).selection != null, expected);
          expect(h.api.uploads, 0);
          if (!expected) {
            for (final file in h.api.files) {
              expect(file.isDisposed, isTrue);
            }
          }
          for (final bytes in h.api.prepared) {
            expect(bytes.every((v) => v == 0), isTrue);
          }
        },
      );
    }
  }
  for (final omitted in [0, 1, 2, 3, 4]) {
    test('consent $omitted is required before execute', () async {
      final h = RestoreHarness();
      addTearDown(h.dispose);
      await h.load();
      final lease = await review(h);
      await execute(h, lease, omittedConsent: omitted);
      expect(h.api.executes, isEmpty);
    });
  }
  for (final wrong in ['target', 'hash', 'session', 'inventory']) {
    test('$wrong mismatch sends no execute', () async {
      final h = RestoreHarness();
      addTearDown(h.dispose);
      await h.load();
      final lease = await review(h);
      if (wrong == 'session') h.select(h.newSession());
      if (wrong == 'inventory') {
        h.container.invalidate(configurationRestoreInventoryProvider);
        h.container.read(configurationRestoreInventoryProvider);
      }
      await execute(
        h,
        lease,
        target: wrong == 'target' ? '${lease.target} ' : null,
        hash: wrong == 'hash' ? '${lease.request.file.sha256} ' : null,
      );
      expect(h.api.executes, isEmpty);
    });
  }
  test(
    'global fence blocks another upload and exact review is single-use',
    () async {
      final h = RestoreHarness();
      addTearDown(h.dispose);
      await h.load();
      final lease = await review(h);
      final lock = h.container.read(serverOperationLockProvider),
          owner = h.container.read(serverOperationLockProvider).acquire()!;
      await execute(h, lease);
      expect(h.api.executes, isEmpty);
      lock.release(owner);
      await execute(h, lease);
      await execute(h, lease);
      expect(h.api.executes, hasLength(1));
      expect(h.api.files.single.isDisposed, isTrue);
    },
  );
  for (final outcome in ConfigurationRestoreOutcome.values) {
    test(
      '$outcome releases or retains write fence without polling and discards capsule',
      () async {
        final h = RestoreHarness(
          fake: RestoreFake()
            ..onExecute = (_, current) async => ConfigurationRestoreResult(
              outcome,
              'PRIVATE-RESULT',
              jobId: 80,
            ),
        );
        addTearDown(h.dispose);
        await h.load();
        final lease = await review(h);
        await execute(h, lease);
        expect(
          state(h).locked,
          outcome != ConfigurationRestoreOutcome.rejected,
        );
        expect(h.api.files.single.isDisposed, isTrue);
        expect(state(h).message, isNot(contains('PRIVATE-RESULT')));
        await Future<void>.delayed(const Duration(milliseconds: 10));
        expect(h.api.reads, 1);
        expect(h.api.executes, hasLength(1));
        if (outcome != ConfigurationRestoreOutcome.rejected) {
          controller(h).discardSelection();
          expect(
            h.container.read(serverOperationLockProvider).acquire(),
            isNull,
          );
        }
      },
    );
  }
  for (final id in <int?>[null, 0, -1, 9007199254740992]) {
    test('invalid accepted job $id remains unknown', () async {
      final h = RestoreHarness(
        fake: RestoreFake()
          ..onExecute = (_, _) async => ConfigurationRestoreResult(
            ConfigurationRestoreOutcome.accepted,
            'Queued',
            jobId: id,
          ),
      );
      addTearDown(h.dispose);
      await h.load();
      await execute(h, await review(h));
      expect(state(h).status, ConfigurationRestoreStatus.unknown);
    });
  }
  for (final typed in [false, true]) {
    test('execute throw typed=$typed is unknown and redacted', () async {
      final h = RestoreHarness(
        fake: RestoreFake()
          ..onExecute = (_, _) async {
            if (typed) {
              throw const ConfigurationRestoreException(
                ConfigurationRestoreExceptionReason.staleReview,
              );
            }
            throw StateError('PRIVATE-ERROR');
          },
      );
      addTearDown(h.dispose);
      await h.load();
      await execute(h, await review(h));
      expect(state(h).status, ConfigurationRestoreStatus.unknown);
      expect(state(h).message, isNot(contains('PRIVATE-ERROR')));
    });
  }
  for (final cause in ['session', 'background', 'route', 'inventory']) {
    test(
      '$cause at final SDK preflight prevents late upload and destroys capsule',
      () async {
        final ready = Completer<void>();
        final h = RestoreHarness();
        addTearDown(h.dispose);
        await h.load();
        final lease = await review(h);
        h.api.onExecute = (_, current) async {
          await ready.future;
          if (current()) h.api.uploads++;
          return const ConfigurationRestoreResult(
            ConfigurationRestoreOutcome.rejected,
            'Guarded',
          );
        };
        final pending = execute(h, lease);
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background();
        if (cause == 'route') controller(h).discardSelection();
        if (cause == 'inventory') {
          h.container.invalidate(configurationRestoreInventoryProvider);
          h.container.read(configurationRestoreInventoryProvider);
        }
        ready.complete();
        await pending;
        expect(h.api.uploads, 0);
        expect(h.api.files.single.isDisposed, isTrue);
        expect(state(h).locked, isTrue);
      },
    );
  }
  for (final addressChanged in [false, true]) {
    test(
      'explicit recovery changedAddress=$addressChanged requires matching host and all acknowledgements',
      () async {
        final h = RestoreHarness(
          fake: RestoreFake()
            ..onExecute = (_, _) async => const ConfigurationRestoreResult(
              ConfigurationRestoreOutcome.accepted,
              'Queued',
              jobId: 80,
            ),
        );
        addTearDown(h.dispose);
        await h.load();
        await execute(h, await review(h));
        final endpoint = addressChanged
            ? 'wss://new.example/api/current'
            : restoreEndpoint;
        h.api.inventory = restoreInventory(endpoint: endpoint);
        h.select(h.newSession(endpoint: endpoint));
        expect(controller(h).canAcknowledge, isFalse);
        expect(h.api.reads, 1);
        await controller(h).verifyReconnectedServer();
        expect(state(h).hostVerified, isTrue);
        expect(controller(h).canAcknowledge, !addressChanged);
        if (addressChanged) controller(h).acknowledgeChangedAddress(true);
        expect(controller(h).canAcknowledge, isTrue);
        controller(h).acknowledgeAfterReconnect();
        expect(state(h).locked, isFalse);
        expect(h.api.executes, hasLength(1));
      },
    );
  }
  for (final wrong in ['host', 'endpoint', 'readiness', 'error']) {
    test('recovery $wrong mismatch retains fence', () async {
      final h = RestoreHarness(
        fake: RestoreFake()
          ..onExecute = (_, _) async => const ConfigurationRestoreResult(
            ConfigurationRestoreOutcome.unknown,
            'Unknown',
          ),
      );
      addTearDown(h.dispose);
      await h.load();
      await execute(h, await review(h));
      h.select(h.newSession());
      h.api.onLoad = () async {
        if (wrong == 'error') throw StateError('PRIVATE-READ');
        return restoreInventory(
          hostId: wrong == 'host'
              ? 'abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789'
              : restoreHost,
          endpoint: wrong == 'endpoint'
              ? 'wss://other.example/api/current'
              : restoreEndpoint,
          jobs: wrong == 'readiness',
        );
      };
      await controller(h).verifyReconnectedServer();
      expect(controller(h).canAcknowledge, isFalse);
      expect(state(h).locked, isTrue);
    });
  }
  test(
    'old pending invocation blocks recovery acknowledgement until it exits',
    () async {
      final pending = Completer<ConfigurationRestoreResult>();
      final h = RestoreHarness(
        fake: RestoreFake()..onExecute = (_, _) => pending.future,
      );
      addTearDown(h.dispose);
      await h.load();
      final first = execute(h, await review(h));
      h.select(h.newSession());
      await controller(h).verifyReconnectedServer();
      expect(state(h).hostVerified, isTrue);
      expect(controller(h).canAcknowledge, isFalse);
      pending.complete(
        const ConfigurationRestoreResult(
          ConfigurationRestoreOutcome.accepted,
          'Late',
          jobId: 80,
        ),
      );
      await first;
      expect(controller(h).canAcknowledge, isTrue);
      expect(state(h).status, ConfigurationRestoreStatus.unknown);
    },
  );
}
