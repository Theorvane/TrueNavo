import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import 'models.dart';

/// Parsed leaf metadata supplied by the future native certificate adapter.
///
/// This is intentionally not an X.509 parser. The adapter owns X.509 parsing
/// and supplies ephemeral leaf DER solely so this policy can calculate its own
/// SHA-256 fingerprint.
final class NativeParsedLeafFacts {
  NativeParsedLeafFacts({
    required this.subjectCommonName,
    required List<String> dnsSubjectAlternativeNames,
    required List<String> ipSubjectAlternativeNames,
    required this.hasSubjectAlternativeNames,
    required this.issuerSummary,
    required this.notValidBefore,
    required this.notValidAfter,
  }) : dnsSubjectAlternativeNames = List.unmodifiable(
         dnsSubjectAlternativeNames,
       ),
       ipSubjectAlternativeNames = List.unmodifiable(ipSubjectAlternativeNames);

  final String? subjectCommonName;
  final List<String> dnsSubjectAlternativeNames;
  final List<String> ipSubjectAlternativeNames;
  final bool hasSubjectAlternativeNames;
  final String issuerSummary;
  final DateTime notValidBefore;
  final DateTime notValidAfter;
}

/// The one-shot native-adapter input. It must not be retained after [assess].
final class NativePresentedLeaf {
  NativePresentedLeaf({required Uint8List leafDer, required this.parsedFacts})
    : leafDer = Uint8List.fromList(leafDer);

  final Uint8List leafDer;
  final NativeParsedLeafFacts parsedFacts;
}

/// A display-safe certificate candidate. It deliberately has no DER field.
final class PresentedCertificate {
  const PresentedCertificate({required this.authority, required this.facts});

  final NormalizedAuthority authority;
  final CertificateFacts facts;

  String get groupedFingerprint => facts.leafDerSha256
      .replaceAllMapped(RegExp(r'.{4}'), (match) => '${match.group(0)} ')
      .trimRight();

  @override
  String toString() =>
      'PresentedCertificate(${authority.pinKey}, ${facts.leafDerSha256})';
}

/// A typed policy outcome that cannot accidentally carry native DER onwards.
final class CertificateProbeResult {
  const CertificateProbeResult._({this.presentedCertificate, this.failure});

  factory CertificateProbeResult.approvable(PresentedCertificate certificate) =>
      CertificateProbeResult._(presentedCertificate: certificate);

  factory CertificateProbeResult.failed(CertificateTrustFailure failure) =>
      CertificateProbeResult._(failure: failure);

  final PresentedCertificate? presentedCertificate;
  final CertificateTrustFailure? failure;

  bool get isApprovable => presentedCertificate != null && failure == null;

  @override
  String toString() => isApprovable
      ? 'CertificateProbeResult(approvable)'
      : 'CertificateProbeResult(${failure!.name})';
}

/// Conservative, pure validation of a native-parsed certificate leaf.
final class CertificateFactsPolicy {
  // The public parameter is named for the policy dependency, not its storage.
  // ignore: prefer_initializing_formals
  CertificateFactsPolicy({required DateTime Function() now}) : _now = now;

  final DateTime Function() _now;

  CertificateProbeResult assess(
    NormalizedAuthority authority,
    NativePresentedLeaf leaf,
  ) {
    if (!_hasDerEnvelope(leaf.leafDer)) {
      return CertificateProbeResult.failed(
        CertificateTrustFailure.malformedCertificate,
      );
    }

    final parsed = leaf.parsedFacts;
    final validation = _validateParsedFacts(parsed);
    if (validation == null) {
      return CertificateProbeResult.failed(
        CertificateTrustFailure.malformedCertificate,
      );
    }

    final currentInstant = _now().toUtc();
    if (validation.notValidBefore.isAfter(validation.notValidAfter)) {
      return CertificateProbeResult.failed(
        CertificateTrustFailure.malformedCertificate,
      );
    }
    // Both bounds are inclusive: a leaf is valid at exactly either endpoint.
    if (currentInstant.isAfter(validation.notValidAfter)) {
      return CertificateProbeResult.failed(
        CertificateTrustFailure.expiredCertificate,
      );
    }
    if (currentInstant.isBefore(validation.notValidBefore)) {
      return CertificateProbeResult.failed(
        CertificateTrustFailure.notYetValidCertificate,
      );
    }
    if (!_matchesAuthority(authority, validation)) {
      return CertificateProbeResult.failed(
        CertificateTrustFailure.hostnameMismatch,
      );
    }

    final digest = sha256.convert(leaf.leafDer).toString().toUpperCase();
    final subject = validation.hasSubjectAlternativeNames
        ? _sanSummary(validation)
        : 'CN: ${validation.commonName!}';
    return CertificateProbeResult.approvable(
      PresentedCertificate(
        authority: authority,
        facts: CertificateFacts(
          subjectSummary: subject,
          issuerSummary: validation.issuer,
          leafDerSha256: digest,
          notValidBefore: validation.notValidBefore,
          notValidAfter: validation.notValidAfter,
        ),
      ),
    );
  }

