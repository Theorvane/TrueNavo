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

    test('accepts valid IPv4 and bracketed IPv6 authorities', () {
      final ipv4 = NormalizedAuthority.parse('https://192.0.2.10');
      final ipv6Default = NormalizedAuthority.parse('https://[2001:db8::10]');
      final ipv6Explicit = NormalizedAuthority.parse(
        'https://[2001:db8::10]:8443',
      );

      expect(ipv4.pinKey, 'https://192.0.2.10:443');
      expect(ipv6Default.pinKey, 'https://[2001:db8::10]:443');
      expect(ipv6Explicit.pinKey, 'https://[2001:db8::10]:8443');
      expect(ipv6Default, NormalizedAuthority.parse('https://[2001:DB8::10]'));
      expect(ipv6Default, isNot(ipv6Explicit));
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
      'https://@nas.example',
      'https://nas.example?value=1',
      'https://nas.example#fragment',
      'https:///api/current',
      'https://:443',
      'https://nas.example:invalid',
      'https://nas.example:0',
      'https://nas.example:65536',
      'https://nas.example:443:444',
      'https://[not-an-ipv6]',
      'https://nas_example',
      'https://nas..example',
      'https://-nas.example',
      'https://nas-.example',
      'https://xn--.example',
      'https://xn--a.example',
      'https://xn---bad.example',
      'https://xn--bcher-kva.example',
      'https://XN--BCHER-KVA.example',
      'https://${'a' * 64}.example',
      'https://${List<String>.filled(128, 'a').join('.')}',
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

    test(
      'rejects timestamps more precise than the stored millisecond format',
      () {
        expect(
          () => PinRecord(
            leafDerSha256: digest,
            createdAt: DateTime.utc(2026, 9, 6, 12, 30, 0, 0, 1),
          ),
          throwsA(isA<PinRecordFormatException>()),
        );
      },
    );

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
        'createdAt': '2026-9-06T12:30:00.000Z',
      },
      <String, Object>{
        'version': 1,
        'leafDerSha256': digest,
        'fingerprintFormat': 'SHA-256/DER',
        'createdAt': '2026-09-06T12:30:00Z',
      },
      <String, Object>{
        'version': 1,
        'leafDerSha256': digest,
        'fingerprintFormat': 'SHA-256/DER',
        'createdAt': '2026-09-06T12:30:00.000+00:00',
      },
      <String, Object>{
        'version': 1,
        'leafDerSha256': digest,
        'fingerprintFormat': 'SHA-256/DER',
        'createdAt': '2026-02-30T12:30:00.000Z',
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
