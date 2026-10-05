import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/tls_trust/certificate_facts.dart';
import 'package:truenavo/features/tls_trust/models.dart';
import 'package:truenavo/features/tls_trust/native_tls_io.dart';
import 'package:truenavo/features/tls_trust/native_tls_io.dart' as native_io;
import 'package:truenavo/features/tls_trust/native_tls_ports.dart';
import 'package:truenavo/features/tls_trust/native_tls_web.dart' as web;

import 'fixtures/certificates.dart';

void main() {
  final authority = NormalizedAuthority.parse('https://NAS.example.test');
  final now = DateTime.utc(2026, 9, 6, 12);

  group('Apple presented-leaf bridge backend', () {
    test('starts a versioned capture request with only operation identity and authority', () {
      final channel = _FakeAppleTlsMethodChannel();
      final backend = PresentedLeafProbeBackend(
        channel: channel,
        now: () => now,
      );

      backend.startProbe(
        authority: authority,
        cancellation: CancellationSource().token,
      );

      expect(channel.outbound, hasLength(1));
      final call = channel.outbound.single;
      expect(call.method, 'truenavo.capturePresentedLeaf');
      expect(
        call.arguments.keys,
        unorderedEquals(<String>[
          'protocolVersion',
          'operationId',
          'host',
          'port',
        ]),
      );
      expect(call.arguments['protocolVersion'], 1);
      expect(call.arguments['operationId'], isA<String>());
      expect(call.arguments['operationId'], isNotEmpty);
      expect(call.arguments['host'], validHostMatchingLeafName);
      expect(call.arguments['port'], 443);
    });

    test(
      'close after an outcome cancels only its operation and is idempotent',
      () async {
        final channel = _FakeAppleTlsMethodChannel();
        final backend = PresentedLeafProbeBackend(
          channel: channel,
          now: () => now,
        );
        final first = backend.startProbe(
          authority: authority,
          cancellation: CancellationSource().token,
        );
        final second = backend.startProbe(
          authority: authority,
          cancellation: CancellationSource().token,
        );
        final firstId = channel.outbound[0].operationId;
        final secondId = channel.outbound[1].operationId;

        channel.completeCapture(
          firstId,
          _successResponse(firstId, validHostMatchingLeafDer),
        );
        expect((await first.outcome).isApprovable, isTrue);

        await first.close();
        await first.close();

        final cancellationCalls = channel.outbound
            .where((call) => call.method == 'truenavo.cancelPresentedLeaf')
            .toList();
        expect(cancellationCalls, hasLength(1));
        expect(cancellationCalls.single.arguments, <String, Object>{
          'protocolVersion': 1,
          'operationId': firstId,
        });
        expect(
          cancellationCalls.single.arguments.values,
          isNot(contains(secondId)),
        );
        await second.close();
      },
    );

    test(
      'decodes only a matching successful capture response and evaluates it',
      () async {
        final channel = _FakeAppleTlsMethodChannel();
        final backend = PresentedLeafProbeBackend(
          channel: channel,
          now: () => now,
        );
        final attempt = backend.startProbe(
          authority: authority,
          cancellation: CancellationSource().token,
        );
        final operationId = channel.outbound.single.operationId;

        channel.completeCapture(
          operationId,
          _successResponse(operationId, validHostMatchingLeafDer),
        );

        final result = await attempt.outcome;
        expect(result.isApprovable, isTrue);
        expect(
          result.presentedCertificate!.platformTrust,
          PlatformTrust.didNotPass,
        );
        expect(
          result.presentedCertificate!.facts.leafDerSha256,
          sha256.convert(validHostMatchingLeafDer).toString().toUpperCase(),
        );
        expect(result.toString(), isNot(contains('base64')));
        await attempt.close();
      },
    );

    test('decodes a measured passing platform-trust fact', () async {
      final channel = _FakeAppleTlsMethodChannel();
      final backend = PresentedLeafProbeBackend(
        channel: channel,
        now: () => now,
      );
      final attempt = backend.startProbe(
        authority: authority,
        cancellation: CancellationSource().token,
      );
      final operationId = channel.outbound.single.operationId;
      channel.completeCapture(
        operationId,
        _successResponse(
          operationId,
          validHostMatchingLeafDer,
          platformTrust: 'passed',
        ),
      );

      final result = await attempt.outcome;
      expect(result.isApprovable, isTrue);
      expect(result.presentedCertificate!.platformTrust, PlatformTrust.passed);
      await attempt.close();
    });

    test('fails closed for a stale response operation id', () async {
      final channel = _FakeAppleTlsMethodChannel();
      final backend = PresentedLeafProbeBackend(
        channel: channel,
        now: () => now,
      );
      final attempt = backend.startProbe(
        authority: authority,
        cancellation: CancellationSource().token,
      );
      final operationId = channel.outbound.single.operationId;

      channel.completeCapture(
        operationId,
        _successResponse('stale-operation', validHostMatchingLeafDer),
      );

      final result = await attempt.outcome;
      expect(result.isApprovable, isFalse);
      expect(result.failure, isNotNull);
      expect(result.toString(), isNot(contains('base64')));
      await attempt.close();
    });

    test('fails closed for every malformed capture response schema', () async {
      const maximumDerBytes = 64 * 1024;
      final oversizedBase64 = base64Encode(
        List<int>.filled(maximumDerBytes + 1, 0),
      );
      final cases = <String, Object?>{
        'non-map payload': 'not a map',
        'missing response member': <String, Object>{
          'protocolVersion': 1,
          'operationId': 'placeholder',
        },
        'extra response member': <String, Object>{
          'protocolVersion': 1,
          'operationId': 'placeholder',
          'leafDerBase64': base64Encode(validHostMatchingLeafDer),
          'platformTrust': 'didNotPass',
          'nativeError': 'do-not-reflect',
        },
        'unknown platform trust': <String, Object>{
          'protocolVersion': 1,
          'operationId': 'placeholder',
          'leafDerBase64': base64Encode(validHostMatchingLeafDer),
          'platformTrust': 'unknown',
        },
        'wrong platform trust type': <String, Object>{
          'protocolVersion': 1,
          'operationId': 'placeholder',
          'leafDerBase64': base64Encode(validHostMatchingLeafDer),
          'platformTrust': true,
        },
        'wrong version type': <String, Object>{
          'protocolVersion': '1',
          'operationId': 'placeholder',
          'leafDerBase64': base64Encode(validHostMatchingLeafDer),
        },
        'wrong operation type': <String, Object>{
          'protocolVersion': 1,
          'operationId': 7,
          'leafDerBase64': base64Encode(validHostMatchingLeafDer),
        },
        'wrong leaf type': <String, Object>{
          'protocolVersion': 1,
          'operationId': 'placeholder',
          'leafDerBase64': 7,
        },
        'mismatched version': <String, Object>{
          'protocolVersion': 2,
          'operationId': 'placeholder',
          'leafDerBase64': base64Encode(validHostMatchingLeafDer),
        },
        'invalid base64': <String, Object>{
          'protocolVersion': 1,
          'operationId': 'placeholder',
          'leafDerBase64': 'not base64',
        },
        'empty base64': <String, Object>{
          'protocolVersion': 1,
          'operationId': 'placeholder',
          'leafDerBase64': '',
        },
        'oversized DER': <String, Object>{
          'protocolVersion': 1,
          'operationId': 'placeholder',
          'leafDerBase64': oversizedBase64,
        },
        'malformed DER': <String, Object>{
          'protocolVersion': 1,
          'operationId': 'placeholder',
          'leafDerBase64': base64Encode(malformedLeafDer),
        },
        'both response variants': <String, Object>{
          'protocolVersion': 1,
          'operationId': 'placeholder',
          'leafDerBase64': base64Encode(validHostMatchingLeafDer),
          'failureCode': 'captureFailed',
        },
        'wrong failure-code type': <String, Object>{
          'protocolVersion': 1,
          'operationId': 'placeholder',
          'failureCode': 7,
        },
        'unknown failure code': <String, Object>{
          'protocolVersion': 1,
          'operationId': 'placeholder',
          'failureCode': 'native failure text',
        },
      };

      for (final entry in cases.entries) {
        final channel = _FakeAppleTlsMethodChannel();
        final backend = PresentedLeafProbeBackend(
          channel: channel,
          now: () => now,
        );
        final attempt = backend.startProbe(
          authority: authority,
          cancellation: CancellationSource().token,
        );
        final operationId = channel.outbound.single.operationId;
        final response = entry.value;
        if (response is Map<String, Object> &&
            response['operationId'] == 'placeholder') {
          response['operationId'] = operationId;
        }

        channel.completeCapture(operationId, response);

        final result = await attempt.outcome;
        expect(result.isApprovable, isFalse, reason: entry.key);
        expect(result.failure, isNotNull, reason: entry.key);
        expect(result.toString(), isNot(contains('base64')), reason: entry.key);
        expect(
          result.toString(),
          isNot(contains('do-not-reflect')),
          reason: entry.key,
        );
        await attempt.close();
      }
    });

    test(
      'accepts only fixed native failure codes and never exposes native text',
      () async {
        const cases = <String, CertificateTrustFailure>{
          'captureFailed': CertificateTrustFailure.malformedCertificate,
          'cancelled': CertificateTrustFailure.cancelled,
        };
        for (final entry in cases.entries) {
          final channel = _FakeAppleTlsMethodChannel();
          final backend = PresentedLeafProbeBackend(
            channel: channel,
            now: () => now,
          );
          final attempt = backend.startProbe(
            authority: authority,
            cancellation: CancellationSource().token,
          );
          final operationId = channel.outbound.single.operationId;

          channel.completeCapture(operationId, <String, Object>{
            'protocolVersion': 1,
            'operationId': operationId,
            'failureCode': entry.key,
          });

          final result = await attempt.outcome;
          expect(result.isApprovable, isFalse, reason: entry.key);
          expect(result.failure, entry.value, reason: entry.key);
          expect(result.toString(), isNot(contains('failureCode')));
          await attempt.close();
        }
      },
    );

    test('cancel failure is surfaced as bounded cleanup failure', () async {
      final channel = _FakeAppleTlsMethodChannel()..failCancel = true;
      final probe = createProbeForNativeTlsPlatform(
        NativeTlsPlatform.apple,
        probeChannel: channel,
        now: () => now,
      );
      final future = probe.probe(
        authority: authority,
        timeout: const Duration(seconds: 1),
        cancellation: CancellationSource().token,
      );
      final id = channel.outbound.single.operationId;
      channel.completeCapture(
        id,
        _successResponse(id, validHostMatchingLeafDer),
      );

      expect(
        await future,
        const NativeProbeBoundaryFailure(
          NativeTlsBoundaryFailure.cleanupFailed,
        ),
      );
    });

    test('pre-cancelled attempt emits no capture request', () async {
      final source = CancellationSource()..cancel();
      final channel = _FakeAppleTlsMethodChannel();
      final attempt = PresentedLeafProbeBackend(
        channel: channel,
        now: () => now,
      ).startProbe(authority: authority, cancellation: source.token);

      expect(channel.outbound, isEmpty);
      expect(
        (await attempt.outcome).failure,
        CertificateTrustFailure.cancelled,
      );
      await attempt.close();
      expect(
        channel.outbound.where(
          (call) => call.method == 'truenavo.cancelPresentedLeaf',
        ),
        hasLength(1),
      );
    });

    test(
      'synchronous bridge exception fails closed and remains closeable',
      () async {
        final channel = _FakeAppleTlsMethodChannel()
          ..throwCaptureSynchronously = true;
        final attempt =
            PresentedLeafProbeBackend(
              channel: channel,
              now: () => now,
            ).startProbe(
              authority: authority,
              cancellation: CancellationSource().token,
            );

        expect(
          (await attempt.outcome).failure,
          CertificateTrustFailure.malformedCertificate,
        );
        await attempt.close();
        expect(
          channel.outbound.where(
            (call) => call.method == 'truenavo.cancelPresentedLeaf',
          ),
          hasLength(1),
        );
      },
    );

    test(
      'late capture response after close cannot resurrect its outcome',
      () async {
        final channel = _FakeAppleTlsMethodChannel();
        final attempt =
            PresentedLeafProbeBackend(
              channel: channel,
              now: () => now,
            ).startProbe(
              authority: authority,
              cancellation: CancellationSource().token,
            );
        final id = channel.outbound.single.operationId;

        await attempt.close();
        channel.completeCapture(
          id,
          _successResponse(id, validHostMatchingLeafDer),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          (await attempt.outcome).failure,
          CertificateTrustFailure.cancelled,
        );
        await attempt.close();
        expect(
          channel.outbound.where(
            (call) => call.method == 'truenavo.cancelPresentedLeaf',
          ),
          hasLength(1),
        );
      },
    );
  });

  group('DER metadata and policy linkage', () {
    test('parses genuine fixture DER and assesses those exact bytes', () {
      final cases = <_FixtureExpectation>[
        _FixtureExpectation(
          authority: authority,
          der: validHostMatchingLeafDer,
          leafName: validHostMatchingLeafName,
          issuer: validHostMatchingLeafIssuer,
          notBefore: validHostMatchingLeafNotBefore,
          notAfter: validHostMatchingLeafNotAfter,
          failure: null,
        ),
        _FixtureExpectation(
          authority: authority,
          der: hostnameMismatchingLeafDer,
          leafName: hostnameMismatchingLeafName,
          issuer: hostnameMismatchingLeafIssuer,
          notBefore: hostnameMismatchingLeafNotBefore,
          notAfter: hostnameMismatchingLeafNotAfter,
          failure: null,
          namesAuthority: false,
        ),
        _FixtureExpectation(
          authority: NormalizedAuthority.parse('https://$expiredLeafName'),
          der: expiredLeafDer,
          leafName: expiredLeafName,
          issuer: expiredLeafIssuer,
          notBefore: expiredLeafNotBefore,
          notAfter: expiredLeafNotAfter,
          failure: CertificateTrustFailure.expiredCertificate,
        ),
        _FixtureExpectation(
          authority: NormalizedAuthority.parse('https://$notYetValidLeafName'),
          der: notYetValidLeafDer,
          leafName: notYetValidLeafName,
          issuer: notYetValidLeafIssuer,
          notBefore: notYetValidLeafNotBefore,
          notAfter: notYetValidLeafNotAfter,
          failure: CertificateTrustFailure.notYetValidCertificate,
        ),
      ];

      for (final fixture in cases) {
        final metadata = parsePresentedLeafDer(fixture.der);
        final result = CertificateFactsPolicy(now: () => now).assess(
          fixture.authority,
          NativePresentedLeaf(leafDer: fixture.der, parsedFacts: metadata),
        );

        expect(metadata.subjectCommonName, fixture.leafName);
        expect(metadata.dnsSubjectAlternativeNames, [fixture.leafName]);
        expect(metadata.ipSubjectAlternativeNames, isEmpty);
        expect(metadata.hasSubjectAlternativeNames, isTrue);
        expect(metadata.issuerSummary, fixture.issuer);
        expect(metadata.notValidBefore, fixture.notBefore);
        expect(metadata.notValidAfter, fixture.notAfter);
        if (fixture.failure == null) {
          expect(result.isApprovable, isTrue);
          expect(
            result.presentedCertificate!.namesAuthority,
            fixture.namesAuthority,
          );
          expect(
            result.presentedCertificate!.facts.subjectSummary,
            'SAN: ${fixture.leafName}',
          );
          expect(
            result.presentedCertificate!.facts.leafDerSha256,
            sha256.convert(fixture.der).toString().toUpperCase(),
          );
        } else {
          expect(result.failure, fixture.failure);
        }
      }
    });

    test('parses a genuine DER-only IP SAN and preserves IP SAN policy', () {
      final metadata = parsePresentedLeafDer(ipSanLeafDer);
      expect(metadata.hasSubjectAlternativeNames, isTrue);
      expect(metadata.dnsSubjectAlternativeNames, isEmpty);
      expect(metadata.ipSubjectAlternativeNames, ['192.0.2.44']);
      final result = CertificateFactsPolicy(now: () => now).assess(
        NormalizedAuthority.parse('https://192.0.2.44'),
        NativePresentedLeaf(leafDer: ipSanLeafDer, parsedFacts: metadata),
      );
      expect(result.isApprovable, isTrue);
    });

    test('rejects truncated and trailing DER objects', () {
      expect(
        () => parsePresentedLeafDer(malformedLeafDer),
        throwsFormatException,
      );
      expect(
        () => parsePresentedLeafDer(
          Uint8List.fromList([...validHostMatchingLeafDer, 0x00]),
        ),
        throwsFormatException,
      );
    });

    test('rejects calendar-normalized UTCTime mutations', () {
      final mutated = Uint8List.fromList(validHostMatchingLeafDer);
      final needle = ascii.encode('260906063052Z');
      final start = _indexOf(mutated, needle);
      expect(start, greaterThanOrEqualTo(0));
      // 2026-09-31 is normalized by DateTime unless explicitly checked.
      mutated[start + 4] = '3'.codeUnitAt(0);
      mutated[start + 5] = '1'.codeUnitAt(0);
      expect(() => parsePresentedLeafDer(mutated), throwsFormatException);
    });

    test('rejects canonical DER mutations in genuine certificate bytes', () {
      final cases = <String, void Function(Uint8List)>{
        'unsupported explicit version': (der) {
          final index = _uniqueIndexOf(der, [0xa0, 0x03, 0x02, 0x01, 0x02]);
          der[index + 4] = 3;
        },
        'explicit FALSE critical default': (der) {
          // Basic Constraints (2.5.29.19) is a critical extension here.
          final valueIndex = _criticalBooleanValueIndexForExtension(der, [
            0x06,
            0x03,
            0x55,
            0x1d,
            0x13,
          ]);
          der[valueIndex] = 0;
        },
        'invalid signature bit padding': (der) {
          final index = _uniqueIndexOf(der, [0x03, 0x82, 0x01, 0x01, 0x00]);
          der[index + 4] = 7;
        },
        'malformed OID base-128': (der) {
          final index = _uniqueIndexOf(der, [0x06, 0x03, 0x55, 0x1d, 0x11]);
          der[index + 2] = 0x80;
        },
      };
      for (final entry in cases.entries) {
        final mutated = Uint8List.fromList(validHostMatchingLeafDer);
        entry.value(mutated);
        expect(
          () => parsePresentedLeafDer(mutated),
          throwsFormatException,
          reason: entry.key,
        );
      }
    });

    test('rejects non-v3 versions when genuine extensions remain', () {
      for (final version in [1, 0]) {
        final mutated = Uint8List.fromList(validHostMatchingLeafDer);
        final index = _uniqueIndexOf(mutated, [0xa0, 0x03, 0x02, 0x01, 0x02]);
        mutated[index + 4] = version;
        expect(
          () => parsePresentedLeafDer(mutated),
          throwsFormatException,
          reason: version == 1
              ? 'v2 cannot retain v3 extensions'
              : 'DER must omit the DEFAULT v1 version',
        );
      }
    });

    test('validates issuer and subject unique-ID BIT STRING content', () {
      for (final tag in [0x81, 0x82]) {
        final v2 = _replaceExtensionsWithUniqueId(
          validHostMatchingLeafDer,
          tag,
          [0],
        );
        final version = _uniqueIndexOf(v2, [0xa0, 0x03, 0x02, 0x01, 0x02]);
        v2[version + 4] = 1;
        expect(parsePresentedLeafDer(v2).hasSubjectAlternativeNames, isFalse);

        final nonempty = _replaceExtensionsWithUniqueId(
          validHostMatchingLeafDer,
          tag,
          [3, 0xa0],
        );
        final nonemptyVersion = _uniqueIndexOf(nonempty, [
          0xa0,
          0x03,
          0x02,
          0x01,
          0x02,
        ]);
        nonempty[nonemptyVersion + 4] = 1;
        expect(
          parsePresentedLeafDer(nonempty).hasSubjectAlternativeNames,
          isFalse,
          reason: 'valid nonempty unique ID for tag $tag',
        );

        for (final content in <List<int>>[
          [],
          [1],
          [0xff],
          [3, 0xa1],
        ]) {
          final invalid = _replaceExtensionsWithUniqueId(
            validHostMatchingLeafDer,
            tag,
            content,
          );
          final invalidVersion = _uniqueIndexOf(invalid, [
            0xa0,
            0x03,
            0x02,
            0x01,
            0x02,
          ]);
          invalid[invalidVersion + 4] = 1;
          expect(
            () => parsePresentedLeafDer(invalid),
            throwsFormatException,
            reason: 'invalid unique ID content $content for tag $tag',
          );
        }

        final v1 = _replaceExtensionsWithUniqueId(
          _withoutExplicitVersion(validHostMatchingLeafDer),
          tag,
          [0],
        );
        expect(() => parsePresentedLeafDer(v1), throwsFormatException);
      }
    });
  });

  test('platform selection supports bridged runners only and Web remains '
      'browser-managed', () async {
    for (final platform in <NativeTlsPlatform>[
      NativeTlsPlatform.linux,
      NativeTlsPlatform.windows,
      NativeTlsPlatform.other,
    ]) {
      final outcome = await native_io
          .createProbeForNativeTlsPlatform(platform)
          .probe(
            authority: authority,
            timeout: const Duration(seconds: 1),
            cancellation: CancellationSource().token,
          );
      expect(
        outcome,
        const NativeProbeBoundaryFailure(
          NativeTlsBoundaryFailure.backendUnavailable,
        ),
        reason: platform.name,
      );
    }

    for (final platform in <NativeTlsPlatform>[
      NativeTlsPlatform.apple,
      NativeTlsPlatform.android,
    ]) {
      final channel = _FakeAppleTlsMethodChannel();
      final bridgedProbe = native_io.createProbeForNativeTlsPlatform(
        platform,
        probeChannel: channel,
        now: () => now,
      );
      final bridgedOutcomeFuture = bridgedProbe.probe(
        authority: authority,
        timeout: const Duration(seconds: 1),
        cancellation: CancellationSource().token,
      );
      final operationId = channel.outbound.single.operationId;
      channel.completeCapture(
        operationId,
        _successResponse(operationId, validHostMatchingLeafDer),
      );
      expect(
        await bridgedOutcomeFuture,
        isA<NativeProbeCertificate>(),
        reason: platform.name,
      );
    }

    final webOutcome = await web.createProbe().probe(
      authority: authority,
      timeout: const Duration(seconds: 1),
      cancellation: CancellationSource().token,
    );
    expect(webOutcome, isA<NativeProbeBrowserManagedTls>());
  });
}

