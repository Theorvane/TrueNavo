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
    final hostLabels = host.split('.');
    final suffixLabels = suffix.split('.');
    // A supported wildcard consumes exactly one complete leftmost host label.
    return hostLabels.length == suffixLabels.length + 1;
  }

  static bool _isIp(String host) =>
      host.contains(':') || RegExp(r'^\d+\.\d+\.\d+\.\d+$').hasMatch(host);

  static String? _canonicalDnsSan(String value) {
    if (value.startsWith('*.')) {
      final suffix = _canonicalDns(value.substring(2));
      // This is a deliberately narrow syntax policy, not Public Suffix List
      // validation: a wildcard has a complete leftmost label and its normalized
      // suffix must contain at least two DNS labels.
      if (suffix == null || suffix.split('.').length < 2) {
        return null;
      }
      return '*.$suffix';
    }
    return _canonicalDns(value);
  }

  static String? _canonicalCommonName(String value) =>
      _canonicalDns(value) ?? _canonicalIp(value);

  static String? _canonicalDns(String value) {
    if (value.isEmpty ||
        value.length > 253 ||
        !value.codeUnits.every((unit) => unit <= 0x7f) ||
        RegExp(r'^[0-9.]+$').hasMatch(value)) {
      return null;
    }
    final labels = value.split('.');
    if (labels.any((label) => !_isValidDnsLabel(label))) return null;
    return value.toLowerCase();
  }

  static bool _isValidDnsLabel(String label) {
    if (label.isEmpty || label.length > 63) return false;
    if (!RegExp(r'^[a-zA-Z0-9-]+$').hasMatch(label) ||
        label.startsWith('-') ||
        label.endsWith('-')) {
      return false;
    }
    // A shape-only validator cannot establish that an ACE label is valid
    // Punycode, so preserve the app's existing fail-closed IDNA policy.
    return !label.toLowerCase().startsWith('xn--');
  }

  static String? _canonicalIp(String value) {
    if (value.isEmpty ||
        !value.codeUnits.every((unit) => unit <= 0x7f) ||
        value.contains(RegExp(r'[\[\]@/?#\\%\s]'))) {
      return null;
    }
    if (!value.contains(':')) {
      return _isValidIpv4(value) ? value : null;
    }
    return _canonicalizeIpv6(value);
  }

  static bool _isValidIpv4(String value) {
    final parts = value.split('.');
    return parts.length == 4 &&
        parts.every((part) {
          if (!RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part)) {
            return false;
          }
          return int.parse(part) <= 255;
        });
  }

  static String? _canonicalizeIpv6(String value) {
    final compressionIndex = value.indexOf('::');
    if (compressionIndex != value.lastIndexOf('::')) return null;
    final hasCompression = compressionIndex >= 0;
    final beforeCompression = hasCompression && compressionIndex > 0
        ? value.substring(0, compressionIndex).split(':')
        : const <String>[];
    final afterCompression =
        hasCompression && compressionIndex + 2 < value.length
        ? value.substring(compressionIndex + 2).split(':')
        : const <String>[];
    final parts = hasCompression
        ? <String>[...beforeCompression, ...afterCompression]
        : value.split(':');
    final groups = <int>[];
    for (var index = 0; index < parts.length; index++) {
      final part = parts[index];
      if (part.isEmpty) return null;
      if (part.contains('.')) {
        if (index != parts.length - 1 || !_isValidIpv4(part)) return null;
        final octets = part.split('.').map(int.parse).toList();
        groups
          ..add((octets[0] << 8) | octets[1])
          ..add((octets[2] << 8) | octets[3]);
      } else if (!RegExp(r'^[0-9a-fA-F]{1,4}$').hasMatch(part)) {
        return null;
      } else {
        groups.add(int.parse(part, radix: 16));
      }
    }
    if (hasCompression) {
      if (groups.length >= 8) return null;
      groups.insertAll(
        beforeCompression.length,
        List<int>.filled(8 - groups.length, 0),
      );
    } else if (groups.length != 8) {
      return null;
    }

    var zeroRunStart = -1;
    var zeroRunLength = 0;
    for (var index = 0; index < groups.length;) {
      if (groups[index] != 0) {
        index++;
        continue;
      }
      final start = index;
      while (index < groups.length && groups[index] == 0) {
        index++;
      }
      final length = index - start;
      if (length > zeroRunLength && length >= 2) {
        zeroRunStart = start;
        zeroRunLength = length;
      }
    }
    final textGroups = groups.map((group) => group.toRadixString(16)).toList();
    if (zeroRunStart < 0) return textGroups.join(':');
    final before = textGroups.take(zeroRunStart).join(':');
    final after = textGroups.skip(zeroRunStart + zeroRunLength).join(':');
    if (before.isEmpty) return '::$after';
    if (after.isEmpty) return '$before::';
    return '$before::$after';
  }

  static String? _safeSummary(String value) {
    if (value.isEmpty || value.length > 256 || value != value.trim()) {
      return null;
    }
    return _isSafeDisplayText(value) ? value : null;
  }

  /// Rejects controls that can alter a security prompt's appearance or order.
  ///
  /// This is intentionally a fail-closed display policy for untrusted issuer
  /// text. It permits normal Unicode letters but rejects C0, DEL, C1, surrogate,
  /// bidi, and Unicode format controls.
  static bool _isSafeDisplayText(String value) =>
      !value.runes.any(_isUnsafeDisplayCodePoint);

  static bool _isUnsafeDisplayCodePoint(int codePoint) {
    if (codePoint <= 0x1f ||
        (codePoint >= 0x7f && codePoint <= 0x9f) ||
        (codePoint >= 0xd800 && codePoint <= 0xdfff)) {
      return true;
    }

    // Unicode General_Category=Format ranges, including all bidi controls.
    return codePoint == 0x00ad ||
        (codePoint >= 0x0600 && codePoint <= 0x0605) ||
        codePoint == 0x061c ||
        codePoint == 0x06dd ||
        codePoint == 0x070f ||
        (codePoint >= 0x0890 && codePoint <= 0x0891) ||
        codePoint == 0x08e2 ||
        codePoint == 0x180e ||
        (codePoint >= 0x200b && codePoint <= 0x200f) ||
        (codePoint >= 0x202a && codePoint <= 0x202e) ||
        (codePoint >= 0x2060 && codePoint <= 0x206f) ||
        codePoint == 0xfeff ||
        (codePoint >= 0xfff9 && codePoint <= 0xfffb) ||
        codePoint == 0x110bd ||
        codePoint == 0x110cd ||
        (codePoint >= 0x13430 && codePoint <= 0x1343f) ||
        (codePoint >= 0x1bca0 && codePoint <= 0x1bca3) ||
        (codePoint >= 0x1d173 && codePoint <= 0x1d17a) ||
        codePoint == 0xe0001 ||
        (codePoint >= 0xe0020 && codePoint <= 0xe007f);
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
