import 'package:truenas_api/truenas_api.dart';

/// A secure server authority normalized for an app-owned TLS pin.
///
/// Non-ASCII host names are rejected because this app does not include a
/// UTS-46 implementation. Callers must provide an ASCII IDNA (punycode) host.
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
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw const AuthorityValidationException(
        'Credentials, queries, and fragments are not allowed.',
      );
    }
    if (!_isAscii(uri.host) || uri.host.contains('%')) {
      throw const AuthorityValidationException(
        'Host names must use ASCII IDNA form.',
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

  static bool _isAscii(String value) =>
      value.codeUnits.every((unit) => unit <= 0x7f);

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
        !createdAt.endsWith('Z')) {
      throw const PinRecordFormatException(
        'The pin record values are invalid.',
      );
    }
    final parsedCreatedAt = DateTime.tryParse(createdAt);
    if (parsedCreatedAt == null) {
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
