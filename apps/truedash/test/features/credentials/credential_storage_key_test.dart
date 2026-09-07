import 'package:flutter_test/flutter_test.dart';
import 'package:truenas_api/truenas_api.dart';
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

    test('trailing-dot DNS aliases derive the same canonical key', () {
      expect(
        credentialStorageKey('https://vault-unit.example.'),
        credentialStorageKey('wss://vault-unit.example/api/current'),
      );
    });

    test('default WSS port aliases derive the same canonical key', () {
      expect(
        credentialStorageKey('wss://vault-unit.example/api/current'),
        credentialStorageKey('wss://vault-unit.example:443/api/current'),
      );
    });

    test('equivalent IPv6 spellings derive the same canonical key', () {
      expect(
        credentialStorageKey('wss://[2001:db8::1]/api/current'),
        credentialStorageKey('wss://[2001:0db8:0:0:0:0:0:1]/api/current'),
      );
      expect(
        credentialStorageKey('wss://[2001:DB8:0:0:1:0:0:1]/api/current'),
        credentialStorageKey('wss://[2001:db8::1:0:0:1]/api/current'),
      );
    });

    test('non-default ports remain distinct credential identities', () {
      expect(
        credentialStorageKey('wss://vault-unit.example:8443/api/current'),
        isNot(
          credentialStorageKey('wss://vault-unit.example:9443/api/current'),
        ),
      );
    });

    test('key canonicalization does not mutate the TLS connector URI', () {
      final endpoint = ValidatedEndpoint.parse(
        'wss://[2001:0db8:0:0:0:0:0:1]:443/connector-path',
      );
      final connectorUri = endpoint.connectionUri;

      credentialStorageKey(endpoint.originalInput);

      expect(endpoint.connectionUri, same(connectorUri));
      expect(
        endpoint.connectionUri.toString(),
        'wss://[2001:0db8:0:0:0:0:0:1]:443/connector-path',
      );
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
        'https://vault-unit.example..',
        'wss://[2001:db8::1::2]/api/current',
        'wss://[1:2:3:4:5:6:7:8::]/api/current',
        'wss://[::ffff:192.0.2.1]/api/current',
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
