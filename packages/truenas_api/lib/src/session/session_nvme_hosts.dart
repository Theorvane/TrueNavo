part of 'true_nas_session_repository.dart';

/// Dedicated public-field NVMe host read. Generic host.query remains blocked
/// because its unrestricted result can include DH-CHAP secrets.
abstract interface class AuthenticatedNvmeHostSession {
  Future<NvmeHostPublicRows> loadNvmeHostReferences();
}

/// On-demand read: key values are reduced to returned presence flags inside
/// the SDK. Flags do not attest usable credentials or runtime authentication.
abstract interface class AuthenticatedNvmeHostAuthenticationSession {
  Future<NvmeHostAuthenticationInventory> loadNvmeHostAuthentication();
}

/// Public algorithm discovery only; never reads hosts or generates keys.
abstract interface class AuthenticatedNvmeHostChoicesSession {
  Future<NvmeHostAuthenticationChoices> loadNvmeHostAuthenticationChoices();
}

final class NvmeHostAuthenticationChoices {
  NvmeHostAuthenticationChoices._(this.hashes, this.groups);
  final List<String> hashes, groups;

  factory NvmeHostAuthenticationChoices.project(
    Object? hashes,
    Object? groups,
  ) {
    List<String> choices(Object? raw, Set<String> allowed) {
      if (raw is! List || raw.length > allowed.length) {
        throw const FormatException('Invalid NVMe authentication choices');
      }
      final seen = <String>{};
      for (final item in raw) {
        if (item is! String || !allowed.contains(item) || !seen.add(item)) {
          throw const FormatException('Invalid NVMe authentication choices');
        }
      }
      // Preserve the advertised subset and order; never invent defaults.
      return List<String>.unmodifiable(seen);
    }

    return NvmeHostAuthenticationChoices._(
      choices(hashes, const {'SHA-256', 'SHA-384', 'SHA-512'}),
      choices(groups, const {
        '2048-BIT',
        '3072-BIT',
        '4096-BIT',
        '6144-BIT',
        '8192-BIT',
      }),
    );
  }
}

final class NvmeHostChoicesException implements Exception {
  const NvmeHostChoicesException();
  String get userMessage =>
      'NVMe authentication algorithm choices are unavailable for this connection.';
  @override
  String toString() => userMessage;
}

final class NvmeHostAuthentication {
  const NvmeHostAuthentication({
    required this.id,
    required this.nqn,
    required this.hostKeyReturned,
    required this.controllerKeyReturned,
    required this.group,
    required this.hash,
  });
  final int id;
  final String nqn, hash;
  final String? group;
  final bool hostKeyReturned, controllerKeyReturned;
  bool get inconsistent =>
      !hostKeyReturned && (controllerKeyReturned || group != null);
}

final class NvmeHostAuthenticationInventory {
  NvmeHostAuthenticationInventory._(List<NvmeHostAuthentication> hosts)
    : hosts = List.unmodifiable(hosts);
  final List<NvmeHostAuthentication> hosts;

  factory NvmeHostAuthenticationInventory.project(Object? raw) {
    final public = NvmeHostPublicRows.project(raw, const <Object?>[]);
    final ids = <int>{};
    final rows = <NvmeHostAuthentication>[];
    for (var i = 0; i < public.hosts.length; i++) {
      final row = (raw as List)[i] as Map;
      final identity = public.hosts[i];
      final id = identity['id'] as int;
      final hash = row['dhchap_hash'];
      final group = row['dhchap_dhgroup'];
      if (!ids.add(id) ||
          !row.containsKey('dhchap_dhgroup') ||
          !const {'SHA-256', 'SHA-384', 'SHA-512'}.contains(hash) ||
          (group != null &&
              !const {
                '2048-BIT',
                '3072-BIT',
                '4096-BIT',
                '6144-BIT',
                '8192-BIT',
              }.contains(group))) {
        throw const FormatException('Invalid NVMe authentication metadata');
      }
      bool presence(String key) {
        if (!row.containsKey(key)) {
          throw const FormatException('Unknown NVMe authentication metadata');
        }
        final value = row[key];
        if (value == null) return false;
        if (value is! String ||
            value.isEmpty ||
            value.length > 512 ||
            value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
          throw const FormatException('Invalid NVMe authentication metadata');
        }
        return true;
      }

      rows.add(
        NvmeHostAuthentication(
          id: id,
          nqn: identity['hostnqn'] as String,
          hostKeyReturned: presence('dhchap_key'),
          controllerKeyReturned: presence('dhchap_ctrl_key'),
          group: group as String?,
          hash: hash as String,
        ),
      );
    }
    return NvmeHostAuthenticationInventory._(rows);
  }
}

/// Explicitly unauthenticated, unassociated identity creation. Secret-bearing
/// middleware responses are validated and reduced before leaving the SDK.
abstract interface class AuthenticatedNvmeHostCreateSession {
  Future<NvmeHostCreated> createUnassociatedNvmeHost({required String hostNqn});
}

/// Narrow NQN editing for uncredentialed hosts. Key-bearing reads/results
/// stay inside the SDK; no credential field is ever sent in the update.
abstract interface class AuthenticatedNvmeHostRenameSession {
  Future<NvmeUncredentialedHost> loadUncredentialedNvmeHost(int id);
  Future<NvmeUncredentialedHost> renameUncredentialedNvmeHost({
    required int id,
    required String expectedNqn,
    required String expectedHash,
    required String newNqn,
  });
}

/// Hash-only editing; nullable key/group fields must be returned unset.
abstract interface class AuthenticatedNvmeHostHashSession {
  Future<NvmeUncredentialedHost> loadUncredentialedNvmeHost(int id);
  Future<NvmeUncredentialedHost> changeUncredentialedNvmeHostHash({
    required int id,
    required String expectedNqn,
    required String expectedHash,
    required String newHash,
  });
}

final class NvmeUncredentialedHost {
  const NvmeUncredentialedHost(this.id, this.nqn, this.hash);
  final int id;
  final String nqn, hash;

  factory NvmeUncredentialedHost.project(Object? raw) {
    final public = NvmeHostCreated.project(raw);
    final hash = (raw as Map)['dhchap_hash'];
    if (!const {'SHA-256', 'SHA-384', 'SHA-512'}.contains(hash)) {
      throw const FormatException('Invalid uncredentialed NVMe host metadata');
    }
    return NvmeUncredentialedHost(public.id, public.nqn, hash as String);
  }
}

/// Conservative printable ASCII input, preserving the exact initiator NQN.
/// This is not complete NQN validation; the server remains authoritative.
bool isSupportedNvmeHostNqn(String value) =>
    value.length >= 11 &&
    value.length <= 223 &&
    value.startsWith('nqn.') &&
    RegExp(r'^[\x21-\x7e]+$').hasMatch(value);

final class NvmeHostCreated {
  const NvmeHostCreated(this.id, this.nqn);
  final int id;
  final String nqn;

  factory NvmeHostCreated.project(Object? raw) {
    if (raw is! Map ||
        raw['id'] is! int ||
        (raw['id'] as int) <= 0 ||
        raw['hostnqn'] is! String ||
        !isSupportedNvmeHostNqn(raw['hostnqn'] as String) ||
        ![
          'dhchap_key',
          'dhchap_ctrl_key',
          'dhchap_dhgroup',
        ].every((key) => raw.containsKey(key) && raw[key] == null)) {
      throw const FormatException('Invalid unassociated NVMe host result');
    }
    return NvmeHostCreated(raw['id'] as int, raw['hostnqn'] as String);
  }
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
