import 'package:truenas_api/truenas_api.dart';

/// A secure server authority normalized for an app-owned TLS pin.
///
/// Non-ASCII and ACE (`xn--`) host names are rejected because this app does not
/// include a standards-compliant UTS-46/IDNA validator. Callers may use plain
/// ASCII DNS names or IP literals in this slice.
final class NormalizedAuthority {
  NormalizedAuthority._({
    required this.scheme,
    required this.host,
    required this.port,
    required this.rpcConnectionUri,
  });

  /// Parses the same secure URL forms accepted by M0's [ValidatedEndpoint].
  factory NormalizedAuthority.parse(String input) {
    final trimmed = input.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) {
      throw const AuthorityValidationException('A secure host is required.');
    }
    if (uri.scheme != 'https' && uri.scheme != 'wss') {
      throw const AuthorityValidationException(
        'Only https and wss are supported.',
      );
    }
    if (uri.userInfo.isNotEmpty ||
        _hasExplicitUserInfoDelimiter(trimmed) ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const AuthorityValidationException(
        'Credentials, queries, and fragments are not allowed.',
      );
    }
    if (!_isValidHost(uri)) {
      throw const AuthorityValidationException(
        'The host is not a valid ASCII DNS name or IP address.',
      );
    }

    final int explicitPort;
    try {
      explicitPort = uri.port;
    } on FormatException {
      throw const AuthorityValidationException('The port is invalid.');
    }
    if (explicitPort != 0 && (explicitPort < 1 || explicitPort > 65535)) {
      throw const AuthorityValidationException('The port is invalid.');
    }
    if (_hasExplicitZeroPort(uri)) {
      throw const AuthorityValidationException('The port is invalid.');
    }

    final ValidatedEndpoint endpoint;
    try {
      endpoint = ValidatedEndpoint.parse(input);
    } on EndpointValidationException catch (error) {
      throw AuthorityValidationException(error.message);
    }
    return NormalizedAuthority._(
      scheme: uri.scheme,
      host: uri.host.toLowerCase(),
      port: explicitPort == 0 ? 443 : explicitPort,
      rpcConnectionUri: endpoint.connectionUri,
    );
  }

  final String scheme;
  final String host;
  final int port;

  /// The M0-derived WebSocket endpoint, including its RPC path.
  final Uri rpcConnectionUri;

  /// The stable storage key, deliberately excluding the RPC path.
  String get pinKey => '$scheme://${_pinKeyHost(host)}:$port';

  @override
  bool operator ==(Object other) =>
      other is NormalizedAuthority &&
      scheme == other.scheme &&
      host == other.host &&
      port == other.port;

  @override
  int get hashCode => Object.hash(scheme, host, port);

  static bool _hasExplicitUserInfoDelimiter(String input) {
    final schemeEnd = input.indexOf('://');
    if (schemeEnd < 0) return false;
    final authorityStart = schemeEnd + 3;
    var authorityEnd = input.length;
    for (final delimiter in const ['/', '?', '#']) {
      final index = input.indexOf(delimiter, authorityStart);
      if (index >= 0 && index < authorityEnd) authorityEnd = index;
    }
    return input.substring(authorityStart, authorityEnd).contains('@');
  }

  static bool _isAscii(String value) =>
      value.codeUnits.every((unit) => unit <= 0x7f);

  static bool _isValidHost(Uri uri) {
    final host = uri.host;
    if (!_isAscii(host) || host.contains('%')) {
      return false;
    }
    if (host.contains(':')) {
      return _isBracketedIpv6(uri) && _isValidIpv6(host);
    }
    if (host.contains(RegExp(r'^[0-9.]+$'))) {
      return _isValidIpv4(host);
    }
    return _isValidDnsName(host);
  }

  static bool _isBracketedIpv6(Uri uri) =>
      uri.authority.startsWith('[') && uri.authority.contains(']');

  static bool _isValidDnsName(String host) {
    if (host.length > 253) {
      return false;
    }
    return host.split('.').every(_isValidDnsLabel);
  }

  static bool _isValidDnsLabel(String label) {
    if (label.length > 63 || !_dnsLabelExpression.hasMatch(label)) {
      return false;
    }
    // A shape-only regex cannot prove that an ACE label is valid Punycode.
    // Reject every ACE label until a standards-compliant IDNA validator exists.
    return !label.toLowerCase().startsWith('xn--');
  }

  static bool _isValidIpv4(String host) {
    final parts = host.split('.');
    return parts.length == 4 &&
        parts.every((part) {
          if (!RegExp(r'^(0|[1-9][0-9]{0,2})$').hasMatch(part)) {
            return false;
          }
          return int.parse(part) <= 255;
        });
  }

  static bool _isValidIpv6(String host) {
    final compressionIndex = host.indexOf('::');
    if (compressionIndex != host.lastIndexOf('::')) {
      return false;
    }
    final hasCompression = compressionIndex >= 0;
    final parts = host.split(':');
    var groupCount = 0;
    for (var index = 0; index < parts.length; index++) {
      final part = parts[index];
      if (part.isEmpty) {
        continue;
      }
      if (part.contains('.')) {
        if (index != parts.length - 1 || !_isValidIpv4(part)) {
          return false;
        }
        groupCount += 2;
      } else if (!RegExp(r'^[0-9a-fA-F]{1,4}$').hasMatch(part)) {
        return false;
      } else {
        groupCount++;
      }
    }
    return hasCompression ? groupCount < 8 : groupCount == 8;
  }

  static final RegExp _dnsLabelExpression = RegExp(
    r'^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,61}[a-zA-Z0-9])?$',
  );

  static bool _hasExplicitZeroPort(Uri uri) {
    final authority = uri.authority;
    final closingBracket = authority.lastIndexOf(']');
    if (closingBracket < 0 && !authority.contains(':')) {
      return false;
    }
    final portPart = closingBracket >= 0
        ? authority.substring(closingBracket + 1)
        : authority.substring(authority.lastIndexOf(':'));
    return portPart == ':0';
  }

  static String _pinKeyHost(String value) =>
      value.contains(':') ? '[$value]' : value;
}