Map<String, Object> _successResponse(
  String operationId,
  Uint8List der, {
  String platformTrust = 'didNotPass',
}) => <String, Object>{
  'protocolVersion': 1,
  'operationId': operationId,
  'leafDerBase64': base64Encode(der),
  'platformTrust': platformTrust,
};

int _indexOf(Uint8List bytes, List<int> needle) {
  for (var start = 0; start <= bytes.length - needle.length; start++) {
    var matches = true;
    for (var offset = 0; offset < needle.length; offset++) {
      if (bytes[start + offset] != needle[offset]) {
        matches = false;
        break;
      }
    }
    if (matches) return start;
  }
  return -1;
}

int _uniqueIndexOf(Uint8List bytes, List<int> needle) {
  final matches = <int>[];
  for (var start = 0; start <= bytes.length - needle.length; start++) {
    if (List.generate(
      needle.length,
      (offset) => bytes[start + offset] == needle[offset],
    ).every((matched) => matched)) {
      matches.add(start);
    }
  }
  expect(matches, hasLength(1), reason: 'fixture pattern must be unique');
  return matches.single;
}

int _criticalBooleanValueIndexForExtension(
  Uint8List bytes,
  List<int> extensionOid,
) {
  final oidIndex = _uniqueIndexOf(bytes, extensionOid);
  final booleanIndex = oidIndex + extensionOid.length;
  expect(bytes.sublist(booleanIndex, booleanIndex + 3), [
    0x01,
    0x01,
    0xff,
  ], reason: 'extension OID must be followed by a critical TRUE BOOLEAN');
  return booleanIndex + 2;
}

