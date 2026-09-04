/// A user-entered server location after M0's strict secure-URL validation.
final class ValidatedEndpoint {
  ValidatedEndpoint._(this.originalInput, this.connectionUri);

  final String originalInput;
  final Uri connectionUri;

  static ValidatedEndpoint parse(String input) {
    final trimmed = input.trim();
    final uri = Uri.tryParse(trimmed);
    if (uri == null || uri.host.isEmpty) {
      throw const EndpointValidationException(
        'Enter a secure server URL with a host.',
      );
    }
    if (uri.scheme != 'https' && uri.scheme != 'wss') {
      throw const EndpointValidationException(
        'Only https:// or wss:// server URLs are supported.',
      );
    }
    if (uri.userInfo.isNotEmpty || uri.hasQuery || uri.hasFragment) {
      throw const EndpointValidationException(
        'Server URLs cannot include credentials, queries, or fragments.',
      );
    }
    try {
      uri.port;
    } on FormatException {
      throw const EndpointValidationException(
        'The server URL has an invalid port.',
      );
    }
    final path = uri.path.isEmpty || uri.path == '/'
        ? '/api/current'
        : uri.path;
    return ValidatedEndpoint._(
      input,
      uri.replace(scheme: 'wss', path: path, query: null, fragment: null),
    );
  }
}

final class EndpointValidationException implements Exception {
  const EndpointValidationException(this.message);
  final String message;
  @override
  String toString() => message;
}
