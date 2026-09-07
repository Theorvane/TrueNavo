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
  final canonicalUri = _canonicalCredentialUri(uri);
  final digest = sha256.convert(
    utf8.encode('$_storageKeyPrefix\u0000${canonicalUri.toString()}'),
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
    !uri.host.endsWith('..') &&
    uri.userInfo.isEmpty &&
    !uri.hasQuery &&
    !uri.hasFragment &&
    uri.path.isNotEmpty;

Uri _canonicalCredentialUri(Uri uri) {
  final host = _canonicalCredentialHost(uri.host);
  if (host.isEmpty) throw const CredentialStorageKeyFailure();
  // This URI exists only to form the vault-key identity. In particular, do not
  // pass it to TLS or the connector: endpoint.connectionUri retains the exact
  // validated transport URI selected by ValidatedEndpoint.
  return Uri(
    scheme: uri.scheme,
    host: host,
    port: uri.port == 443 ? null : uri.port,
    path: uri.path,
  );
}

String _canonicalCredentialHost(String host) {
  final dnsHost = host.endsWith('.')
      ? host.substring(0, host.length - 1)
      : host;
  if (!dnsHost.contains(':')) return dnsHost;
  return _canonicalIpv6Address(dnsHost);
}

/// Formats a valid IPv6 address according to the stable RFC 5952 form.
///
/// This intentionally has no platform dependency so vault-key identity stays
/// deterministic on native and web builds.
String _canonicalIpv6Address(String address) {
  if (address.contains('%') || address.split('::').length > 2) {
    throw const CredentialStorageKeyFailure();
  }

  final halves = address.split('::');
  final left = _parseIpv6Groups(halves.first);
  final right = halves.length == 2 ? _parseIpv6Groups(halves.last) : <int>[];
  final missingGroups = 8 - left.length - right.length;
  if ((halves.length == 1 && missingGroups != 0) ||
      (halves.length == 2 && missingGroups < 1)) {
    throw const CredentialStorageKeyFailure();
  }
  final groups = <int>[
    ...left,
    ...List<int>.filled(missingGroups, 0),
    ...right,
  ];
  if (groups.length != 8) throw const CredentialStorageKeyFailure();

  var bestStart = -1;
  var bestLength = 0;
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
    if (length > bestLength && length > 1) {
      bestStart = start;
      bestLength = length;
    }
  }

  final before = groups
      .sublist(0, bestStart < 0 ? groups.length : bestStart)
      .map((group) => group.toRadixString(16))
      .join(':');
  if (bestStart < 0) return before;
  final after = groups
      .sublist(bestStart + bestLength)
      .map((group) => group.toRadixString(16))
      .join(':');
  if (before.isEmpty) return after.isEmpty ? '::' : '::$after';
  return after.isEmpty ? '$before::' : '$before::$after';
}

List<int> _parseIpv6Groups(String half) {
  if (half.isEmpty) return <int>[];
  return half
      .split(':')
      .map((group) {
        if (!RegExp(r'^[0-9A-Fa-f]{1,4}$').hasMatch(group)) {
          throw const CredentialStorageKeyFailure();
        }
        return int.parse(group, radix: 16);
      })
      .toList(growable: false);
}

/// Deliberately credential-free validation failure.
final class CredentialStorageKeyFailure implements Exception {
  const CredentialStorageKeyFailure();

  @override
  String toString() => 'The server identifier cannot be used for credentials.';
}
