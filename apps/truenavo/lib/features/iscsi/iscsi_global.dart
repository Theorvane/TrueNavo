/// Public, bounded projection of iscsi.global.config and the iscsitarget
/// service row. Configuration is not proof that the service is running.
final class IscsiGlobalSummary {
  const IscsiGlobalSummary({
    required this.config,
    required this.service,
    required this.observedAt,
  });

  final IscsiGlobalConfig config;
  final IscsiServiceStatus? service;
  final DateTime observedAt;
}

final class IscsiGlobalConfig {
  const IscsiGlobalConfig({
    required this.basename,
    required this.isnsServers,
    required this.listenPort,
    required this.poolAvailThreshold,
    required this.alua,
    required this.iser,
  });

  final String basename;
  final List<String> isnsServers;
  final int? listenPort;
  final int? poolAvailThreshold;
  final bool alua;
  final bool iser;

  factory IscsiGlobalConfig.parse(Object? raw) {
    if (raw is! Map) throw const FormatException('Invalid iSCSI configuration');
    final basename = _label(raw['basename']);
    final servers = raw['isns_servers'];
    final port = raw['listen_port'];
    final threshold = raw['pool_avail_threshold'];
    final alua = raw['alua'];
    final iser = raw['iser'];
    if (basename == null ||
        servers is! List ||
        servers.length > 100 ||
        servers.any((server) => _label(server) == null) ||
        (port != null && (port is! int || port < 1025 || port > 65535)) ||
        (threshold != null &&
            (threshold is! int || threshold < 1 || threshold > 99)) ||
        alua is! bool ||
        iser is! bool) {
      throw const FormatException('Invalid iSCSI configuration');
    }
    return IscsiGlobalConfig(
      basename: basename,
      isnsServers: List.unmodifiable(servers.map((server) => _label(server)!)),
      listenPort: port as int?,
      poolAvailThreshold: threshold as int?,
      alua: alua,
      iser: iser,
    );
  }
}

final class IscsiServiceStatus {
  const IscsiServiceStatus({required this.enabledOnBoot, required this.state});

  final bool enabledOnBoot;
  final String state;

  static IscsiServiceStatus? parse(Object? raw) {
    if (raw is! List || raw.length != 1 || raw.single is! Map) return null;
    final row = raw.single as Map;
    final enabled = row['enable'];
    final state = row['state'];
    if (row['service'] != 'iscsitarget' ||
        enabled is! bool ||
        state is! String ||
        !RegExp(r'^[A-Z_]{3,30}$').hasMatch(state)) {
      return null;
    }
    return IscsiServiceStatus(enabledOnBoot: enabled, state: state);
  }
}

String? _label(Object? raw) {
  if (raw is! String) return null;
  final clean = raw.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  if (clean.isEmpty || clean.length > 200) return null;
  return clean;
}
