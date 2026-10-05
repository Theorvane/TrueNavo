import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/boot_environments/boot_environments_controller.dart';
import 'package:truenas_api/truenas_api.dart';

import 'boot_environments_fakes.dart';

const _verified = BootEnvironmentResult(
  outcome: BootEnvironmentOutcome.verified,
  message: 'Fixture verified.',
);
const _unknown = BootEnvironmentResult(
  outcome: BootEnvironmentOutcome.unknown,
  message: 'Inspect the original server.',
);

void main() {
  test(
    'one-shot execution holds the shared lock and excludes duplicates',
    () async {
      final h = await BootHarness.create();
      addTearDown(h.dispose);
      final review = await h.review();
      final done = Completer<BootEnvironmentResult>();
      h.api.onExecute = () => done.future;
      final first = h.controller.execute(
        expectedSession: h.session,
        review: review,
      );
      await h.controller.execute(expectedSession: h.session, review: review);
      expect(h.api.executions, 1);
      expect(h.state.busy, isTrue);
      expect(h.lock.acquire(), isNull);
      done.complete(_verified);
      await first;
      expect(h.state.locked, isFalse);
      expect(h.lock.acquire(), isNotNull);
    },
  );

  test('another management operation prevents dispatch', () async {
    final h = await BootHarness.create();
    addTearDown(h.dispose);
    final review = await h.review();
    final owner = h.lock.acquire()!;
    await h.controller.execute(expectedSession: h.session, review: review);
    expect(h.api.executions, 0);
    expect(h.state.result!.outcome, BootEnvironmentOutcome.rejected);
    h.lock.release(owner);
  });

  test(
    'changed connection and missing endpoint reject reviewed execution',
    () async {
      final h = await BootHarness.create();
      addTearDown(h.dispose);
      final review = await h.review();
      h.select(h.newSession());
      await h.controller.execute(expectedSession: h.session, review: review);
      expect(h.api.executions, 0);
      final noEndpoint = h.newSession(endpoint: null);
      h.select(noEndpoint);
      await h.controller.execute(expectedSession: noEndpoint, review: review);
      expect(h.api.executions, 0);
    },
  );

  test('unknown outcome holds the lock and never replays the review', () async {
    final h = await BootHarness.create();
    addTearDown(h.dispose);
    final review = await h.review();
    h.api.onExecute = () async => _unknown;
    await h.controller.execute(expectedSession: h.session, review: review);
    await h.controller.execute(expectedSession: h.session, review: review);
    h.controller.acknowledgeAfterReconnect();
    expect(h.api.executions, 1);
    expect(h.state.unknown, isTrue);
    expect(h.lock.acquire(), isNull);
  });

  test('unexpected failure never reveals raw remote details', () async {
    final h = await BootHarness.create();
    addTearDown(h.dispose);
    final review = await h.review();
    h.api.onExecute = () =>
        Future.error(StateError('private traceback fixture'));
    await h.controller.execute(expectedSession: h.session, review: review);
    expect(h.state.unknown, isTrue);
    expect(h.state.result!.message, isNot(contains('private')));
  });

  test(
    'session switch preserves origin and ignores late verified completion',
    () async {
      final h = await BootHarness.create();
      addTearDown(h.dispose);
      final review = await h.review();
      final done = Completer<BootEnvironmentResult>();
      h.api.onExecute = () => done.future;
      final pending = h.controller.execute(
        expectedSession: h.session,
        review: review,
      );
      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
      done.complete(_verified);
      await pending;
      expect(h.state.unknown, isTrue);
      expect(h.state.connectionCurrent, isFalse);
      expect(h.state.server, bootEndpoint);
      expect(h.state.target, 'old');
      expect(h.lock.acquire(), isNotNull);
    },
  );

  test(
    'warning clears only after explicit acknowledgement at original endpoint',
    () async {
      final h = await BootHarness.create();
      addTearDown(h.dispose);
      final review = await h.review();
      h.api.onExecute = () async => _unknown;
      await h.controller.execute(expectedSession: h.session, review: review);
      h.select(null);
      h.controller.acknowledgeAfterReconnect();
      expect(h.state.unknown, isTrue);
      h.select(h.newSession(endpoint: 'wss://other.example/api/current'));
      h.controller.acknowledgeAfterReconnect();
      expect(h.state.unknown, isTrue);
      h.select(h.session);
      h.controller.acknowledgeAfterReconnect();
      expect(h.state.unknown, isTrue);
      h.select(h.newSession());
      expect(h.controller.canAcknowledge, isTrue);
      h.controller.acknowledgeAfterReconnect();
      expect(h.state.locked, isFalse);
      expect(h.state.result, isNull);
      expect(h.api.executions, 1);
    },
  );

  test(
    'inventory reloads for a new session even when repository is reused',
    () async {
      final h = await BootHarness.create();
      addTearDown(h.dispose);
      await h.container.read(bootEnvironmentsInventoryProvider.future);
      expect(h.api.reads, 1);
      h.select(h.newSession());
      await h.container.read(bootEnvironmentsInventoryProvider.future);
      expect(h.api.reads, 2);
    },
  );
}
