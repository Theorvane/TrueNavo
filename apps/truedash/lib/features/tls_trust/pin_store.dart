import 'dart:convert';

import 'models.dart';
import 'platform_pin_storage.dart';
import 'raw_pin_storage.dart';

enum PinStoreFailure {
  readFailed,
  writeFailed,
  deleteFailed,
  malformedRecord,
  replacementInProgress,
  replacementChanged,
  unsupportedPlatform,
  transactionFinished,
}

sealed class PinReadResult {
  const PinReadResult();
  const factory PinReadResult.absent() = PinAbsent;
  factory PinReadResult.record(PinRecord record) = PinRecordRead;
  const factory PinReadResult.failure(PinStoreFailure failure) = PinReadFailure;
}

final class PinAbsent extends PinReadResult {
  const PinAbsent();
  @override
  bool operator ==(Object other) => other is PinAbsent;
  @override
  int get hashCode => 0;
}

final class PinRecordRead extends PinReadResult {
  const PinRecordRead(this.record);
  final PinRecord record;
  @override
  bool operator ==(Object other) =>
      other is PinRecordRead && other.record == record;
  @override
  int get hashCode => record.hashCode;
}

final class PinReadFailure extends PinReadResult {
  const PinReadFailure(this.failure);
  final PinStoreFailure failure;
  @override
  bool operator ==(Object other) =>
      other is PinReadFailure && other.failure == failure;
  @override
  int get hashCode => failure.hashCode;
}

sealed class PinStoreResult {
  const PinStoreResult();
  const factory PinStoreResult.success() = PinStoreSuccess;
  const factory PinStoreResult.failure(PinStoreFailure failure) =
      PinStoreOperationFailure;
}

final class PinStoreSuccess extends PinStoreResult {
  const PinStoreSuccess();
  @override
  bool operator ==(Object other) => other is PinStoreSuccess;
  @override
  int get hashCode => 0;
}

class PinStoreOperationFailure extends PinStoreResult {
  const PinStoreOperationFailure(this.failure);
  final PinStoreFailure failure;
  @override
  bool operator ==(Object other) =>
      other is PinStoreOperationFailure && other.failure == failure;
  @override
  int get hashCode => failure.hashCode;
}

/// A failed atomic active write that is known not to have changed active.
/// The transaction remains open and may be safely aborted to release pending
/// state and same-process ownership.
final class PinStorePreActiveWriteFailure extends PinStoreOperationFailure {
  const PinStorePreActiveWriteFailure(super.failure);
}

sealed class PinStageResult {
  const PinStageResult();
  const factory PinStageResult.success(PinStoreTransaction transaction) =
      PinStageSuccess;
  const factory PinStageResult.failure(PinStoreFailure failure) =
      PinStageFailure;
}

sealed class PinRecoveryResult {
  const PinRecoveryResult();
  const factory PinRecoveryResult.none() = PinRecoveryNone;
  const factory PinRecoveryResult.success(
    PinRecord pending,
    PinStoreTransaction transaction,
  ) = PinRecoverySuccess;
  const factory PinRecoveryResult.failure(PinStoreFailure failure) =
      PinRecoveryFailure;
}

final class PinRecoveryNone extends PinRecoveryResult {
  const PinRecoveryNone();
  @override
  bool operator ==(Object other) => other is PinRecoveryNone;
  @override
  int get hashCode => 0;
}

final class PinRecoverySuccess extends PinRecoveryResult {
  const PinRecoverySuccess(this.pending, this.transaction);
  final PinRecord pending;
  final PinStoreTransaction transaction;
}

final class PinRecoveryFailure extends PinRecoveryResult {
  const PinRecoveryFailure(this.failure);
  final PinStoreFailure failure;
  @override
  bool operator ==(Object other) =>
      other is PinRecoveryFailure && other.failure == failure;
  @override
  int get hashCode => failure.hashCode;
}

