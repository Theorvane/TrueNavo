part of 'true_nas_session_repository.dart';

/// Explicit protected secret generation, never a generic read or host update.
abstract interface class AuthenticatedNvmeHostKeyGenerationSession {
  Future<NvmeGeneratedHostKey> generateNvmeHostKey({
    required String hash,
    String? nqn,
  });
}

final class NvmeHostKeyGenerationException implements Exception {
  const NvmeHostKeyGenerationException();
  @override
  String toString() =>
      'Protected NVMe key generation or transfer is unavailable.';
}

/// Caller-owned, connection-bound single-use transfer envelope. No serializer
/// or raw getter. Managed strings and transport copies cannot be zeroized.
final class NvmeGeneratedHostKey {
  NvmeGeneratedHostKey._(this.hash, this.nqn, this._bytes, this._isValid);
  final String hash;
  final String? nqn;
  Uint8List? _bytes;
  final bool Function() _isValid;
  bool get isDisposed => _bytes == null;

  /// Intentionally exposes a secret only for a protected initiator transfer.
  /// The caller must not log, persist or display it in an unprotected viewer.
  String takeForTransfer({required bool acknowledgeSecretExposure}) {
    if (_bytes == null) throw const NvmeHostKeyGenerationException();
    if (!_isValid()) {
      dispose();
      throw const NvmeHostKeyGenerationException();
    }
    if (!acknowledgeSecretExposure) {
      throw const NvmeHostKeyGenerationException();
    }
    try {
      return ascii.decode(_bytes!);
    } finally {
      dispose();
    }
  }

  void dispose() {
    _bytes?.fillRange(0, _bytes!.length, 0);
    _bytes = null;
  }

  @override
  String toString() => 'NvmeGeneratedHostKey(redacted)';
}

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

/// Unassociated-host orchestration belongs to the app; this SDK path privately
/// projects key values and submits only explicit key/group nulls.
abstract interface class AuthenticatedNvmeHostAuthenticationClearSession {
  Future<NvmeHostAuthentication> loadNvmeHostAuthenticationTarget(int id);
  Future<NvmeHostAuthentication> clearNvmeHostAuthentication({
    required NvmeHostAuthentication expected,
  });
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
  bool get hasReturnedAuthentication =>
      hostKeyReturned || controllerKeyReturned || group != null;

  /// Public metadata comparison only: cannot detect rotations with unchanged
  /// presence flags, or attest actual key absence under redaction.
  bool sameReturnedSettings(NvmeHostAuthentication other) =>
      id == other.id &&
      nqn == other.nqn &&
      hash == other.hash &&
      group == other.group &&
      hostKeyReturned == other.hostKeyReturned &&
      controllerKeyReturned == other.controllerKeyReturned;
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

/// Protected imported-key registration. Native callers supply endpoint-bound
/// consent, complete public topology checks and conservative uncertainty fencing.
abstract interface class AuthenticatedNvmeHostKeyCreateSession {
  Future<NvmeHostAuthentication> createNvmeHostWithImportedKeys({
    required String hostNqn,
    required String hash,
    required String? group,
    required NvmeHostKeyDraft keys,
  });
}

/// Protected credential replacement. Native callers supply credential-loss
/// consent, complete public topology checks and conservative uncertainty fencing.
abstract interface class AuthenticatedNvmeHostKeyReplaceSession {
  Future<NvmeHostKeyReplacementReview> reviewNvmeHostKeyReplacement(int id);
  Future<NvmeHostAuthentication> replaceNvmeHostImportedKeys({
    required NvmeHostKeyReplacementReview review,
    required String hash,
    required String? group,
    required NvmeHostKeyDraft keys,
  });
}

/// Opaque, connection-bound, single-use proof of returned credential fields.
/// No old key value or fingerprint getter/serializer is exposed. Redaction
/// can hide changes; this does not prove actual credential state or inactivity.
final class NvmeHostKeyReplacementReview {
  NvmeHostKeyReplacementReview._(
    this.target,
    this.issuedAt,
    this._owner,
    this._references,
    this._salt,
    this._digest,
  );
  final NvmeHostAuthentication target;
  final DateTime issuedAt;
  final Object _owner;
  final String _references;
  Uint8List? _salt, _digest;
  bool _claimed = false;
  bool get isDisposed => _salt == null;
  void _claim() {
    if (_claimed || isDisposed) throw const NvmeHostException();
    _claimed = true;
  }

  void dispose() {
    _salt?.fillRange(0, _salt!.length, 0);
    _digest?.fillRange(0, _digest!.length, 0);
    _salt = null;
    _digest = null;
  }

