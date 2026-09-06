/// A narrow, injected boundary for an operating-system secure store.
///
/// Values are serialized pin envelopes. Implementations must never log them.
abstract interface class RawPinStorage {
  Future<RawPinReadResult> read(String key);
  Future<RawPinStorageResult> write(String key, String value);
  Future<RawPinStorageResult> delete(String key);

  /// Changes a value only when it still has the expected value. A null
  /// expectation means the key must still be absent.
  Future<RawPinStorageResult> writeIfValue(
    String key,
    String? expectedValue,
    String value,
  );

  /// Changes [key] only while both it and [guardKey] still match their
  /// expected values. Store ownership serializes app operations; backends
  /// fail closed when either condition cannot be verified.
  Future<RawPinStorageResult> writeIfValues(
    String key,
    String? expectedValue,
    String guardKey,
    String expectedGuardValue,
    String value,
  );

  /// Deletes a value only when it still exactly matches [expectedValue].
  Future<RawPinStorageResult> deleteIfValue(String key, String expectedValue);
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
  const factory RawPinStorageResult.notMatched() = RawPinStorageNotMatched;
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

final class RawPinStorageNotMatched extends RawPinStorageResult {
  const RawPinStorageNotMatched();
  @override
  bool operator ==(Object other) => other is RawPinStorageNotMatched;
  @override
  int get hashCode => 1;
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

  @override
  Future<RawPinStorageResult> writeIfValue(
    String key,
    String? expectedValue,
    String value,
  ) async {
    final failure = _writeFailure;
    _writeFailure = null;
    if (failure != null) return RawPinStorageResult.failure(failure);
    if (values[key] != expectedValue) {
      return const RawPinStorageResult.notMatched();
    }
    values[key] = value;
    return const RawPinStorageResult.success();
  }

  @override
  Future<RawPinStorageResult> deleteIfValue(
    String key,
    String expectedValue,
  ) async {
    final failure = _deleteFailure;
    _deleteFailure = null;
    if (failure != null) return RawPinStorageResult.failure(failure);
    if (values[key] != expectedValue) {
      return const RawPinStorageResult.notMatched();
    }
    values.remove(key);
    return const RawPinStorageResult.success();
  }

  @override
  Future<RawPinStorageResult> writeIfValues(
    String key,
    String? expectedValue,
    String guardKey,
    String expectedGuardValue,
    String value,
  ) async {
    final failure = _writeFailure;
    _writeFailure = null;
    if (failure != null) return RawPinStorageResult.failure(failure);
    if (values[key] != expectedValue ||
        values[guardKey] != expectedGuardValue) {
      return const RawPinStorageResult.notMatched();
    }
    values[key] = value;
    return const RawPinStorageResult.success();
  }
}
