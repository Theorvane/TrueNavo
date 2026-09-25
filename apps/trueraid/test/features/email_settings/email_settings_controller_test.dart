import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/email_settings/email_settings_controller.dart';
import 'package:trueraid/features/management/server_operation_lock.dart';
import 'package:truenas_api/truenas_api.dart';

import 'email_settings_fakes.dart';

EmailSettingsController controller(EmailHarness h) =>
    h.container.read(emailSettingsControllerProvider.notifier);
EmailSettingsState state(EmailHarness h) =>
    h.container.read(emailSettingsControllerProvider);
Future<EmailSettingsReview> review(
  EmailHarness h,
  EmailSettingsAction action, {
  EmailPasswordChange password = const EmailPasswordChange.keep(),
}) async => (await controller(h).review(
  expectedSession: h.session,
  request: emailRequest(h.api.inventory, action, password: password),
  isRouteCurrent: () => true,
))!;
Future<void> execute(
  EmailHarness h,
  EmailSettingsReview review, {
  String? target,
  String? omit,
  bool Function()? route,
}) => controller(h).execute(
  expectedSession: h.session,
  review: review,
  confirmation: target ?? review.target,
  serverContactAccepted: omit != 'contact',
  queuedMailImpactAccepted: omit != 'queue',
  passwordClearAccepted: omit != 'clear',
  testDisclosureAccepted: omit != 'disclosure',
  isRouteCurrent: route ?? () => true,
);
void background() {
  WidgetsBinding.instance.handleAppLifecycleStateChanged(
    AppLifecycleState.inactive,
  );
  WidgetsBinding.instance.handleAppLifecycleStateChanged(
    AppLifecycleState.resumed,
  );
}

void expectLocked(EmailHarness h) =>
    expect(h.container.read(serverOperationLockProvider).acquire(), isNull);
