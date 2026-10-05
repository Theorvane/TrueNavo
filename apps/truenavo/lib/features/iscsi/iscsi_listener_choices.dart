/// Bounded projection of the server's portal listener address choices.
///
/// The values can describe HA backing addresses, so only keys are retained.
final class IscsiListenerChoices {
  IscsiListenerChoices._(this.addresses, this.observedAt);

  final Set<String> addresses;
  final DateTime observedAt;

  factory IscsiListenerChoices.parse(Object? raw, {DateTime Function()? now}) {
    if (raw is! Map || raw.length > 100) {
      throw const FormatException('Incomplete iSCSI listener choices.');
    }
    final addresses = <String>{};
    for (final entry in raw.entries) {
      final address = entry.key;
      final description = entry.value;
      if (address is! String ||
          address.isEmpty ||
          address.length > 64 ||
          address.contains(RegExp(r'[\x00-\x20\x7f]')) ||
          description is! String ||
          description.length > 512) {
        throw const FormatException('Invalid iSCSI listener choice.');
      }
      addresses.add(address);
    }
    return IscsiListenerChoices._(
      Set.unmodifiable(addresses),
      (now ?? DateTime.now)().toUtc(),
    );
  }
}