final class PinStageSuccess extends PinStageResult {
  const PinStageSuccess(this.transaction);
  final PinStoreTransaction transaction;
}

final class PinStageFailure extends PinStageResult {
  const PinStageFailure(this.failure);
  final PinStoreFailure failure;
  @override
  bool operator ==(Object other) =>
      other is PinStageFailure && other.failure == failure;
  @override
  int get hashCode => failure.hashCode;
}

abstract interface class PinStoreTransaction {
  Future<PinStoreResult> commit();
  Future<PinStoreResult> abort();
}

abstract interface class PinStore {
  Future<PinReadResult> read(NormalizedAuthority authority);
  Future<PinStageResult> stageReplacement(
    NormalizedAuthority authority,
    PinRecord replacement,
  );
  Future<PinRecoveryResult> recoverReplacement(NormalizedAuthority authority);
}

/// Selects the app-owned platform raw backend. Web returns typed unsupported
/// results and never loads FlutterSecureStorage.
PinStore createPlatformPinStore() =>
    PersistentPinStore(createPlatformRawPinStorage());

/// App-owned durable protocol: pending is written first, then active, then pending is removed.
final class PersistentPinStore implements PinStore {
  PersistentPinStore(this._raw);
  final RawPinStorage _raw;
  static final Set<String> _ownedAuthorities = <String>{};
  static const _namespace = 'com.truedash.tls-pin.v1';
  static String activeKey(NormalizedAuthority authority) =>
      '$_namespace.active.${authority.pinKey}';
  static String pendingKey(NormalizedAuthority authority) =>
      '$_namespace.pending.${authority.pinKey}';

  @override
  Future<PinReadResult> read(NormalizedAuthority authority) async {
    final active = await _readEnvelope(activeKey(authority), authority);
    if (active case _EnvelopeFailure(:final failure)) {
      return PinReadResult.failure(failure);
    }
    final pending = await _readEnvelope(pendingKey(authority), authority);
    if (pending case _EnvelopeFailure(:final failure)) {
      return PinReadResult.failure(failure);
    }
    return switch (active) {
      _EnvelopeAbsent() => const PinReadResult.absent(),
      _EnvelopeValue(:final record) => PinReadResult.record(record),
      _ => const PinReadResult.failure(PinStoreFailure.readFailed),
    };
  }

  @override
  Future<PinStageResult> stageReplacement(
    NormalizedAuthority authority,
    PinRecord replacement,
  ) async {
    final ownership = authority.pinKey;
    if (!_ownedAuthorities.add(ownership)) {
      return const PinStageResult.failure(
        PinStoreFailure.replacementInProgress,
      );
    }
    final active = await _readEnvelope(activeKey(authority), authority);
    final pending = await _readEnvelope(pendingKey(authority), authority);
    if (active is _EnvelopeFailure) {
      _release(ownership);
      return PinStageResult.failure(active.failure);
    }
    if (pending is _EnvelopeFailure) {
      _release(ownership);
      return PinStageResult.failure(pending.failure);
    }
    // A matching pending value is an orphan after active was committed but its
    // cleanup failed. It is the sole safe recovery case.
    if (pending is _EnvelopeValue &&
        active is _EnvelopeValue &&
        active.record == pending.record) {
      final cleanup = await _raw.deleteIfValue(
        pendingKey(authority),
        pending.value,
      );
      if (cleanup is RawPinStorageOperationFailure) {
        _release(ownership);
        return PinStageResult.failure(_map(cleanup.failure));
      }
      if (cleanup is RawPinStorageNotMatched) {
        _release(ownership);
        return const PinStageResult.failure(PinStoreFailure.replacementChanged);
      }
    } else if (pending is _EnvelopeValue) {
      _release(ownership);
      return const PinStageResult.failure(
        PinStoreFailure.replacementInProgress,
      );
    }
    final pendingValue = _serialize(authority, replacement);
    final result = await _raw.writeIfValue(
      pendingKey(authority),
      null,
      pendingValue,
    );
    if (result is RawPinStorageOperationFailure) {
      _release(ownership);
      return PinStageResult.failure(_map(result.failure));
    }
    if (result is RawPinStorageNotMatched) {
      _release(ownership);
      return const PinStageResult.failure(PinStoreFailure.replacementChanged);
    }
    return PinStageResult.success(
      _PersistentTransaction(
        this,
        authority,
        replacement,
        pendingValue,
        active is _EnvelopeValue ? active.value : null,
        ownership,
      ),
    );
  }

