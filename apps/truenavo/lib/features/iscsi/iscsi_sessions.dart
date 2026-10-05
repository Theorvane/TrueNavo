/// A bounded projection of iscsi.global.sessions. This is a point-in-time
/// observation, not a subscription or proof that a client remains connected.
final class IscsiSessionsSnapshot {
  const IscsiSessionsSnapshot(this.sessions, this.observedAt);
  final List<IscsiSession> sessions;
  final DateTime observedAt;

  factory IscsiSessionsSnapshot.parse(Object? raw, DateTime observedAt) {
    if (raw is! List || raw.length > 100 || raw.any((row) => row is! Map)) {
      throw const FormatException('Incomplete iSCSI sessions');
    }
    return IscsiSessionsSnapshot(
      List.unmodifiable([
        for (final row in raw) IscsiSession.parse(row as Map),
      ]),
      observedAt.toUtc(),
    );
  }
}

final class IscsiSession {
  const IscsiSession({
    required this.initiator,
    required this.initiatorAddress,
    required this.target,
    required this.iser,
    required this.offload,
  });
  final String initiator, initiatorAddress, target;
  final bool iser, offload;

  factory IscsiSession.parse(Map raw) {
    final initiator = _text(raw['initiator']);
    final address = _text(raw['initiator_addr']);
    final target = _text(raw['target']);
    final iser = raw['iser'];
    final offload = raw['offload'];
    if (initiator == null ||
        address == null ||
        target == null ||
        iser is! bool ||
        offload is! bool) {
      throw const FormatException('Invalid iSCSI session');
    }
    return IscsiSession(
      initiator: initiator,
      initiatorAddress: address,
      target: target,
      iser: iser,
      offload: offload,
    );
  }
}

String? _text(Object? raw) {
  if (raw is! String) return null;
  final clean = raw.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  if (clean.isEmpty) return null;
  return clean.length <= 180 ? clean : clean.substring(0, 180);
}