void expectUnlocked(EmailHarness h) {
  final lock = h.container.read(serverOperationLockProvider),
      owner = h.container.read(serverOperationLockProvider).acquire();
  expect(owner, isNotNull);
  lock.release(owner!);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final action in EmailSettingsAction.values) {
    test(
      '${action.name} is review-only until explicit consent and single use target',
      () async {
        final h = EmailHarness();
        addTearDown(h.dispose);
        await h.load();
        final r = await review(h, action);
        expect(r.target, contains(emailHost));
        expect(h.api.executes, isEmpty);
        expect(h.api.checks, isEmpty);
        await execute(h, r, target: '${r.target} ');
        expect(h.api.executes, isEmpty);
        await execute(h, r);
        expect(h.api.executes, hasLength(1));
        expect(h.api.mutations, 1);
        expect(
          state(h).status,
          action == EmailSettingsAction.test
              ? EmailSettingsStatus.pending
              : EmailSettingsStatus.completed,
        );
        await execute(h, r);
        expect(h.api.executes, hasLength(1));
        expect(h.api.reads, 1);
        expect(h.api.checks, isEmpty);
      },
    );
    for (final omit in [
      'contact',
      action == EmailSettingsAction.configure ? 'queue' : 'disclosure',
    ]) {
      test('${action.name} requires $omit consent', () async {
        final h = EmailHarness();
        addTearDown(h.dispose);
        await h.load();
        await execute(h, await review(h, action), omit: omit);
        expect(h.api.executes, isEmpty);
        expectUnlocked(h);
      });
    }
    test('${action.name} capability prevents review', () async {
      final h = EmailHarness(
        fake: EmailFake(
          caps: EmailSettingsCapabilities(
            connected: true,
            versionSupported: true,
            available: true,
            canConfigure: action != EmailSettingsAction.configure,
            canTest: action != EmailSettingsAction.test,
          ),
        ),
      );
      addTearDown(h.dispose);
      await h.load();
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: emailRequest(h.api.inventory, action),
          isRouteCurrent: () => true,
        ),
        isNull,
      );
      expect(h.api.reviews, isEmpty);
    });
  }
  test('clear requires independent password deletion consent', () async {
    final h = EmailHarness();
    addTearDown(h.dispose);
    await h.load();
    final r = await review(
      h,
      EmailSettingsAction.configure,
      password: const EmailPasswordChange.clear(),
    );
    await execute(h, r, omit: 'clear');
    expect(h.api.executes, isEmpty);
    await execute(h, r);
    expect(h.api.executes, hasLength(1));
  });
  test(
    'replace capsule stays private until single write then is disposed',
    () async {
      final h = EmailHarness();
      addTearDown(h.dispose);
      await h.load();
      final secret = EmailPasswordChange.replace('PRIVATE-NEW-PASSWORD'),
          r = await review(h, EmailSettingsAction.configure, password: secret);
      expect(secret.isDisposed, isFalse);
      expect(state(h).toString(), isNot(contains('PRIVATE-NEW-PASSWORD')));
      expect(secret.toString(), isNot(contains('PRIVATE-NEW-PASSWORD')));
      await execute(h, r);
      expect(secret.isDisposed, isTrue);
      expect(state(h).message, isNot(contains('PRIVATE-NEW-PASSWORD')));
      expectUnlocked(h);
    },
  );
  for (final cause in [
    'session',
    'background',
    'route',
    'refresh',
    'dispose',
  ]) {
    test('owned replacement is destroyed on $cause', () async {
      final h = EmailHarness();
      if (cause != 'dispose') addTearDown(h.dispose);
      await h.load();
      final secret = EmailPasswordChange.replace('PRIVATE-PASSWORD');
      await review(h, EmailSettingsAction.configure, password: secret);
      if (cause == 'session') h.select(h.newSession());
      if (cause == 'background') background();
      if (cause == 'route') controller(h).abandonRoute();
      if (cause == 'refresh') controller(h).refreshConfiguration();
      if (cause == 'dispose') h.dispose();
      expect(secret.isDisposed, isTrue);
      expect(h.api.executes, isEmpty);
    });
  }
  test('new review disposes prior private capsule', () async {
    final h = EmailHarness();
    addTearDown(h.dispose);
    await h.load();
    final one = EmailPasswordChange.replace('PRIVATE-ONE'),
        two = EmailPasswordChange.replace('PRIVATE-TWO');
    await review(h, EmailSettingsAction.configure, password: one);
    await review(h, EmailSettingsAction.configure, password: two);
    expect(one.isDisposed, isTrue);
    expect(two.isDisposed, isFalse);
    controller(h).expireContext();
    expect(two.isDisposed, isTrue);
  });
  for (final entry in <String, EmailSettingsInventory>{
    'HA': emailInventory(ha: true),
    'admin': emailInventory(admin: false),
    'jobs': emailInventory(jobs: true),
    'boot': emailInventory(healthy: false),
    'state': emailInventory(state: 'BOOTING'),
    'nextboot': emailInventory(nextChanged: true),
    'OAuth': emailInventory(oauth: true),
    'password unknown': emailInventory(passwordPresent: null),
  }.entries) {
    test(
      '${entry.key} blocks writes and disposes rejected incoming secret',
      () async {
        final h = EmailHarness(fake: EmailFake(inventory: entry.value));
        addTearDown(h.dispose);
        await h.load();
        final secret = EmailPasswordChange.replace('PRIVATE-REJECTED');
        expect(
          await controller(h).review(
            expectedSession: h.session,
            request: emailRequest(
              h.api.inventory,
              EmailSettingsAction.configure,
              password: secret,
            ),
            isRouteCurrent: () => true,
          ),
          isNull,
        );
        expect(secret.isDisposed, isTrue);
        expect(h.api.reviews, isEmpty);
      },
    );
  }
  for (final recipient in [
    '',
    'one@example.test,two@example.test',
    'one@example.test\r\nBcc:other@example.test',
    'one@example.test ',
    'a@localhost',
  ]) {
    test('invalid one-recipient test [$recipient] never reaches API', () async {
      final h = EmailHarness();
      addTearDown(h.dispose);
      await h.load();
      expect(
        await controller(h).review(
          expectedSession: h.session,
          request: emailRequest(
            h.api.inventory,
            EmailSettingsAction.test,
            recipient: recipient,
          ),
          isRouteCurrent: () => true,
        ),
        isNull,
      );
      expect(h.api.reviews, isEmpty);
    });
  }
  for (final cause in ['session', 'background', 'route', 'inventory']) {
    test(
      'review late $cause disposes capsule and issues no authorization',
      () async {
        final h = EmailHarness();
        addTearDown(h.dispose);
        await h.load();
        final secret = EmailPasswordChange.replace('PRIVATE-LATE'),
            pending = Completer<EmailSettingsReview>();
        h.api.onReview = (_) => pending.future;
        var route = true;
        final request = emailRequest(
          h.api.inventory,
          EmailSettingsAction.configure,
          password: secret,
        );
        final future = controller(h).review(
          expectedSession: h.session,
          request: request,
          isRouteCurrent: () => route,
        );
        expect(
          await controller(h).review(
            expectedSession: h.session,
            request: request,
            isRouteCurrent: () => true,
          ),
          isNull,
        );
        expect(secret.isDisposed, isFalse);
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background();
        if (cause == 'route') route = false;
        if (cause == 'inventory') {
          h.api.inventory = emailInventory();
          h.container.invalidate(emailSettingsInventoryProvider);
        }
        pending.complete(
          EmailSettingsReview(
            request: request,
            endpoint: emailEndpoint,
            warnings: const [],
          ),
        );
        expect(await future, isNull);
        expect(secret.isDisposed, isTrue);
        expect(h.api.executes, isEmpty);
      },
    );
    test(
      'held execute after $cause prevents fake dispatch and holds unknown fence',
      () async {
        final h = EmailHarness();
        addTearDown(h.dispose);
        await h.load();
        final secret = EmailPasswordChange.replace('PRIVATE-LATE'),
            r = await review(
              h,
              EmailSettingsAction.configure,
              password: secret,
            ),
            pending = Completer<void>();
        var route = true;
        h.api.onExecute = (_, current) async {
          await pending.future;
          if (current()) h.api.mutations++;
          return const EmailSettingsResult(
            EmailSettingsOutcome.rejected,
            'stale',
          );
        };
        final future = execute(h, r, route: () => route);
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background();
        if (cause == 'route') route = false;
        if (cause == 'inventory') {
          h.api.inventory = emailInventory();
          h.container.invalidate(emailSettingsInventoryProvider);
        }
        pending.complete();
        await future;
        expect(h.api.mutations, 0);
        expect(secret.isDisposed, isTrue);
        expect(state(h).status, EmailSettingsStatus.unknown);
        expectLocked(h);
      },
    );
  }
  for (final kind in ['request', 'endpoint', 'error']) {
    test(
      'mismatched $kind review disposes input without leaking errors',
      () async {
        final h = EmailHarness();
        addTearDown(h.dispose);
        await h.load();
        final secret = EmailPasswordChange.replace('PRIVATE-REVIEW');
        h.api.onReview = (request) async {
          if (kind == 'error') throw StateError('PRIVATE-ERROR');
          return EmailSettingsReview(
            request: kind == 'request'
                ? emailRequest(h.api.inventory, request.action)
                : request,
            endpoint: kind == 'endpoint'
                ? 'wss://other.example/api/current'
                : emailEndpoint,
            warnings: const [],
          );
        };
        expect(
          await controller(h).review(
            expectedSession: h.session,
            request: emailRequest(
              h.api.inventory,
              EmailSettingsAction.configure,
              password: secret,
            ),
            isRouteCurrent: () => true,
          ),
          isNull,
        );
        expect(secret.isDisposed, isTrue);
        expect(state(h).message, isNot(contains('PRIVATE')));
      },
    );
  }
  test('busy shared owner discards secret and sends nothing', () async {
    final h = EmailHarness();
    addTearDown(h.dispose);
    await h.load();
    final secret = EmailPasswordChange.replace('PRIVATE-BUSY'),
        r = await review(h, EmailSettingsAction.configure, password: secret),
        lock = h.container.read(serverOperationLockProvider),
        owner = h.container.read(serverOperationLockProvider).acquire()!;
    await execute(h, r);
    expect(secret.isDisposed, isTrue);
    expect(h.api.executes, isEmpty);
    lock.release(owner);
  });
  test('duplicate submission cannot repeat SMTP contact', () async {
    final h = EmailHarness();
    addTearDown(h.dispose);
    await h.load();
    final r = await review(h, EmailSettingsAction.test),
        pending = Completer<EmailSettingsResult>();
    h.api.onExecute = (_, _) => pending.future;
    final future = execute(h, r);
    await execute(h, r);
    expect(h.api.executes, hasLength(1));
    pending.complete(
      const EmailSettingsResult(
        EmailSettingsOutcome.pending,
        'pending',
        jobId: 51,
      ),
    );
    await future;
    await execute(h, r);
    expect(h.api.executes, hasLength(1));
    expectLocked(h);
  });
  for (final kind in [
    'unknown',
    'exception',
    'typedexception',
    'missingjob',
    'wrongpendingaction',
    'directtestcomplete',
  ]) {
    test('$kind remains unknown, no secret reuse, polling or resend', () async {
      final h = EmailHarness();
      addTearDown(h.dispose);
      await h.load();
      final secret = EmailPasswordChange.replace('PRIVATE-EXECUTE');
      final action = kind == 'missingjob' || kind == 'directtestcomplete'
          ? EmailSettingsAction.test
          : EmailSettingsAction.configure;
      final r = await review(
        h,
        action,
        password: action == EmailSettingsAction.configure
            ? secret
            : const EmailPasswordChange.keep(),
      );
      h.api.onExecute = (_, _) async {
        if (kind == 'exception') throw StateError('PRIVATE-ERROR');
        if (kind == 'typedexception') {
          throw const EmailSettingsException(EmailSettingsExceptionReason.busy);
        }
        return EmailSettingsResult(
          kind == 'missingjob' || kind == 'wrongpendingaction'
              ? EmailSettingsOutcome.pending
              : kind == 'directtestcomplete'
              ? EmailSettingsOutcome.completed
              : EmailSettingsOutcome.unknown,
          'PRIVATE-ERROR',
          jobId: kind == 'wrongpendingaction' ? 51 : null,
        );
      };
      await execute(h, r);
      expect(state(h).status, EmailSettingsStatus.unknown);
      expect(state(h).message, isNot(contains('PRIVATE')));
      if (action == EmailSettingsAction.configure) {
        expect(secret.isDisposed, isTrue);
      }
      secret.dispose();
      await controller(h).checkJob(isRouteCurrent: () => true);
      await execute(h, r);
      expect(h.api.checks, isEmpty);
      expect(h.api.executes, hasLength(1));
      expect(h.api.reads, 1);
      expectLocked(h);
    });
  }
  test('one explicit owned check, pending then true completion, never auto polls or resends', () async {
    final h = EmailHarness();
    addTearDown(h.dispose);
    await h.load();
    await execute(h, await review(h, EmailSettingsAction.test));
    expect(state(h).jobId, 51);
    expect(h.api.checks, isEmpty);
    expect(controller(h).canCheckJob, isTrue);
    h.api.onCheck = (id, _) async =>
        EmailSettingsResult(EmailSettingsOutcome.pending, 'pending', jobId: id);
    await controller(h).checkJob(isRouteCurrent: () => true);
    expect(h.api.checks, [51]);
    expect(state(h).status, EmailSettingsStatus.pending);
    expectLocked(h);
    h.api.onCheck = null;
    await controller(h).checkJob(isRouteCurrent: () => true);
    expect(h.api.checks, [51, 51]);
    expect(state(h).status, EmailSettingsStatus.completed);
    expect(state(h).message, contains('not proof of recipient delivery'));
    expectUnlocked(h);
    await controller(h).checkJob(isRouteCurrent: () => true);
    expect(h.api.checks, hasLength(2));
    expect(h.api.executes, hasLength(1));
  });
  for (final kind in [
    'unknown',
    'wrongjob',
    'missingjob',
    'rejected',
    'error',
  ]) {
    test('owned check $kind never reports delivery or unlocks', () async {
      final h = EmailHarness();
      addTearDown(h.dispose);
      await h.load();
      await execute(h, await review(h, EmailSettingsAction.test));
      h.api.onCheck = (_, _) async {
        if (kind == 'error') throw StateError('PRIVATE-ERROR');
        return EmailSettingsResult(
          kind == 'unknown'
              ? EmailSettingsOutcome.unknown
              : kind == 'rejected'
              ? EmailSettingsOutcome.rejected
              : EmailSettingsOutcome.completed,
          'PRIVATE-ERROR',
          jobId: kind == 'missingjob'
              ? null
              : kind == 'wrongjob'
              ? 99
              : 51,
        );
      };
      await controller(h).checkJob(isRouteCurrent: () => true);
      expect(state(h).status, EmailSettingsStatus.unknown);
      expect(state(h).jobId, 51);
      expect(state(h).message, isNot(contains('PRIVATE')));
      expectLocked(h);
      await controller(h).checkJob(isRouteCurrent: () => true);
      expect(h.api.checks, [51]);
    });
  }
  for (final cause in ['session', 'background', 'route', 'inventory']) {
    test(
      'late owned check $cause cannot publish success or release fence',
      () async {
        final h = EmailHarness();
        addTearDown(h.dispose);
        await h.load();
        await execute(h, await review(h, EmailSettingsAction.test));
        final pending = Completer<EmailSettingsResult>();
        h.api.onCheck = (_, _) => pending.future;
        var route = true;
        final future = controller(h).checkJob(isRouteCurrent: () => route);
        await controller(h).checkJob(isRouteCurrent: () => true);
        expect(h.api.checks, [51]);
        if (cause == 'session') h.select(h.newSession());
        if (cause == 'background') background();
        if (cause == 'route') route = false;
        if (cause == 'inventory') {
          h.api.inventory = emailInventory();
          h.container.invalidate(emailSettingsInventoryProvider);
        }
        pending.complete(
          const EmailSettingsResult(
            EmailSettingsOutcome.completed,
            'late',
            jobId: 51,
          ),
        );
        await future;
        expect(state(h).status, EmailSettingsStatus.unknown);
        expectLocked(h);
      },
    );
  }
  for (final cause in [
    'differenthost',
    'endpoint',
    'unready',
    'background',
    'route',
    'session',
    'failure',
  ]) {
    test('recovery $cause cannot release unknown fence', () async {
      final h = EmailHarness();
      addTearDown(h.dispose);
      await h.load();
      h.api.onExecute = (_, _) async =>
          const EmailSettingsResult(EmailSettingsOutcome.unknown, 'unknown');
      await execute(h, await review(h, EmailSettingsAction.configure));
      h.select(
        h.newSession(
          endpoint: cause == 'endpoint'
              ? 'wss://other.example/api/current'
              : emailEndpoint,
        ),
      );
      if (cause == 'endpoint') {
        expect(controller(h).canVerifyReconnectedServer, isFalse);
        expectLocked(h);
        return;
      }
      final pending = Completer<EmailSettingsInventory>();
      h.api.onLoad = () => pending.future;
      final future = controller(h).verifyReconnectedServer();
      if (cause == 'background') background();
      if (cause == 'route') controller(h).abandonRoute();
      if (cause == 'session') h.select(h.newSession());
      if (cause == 'failure') {
        pending.completeError(StateError('PRIVATE-ERROR'));
      } else {
        pending.complete(
          emailInventory(
            hostId: cause == 'differenthost' ? 'f' * 64 : emailHost,
            state: cause == 'unready' ? 'BOOTING' : 'READY',
          ),
        );
      }
      await future;
      expect(state(h).hostVerified, isFalse);
      expect(controller(h).canAcknowledge, isFalse);
      expectLocked(h);
    });
  }
  test('fresh original-host read allows independent ACK even protected config, only after old invocation settles', () async {
    final h = EmailHarness();
    addTearDown(h.dispose);
    await h.load();
    final pending = Completer<EmailSettingsResult>();
    h.api.onExecute = (_, _) => pending.future;
    final future = execute(h, await review(h, EmailSettingsAction.test));
    h.select(h.newSession());
    h.api.inventory = emailInventory(oauth: true, passwordPresent: null);
    expect(h.api.reads, 1);
    await controller(h).verifyReconnectedServer();
    expect(state(h).hostVerified, isTrue);
    expect(controller(h).canAcknowledge, isFalse);
    controller(h).acknowledgeAfterReconnect();
    expectLocked(h);
    pending.complete(
      const EmailSettingsResult(
        EmailSettingsOutcome.pending,
        'late',
        jobId: 51,
      ),
    );
    await future;
    expect(controller(h).canAcknowledge, isTrue);
    controller(h).acknowledgeAfterReconnect();
    expectUnlocked(h);
    expect(h.api.executes, hasLength(1));
    expect(h.api.checks, isEmpty);
    expect(state(h).message, contains('remains unverified'));
  });
}