  @override
  Future<PinRecoveryResult> recoverReplacement(
    NormalizedAuthority authority,
  ) async {
    final ownership = authority.pinKey;
    if (!_ownedAuthorities.add(ownership)) {
      return const PinRecoveryResult.failure(
        PinStoreFailure.replacementInProgress,
      );
    }
    final active = await _readEnvelope(activeKey(authority), authority);
    final pending = await _readEnvelope(pendingKey(authority), authority);
    if (active is _EnvelopeFailure) {
      _release(ownership);
      return PinRecoveryResult.failure(active.failure);
    }
    if (pending is _EnvelopeFailure) {
      _release(ownership);
      return PinRecoveryResult.failure(pending.failure);
    }
    if (pending is _EnvelopeAbsent) {
      _release(ownership);
      return const PinRecoveryResult.none();
    }
    final pendingRecord = pending as _EnvelopeValue;
    final pendingValue = pendingRecord.value;
    if (active is _EnvelopeValue && active.record == pendingRecord.record) {
      final cleanup = await _raw.deleteIfValue(
        pendingKey(authority),
        pendingValue,
      );
      if (cleanup is RawPinStorageOperationFailure) {
        _release(ownership);
        return PinRecoveryResult.failure(_map(cleanup.failure));
      }
      if (cleanup is RawPinStorageNotMatched) {
        _release(ownership);
        return const PinRecoveryResult.failure(
          PinStoreFailure.replacementChanged,
        );
      }
      _release(ownership);
      return const PinRecoveryResult.none();
    }
    return PinRecoveryResult.success(
      pendingRecord.record,
      _PersistentTransaction(
        this,
        authority,
        pendingRecord.record,
        pendingValue,
        active is _EnvelopeValue ? active.value : null,
        ownership,
      ),
    );
  }

  Future<_Envelope> _readEnvelope(
    String key,
    NormalizedAuthority authority,
  ) async {
    final result = await _raw.read(key);
    if (result is RawPinReadFailure) {
      return _EnvelopeFailure(_map(result.failure));
    }
    if (result is RawPinAbsent) return const _EnvelopeAbsent();
    final value = result as RawPinValue;
    try {
      final decoded = jsonDecode(value.value);
      if (decoded is! Map<String, Object?> ||
          decoded.length != 2 ||
          decoded['authority'] != authority.pinKey ||
          !decoded.containsKey('record')) {
        throw const FormatException();
      }
      return _EnvelopeValue(
        PinRecord.fromJson(decoded['record']!),
        value.value,
      );
    } on Object {
      return const _EnvelopeFailure(PinStoreFailure.malformedRecord);
    }
  }

  String _serialize(NormalizedAuthority authority, PinRecord record) =>
      jsonEncode(<String, Object>{
        'authority': authority.pinKey,
        'record': record.toJson(),
      });
  PinStoreFailure _map(RawPinStorageFailure failure) => switch (failure) {
    RawPinStorageFailure.readFailed => PinStoreFailure.readFailed,
    RawPinStorageFailure.writeFailed => PinStoreFailure.writeFailed,
    RawPinStorageFailure.deleteFailed => PinStoreFailure.deleteFailed,
    RawPinStorageFailure.unsupportedPlatform =>
      PinStoreFailure.unsupportedPlatform,
  };
  void _release(String ownership) => _ownedAuthorities.remove(ownership);
}

sealed class _Envelope {
  const _Envelope();
}

