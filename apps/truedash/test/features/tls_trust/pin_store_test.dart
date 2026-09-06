import 'dart:async';
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
  test('a commit in progress cannot be successfully aborted', () async {
    final raw = _DelayedCommitRawPinStorage();
    final store = PersistentPinStore(raw);
    await staged(await store.stageReplacement(authority, old)).commit();
    raw.delayNextActiveWrite();
    final transaction = staged(
      await store.stageReplacement(authority, replacement),
    );

    final committing = transaction.commit();
    await raw.activeWriteStarted.future;
    expect(
      await transaction.commit(),
      const PinStoreResult.failure(PinStoreFailure.transactionFinished),
    );
    expect(
      await transaction.abort(),
      const PinStoreResult.failure(PinStoreFailure.transactionFinished),
    );

    raw.allowActiveWrite.complete();
    expect(await committing, const PinStoreResult.success());
    expect(await store.read(authority), PinReadResult.record(replacement));
    expect(
      await transaction.commit(),
      const PinStoreResult.failure(PinStoreFailure.transactionFinished),
    );
    expect(
      await transaction.abort(),
      const PinStoreResult.failure(PinStoreFailure.transactionFinished),
    );
  });
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
  test(
    'restart recovery exposes an orphan without active for explicit commit',
    () async {
      final raw = InMemoryRawPinStorage();
      raw.values[PersistentPinStore.pendingKey(authority)] = envelope(
        authority,
        replacement,
      );
      final restarted = make(raw);
      final recovered = await restarted.recoverReplacement(authority);
      final transaction = recoveredTransaction(recovered, replacement);
      expect(await transaction.commit(), const PinStoreResult.success());
      expect(
        await restarted.read(authority),
        PinReadResult.record(replacement),
      );
    },
  );
  test(
    'restart recovery preserves differing active until explicit abort',
    () async {
      final raw = InMemoryRawPinStorage();
      raw.values[PersistentPinStore.activeKey(authority)] = envelope(
        authority,
        old,
      );
      raw.values[PersistentPinStore.pendingKey(authority)] = envelope(
        authority,
        replacement,
      );
      final restarted = make(raw);
      final transaction = recoveredTransaction(
        await restarted.recoverReplacement(authority),
        replacement,
      );
      expect(await transaction.abort(), const PinStoreResult.success());
      expect(await restarted.read(authority), PinReadResult.record(old));
    },
  );
  test(
    'recovered commit fails closed when active or pending changed',
    () async {
      final raw = InMemoryRawPinStorage();
      raw.values[PersistentPinStore.activeKey(authority)] = envelope(
        authority,
        old,
      );
      raw.values[PersistentPinStore.pendingKey(authority)] = envelope(
        authority,
        replacement,
      );
      final restarted = make(raw);
      final transaction = recoveredTransaction(
        await restarted.recoverReplacement(authority),
        replacement,
      );
      raw.values[PersistentPinStore.activeKey(authority)] = envelope(
        authority,
        replacement,
      );
      expect(
        await transaction.commit(),
        const PinStoreResult.failure(PinStoreFailure.replacementChanged),
      );
      raw.values[PersistentPinStore.pendingKey(authority)] = envelope(
        authority,
        old,
      );
      expect(
        await transaction.abort(),
        const PinStoreResult.failure(PinStoreFailure.replacementChanged),
      );
      raw.values[PersistentPinStore.activeKey(authority)] = envelope(
        authority,
        old,
      );
      raw.values[PersistentPinStore.pendingKey(authority)] = envelope(
        authority,
        replacement,
      );
      expect(await transaction.abort(), const PinStoreResult.success());
    },
  );
  test('recovery fails closed for malformed/backend values and ownership collision', () async {
    final raw = InMemoryRawPinStorage();
    raw.values[PersistentPinStore.pendingKey(authority)] = '{}';
    final store = make(raw);
    expect(
      await store.recoverReplacement(authority),
      const PinRecoveryResult.failure(PinStoreFailure.malformedRecord),
    );
    raw.values.clear();
    raw.values[PersistentPinStore.activeKey(authority)] = '{}';
    expect(
      await store.recoverReplacement(authority),
      const PinRecoveryResult.failure(PinStoreFailure.malformedRecord),
    );
    raw.values.clear();
    raw.failNextRead();
    expect(
      await store.recoverReplacement(authority),
      const PinRecoveryResult.failure(PinStoreFailure.readFailed),
    );
    raw.values[PersistentPinStore.pendingKey(authority)] = envelope(
      authority,
      replacement,
    );
    final first = make(raw);
    final transaction = recoveredTransaction(
      await first.recoverReplacement(authority),
      replacement,
    );
    final second = make(raw);
    expect(
      await second.recoverReplacement(authority),
      const PinRecoveryResult.failure(PinStoreFailure.replacementInProgress),
    );
    expect(await transaction.abort(), const PinStoreResult.success());
  });
  test(
    'recovery safely cleans a pending value already committed as active',
    () async {
      final raw = InMemoryRawPinStorage();
      raw.values[PersistentPinStore.activeKey(authority)] = envelope(
        authority,
        replacement,
      );
      raw.values[PersistentPinStore.pendingKey(authority)] = envelope(
        authority,
        replacement,
      );
      final store = make(raw);
      expect(
        await store.recoverReplacement(authority),
        const PinRecoveryResult.none(),
      );
      expect(
        raw.values.containsKey(PersistentPinStore.pendingKey(authority)),
        isFalse,
      );
      expect(await store.read(authority), PinReadResult.record(replacement));
    },
  );
}