final class AuthorityValidationException implements Exception {
  const AuthorityValidationException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// The version-one persistent representation of a trusted leaf certificate.
final class PinRecord {
  PinRecord({required this.leafDerSha256, required DateTime createdAt})
    : createdAt = createdAt.toUtc() {
    if (!_digestExpression.hasMatch(leafDerSha256)) {
      throw const PinRecordFormatException(
        'A pin digest must be 64 uppercase hexadecimal characters.',
      );
    }
    if (!_canonicalUtcTimestampExpression.hasMatch(
      this.createdAt.toIso8601String(),
    )) {
      throw const PinRecordFormatException(
        'The pin creation time must use canonical UTC millisecond precision.',
      );
    }
  }

  factory PinRecord.fromJson(Object json) {
    if (json is! Map<Object?, Object?> ||
        json.length != _jsonFields.length ||
        !json.keys.every((key) => key is String && _jsonFields.contains(key))) {
      throw const PinRecordFormatException('The pin record shape is invalid.');
    }
    final version = json['version'];
    final digest = json['leafDerSha256'];
    final format = json['fingerprintFormat'];
    final createdAt = json['createdAt'];
    if (version != 1 ||
        digest is! String ||
        format != fingerprintFormatValue ||
        createdAt is! String ||
        !_canonicalUtcTimestampExpression.hasMatch(createdAt)) {
      throw const PinRecordFormatException(
        'The pin record values are invalid.',
      );
    }
    final parsedCreatedAt = DateTime.tryParse(createdAt);
    if (parsedCreatedAt == null ||
        parsedCreatedAt.toUtc().toIso8601String() != createdAt) {
      throw const PinRecordFormatException('The pin creation time is invalid.');
    }
    return PinRecord(leafDerSha256: digest, createdAt: parsedCreatedAt);
  }

  static const int currentVersion = 1;
  static const String fingerprintFormatValue = 'SHA-256/DER';
  static const Set<String> _jsonFields = {
    'version',
    'leafDerSha256',
    'fingerprintFormat',
    'createdAt',
  };
  static final RegExp _digestExpression = RegExp(r'^[0-9A-F]{64}$');
  static final RegExp _canonicalUtcTimestampExpression = RegExp(
    r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$',
  );

  int get version => currentVersion;
  final String leafDerSha256;
  String get fingerprintFormat => fingerprintFormatValue;
  final DateTime createdAt;

  String get groupedFingerprint => leafDerSha256
      .replaceAllMapped(RegExp(r'.{4}'), (match) => '${match.group(0)} ')
      .trimRight();

  Map<String, Object> toJson() => <String, Object>{
    'version': version,
    'leafDerSha256': leafDerSha256,
    'fingerprintFormat': fingerprintFormat,
    'createdAt': createdAt.toIso8601String(),
  };

  @override
  bool operator ==(Object other) =>
      other is PinRecord &&
      leafDerSha256 == other.leafDerSha256 &&
      createdAt == other.createdAt;

  @override
  int get hashCode => Object.hash(leafDerSha256, createdAt);
}

final class PinRecordFormatException implements Exception {
  const PinRecordFormatException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Display-safe certificate metadata; it never retains raw certificate DER.
final class CertificateFacts {
  CertificateFacts({
    required this.subjectSummary,
    required this.issuerSummary,
    required this.leafDerSha256,
    required this.notValidBefore,
    required this.notValidAfter,
  }) {
    if (!PinRecord._digestExpression.hasMatch(leafDerSha256)) {
      throw const PinRecordFormatException(
        'A certificate digest must be 64 uppercase hexadecimal characters.',
      );
    }
  }

  final String subjectSummary;
  final String issuerSummary;
  final String leafDerSha256;
  final DateTime notValidBefore;
  final DateTime notValidAfter;
}

/// Non-secret, typed reasons a TLS trust operation cannot continue.
enum CertificateTrustFailure {
  malformedAuthority,
  malformedCertificate,
  hostnameMismatch,
  expiredCertificate,
  notYetValidCertificate,
  pinMismatch,
  probeTimedOut,
  cancelled,
  pinStoreFailure,
  pinnedReconnectFailed,
  browserManagedTls,
}
