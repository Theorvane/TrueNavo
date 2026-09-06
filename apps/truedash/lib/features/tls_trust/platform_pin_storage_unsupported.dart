import 'raw_pin_storage.dart';

/// Web intentionally has no secure-storage import or instance.
RawPinStorage createPlatformRawPinStorage() => const UnsupportedRawPinStorage();

final class UnsupportedRawPinStorage implements RawPinStorage {
  const UnsupportedRawPinStorage();
  @override
  Future<RawPinReadResult> read(String key) async =>
      const RawPinReadResult.failure(RawPinStorageFailure.unsupportedPlatform);
  @override
  Future<RawPinStorageResult> write(String key, String value) async =>
      const RawPinStorageResult.failure(
        RawPinStorageFailure.unsupportedPlatform,
      );
  @override
  Future<RawPinStorageResult> delete(String key) async =>
      const RawPinStorageResult.failure(
        RawPinStorageFailure.unsupportedPlatform,
      );
  @override
  Future<RawPinStorageResult> writeIfValue(
    String key,
    String? expectedValue,
    String value,
  ) async => const RawPinStorageResult.failure(
    RawPinStorageFailure.unsupportedPlatform,
  );
  @override
  Future<RawPinStorageResult> writeIfValues(
    String key,
    String? expectedValue,
    String guardKey,
    String expectedGuardValue,
    String value,
  ) async => const RawPinStorageResult.failure(
    RawPinStorageFailure.unsupportedPlatform,
  );
  @override
  Future<RawPinStorageResult> deleteIfValue(
    String key,
    String expectedValue,
  ) async => const RawPinStorageResult.failure(
    RawPinStorageFailure.unsupportedPlatform,
  );
}
