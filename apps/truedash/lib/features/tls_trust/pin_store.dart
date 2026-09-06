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

final class PinStoreOperationFailure extends PinStoreResult {
  const PinStoreOperationFailure(this.failure);
  final PinStoreFailure failure;
  @override
  bool operator ==(Object other) =>
      other is PinStoreOperationFailure && other.failure == failure;
  @override
  int get hashCode => failure.hashCode;
}

sealed class PinStageResult {
  const PinStageResult();
  const factory PinStageResult.success(PinStoreTransaction transaction) =
      PinStageSuccess;
  const factory PinStageResult.failure(PinStoreFailure failure) =
      PinStageFailure;
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
      final cleanup = await _raw.delete(pendingKey(authority));
      if (cleanup is RawPinStorageOperationFailure) {
        _release(ownership);
        return PinStageResult.failure(_map(cleanup.failure));
      }
    } else if (pending is _EnvelopeValue) {
      _release(ownership);
      return const PinStageResult.failure(
        PinStoreFailure.replacementInProgress,
      );
    }
    final result = await _raw.write(
      pendingKey(authority),
      _serialize(authority, replacement),
    );
    if (result is RawPinStorageOperationFailure) {
      _release(ownership);
      return PinStageResult.failure(_map(result.failure));
    }
    return PinStageResult.success(
      _PersistentTransaction(this, authority, replacement, ownership),
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
      return _EnvelopeValue(PinRecord.fromJson(decoded['record']!));
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
  const _EnvelopeValue(this.record);
  final PinRecord record;
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
    this._ownership,
  );
  final PersistentPinStore _store;
  final NormalizedAuthority _authority;
  final PinRecord _record;
  final String _ownership;
  var _activeWritten = false;
  var _finished = false;
  @override
  Future<PinStoreResult> commit() async {
    if (_finished) {
      return const PinStoreResult.failure(PinStoreFailure.transactionFinished);
    }
    if (!_activeWritten) {
      final write = await _store._raw.write(
        PersistentPinStore.activeKey(_authority),
        _store._serialize(_authority, _record),
      );
      if (write is RawPinStorageOperationFailure) {
        return PinStoreResult.failure(_store._map(write.failure));
      }
      _activeWritten = true;
    }
    final delete = await _store._raw.delete(
      PersistentPinStore.pendingKey(_authority),
    );
    if (delete is RawPinStorageOperationFailure) {
      return PinStoreResult.failure(_store._map(delete.failure));
    }
    _finish();
    return const PinStoreResult.success();
  }

  @override
  Future<PinStoreResult> abort() async {
    if (_finished) {
      return const PinStoreResult.failure(PinStoreFailure.transactionFinished);
    }
    if (_activeWritten) {
      return const PinStoreResult.failure(PinStoreFailure.transactionFinished);
    }
    final delete = await _store._raw.delete(
      PersistentPinStore.pendingKey(_authority),
    );
    if (delete is RawPinStorageOperationFailure) {
      return PinStoreResult.failure(_store._map(delete.failure));
    }
    _finish();
    return const PinStoreResult.success();
  }

  void _finish() {
    _finished = true;
    _store._release(_ownership);
  }
}

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
