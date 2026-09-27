part of 'true_nas_session_repository.dart';

/// Dedicated public-field NVMe host read. Generic host.query remains blocked
/// because its unrestricted result can include DH-CHAP secrets.
abstract interface class AuthenticatedNvmeHostSession {
  Future<NvmeHostPublicRows> loadNvmeHostReferences();
}

final class NvmeHostPublicRows {
  NvmeHostPublicRows._(this.hosts, this.mappings);

  final List<Map<String, Object?>> hosts;
  final List<Map<String, Object?>> mappings;

  factory NvmeHostPublicRows.project(Object? rawHosts, Object? rawMappings) {
    if (rawHosts is! List ||
        rawMappings is! List ||
        rawHosts.length > 100 ||
        rawMappings.length > 100 ||
        rawHosts.any((row) => row is! Map) ||
        rawMappings.any((row) => row is! Map)) {
      throw const FormatException('Incomplete NVMe host inventory');
    }
    final hosts = <Map<String, Object?>>[];
    for (final item in rawHosts) {
      final row = item as Map;
      final id = row['id'];
      final nqn = row['hostnqn'];
      if (id is! int ||
          id <= 0 ||
          nqn is! String ||
          nqn.isEmpty ||
          nqn.length > 512 ||
          nqn.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
        throw const FormatException('Invalid NVMe host');
      }
      hosts.add(Map.unmodifiable({'id': id, 'hostnqn': nqn}));
    }
    final mappings = <Map<String, Object?>>[];
    for (final item in rawMappings) {
      final row = item as Map;
      final id = row['id'];
      final host = row['host'];
      final subsys = row['subsys'];
      final hostId = host is Map ? host['id'] : null;
      final subsystemId = subsys is Map ? subsys['id'] : null;
      if (id is! int ||
          id <= 0 ||
          hostId is! int ||
          hostId <= 0 ||
          subsystemId is! int ||
          subsystemId <= 0) {
        throw const FormatException('Invalid NVMe host association');
      }
      mappings.add(
        Map.unmodifiable({
          'id': id,
          'host': Map.unmodifiable({'id': hostId}),
          'subsys': Map.unmodifiable({'id': subsystemId}),
        }),
      );
    }
    return NvmeHostPublicRows._(
      List.unmodifiable(hosts),
      List.unmodifiable(mappings),
    );
  }
}

final class NvmeHostException implements Exception {
  const NvmeHostException();

  String get userMessage =>
      'NVMe-oF host references are unavailable for this connection.';
}
