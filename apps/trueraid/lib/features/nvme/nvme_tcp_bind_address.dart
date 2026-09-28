/// Pure literal parsing: no DNS resolution, sockets or platform dependency.
/// Creation is deliberately limited to explicit IPv4 or global/ULA IPv6.
final class NvmeTcpBindAddress {
  const NvmeTcpBindAddress._(this.identity, this.creatable, this.wildcard);
  final String identity;
  final bool creatable, wildcard;

  static NvmeTcpBindAddress? parse(String input) {
    if (input.isEmpty) {
      return const NvmeTcpBindAddress._('wildcard', false, true);
    }
    if (input.length > 45 ||
        input.trim() != input ||
        input.contains(RegExp(r'[\x00-\x20\x7f%\[\]]'))) {
      return null;
    }
    if (!input.contains(':')) {
      final octets = _ipv4(input);
      if (octets == null) return null;
      return NvmeTcpBindAddress._(
        'v4:${octets.join('.')}',
        octets.first >= 1 && octets.first <= 223,
        octets.every((b) => b == 0),
      );
    }
    var literal = input;
    if (literal.contains('.')) {
      final index = literal.lastIndexOf(':');
      final octets = _ipv4(literal.substring(index + 1));
      if (octets == null) return null;
      literal =
          '${literal.substring(0, index + 1)}${((octets[0] << 8) | octets[1]).toRadixString(16)}:${((octets[2] << 8) | octets[3]).toRadixString(16)}';
    }
    final halves = literal.split('::');
    if (halves.length > 2) return null;
    List<int>? half(String value) {
      if (value.isEmpty) return <int>[];
      final fields = value.split(':');
      if (fields.any((v) => !RegExp(r'^[0-9a-fA-F]{1,4}$').hasMatch(v))) {
        return null;
      }
      return fields.map((v) => int.parse(v, radix: 16)).toList();
    }

    final left = half(halves.first),
        right = halves.length == 2 ? half(halves.last) : <int>[];
    if (left == null || right == null) return null;
    final missing = 8 - left.length - right.length;
    if ((halves.length == 1 && missing != 0) ||
        (halves.length == 2 && missing < 1)) {
      return null;
    }
    final groups = [...left, ...List<int>.filled(missing, 0), ...right];
    if (groups.take(5).every((v) => v == 0) && groups[5] == 0xffff) {
      final v4 =
          '${groups[6] >> 8}.${groups[6] & 255}.${groups[7] >> 8}.${groups[7] & 255}';
      // Existing IPv4-mapped spellings must collide with equivalent IPv4.
      // Mapped addresses themselves are never offered for creation.
      return NvmeTcpBindAddress._(
        'v4:$v4',
        false,
        groups[6] == 0 && groups[7] == 0,
      );
    }
    final global = (groups.first & 0xe000) == 0x2000;
    final ula = (groups.first & 0xfe00) == 0xfc00;
    return NvmeTcpBindAddress._(
      'v6:${groups.map((g) => g.toRadixString(16)).join(':')}',
      (global || ula) && !input.contains('.'),
      groups.every((g) => g == 0),
    );
  }

  static List<int>? _ipv4(String input) {
    if (!RegExp(r'^(0|[1-9][0-9]{0,2})(\.(0|[1-9][0-9]{0,2})){3}$')
        .hasMatch(input)) {
      return null;
    }
    final octets = input.split('.').map(int.parse).toList();
    return octets.every((v) => v <= 255) ? octets : null;
  }

  static bool equivalent(String first, String second) {
    final a = parse(first), b = parse(second);
    return a != null && b != null && a.identity == b.identity;
  }
}
