import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/tls_trust/certificate_facts.dart';
import 'package:truedash/features/tls_trust/models.dart';

import 'fixtures/certificates.dart';

void main() {
  final now = DateTime.utc(2026, 9, 6, 12);
  final authority = NormalizedAuthority.parse('https://nas.example.test');

  NativeParsedLeafFacts parsed({
    String? commonName = 'nas.example.test',
    List<String> dnsSans = const <String>['nas.example.test'],
    List<String> ipSans = const <String>[],
    bool hasSubjectAlternativeNames = true,
    String issuer = 'Example Test Issuer',
    DateTime? notValidBefore,
    DateTime? notValidAfter,
  }) => NativeParsedLeafFacts(
    subjectCommonName: commonName,
    dnsSubjectAlternativeNames: dnsSans,
    ipSubjectAlternativeNames: ipSans,
    hasSubjectAlternativeNames: hasSubjectAlternativeNames,
    issuerSummary: issuer,
    notValidBefore: notValidBefore ?? now.subtract(const Duration(days: 1)),
    notValidAfter: notValidAfter ?? now.add(const Duration(days: 1)),
  );

  NativeParsedLeafFacts parsedFixture({
    required String name,
    required String issuer,
    required DateTime notValidBefore,
    required DateTime notValidAfter,
  }) => parsed(
    commonName: name,
    dnsSans: <String>[name],
    issuer: issuer,
    notValidBefore: notValidBefore,
    notValidAfter: notValidAfter,
  );

  final validFacts = parsedFixture(
    name: validHostMatchingLeafName,
    issuer: validHostMatchingLeafIssuer,
    notValidBefore: validHostMatchingLeafNotBefore,
    notValidAfter: validHostMatchingLeafNotAfter,
  );
  final changedFacts = parsedFixture(
    name: changedLeafName,
    issuer: changedLeafIssuer,
    notValidBefore: changedLeafNotBefore,
    notValidAfter: changedLeafNotAfter,
  );
  final expiredFacts = parsedFixture(
    name: expiredLeafName,
    issuer: expiredLeafIssuer,
    notValidBefore: expiredLeafNotBefore,
    notValidAfter: expiredLeafNotAfter,
  );
  final notYetValidFacts = parsedFixture(
    name: notYetValidLeafName,
    issuer: notYetValidLeafIssuer,
    notValidBefore: notYetValidLeafNotBefore,
    notValidAfter: notYetValidLeafNotAfter,
  );
  final hostnameMismatchingFacts = parsedFixture(
    name: hostnameMismatchingLeafName,
    issuer: hostnameMismatchingLeafIssuer,
    notValidBefore: hostnameMismatchingLeafNotBefore,
    notValidAfter: hostnameMismatchingLeafNotAfter,
  );

  CertificateProbeResult assess(
    NormalizedAuthority target,
    Uint8List der,
    NativeParsedLeafFacts facts,
  ) => CertificateFactsPolicy(now: () => now)
      .assess(target, NativePresentedLeaf(leafDer: der, parsedFacts: facts));

  test('non-malformed fixtures are distinct, realistic DER certificates', () {
    final fixtures = <Uint8List>[
      validHostMatchingLeafDer,
      changedLeafDer,
      expiredLeafDer,
      notYetValidLeafDer,
      hostnameMismatchingLeafDer,
    ];

    expect(fixtures.map(base64.encode).toSet(), hasLength(fixtures.length));
    for (final der in fixtures) {
      // A leaf certificate is a DER SEQUENCE whose body begins with a TBSCertificate
      // SEQUENCE. This keeps the fixture contract independent of native tools.
      expect(der.length, greaterThan(256));
      expect(der[0], 0x30);
      expect(der[1] & 0x80, isNot(0));
      expect(der[4], 0x30);
    }
  });

  test(
    'returns safe, approvable facts with an independently computed digest',
    () {
      final result = assess(authority, validHostMatchingLeafDer, validFacts);
      final expected = sha256
          .convert(validHostMatchingLeafDer)
          .toString()
          .toUpperCase();

      expect(result.isApprovable, isTrue);
      expect(result.presentedCertificate!.authority, authority);
      expect(result.presentedCertificate!.facts.leafDerSha256, expected);
      expect(
        result.presentedCertificate!.facts.leafDerSha256,
        matches(r'^[0-9A-F]{64}$'),
      );
      expect(
        result.presentedCertificate!.groupedFingerprint,
        expected
            .replaceAllMapped(RegExp(r'.{4}'), (match) => '${match[0]} ')
            .trimRight(),
      );
      expect(
        result.presentedCertificate!.facts.subjectSummary,
        'SAN: nas.example.test',
      );
      expect(
        result.presentedCertificate!.facts.issuerSummary,
        'CN=nas.example.test, O=TrueDash Non-Production Test',
      );
      expect(
        result.presentedCertificate!.facts.notValidBefore,
        validHostMatchingLeafNotBefore,
      );
      expect(
        result.presentedCertificate!.facts.notValidAfter,
        validHostMatchingLeafNotAfter,
      );
    },
  );

  test('changed leaf has a distinct independently computed digest', () {
    final original = assess(authority, validHostMatchingLeafDer, validFacts);
    final changed = assess(authority, changedLeafDer, changedFacts);

    expect(changed.isApprovable, isTrue);
    expect(
      changed.presentedCertificate!.facts.leafDerSha256,
      isNot(original.presentedCertificate!.facts.leafDerSha256),
    );
  });

  test('SAN takes precedence over CN and CN is used only without SAN', () {
    final san = assess(
      authority,
      validHostMatchingLeafDer,
      parsed(commonName: 'wrong.example.test'),
    );
    final cn = assess(
      authority,
      validHostMatchingLeafDer,
      parsed(
        hasSubjectAlternativeNames: false,
        dnsSans: const <String>[],
        commonName: 'nas.example.test',
      ),
    );

    expect(san.isApprovable, isTrue);
    expect(
      san.presentedCertificate!.facts.subjectSummary,
      'SAN: nas.example.test',
    );
    expect(cn.isApprovable, isTrue);
    expect(
      cn.presentedCertificate!.facts.subjectSummary,
      'CN: nas.example.test',
    );
  });

  test(
    'rejects contradictory SAN-presence metadata from the native parser',
    () {
      expect(
        assess(
          authority,
          validHostMatchingLeafDer,
          parsed(hasSubjectAlternativeNames: false),
        ).failure,
        CertificateTrustFailure.malformedCertificate,
      );
      expect(
        assess(
          authority,
          validHostMatchingLeafDer,
          parsed(
            hasSubjectAlternativeNames: true,
            dnsSans: const <String>[],
            ipSans: const <String>[],
          ),
        ).failure,
        CertificateTrustFailure.malformedCertificate,
      );
    },
  );

  test('matches exact DNS and only a supported, one-label wildcard', () {
    final wildcardFacts = parsed(dnsSans: const <String>['*.example.test']);

    expect(
      assess(
        NormalizedAuthority.parse('https://node.example.test'),
        validHostMatchingLeafDer,
        wildcardFacts,
      ).isApprovable,
      isTrue,
    );
    expect(
      assess(
        NormalizedAuthority.parse('https://a.node.example.test'),
        validHostMatchingLeafDer,
        wildcardFacts,
      ).failure,
      CertificateTrustFailure.hostnameMismatch,
    );
    expect(
      assess(
        NormalizedAuthority.parse('https://example.test'),
        validHostMatchingLeafDer,
        wildcardFacts,
      ).failure,
      CertificateTrustFailure.hostnameMismatch,
    );
    expect(
      assess(
        authority,
        validHostMatchingLeafDer,
        parsed(dnsSans: const <String>['nas.example.test']),
      ).isApprovable,
      isTrue,
    );
    expect(
      assess(
        authority,
        validHostMatchingLeafDer,
        parsed(dnsSans: const <String>['*.test']),
      ).failure,
      CertificateTrustFailure.malformedCertificate,
    );
    for (final invalidWildcard in <String>[
      '*a.example.test',
      '*.*.example.test',
      '*.example..test',
      '*.xn--bad.example.test',
    ]) {
      expect(
        assess(
          authority,
          validHostMatchingLeafDer,
          parsed(dnsSans: <String>[invalidWildcard]),
        ).failure,
        CertificateTrustFailure.malformedCertificate,
        reason: 'must reject unsupported wildcard SAN syntax',
      );
    }
  });

  test('accepts normal safe Unicode issuer text', () {
    final result = assess(
      authority,
      validHostMatchingLeafDer,
      parsed(issuer: 'Émetteur 인증서'),
    );

    expect(result.isApprovable, isTrue);
    expect(result.presentedCertificate!.facts.issuerSummary, 'Émetteur 인증서');
  });

  test('rejects display-spoofing issuer controls without exposing them', () {
    for (final unsafeIssuer in <String>[
      'Example\u202Eissuer',
      'Example\u2066issuer\u2069',
      'Example\u200Bissuer',
      'Example\u2060issuer',
      'Example\u0085issuer',
      'Example\u2028issuer',
      'Example\u2029issuer',
    ]) {
      final result = assess(
        authority,
        validHostMatchingLeafDer,
        parsed(issuer: unsafeIssuer),
      );

      expect(result.failure, CertificateTrustFailure.malformedCertificate);
      expect(result.toString(), isNot(contains(unsafeIssuer)));
    }
  });

  test('IP authorities require an exact canonical IP SAN and never use CN', () {
    final ipv4 = NormalizedAuthority.parse('https://192.0.2.10');
    final ipv6 = NormalizedAuthority.parse('https://[2001:db8::10]');

    expect(
      assess(
        ipv4,
        validHostMatchingLeafDer,
        parsed(dnsSans: const <String>[], ipSans: const <String>['192.0.2.10']),
      ).isApprovable,
      isTrue,
    );
    expect(
      assess(
        ipv6,
        validHostMatchingLeafDer,
        parsed(
          dnsSans: const <String>[],
          ipSans: const <String>['2001:0db8:0:0:0:0:0:10'],
        ),
      ).isApprovable,
      isTrue,
    );
    expect(
      assess(
        ipv4,
        validHostMatchingLeafDer,
        parsed(
          hasSubjectAlternativeNames: false,
          dnsSans: const <String>[],
          commonName: '192.0.2.10',
        ),
      ).failure,
      CertificateTrustFailure.hostnameMismatch,
    );
  });

  test(
    'accepts canonical IPv6 SAN equivalents and rejects malformed forms',
    () {
      final canonicalIpv6 = NormalizedAuthority.parse(
        'https://[2001:db8::c000:20a]',
      );
      final unspecifiedIpv6 = NormalizedAuthority.parse('https://[::]');
      final loopbackIpv6 = NormalizedAuthority.parse('https://[::1]');

      for (final san in <String>[
        '2001:0DB8:0000:0000:0000:0000:C000:020A',
        '2001:db8::c000:20a',
        '2001:db8::192.0.2.10',
      ]) {
        expect(
          assess(
            canonicalIpv6,
            validHostMatchingLeafDer,
            parsed(dnsSans: const <String>[], ipSans: <String>[san]),
          ).isApprovable,
          isTrue,
          reason: 'IPv6 SAN $san must match its canonical hex authority',
        );
      }
      expect(
        assess(
          unspecifiedIpv6,
          validHostMatchingLeafDer,
          parsed(dnsSans: const <String>[], ipSans: const <String>['::']),
        ).isApprovable,
        isTrue,
      );
      expect(
        assess(
          loopbackIpv6,
          validHostMatchingLeafDer,
          parsed(
            dnsSans: const <String>[],
            ipSans: const <String>['0:0:0:0:0:0:0:1'],
          ),
        ).isApprovable,
        isTrue,
      );

      for (final san in <String>[
        '2001::db8::1',
        '2001:::db8',
        '2001:db8:0:0:0:0:1',
        '1:2:3:4:5:6:7:8:9',
        '1:2:3:4:5:6:7:8::',
        '20001:db8::1',
        '2001:db8::g',
        '2001:db8::192.0.2.256',
        '2001:db8::192.0.2.010',
      ]) {
        expect(
          assess(
            canonicalIpv6,
            validHostMatchingLeafDer,
            parsed(dnsSans: const <String>[], ipSans: <String>[san]),
          ).failure,
          CertificateTrustFailure.malformedCertificate,
          reason: 'IPv6 SAN $san must be malformed',
        );
      }
    },
  );

  test(
    'rejects URL syntax in DNS SANs, CN fallback, and wildcard suffixes',
    () {
      final invalidDnsIdentities = <String>[
        'nas.example.test/path',
        'nas.example.test:443',
        '[nas.example.test]',
        'user@nas.example.test',
        'nas.example.test?query',
        'nas.example.test#fragment',
        r'nas.example.test\path',
        ' nas.example.test',
        'nas.example.test ',
      ];

      for (final identity in invalidDnsIdentities) {
        expect(
          assess(
            authority,
            validHostMatchingLeafDer,
            parsed(dnsSans: <String>[identity]),
          ).failure,
          CertificateTrustFailure.malformedCertificate,
          reason: 'DNS SAN must reject $identity',
        );
        expect(
          assess(
            authority,
            validHostMatchingLeafDer,
            parsed(
              hasSubjectAlternativeNames: false,
              dnsSans: const <String>[],
              commonName: identity,
            ),
          ).failure,
          CertificateTrustFailure.malformedCertificate,
          reason: 'CN fallback must reject $identity',
        );
        expect(
          assess(
            authority,
            validHostMatchingLeafDer,
            parsed(dnsSans: <String>['*.$identity']),
          ).failure,
          CertificateTrustFailure.malformedCertificate,
          reason: 'wildcard suffix must reject $identity',
        );
      }
    },
  );

  test('rejects URL syntax in IPv4 and IPv6 SANs', () {
    final ipv4 = NormalizedAuthority.parse('https://192.0.2.10');
    final ipv6 = NormalizedAuthority.parse('https://[2001:db8::10]');
    final invalidIpv4 = <String>[
      '192.0.2.10/path',
      '192.0.2.10:443',
      '[192.0.2.10]',
      'user@192.0.2.10',
      '192.0.2.10?query',
      '192.0.2.10#fragment',
      r'192.0.2.10\path',
      '192.0.2.010',
      '+192.0.2.10',
      '0xc0.0.2.10',
    ];
    final invalidIpv6 = <String>[
      '[2001:db8::10]',
      '[2001:db8::10]:443',
      '2001:db8::10/path',
      '2001:db8::10%en0',
      'user@2001:db8::10',
      '2001:db8::10?query',
      '2001:db8::10#fragment',
      r'2001:db8::10\path',
      ' 2001:db8::10',
    ];

    for (final identity in invalidIpv4) {
      expect(
        assess(
          ipv4,
          validHostMatchingLeafDer,
          parsed(dnsSans: const <String>[], ipSans: <String>[identity]),
        ).failure,
        CertificateTrustFailure.malformedCertificate,
        reason: 'IPv4 SAN must reject $identity',
      );
    }
    for (final identity in invalidIpv6) {
      expect(
        assess(
          ipv6,
          validHostMatchingLeafDer,
          parsed(dnsSans: const <String>[], ipSans: <String>[identity]),
        ).failure,
        CertificateTrustFailure.malformedCertificate,
        reason: 'IPv6 SAN must reject $identity',
      );
    }
  });

  test(
    'fails closed for malformed data, mismatched host, and invalid validity',
    () {
      expect(
        assess(authority, malformedLeafDer, parsed()).failure,
        CertificateTrustFailure.malformedCertificate,
      );
      expect(
        assess(
          authority,
          validHostMatchingLeafDer,
          parsed(dnsSans: const <String>['other.example.test']),
        ).failure,
        CertificateTrustFailure.hostnameMismatch,
      );
      expect(
        assess(
          NormalizedAuthority.parse('https://$expiredLeafName'),
          expiredLeafDer,
          expiredFacts,
        ).failure,
        CertificateTrustFailure.expiredCertificate,
      );
      expect(
        assess(
          NormalizedAuthority.parse('https://$notYetValidLeafName'),
          notYetValidLeafDer,
          notYetValidFacts,
        ).failure,
        CertificateTrustFailure.notYetValidCertificate,
      );
      expect(
        assess(
          authority,
          hostnameMismatchingLeafDer,
          hostnameMismatchingFacts,
        ).failure,
        CertificateTrustFailure.hostnameMismatch,
      );
      expect(
        assess(
          authority,
          changedLeafDer,
          parsed(
            notValidBefore: now.add(const Duration(days: 1)),
            notValidAfter: now.subtract(const Duration(days: 1)),
          ),
        ).failure,
        CertificateTrustFailure.malformedCertificate,
      );
      expect(
        assess(authority, changedLeafDer, parsed(issuer: '')).failure,
        CertificateTrustFailure.malformedCertificate,
      );
      expect(
        assess(
          authority,
          changedLeafDer,
          parsed(dnsSans: const <String>['xn--bad.example.test']),
        ).failure,
        CertificateTrustFailure.malformedCertificate,
      );
    },
  );

  test('validity endpoints are inclusive and raw DER never escapes result or error text', () {
    final boundary = assess(
      authority,
      validHostMatchingLeafDer,
      parsed(notValidBefore: now, notValidAfter: now),
    );
    final failed = assess(authority, malformedLeafDer, parsed());
    final rawMarker = base64.encode(validHostMatchingLeafDer);

    expect(boundary.isApprovable, isTrue);
    expect(boundary.toString(), isNot(contains(rawMarker)));
    expect(failed.toString(), isNot(contains(rawMarker)));
    expect(
      failed.toString(),
      isNot(contains(validHostMatchingLeafDer.join(','))),
    );
    expect(failed.presentedCertificate, isNull);
  });
}
