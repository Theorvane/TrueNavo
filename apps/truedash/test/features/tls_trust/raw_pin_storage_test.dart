import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/tls_trust/raw_pin_storage.dart';

void main() {
  test(
    'raw storage fake distinguishes absence and operation failures',
    () async {
      final storage = InMemoryRawPinStorage();
      expect(await storage.read('key'), const RawPinReadResult.absent());

      storage.failNextRead();
      expect(
        await storage.read('key'),
        const RawPinReadResult.failure(RawPinStorageFailure.readFailed),
      );

      storage.failNextWrite();
      expect(
        await storage.write('key', 'value'),
        const RawPinStorageResult.failure(RawPinStorageFailure.writeFailed),
      );
    },
  );

  test('raw storage result variants compare by value', () {
    expect(
      const RawPinReadResult.value('envelope'),
      const RawPinReadResult.value('envelope'),
    );
    expect(
      const RawPinReadResult.failure(RawPinStorageFailure.readFailed),
      const RawPinReadResult.failure(RawPinStorageFailure.readFailed),
    );
    expect(
      const RawPinStorageResult.success(),
      const RawPinStorageResult.success(),
    );
    expect(
      const RawPinStorageResult.failure(RawPinStorageFailure.deleteFailed),
      const RawPinStorageResult.failure(RawPinStorageFailure.deleteFailed),
    );
  });
}