  _ValidatedFacts? _validateParsedFacts(NativeParsedLeafFacts facts) {
    final issuer = _safeSummary(facts.issuerSummary);
    if (issuer == null) return null;
    final commonName = facts.subjectCommonName;
    final canonicalCn = commonName == null
        ? null
        : _canonicalCommonName(commonName);
    if (commonName != null && canonicalCn == null) return null;

    final dnsSans = <String>[];
    for (final san in facts.dnsSubjectAlternativeNames) {
      final canonical = _canonicalDnsSan(san);
      if (canonical == null) return null;
      dnsSans.add(canonical);
    }
    final ipSans = <String>[];
    for (final san in facts.ipSubjectAlternativeNames) {
      final canonical = _canonicalIp(san);
      if (canonical == null) return null;
      ipSans.add(canonical);
    }
    // The adapter must report SAN presence consistently with the DNS/IP names
    // it supplies. A SAN extension containing only unsupported identities is
    // therefore also fail-closed: it is present but has no usable DNS/IP name.
    if (facts.hasSubjectAlternativeNames !=
        (dnsSans.isNotEmpty || ipSans.isNotEmpty)) {
      return null;
    }
    if (!facts.hasSubjectAlternativeNames && canonicalCn == null) return null;
    return _ValidatedFacts(
      commonName: canonicalCn,
      dnsSans: dnsSans,
      ipSans: ipSans,
      hasSubjectAlternativeNames: facts.hasSubjectAlternativeNames,
      issuer: issuer,
      notValidBefore: facts.notValidBefore.toUtc(),
      notValidAfter: facts.notValidAfter.toUtc(),
    );
  }

  bool _matchesAuthority(NormalizedAuthority authority, _ValidatedFacts facts) {
    if (_isIp(authority.host)) {
      return facts.hasSubjectAlternativeNames &&
          facts.ipSans.contains(authority.host);
    }
    if (facts.hasSubjectAlternativeNames) {
      return facts.dnsSans.any((san) => _matchesDns(authority.host, san));
    }
    return authority.host == facts.commonName;
  }

  static String _sanSummary(_ValidatedFacts facts) {
    final names = <String>[...facts.dnsSans, ...facts.ipSans];
    final concise = names.take(3).join(', ');
    return names.length > 3 ? 'SAN: $concise, …' : 'SAN: $concise';
  }

  static bool _matchesDns(String host, String san) {
    if (!san.startsWith('*.')) return host == san;
    final suffix = san.substring(2);
    if (!host.endsWith('.$suffix')) return false;
    return host.split('.').length == suffix.split('.').length + 1;
  }

  static bool _isIp(String host) =>
      host.contains(':') || RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host);

  static String? _canonicalDnsSan(String value) {
    if (value.startsWith('*.')) {
      final suffix = _canonicalDns(value.substring(2));
      // Without a Public Suffix List, only accept a wildcard below at least
      // three registrable-looking labels; this rejects broad suffix wildcards.
      if (suffix == null || suffix.split('.').length < 3) {
        return null;
      }
      return '*.$suffix';
    }
    return _canonicalDns(value);
  }

  static String? _canonicalCommonName(String value) =>
      _canonicalDns(value) ?? _canonicalIp(value);

  static String? _canonicalDns(String value) {
    if (value.isEmpty || value != value.trim() || value.contains('*')) {
      return null;
    }
    try {
      final host = NormalizedAuthority.parse('https://$value').host;
      return _isIp(host) ? null : host;
    } on AuthorityValidationException {
      return null;
    }
  }

  static String? _canonicalIp(String value) {
    if (value.isEmpty || value != value.trim()) return null;
    try {
      final uriHost = value.contains(':') ? '[$value]' : value;
      final host = NormalizedAuthority.parse('https://$uriHost').host;
      return _isIp(host) ? host : null;
    } on AuthorityValidationException {
      return null;
    }
  }

  static String? _safeSummary(String value) {
    if (value.isEmpty || value.length > 256 || value != value.trim()) {
      return null;
    }
    return value.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)
        ? null
        : value;
  }

  /// Checks only a canonical outer DER TLV envelope, not X.509 semantics.
  static bool _hasDerEnvelope(Uint8List der) {
    if (der.length < 3 || der.first != 0x30) return false;
    final lengthByte = der[1];
    if (lengthByte < 0x80) return der.length == lengthByte + 2;
    final lengthOctets = lengthByte & 0x7f;
    if (lengthOctets == 0 ||
        lengthOctets > 4 ||
        der.length < 2 + lengthOctets) {
      return false;
    }
    if (der[2] == 0 || (lengthOctets == 1 && der[2] < 0x80)) return false;
    var length = 0;
    for (var index = 0; index < lengthOctets; index++) {
      length = (length << 8) | der[2 + index];
    }
    return der.length == 2 + lengthOctets + length;
  }
}

final class _ValidatedFacts {
  const _ValidatedFacts({
    required this.commonName,
    required this.dnsSans,
    required this.ipSans,
    required this.hasSubjectAlternativeNames,
    required this.issuer,
    required this.notValidBefore,
    required this.notValidAfter,
  });

  final String? commonName;
  final List<String> dnsSans;
  final List<String> ipSans;
  final bool hasSubjectAlternativeNames;
  final String issuer;
  final DateTime notValidBefore;
  final DateTime notValidAfter;
}
