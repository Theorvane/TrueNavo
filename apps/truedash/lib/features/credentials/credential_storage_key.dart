import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:truenas_api/truenas_api.dart';

const _storageKeyPrefix = 'com.truedash.api-key.v1';
const _maximumEndpointLength = 2048;

/// Produces an opaque, versioned storage identifier for one validated server.
String credentialStorageKey(String endpointInput) {
  if (!_isSafeEndpointInput(endpointInput)) {
    throw const CredentialStorageKeyFailure();
  }

  final ValidatedEndpoint endpoint;
  try {
    endpoint = ValidatedEndpoint.parse(endpointInput);
  } on Object {
    throw const CredentialStorageKeyFailure();
  }
  final uri = endpoint.connectionUri;
  if (!_isCanonicalEndpointIdentity(uri)) {
    throw const CredentialStorageKeyFailure();
  }
  final digest = sha256.convert(
    utf8.encode('$_storageKeyPrefix\u0000${uri.toString()}'),
  );
  return '$_storageKeyPrefix.$digest';
}

bool _isSafeEndpointInput(String input) {
  if (input.isEmpty ||
      input.length > _maximumEndpointLength ||
      input != input.trim()) {
    return false;
  }
  if (input.codeUnits.any((unit) => unit < 0x20 || unit == 0x7f)) return false;
  if (RegExp(r'%(?![0-9A-Fa-f]{2})').hasMatch(input)) return false;
  // Uri parsing normalizes dot segments. Reject them in the original spelling
  // so a noncanonical identifier can never alias a different endpoint key.
  if (RegExp(r'(^|/)(?:(?:\.)|(?:%2[eE])){1,2}(?:/|$)').hasMatch(input)) {
    return false;
  }
  final uri = Uri.tryParse(input);
  if (uri == null) return false;
  return true;
}

bool _isCanonicalEndpointIdentity(Uri uri) =>
    uri.scheme == 'wss' &&
    uri.host.isNotEmpty &&
    uri.userInfo.isEmpty &&
    !uri.hasQuery &&
    !uri.hasFragment &&
    uri.path.isNotEmpty;

/// Deliberately credential-free validation failure.
final class CredentialStorageKeyFailure implements Exception {
  const CredentialStorageKeyFailure();

  @override
  String toString() => 'The server identifier cannot be used for credentials.';
}
