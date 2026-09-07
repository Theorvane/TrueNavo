import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/credentials/credential_storage_key.dart';

void main() {
  group('credentialStorageKey', () {
    test('is a domain-separated versioned SHA-256 key', () {
      final key = credentialStorageKey('https://vault-unit.example:8443');

      expect(
        key,
        'com.truedash.api-key.v1.edfbdd666aa25a46458c9a96e832d01e45c2c4d48396f4d1f569f94b3afa36e4',
      );
      expect(
        key,
        matches(RegExp(r'^com\.truedash\.api-key\.v1\.[a-f0-9]{64}$')),
      );
      expect(
        key,
        credentialStorageKey('wss://vault-unit.example:8443/api/current'),
      );
      expect(key, isNot(contains('vault-unit.example')));
      expect(key, isNot(contains('https')));
    });

    test('rejects unsafe or noncanonical credential identifiers', () {
      for (final input in <String>[
        ' http://vault-unit.example',
        'https://user:pass@vault-unit.example',
        'https://vault-unit.example?x=1',
        'https://vault-unit.example#part',
        'https://vault-unit.example/../api',
        'https://vault-unit.example/%2e%2e/api',
        'https://vault-unit.example/%2E/api',
        'https://vault-unit.example/%',
        'https://vault-unit.example/\napi',
      ]) {
        expect(
          () => credentialStorageKey(input),
          throwsA(isA<CredentialStorageKeyFailure>()),
          reason: input,
        );
      }
    });
  });
}
