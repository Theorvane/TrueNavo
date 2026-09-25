part of 'true_nas_session_repository.dart';

/// Dedicated read path. The generic administration method remains blocked
/// because its unfiltered result can contain CHAP and mutual-CHAP secrets.
abstract interface class AuthenticatedIscsiAuthSession {
  Future<IscsiAuthInventory> loadIscsiAuthReferences();
}

final class IscsiAuthInventory {
  IscsiAuthInventory(List<IscsiAuthReference> references, this.observedAt)
    : references = List.unmodifiable(references);

  final List<IscsiAuthReference> references;
  final DateTime observedAt;

  factory IscsiAuthInventory.parse(Object? raw, DateTime observedAt) {
    if (raw is! List || raw.length > 100 || raw.any((row) => row is! Map)) {
      throw const FormatException('Incomplete iSCSI authentication inventory');
    }
    final references = <IscsiAuthReference>[];
    final ids = <int>{};
    for (final row in raw) {
      final reference = IscsiAuthReference.parse(row as Map);
      if (!ids.add(reference.id)) {
        throw const FormatException('Duplicate iSCSI authentication identity');
      }
      references.add(reference);
    }
    return IscsiAuthInventory(references, observedAt.toUtc());
  }
}

final class IscsiAuthReference {
  const IscsiAuthReference({
    required this.id,
    required this.tag,
    required this.user,
    required this.peerUser,
    required this.discoveryAuth,
  });

  final int id, tag;
  final String user, peerUser, discoveryAuth;

  factory IscsiAuthReference.parse(Map raw) {
    final id = raw['id'];
    final tag = raw['tag'];
    final user = _iscsiAuthLabel(raw['user']);
    final rawPeer = raw['peeruser'];
    final peerUser = rawPeer == null || rawPeer == ''
        ? ''
        : _iscsiAuthLabel(rawPeer);
    final discoveryAuth = raw['discovery_auth'] ?? 'NONE';
    if (id is! int ||
        id <= 0 ||
        tag is! int ||
        tag <= 0 ||
        user == null ||
        peerUser == null ||
        !const {'NONE', 'CHAP', 'CHAP_MUTUAL'}.contains(discoveryAuth)) {
      throw const FormatException('Invalid iSCSI authentication record');
    }
    return IscsiAuthReference(
      id: id,
      tag: tag,
      user: user,
      peerUser: peerUser,
      discoveryAuth: discoveryAuth as String,
    );
  }
}

String? _iscsiAuthLabel(Object? raw) {
  if (raw is! String) return null;
  final clean = raw.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  if (clean.isEmpty || clean.length > 120) return null;
  return clean;
}

final class IscsiAuthException implements Exception {
  const IscsiAuthException();

  String get userMessage =>
      'iSCSI authentication references are unavailable for this connection.';
}