Uint8List _withoutExplicitVersion(Uint8List der) {
  final version = _uniqueIndexOf(der, [0xa0, 0x03, 0x02, 0x01, 0x02]);
  expect(version, 8, reason: 'fixture version must be the first TBS field');
  final result = Uint8List.fromList([
    ...der.sublist(0, version),
    ...der.sublist(version + 5),
  ]);
  _adjustCertificateAndTbsLengths(result, -5);
  return result;
}

Uint8List _replaceExtensionsWithUniqueId(
  Uint8List der,
  int tag,
  List<int> bitStringContent,
) {
  final extension = _uniqueIndexOf(der, [0xa3, 0x52, 0x30, 0x50]);
  expect(tag == 0x81 || tag == 0x82, isTrue);
  expect(bitStringContent.length, lessThan(128));
  // Replace the complete [3] EXPLICIT Extensions field (84 bytes) with one
  // IMPLICIT BIT STRING field, retaining genuine certificate structure.
  final result = Uint8List.fromList([
    ...der.sublist(0, extension),
    tag,
    bitStringContent.length,
    ...bitStringContent,
    ...der.sublist(extension + 84),
  ]);
  _adjustCertificateAndTbsLengths(result, bitStringContent.length - 82);
  return result;
}

void _adjustCertificateAndTbsLengths(Uint8List der, int delta) {
  // The fixture uses two-byte definite lengths for Certificate and
  // TBSCertificate.
  for (final lengthOffset in [2, 6]) {
    final oldLength = (der[lengthOffset] << 8) | der[lengthOffset + 1];
    final newLength = oldLength + delta;
    der[lengthOffset] = newLength >> 8;
    der[lengthOffset + 1] = newLength & 0xff;
  }
}

