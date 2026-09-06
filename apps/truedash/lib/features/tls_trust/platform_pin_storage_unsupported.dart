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
}
