/// A narrow, injected boundary for an operating-system secure store.
///
/// Values are serialized pin envelopes. Implementations must never log them.
abstract interface class RawPinStorage {
  Future<RawPinReadResult> read(String key);
  Future<RawPinStorageResult> write(String key, String value);
  Future<RawPinStorageResult> delete(String key);
}

enum RawPinStorageFailure {
  readFailed,
  writeFailed,
  deleteFailed,
  unsupportedPlatform,
}

sealed class RawPinReadResult {
  const RawPinReadResult();
  const factory RawPinReadResult.absent() = RawPinAbsent;
  const factory RawPinReadResult.value(String value) = RawPinValue;
  const factory RawPinReadResult.failure(RawPinStorageFailure failure) =
      RawPinReadFailure;
}

final class RawPinAbsent extends RawPinReadResult {
  const RawPinAbsent();
  @override
  bool operator ==(Object other) => other is RawPinAbsent;
  @override
  int get hashCode => 0;
}

final class RawPinValue extends RawPinReadResult {
  const RawPinValue(this.value);
  final String value;
  @override
  bool operator ==(Object other) =>
      other is RawPinValue && other.value == value;
  @override
  int get hashCode => value.hashCode;
}

final class RawPinReadFailure extends RawPinReadResult {
  const RawPinReadFailure(this.failure);
  final RawPinStorageFailure failure;
  @override
  bool operator ==(Object other) =>
      other is RawPinReadFailure && other.failure == failure;
  @override
  int get hashCode => failure.hashCode;
}

sealed class RawPinStorageResult {
  const RawPinStorageResult();
  const factory RawPinStorageResult.success() = RawPinStorageSuccess;
  const factory RawPinStorageResult.failure(RawPinStorageFailure failure) =
      RawPinStorageOperationFailure;
}

final class RawPinStorageSuccess extends RawPinStorageResult {
  const RawPinStorageSuccess();
  @override
  bool operator ==(Object other) => other is RawPinStorageSuccess;
  @override
  int get hashCode => 0;
}

final class RawPinStorageOperationFailure extends RawPinStorageResult {
  const RawPinStorageOperationFailure(this.failure);
  final RawPinStorageFailure failure;
  @override
  bool operator ==(Object other) =>
      other is RawPinStorageOperationFailure && other.failure == failure;
  @override
  int get hashCode => failure.hashCode;
}

/// Test-only deterministic raw-store fake; it deliberately contains no OS API.
final class InMemoryRawPinStorage implements RawPinStorage {
  final Map<String, String> values = <String, String>{};
  RawPinStorageFailure? _readFailure;
  RawPinStorageFailure? _writeFailure;
  RawPinStorageFailure? _deleteFailure;
  void failNextRead() => _readFailure = RawPinStorageFailure.readFailed;
  void failNextWrite() => _writeFailure = RawPinStorageFailure.writeFailed;
  void failNextDelete() => _deleteFailure = RawPinStorageFailure.deleteFailed;
  @override
  Future<RawPinReadResult> read(String key) async {
    final failure = _readFailure;
    _readFailure = null;
    if (failure != null) return RawPinReadResult.failure(failure);
    final value = values[key];
    return value == null
        ? const RawPinReadResult.absent()
        : RawPinReadResult.value(value);
  }

  @override
  Future<RawPinStorageResult> write(String key, String value) async {
    final failure = _writeFailure;
    _writeFailure = null;
    if (failure != null) return RawPinStorageResult.failure(failure);
    values[key] = value;
    return const RawPinStorageResult.success();
  }

  @override
  Future<RawPinStorageResult> delete(String key) async {
    final failure = _deleteFailure;
    _deleteFailure = null;
    if (failure != null) return RawPinStorageResult.failure(failure);
    values.remove(key);
    return const RawPinStorageResult.success();
  }
}
