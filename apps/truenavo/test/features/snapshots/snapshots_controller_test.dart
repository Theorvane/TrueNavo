import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:truenas_api/truenas_api.dart';

import 'snapshot_fakes.dart';

void main() {
  test('inventory reads never mutate', () async {
    final h = SnapshotHarness();
    addTearDown(h.dispose);
    await h.api.loadSnapshotDatasets();
    await h.api.loadSnapshots(const SnapshotQuery(dataset: 'tank/data'));
    expect(h.api.creates, isEmpty);
    expect(h.api.deletes, isEmpty);
  });
  test(
    'explicit create uses the exact reviewed dataset and shared lock',
    () async {
      final h = SnapshotHarness();
      addTearDown(h.dispose);
      final pending = Completer<SnapshotOperationResult>();
      h.api.onWrite = () => pending.future;
      final first = h.create();
      expect(h.api.creates.single.dataset, same(h.api.dataset));
      expect(h.lock.acquire(), isNull);
      await h.create();
      expect(h.api.creates.length, 1);
      pending.complete(
        const SnapshotOperationResult(
          outcome: SnapshotOperationOutcome.verified,
          message: 'Verified',
        ),
      );
      await first;
      expect(h.state.result!.outcome, SnapshotOperationOutcome.verified);
      expect(h.lock.acquire(), isNotNull);
    },
  );
  test('another operation prevents both create and delete', () async {
    final h = SnapshotHarness();
    addTearDown(h.dispose);
    final owner = h.lock.acquire()!;
    await h.create();
    await h.delete();
    expect(h.api.creates, isEmpty);
    expect(h.api.deletes, isEmpty);
    expect(h.state.result!.outcome, SnapshotOperationOutcome.rejected);
    h.lock.release(owner);
  });
  test(
    'same endpoint with replaced authenticated object invalidates review',
    () async {
      final h = SnapshotHarness();
      addTearDown(h.dispose);
      h.select(snapshotSession(h.api));
      await h.create();
      await h.delete();
      expect(h.api.creates, isEmpty);
      expect(h.api.deletes, isEmpty);
      expect(h.state.result!.message, contains('server changed'));
    },
  );
  test(
    'delete requires the exact full identifier without normalization',
    () async {
      final h = SnapshotHarness();
      addTearDown(h.dispose);
      await h.delete(confirmation: 'manual-1');
      await h.delete(confirmation: '${h.api.entry.id} ');
      expect(h.api.deletes, isEmpty);
      await h.delete();
      expect(h.api.deletes.single.snapshot, same(h.api.entry));
      expect(h.api.creates, isEmpty);
    },
  );
  test(
    'unknown result holds lock until new session and explicit acknowledgement',
    () async {
      final h = SnapshotHarness();
      addTearDown(h.dispose);
      h.api.outcome = SnapshotOperationOutcome.unknown;
      await h.delete();
      expect(h.state.unresolved, isTrue);
      expect(h.lock.acquire(), isNull);
      h.controller.acknowledgeUnknown();
      expect(h.state.unresolved, isTrue);
      await h.delete();
      expect(h.api.deletes.length, 1);
      h.select(null);
      h.controller.acknowledgeUnknown();
      expect(h.state.unresolved, isTrue);
      h.select(snapshotSession(SnapshotFake()));
      expect(h.controller.canAcknowledgeUnknown, isTrue);
      h.controller.acknowledgeUnknown();
      expect(h.state.unresolved, isFalse);
    },
  );
  test('late completion after session change cannot claim success', () async {
    final h = SnapshotHarness();
    addTearDown(h.dispose);
    final pending = Completer<SnapshotOperationResult>();
    h.api.onWrite = () => pending.future;
    final first = h.delete();
    h.select(snapshotSession(SnapshotFake()));
    pending.complete(
      const SnapshotOperationResult(
        outcome: SnapshotOperationOutcome.verified,
        message: 'Late success',
      ),
    );
    await first;
    expect(h.state.unresolved, isTrue);
    expect(h.state.server, h.session.endpoint);
    expect(h.state.target, h.api.entry.id);
    expect(h.state.result!.message, isNot(contains('Late success')));
  });
  test(
    'unexpected failure remains unknown and never reveals remote details',
    () async {
      final h = SnapshotHarness();
      addTearDown(h.dispose);
      h.api.onWrite = () => Future.error(StateError('private-secret'));
      await h.create();
      expect(h.state.unresolved, isTrue);
      expect(h.state.result!.message, isNot(contains('private-secret')));
      expect(h.lock.acquire(), isNull);
    },
  );
}
