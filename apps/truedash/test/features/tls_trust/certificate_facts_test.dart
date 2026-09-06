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

  test('matches exact DNS and only a safe, one-label wildcard', () {
    final wildcardFacts = parsed(dnsSans: const <String>['*.nas.example.test']);

    expect(
      assess(
        NormalizedAuthority.parse('https://node.nas.example.test'),
        validHostMatchingLeafDer,
        wildcardFacts,
      ).isApprovable,
      isTrue,
    );
    expect(
      assess(
        NormalizedAuthority.parse('https://a.node.nas.example.test'),
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
        parsed(dnsSans: const <String>['*.example.test']),
      ).failure,
      CertificateTrustFailure.malformedCertificate,
    );
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