  @override
  String toString() => 'NvmeHostKeyReplacementReview(redacted)';
}

Uint8List _nvmeCredentialProof(Object? raw, Uint8List salt) {
  final target = NvmeHostAuthenticationInventory.project([raw]).hosts.single;
  final row = raw as Map;
  final bytes = utf8.encode(
    jsonEncode([
      target.id,
      target.nqn,
      target.hash,
      target.group,
      row['dhchap_key'],
      row['dhchap_ctrl_key'],
    ]),
  );
  try {
    return Uint8List.fromList(
      crypto.Hmac(crypto.sha256, salt).convert(bytes).bytes,
    );
  } finally {
    bytes.fillRange(0, bytes.length, 0);
  }
}

bool _nvmeSameDigest(Uint8List a, Uint8List b) {
  if (a.length != b.length) return false;
  var difference = 0;
  for (var i = 0; i < a.length; i++) {
    difference |= a[i] ^ b[i];
  }
  return difference == 0;
}

/// Opaque, single-use, caller-disposable key material. No public key getter,
/// JSON serializer or key-bearing toString. Buffer wiping is best effort:
/// Dart strings and transport serialization copies cannot be zeroized here.
final class NvmeHostKeyDraft {
  NvmeHostKeyDraft._(this._host, this._controller)
    : hasControllerKey = _controller != null;
  Uint8List? _host, _controller;
  bool _claimed = false;
  final bool hasControllerKey;
  bool get isDisposed => _host == null;

  /// Conservative DHHC-1:01/02/03 canonical base64 and decoded-size checks.
  /// This does NOT verify CRC, key derivation, entropy or initiator compatibility.
  /// Raw format 00 is intentionally unsupported; server validation is authoritative.
  factory NvmeHostKeyDraft.import({
    required String hostKey,
    String? controllerKey,
  }) {
    Uint8List parse(String value) {
      try {
        if (value.length > 120) throw const FormatException();
        final match = RegExp(r'^DHHC-1:(01|02|03):([A-Za-z0-9+/]+={0,2}):$')
            .firstMatch(value);
        if (match == null || match.end != value.length) {
          throw const FormatException();
        }
        final encoded = match.group(2)!;
        final decoded = base64Decode(encoded);
        try {
          final length = switch (match.group(1)) {
            '01' => 36,
            '02' => 52,
            _ => 68,
          };
          if (decoded.length != length || base64Encode(decoded) != encoded) {
            throw const FormatException();
          }
        } finally {
          decoded.fillRange(0, decoded.length, 0);
        }
        final bytes = ascii.encode(value);
        try {
          return Uint8List.fromList(bytes);
        } finally {
          bytes.fillRange(0, bytes.length, 0);
        }
      } on Object {
        throw const FormatException('Unsupported imported NVMe key structure');
      }
    }

    final host = parse(hostKey);
    try {
      return NvmeHostKeyDraft._(
        host,
        controllerKey == null ? null : parse(controllerKey),
      );
    } on Object {
      host.fillRange(0, host.length, 0);
      rethrow;
    }
  }
  void _claim() {
    if (_claimed || isDisposed) throw const NvmeHostException();
    _claimed = true;
  }

  String get _hostText {
    if (isDisposed) throw const NvmeHostException();
    return ascii.decode(_host!);
  }

  String? get _controllerText {
    if (isDisposed) throw const NvmeHostException();
    return _controller == null ? null : ascii.decode(_controller!);
  }

  void dispose() {
    _host?.fillRange(0, _host!.length, 0);
    _controller?.fillRange(0, _controller!.length, 0);
    _host = null;
    _controller = null;
  }

  @override
  String toString() => 'NvmeHostKeyDraft(redacted)';
}

String _nvmeHostReferenceProof(NvmeHostPublicRows value, {int? omitHost}) {
  final hostIds = <int>{};
  final mappingIds = <int>{};
  for (final row in value.hosts) {
    if (!hostIds.add(row['id'] as int)) throw const NvmeHostException();
  }
  for (final row in value.mappings) {
    if (!mappingIds.add(row['id'] as int) ||
        !hostIds.contains((row['host'] as Map)['id'])) {
      throw const NvmeHostException();
    }
  }
  final hosts =
      value.hosts
          .where((h) => h['id'] != omitHost)
          .map((h) => [h['id'], h['hostnqn']])
          .toList()
        ..sort((a, b) => (a.first as int).compareTo(b.first as int));
  final mappings =
      value.mappings
          .map(
            (m) => [
              m['id'],
              (m['host'] as Map)['id'],
              (m['subsys'] as Map)['id'],
            ],
          )
          .toList()
        ..sort((a, b) => (a.first as int).compareTo(b.first as int));
  return jsonEncode([hosts, mappings]);
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