PinStoreTransaction staged(PinStageResult result) => switch (result) {
  PinStageSuccess(:final transaction) => transaction,
  PinStageFailure(:final failure) => fail('stage failed: $failure'),
};

PinStoreTransaction recoveredTransaction(
  PinRecoveryResult result,
  PinRecord record,
) => switch (result) {
  PinRecoverySuccess(:final pending, :final transaction)
      when pending == record =>
    transaction,
  PinRecoveryFailure(:final failure) => fail('recovery failed: $failure'),
  _ => fail('recovery did not return the expected pending record'),
};

String envelope(NormalizedAuthority authority, PinRecord record) =>
    jsonEncode({'authority': authority.pinKey, 'record': record.toJson()});

final class _DelayedCommitRawPinStorage implements RawPinStorage {
  final _delegate = InMemoryRawPinStorage();
  final activeWriteStarted = Completer<void>();
  final allowActiveWrite = Completer<void>();
  var _delayNextActiveWrite = false;

  void delayNextActiveWrite() => _delayNextActiveWrite = true;

  @override
  Future<RawPinReadResult> read(String key) => _delegate.read(key);

  @override
  Future<RawPinStorageResult> write(String key, String value) =>
      _delegate.write(key, value);

  @override
  Future<RawPinStorageResult> delete(String key) => _delegate.delete(key);

  @override
  Future<RawPinStorageResult> deleteIfValue(String key, String expectedValue) =>
      _delegate.deleteIfValue(key, expectedValue);

  @override
  Future<RawPinStorageResult> writeIfValue(
    String key,
    String? expectedValue,
    String value,
  ) => _delegate.writeIfValue(key, expectedValue, value);

  @override
  Future<RawPinStorageResult> writeIfValues(
    String key,
    String? expectedValue,
    String guardKey,
    String expectedGuardValue,
    String value,
  ) async {
    if (_delayNextActiveWrite) {
      _delayNextActiveWrite = false;
      activeWriteStarted.complete();
      await allowActiveWrite.future;
    }
    return _delegate.writeIfValues(
      key,
      expectedValue,
      guardKey,
      expectedGuardValue,
      value,
    );
  }
}
