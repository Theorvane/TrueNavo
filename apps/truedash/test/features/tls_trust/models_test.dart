import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/tls_trust/models.dart';

void main() {
  const digest =
      '0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF0123456789ABCDEF';

  group('NormalizedAuthority', () {
    test('canonicalizes the authority while retaining the RPC URI path', () {
      final authority = NormalizedAuthority.parse(
        ' HTTPS://NAS.Example:8443/custom/rpc ',
      );

      expect(authority.scheme, 'https');
      expect(authority.host, 'nas.example');
      expect(authority.port, 8443);
      expect(authority.pinKey, 'https://nas.example:8443');
      expect(
        authority.rpcConnectionUri,
        Uri.parse('wss://nas.example:8443/custom/rpc'),
      );
    });

    test('uses effective default ports and the M0 default RPC path', () {
      final https = NormalizedAuthority.parse('https://NAS.example');
      final wss = NormalizedAuthority.parse('wss://nas.example/');

      expect(https.pinKey, 'https://nas.example:443');
      expect(wss.pinKey, 'wss://nas.example:443');
      expect(
        https.rpcConnectionUri,
        Uri.parse('wss://nas.example/api/current'),
      );
      expect(wss.rpcConnectionUri, Uri.parse('wss://nas.example/api/current'));
    });

    test('accepts lowercase ASCII IDNA labels', () {
      final authority = NormalizedAuthority.parse(
        'https://XN--BCHER-KVA.example',
      );

      expect(authority.host, 'xn--bcher-kva.example');
      expect(authority.pinKey, 'https://xn--bcher-kva.example:443');
    });

    test(
      'fails closed for non-ASCII hosts without a UTS-46 implementation',
      () {
        expect(
          () => NormalizedAuthority.parse('https://bücher.example'),
          throwsA(isA<AuthorityValidationException>()),
        );
      },
    );

    test('keeps scheme and effective port in the key', () {
      expect(
        NormalizedAuthority.parse('https://nas.example').pinKey,
        isNot(NormalizedAuthority.parse('wss://nas.example').pinKey),
      );
      expect(
        NormalizedAuthority.parse('https://nas.example').pinKey,
        isNot(NormalizedAuthority.parse('https://nas.example:8443').pinKey),
      );
    });

    for (final input in <String>[
      'http://nas.example',
      'ws://nas.example',
      'https://user@nas.example',
      'https://nas.example?value=1',
      'https://nas.example#fragment',
      'https:///api/current',
      'https://:443',
      'https://nas.example:invalid',
      'https://nas.example:0',
      'https://nas.example:65536',
      'https://nas.example:443:444',
      'https://[not-an-ipv6]',
    ]) {
      test('rejects unsafe or ambiguous authority: $input', () {
        expect(
          () => NormalizedAuthority.parse(input),
          throwsA(isA<AuthorityValidationException>()),
        );
      });
    }

    test('compares canonical authorities by value', () {
      expect(
        NormalizedAuthority.parse('https://NAS.example'),
        NormalizedAuthority.parse('https://nas.example:443/another/path'),
      );
    });
  });

  group('PinRecord', () {
    test(
      'serializes only the version-one pin fields and compares by value',
      () {
        final createdAt = DateTime.utc(2026, 9, 6, 12, 30);
        final record = PinRecord(leafDerSha256: digest, createdAt: createdAt);

        expect(record.version, 1);
        expect(record.fingerprintFormat, 'SHA-256/DER');
        expect(record.toJson(), <String, Object>{
          'version': 1,
          'leafDerSha256': digest,
          'fingerprintFormat': 'SHA-256/DER',
          'createdAt': '2026-09-06T12:30:00.000Z',
        });
        expect(
          record.groupedFingerprint,
          '0123 4567 89AB CDEF 0123 4567 89AB CDEF '
          '0123 4567 89AB CDEF 0123 4567 89AB CDEF',
        );
        expect(record, PinRecord.fromJson(record.toJson()));
      },
    );

    test('requires an uppercase 64-character SHA-256 DER fingerprint', () {
      expect(
        () => PinRecord(
          leafDerSha256: digest.toLowerCase(),
          createdAt: DateTime.utc(2026),
        ),
        throwsA(isA<PinRecordFormatException>()),
      );
      expect(
        () => PinRecord(leafDerSha256: 'ABCD', createdAt: DateTime.utc(2026)),
        throwsA(isA<PinRecordFormatException>()),
      );
    });

    for (final json in <Object>[
      <String, Object>{},
      <String, Object>{
        'version': 2,
        'leafDerSha256': digest,
        'fingerprintFormat': 'SHA-256/DER',
        'createdAt': '2026-09-06T12:30:00.000Z',
      },
      <String, Object>{
        'version': 1,
        'leafDerSha256': digest.toLowerCase(),
        'fingerprintFormat': 'SHA-256/DER',
        'createdAt': '2026-09-06T12:30:00.000Z',
      },
      <String, Object>{
        'version': 1,
        'leafDerSha256': digest,
        'fingerprintFormat': 'sha256',
        'createdAt': '2026-09-06T12:30:00.000Z',
      },
      <String, Object>{
        'version': 1,
        'leafDerSha256': digest,
        'fingerprintFormat': 'SHA-256/DER',
        'createdAt': 'not-a-date',
      },
      <String, Object>{
        'version': 1,
        'leafDerSha256': digest,
        'fingerprintFormat': 'SHA-256/DER',
        'createdAt': '2026-09-06T12:30:00.000Z',
        'unexpected': true,
      },
      <String, Object>{
        'version': 1,
        'leafDerSha256': digest,
        'fingerprintFormat': 'SHA-256/DER',
      },
      'not a record',
    ]) {
      test('rejects malformed or unknown pin records: $json', () {
        expect(
          () => PinRecord.fromJson(json),
          throwsA(isA<PinRecordFormatException>()),
        );
      });
    }
  });

  test('certificate facts and failures are typed and contain no raw DER', () {
    final facts = CertificateFacts(
      subjectSummary: 'nas.example',
      issuerSummary: 'Example CA',
      leafDerSha256: digest,
      notValidBefore: DateTime.utc(2026),
      notValidAfter: DateTime.utc(2027),
    );

    expect(facts.leafDerSha256, digest);
    expect(
      CertificateTrustFailure.hostnameMismatch,
      isA<CertificateTrustFailure>(),
    );
    expect(CertificateTrustFailure.pinMismatch, isA<CertificateTrustFailure>());
  });
}