final class _EnvelopeAbsent extends _Envelope {
  const _EnvelopeAbsent();
}

final class _EnvelopeValue extends _Envelope {
  const _EnvelopeValue(this.record, this.value);
  final PinRecord record;
  final String value;
}

final class _EnvelopeFailure extends _Envelope {
  const _EnvelopeFailure(this.failure);
  final PinStoreFailure failure;
}

final class _PersistentTransaction implements PinStoreTransaction {
  _PersistentTransaction(
    this._store,
    this._authority,
    this._record,
    this._pendingValue,
    this._expectedActiveValue,
    this._ownership,
  );
  final PersistentPinStore _store;
  final NormalizedAuthority _authority;
  final PinRecord _record;
  final String _pendingValue;
  final String? _expectedActiveValue;
  final String _ownership;
  var _state = _TransactionState.open;

  @override
  Future<PinStoreResult> commit() async {
    if (_state == _TransactionState.finished ||
        _state == _TransactionState.committing ||
        _state == _TransactionState.aborting) {
      return const PinStoreResult.failure(PinStoreFailure.transactionFinished);
    }
    if (_state == _TransactionState.open) {
      // This synchronous transition is deliberately before the first await:
      // once commit begins, abort must never remove the durable pending value.
      _state = _TransactionState.committing;
      final write = await _store._raw.writeIfValues(
        PersistentPinStore.activeKey(_authority),
        _expectedActiveValue,
        PersistentPinStore.pendingKey(_authority),
        _pendingValue,
        _store._serialize(_authority, _record),
      );
      if (write is RawPinStorageOperationFailure) {
        _state = _TransactionState.open;
        return PinStorePreActiveWriteFailure(_store._map(write.failure));
      }
      if (write is RawPinStorageNotMatched) {
        _state = _TransactionState.open;
        return const PinStorePreActiveWriteFailure(
          PinStoreFailure.replacementChanged,
        );
      }
      _state = _TransactionState.activeWritten;
    }
    _state = _TransactionState.committing;
    final delete = await _store._raw.deleteIfValue(
      PersistentPinStore.pendingKey(_authority),
      _pendingValue,
    );
    if (delete is RawPinStorageOperationFailure) {
      _state = _TransactionState.activeWritten;
      return PinStoreResult.failure(_store._map(delete.failure));
    }
    if (delete is RawPinStorageNotMatched) {
      _state = _TransactionState.activeWritten;
      return const PinStoreResult.failure(PinStoreFailure.replacementChanged);
    }
    _finish();
    return const PinStoreResult.success();
  }

  @override
  Future<PinStoreResult> abort() async {
    if (_state != _TransactionState.open) {
      return const PinStoreResult.failure(PinStoreFailure.transactionFinished);
    }
    // As with commit, serialize before the first await so duplicate aborts
    // cannot both report success.
    _state = _TransactionState.aborting;
    final delete = await _store._raw.deleteIfValue(
      PersistentPinStore.pendingKey(_authority),
      _pendingValue,
    );
    if (delete is RawPinStorageOperationFailure) {
      _state = _TransactionState.open;
      return PinStoreResult.failure(_store._map(delete.failure));
    }
    if (delete is RawPinStorageNotMatched) {
      _state = _TransactionState.open;
      return const PinStoreResult.failure(PinStoreFailure.replacementChanged);
    }
    _finish();
    return const PinStoreResult.success();
  }

  void _finish() {
    _state = _TransactionState.finished;
    _store._release(_ownership);
  }
}

enum _TransactionState { open, committing, activeWritten, aborting, finished }

/// Compatibility fake backed by the same persistent protocol.
final class InMemoryPinStore extends PersistentPinStore {
  InMemoryPinStore() : super(InMemoryRawPinStorage());
}

final class PinStoreErrorMapper {
  const PinStoreErrorMapper._();
  static PinStoreFailure map(
    Object _, {
    PinStoreFailure operation = PinStoreFailure.readFailed,
  }) => operation;
}
