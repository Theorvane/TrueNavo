part of 'true_nas_session_repository.dart';

/// Dedicated public-field NVMe host read. Generic host.query remains blocked
/// because its unrestricted result can include DH-CHAP secrets.
abstract interface class AuthenticatedNvmeHostSession {
  Future<NvmeHostPublicRows> loadNvmeHostReferences();
}

/// Dedicated write path: only IDs leave the SDK even when middleware embeds
/// DH-CHAP key fields in the created association response.
abstract interface class AuthenticatedNvmeHostAccessSession {
  Future<NvmeHostAssociationCreated> createNvmeHostAssociation({
    required int hostId,
    required int subsystemId,
  });
}

/// Dedicated port association write. Embedded port/subsystem response fields
/// are reduced to their IDs before crossing into the application.
abstract interface class AuthenticatedNvmePortAccessSession {
  Future<NvmePortAssociationCreated> createNvmePortAssociation({
    required int portId,
    required int subsystemId,
  });
}

final class NvmePortAssociationCreated {
  const NvmePortAssociationCreated(this.id, this.portId, this.subsystemId);
  final int id, portId, subsystemId;

  factory NvmePortAssociationCreated.project(Object? raw) {
    if (raw is! Map ||
        raw['id'] is! int ||
        (raw['id'] as int) <= 0 ||
        raw['port'] is! Map ||
        (raw['port'] as Map)['id'] is! int ||
        ((raw['port'] as Map)['id'] as int) <= 0 ||
        raw['subsys'] is! Map ||
        (raw['subsys'] as Map)['id'] is! int ||
        ((raw['subsys'] as Map)['id'] as int) <= 0) {
      throw const FormatException('Invalid NVMe port association result');
    }
    return NvmePortAssociationCreated(
      raw['id'] as int,
      (raw['port'] as Map)['id'] as int,
      (raw['subsys'] as Map)['id'] as int,
    );
  }
}

final class NvmeHostAssociationCreated {
  const NvmeHostAssociationCreated(this.id, this.hostId, this.subsystemId);
  final int id, hostId, subsystemId;

  factory NvmeHostAssociationCreated.project(Object? raw) {
    if (raw is! Map ||
        raw['id'] is! int ||
        (raw['id'] as int) <= 0 ||
        raw['host'] is! Map ||
        (raw['host'] as Map)['id'] is! int ||
        ((raw['host'] as Map)['id'] as int) <= 0 ||
        raw['subsys'] is! Map ||
        (raw['subsys'] as Map)['id'] is! int ||
        ((raw['subsys'] as Map)['id'] as int) <= 0) {
      throw const FormatException('Invalid NVMe host association result');
    }
    return NvmeHostAssociationCreated(
      raw['id'] as int,
      (raw['host'] as Map)['id'] as int,
      (raw['subsys'] as Map)['id'] as int,
    );
  }
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
