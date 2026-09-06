import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/tls_trust/models.dart';
import 'package:truedash/features/tls_trust/pin_store.dart';
import 'package:truedash/features/tls_trust/raw_pin_storage.dart';

void main() {
  final authority = NormalizedAuthority.parse('https://nas.example:8443');
  final other = NormalizedAuthority.parse('https://other.example');
  final old = PinRecord(
    leafDerSha256:
        '0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF',
    createdAt: DateTime.utc(2026, 9, 6, 12),
  );
  final replacement = PinRecord(
    leafDerSha256:
        'FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210FEDCBA9876543210',
    createdAt: DateTime.utc(2026, 9, 6, 13),
  );
  PersistentPinStore make(InMemoryRawPinStorage raw) => PersistentPinStore(raw);

  test('absence is distinct from raw read failure', () async {
    final raw = InMemoryRawPinStorage();
    final store = make(raw);
    expect(await store.read(authority), const PinReadResult.absent());
    raw.failNextRead();
    expect(
      await store.read(authority),
      const PinReadResult.failure(PinStoreFailure.readFailed),
    );
  });
  test(
    'uses a canonical-authority envelope around exactly four PinRecord fields',
    () async {
      final raw = InMemoryRawPinStorage();
      final store = make(raw);
      final transaction = staged(await store.stageReplacement(authority, old));
      expect(await transaction.commit(), const PinStoreResult.success());
      final decoded = jsonDecode(
        raw.values[PersistentPinStore.activeKey(authority)]!,
      ) as Map<String, dynamic>;
      expect(decoded['authority'], authority.pinKey);
      expect(
        (decoded['record'] as Map).keys,
        unorderedEquals([
          'version',
          'leafDerSha256',
          'fingerprintFormat',
          'createdAt',
        ]),
      );
      expect(raw.values.values.join(), isNot(contains('rawDer')));
    },
  );
  test(
    'staging retains active and commit writes active before pending cleanup',
    () async {
      final raw = InMemoryRawPinStorage();
      final store = make(raw);
      final first = staged(await store.stageReplacement(authority, old));
      await first.commit();
      final tx = staged(await store.stageReplacement(authority, replacement));
      expect(await store.read(authority), PinReadResult.record(old));
      expect(
        raw.values.containsKey(PersistentPinStore.pendingKey(authority)),
        isTrue,
      );
      expect(await tx.commit(), const PinStoreResult.success());
      expect(await store.read(authority), PinReadResult.record(replacement));
      expect(
        raw.values.containsKey(PersistentPinStore.pendingKey(authority)),
        isFalse,
      );
    },
  );
  test(
    'active write failure preserves old active and can be aborted',
    () async {
      final raw = InMemoryRawPinStorage();
      final store = make(raw);
      await staged(await store.stageReplacement(authority, old)).commit();
      raw.failNextWrite();
      expect(
        await store.stageReplacement(authority, replacement),
        const PinStageResult.failure(PinStoreFailure.writeFailed),
      );
      final tx = staged(await store.stageReplacement(authority, replacement));
      raw.failNextWrite();
      expect(
        await tx.commit(),
        const PinStoreResult.failure(PinStoreFailure.writeFailed),
      );
      expect(await store.read(authority), PinReadResult.record(old));
      expect(await tx.abort(), const PinStoreResult.success());
      expect(await store.read(authority), PinReadResult.record(old));
      final retry = staged(
        await store.stageReplacement(authority, replacement),
      );
      expect(await retry.abort(), const PinStoreResult.success());
    },
  );
  test('pending cleanup failure leaves new active recoverable and abort only removes pending', () async {
    final raw = InMemoryRawPinStorage();
    final store = make(raw);
    final tx = staged(await store.stageReplacement(authority, replacement));
    raw.failNextDelete();
    expect(
      await tx.commit(),
      const PinStoreResult.failure(PinStoreFailure.deleteFailed),
    );
    expect(await store.read(authority), PinReadResult.record(replacement));
    expect(await tx.commit(), const PinStoreResult.success());
    final abort = staged(await store.stageReplacement(authority, old));
    expect(await abort.abort(), const PinStoreResult.success());
    expect(await store.read(authority), PinReadResult.record(replacement));
  });
  test(
    'abort delete failure retains its live transaction for a safe retry',
    () async {
      final raw = InMemoryRawPinStorage();
      final store = make(raw);
      final tx = staged(await store.stageReplacement(authority, replacement));
      raw.failNextDelete();
      expect(
        await tx.abort(),
        const PinStoreResult.failure(PinStoreFailure.deleteFailed),
      );
      expect(await store.read(authority), const PinReadResult.absent());
      expect(await tx.abort(), const PinStoreResult.success());
      expect(await store.read(authority), const PinReadResult.absent());
    },
  );
  test(
    'a leftover pending matching active is cleaned before a new stage',
    () async {
      final raw = InMemoryRawPinStorage();
      final store = make(raw);
      final envelope = jsonEncode({
        'authority': authority.pinKey,
        'record': old.toJson(),
      });
      raw.values[PersistentPinStore.activeKey(authority)] = envelope;
      raw.values[PersistentPinStore.pendingKey(authority)] = envelope;
      final transaction = staged(
        await store.stageReplacement(authority, replacement),
      );
      expect(
        raw.values.containsKey(PersistentPinStore.pendingKey(authority)),
        isTrue,
      );
      expect(await transaction.abort(), const PinStoreResult.success());
      expect(await store.read(authority), PinReadResult.record(old));
    },
  );
  test(
    'malformed active or stale/malformed pending blocks and is never repaired',
    () async {
      final raw = InMemoryRawPinStorage();
      final store = make(raw);
      raw.values[PersistentPinStore.activeKey(authority)] = '{}';
      expect(
        await store.read(authority),
        const PinReadResult.failure(PinStoreFailure.malformedRecord),
      );
      raw.values.clear();
      raw.values[PersistentPinStore.pendingKey(authority)] = '{}';
      expect(
        await store.stageReplacement(authority, replacement),
        const PinStageResult.failure(PinStoreFailure.malformedRecord),
      );
      raw.values[PersistentPinStore.pendingKey(authority)] = jsonEncode({
        'authority': authority.pinKey,
        'record': old.toJson(),
      });
      expect(
        await store.stageReplacement(authority, replacement),
        const PinStageResult.failure(PinStoreFailure.replacementInProgress),
      );
    },
  );
  test('replay is rejected; same authority locks while independent authorities do not', () async {
    final raw = InMemoryRawPinStorage();
    final store = make(raw);
    final tx = staged(await store.stageReplacement(authority, old));
    expect(
      await store.stageReplacement(authority, replacement),
      const PinStageResult.failure(PinStoreFailure.replacementInProgress),
    );
    final independent = staged(await store.stageReplacement(other, old));
    expect(await independent.abort(), const PinStoreResult.success());
    expect(await tx.abort(), const PinStoreResult.success());
    expect(
      await tx.commit(),
      const PinStoreResult.failure(PinStoreFailure.transactionFinished),
    );
  });
}

PinStoreTransaction staged(PinStageResult result) => switch (result) {
  PinStageSuccess(:final transaction) => transaction,
  PinStageFailure(:final failure) => fail('stage failed: $failure'),
};