final class _FixtureExpectation {
  const _FixtureExpectation({
    required this.authority,
    required this.der,
    required this.leafName,
    required this.issuer,
    required this.notBefore,
    required this.notAfter,
    required this.failure,
    this.namesAuthority = true,
  });

  final NormalizedAuthority authority;
  final Uint8List der;
  final String leafName;
  final String issuer;
  final DateTime notBefore;
  final DateTime notAfter;
  final CertificateTrustFailure? failure;
  final bool namesAuthority;
}

final class _FakeAppleTlsMethodChannel implements PresentedLeafProbeChannel {
  final outbound = <_OutboundCall>[];
  final _pendingCaptures = <String, Completer<Object?>>{};
  var failCancel = false;
  var throwCaptureSynchronously = false;

  @override
  Future<Object?> invokeMethod(String method, Map<String, Object?> arguments) {
    final call = _OutboundCall(method, Map<String, Object?>.from(arguments));
    outbound.add(call);
    if (method == 'truenavo.capturePresentedLeaf') {
      if (throwCaptureSynchronously) throw StateError('native secret text');
      final completer = Completer<Object?>();
      _pendingCaptures[call.operationId] = completer;
      return completer.future;
    }
    if (method == 'truenavo.cancelPresentedLeaf') {
      if (failCancel) {
        return Future<Object?>.error(StateError('cancel failure'));
      }
      return Future<Object?>.value(<String, Object>{
        'protocolVersion': 1,
        'operationId': call.operationId,
        'failureCode': 'cancelled',
      });
    }
    return Future<Object?>.error(StateError('unexpected native method'));
  }

  void completeCapture(String requestOperationId, Object? response) {
    final completer = _pendingCaptures[requestOperationId];
    if (completer == null) throw StateError('unknown capture operation');
    if (!completer.isCompleted) completer.complete(response);
  }
}

final class _OutboundCall {
  const _OutboundCall(this.method, this.arguments);

  final String method;
  final Map<String, Object?> arguments;

  String get operationId => arguments['operationId']! as String;
}
