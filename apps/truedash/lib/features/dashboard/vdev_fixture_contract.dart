import 'dart:collection';

import 'dashboard_capabilities.dart';

enum VdevFixtureStatus { complete, partial, rejected }

enum VdevFixtureRejectionReason {
  unsupportedVersion,
  malformedEnvelope,
  duplicateOrUnknownGroup,
  traversalLimitExceeded,
  sharedContainer,
  noSafeObservation,
}

enum VdevTopologyGroupKind { data, spare, cache, log, special, dedup }

enum VdevOperationalStatus {
  online,
  degraded,
  faulted,
  offline,
  unavailable,
  unknown,
}

final class VdevTopologyNode {
  VdevTopologyNode._({
    required this.status,
    required List<VdevTopologyNode> children,
    required this.deviceCount,
  }) : children = List.unmodifiable(children);

  final VdevOperationalStatus status;
  final List<VdevTopologyNode> children;
  final int deviceCount;
}

final class VdevTopologyGroup {
  VdevTopologyGroup._({
    required this.kind,
    required List<VdevTopologyNode> roots,
  }) : roots = List.unmodifiable(roots);

  final VdevTopologyGroupKind kind;
  final List<VdevTopologyNode> roots;
}

final class VdevTopologySnapshot {
  VdevTopologySnapshot._({
    required this.versionFamily,
    required List<VdevTopologyGroup> groups,
    required this.nodeCount,
    required this.partial,
  }) : groups = List.unmodifiable(groups);

  final DashboardVersionFamily versionFamily;
  final List<VdevTopologyGroup> groups;
  final int nodeCount;
  final bool partial;
}

final class VdevFixtureResult {
  const VdevFixtureResult._({
    required this.status,
    this.snapshot,
    this.rejectionReason,
  });

  factory VdevFixtureResult._accepted(VdevTopologySnapshot snapshot) =>
      VdevFixtureResult._(
        status: snapshot.partial
            ? VdevFixtureStatus.partial
            : VdevFixtureStatus.complete,
        snapshot: snapshot,
      );

  factory VdevFixtureResult._rejected(VdevFixtureRejectionReason reason) =>
      VdevFixtureResult._(
        status: VdevFixtureStatus.rejected,
        rejectionReason: reason,
      );

  final VdevFixtureStatus status;
  final VdevTopologySnapshot? snapshot;
  final VdevFixtureRejectionReason? rejectionReason;
}

/// A static-fixture decoder only. It has no transport, provider, or runtime API.
final class VdevFixtureContract {
  const VdevFixtureContract._(this.versionFamily);

  static const maxDepth = 8;
  static const maxChildren = 32;
  static const maxNodes = 512;
  static const maxVisitedMaps = 1024;
  static const maxVisitedLists = 256;
  static const maxStringUnits = 64;

  final DashboardVersionFamily versionFamily;

  bool get isRuntimeEnabled => false;

  factory VdevFixtureContract.select(DashboardVersionFamily versionFamily) =>
      VdevFixtureContract._(versionFamily);

  VdevFixtureResult parse(Object? fixture) {
    if (versionFamily == DashboardVersionFamily.unknownUnsupported) {
      return VdevFixtureResult._rejected(
        VdevFixtureRejectionReason.unsupportedVersion,
      );
    }

    try {
      _preflight(fixture, _PreflightContext());
      final snapshot = switch (versionFamily) {
        DashboardVersionFamily.v25_04 => _decodeV25_04(fixture),
        DashboardVersionFamily.v25_10 => _decodeV25_10(fixture),
        DashboardVersionFamily.v26Plus => _decodeV26Plus(fixture),
        DashboardVersionFamily.unknownUnsupported => null,
      };
      if (snapshot == null || snapshot.nodeCount == 0) {
        return VdevFixtureResult._rejected(
          VdevFixtureRejectionReason.noSafeObservation,
        );
      }
      return VdevFixtureResult._accepted(snapshot);
    } on _FixtureRejection catch (error) {
      return VdevFixtureResult._rejected(error.reason);
    } on Object {
      return VdevFixtureResult._rejected(
        VdevFixtureRejectionReason.malformedEnvelope,
      );
    }
  }

  VdevTopologySnapshot? _decodeV25_04(Object? fixture) =>
      _decodeKnownFixture(fixture, _v25_04NodeTypes);

  VdevTopologySnapshot? _decodeV25_10(Object? fixture) =>
      _decodeKnownFixture(fixture, _v25_10NodeTypes);

  VdevTopologySnapshot? _decodeV26Plus(Object? fixture) =>
      _decodeKnownFixture(fixture, _v26PlusNodeTypes);

  VdevTopologySnapshot? _decodeKnownFixture(
    Object? fixture,
    Set<String> allowedNodeTypes,
  ) {
    if (fixture is! Map) {
      throw const _FixtureRejection(
        VdevFixtureRejectionReason.malformedEnvelope,
      );
    }
    final topology = fixture['topology'];
    if (topology is! Map) {
      throw const _FixtureRejection(
        VdevFixtureRejectionReason.malformedEnvelope,
      );
    }

    final rawGroups = <VdevTopologyGroupKind, Object?>{};
    for (final entry in topology.entries) {
      if (entry.key is! String) {
        throw const _FixtureRejection(
          VdevFixtureRejectionReason.duplicateOrUnknownGroup,
        );
      }
      final kind = _groupKind(entry.key as String);
      if (kind == null || rawGroups.containsKey(kind)) {
        throw const _FixtureRejection(
          VdevFixtureRejectionReason.duplicateOrUnknownGroup,
        );
      }
      rawGroups[kind] = entry.value;
    }
    if (rawGroups.length > VdevTopologyGroupKind.values.length) {
      throw const _FixtureRejection(
        VdevFixtureRejectionReason.duplicateOrUnknownGroup,
      );
    }

    final context = _DecodeContext(allowedNodeTypes);
    final groups = <VdevTopologyGroup>[];
    for (final kind in VdevTopologyGroupKind.values) {
      if (!rawGroups.containsKey(kind)) continue;
      final rawRoots = rawGroups[kind];
      if (rawRoots is! List) {
        throw const _FixtureRejection(
          VdevFixtureRejectionReason.malformedEnvelope,
        );
      }
      if (rawRoots.length > maxChildren) context.partial = true;
      final roots = <VdevTopologyNode>[];
      for (final rawRoot in rawRoots.take(maxChildren)) {
        final root = _decodeNode(rawRoot, context, 1);
        if (root != null) roots.add(root);
      }
      if (roots.isNotEmpty) {
        groups.add(VdevTopologyGroup._(kind: kind, roots: roots));
      }
    }

    if (context.nodeCount == 0) return null;
    return VdevTopologySnapshot._(
      versionFamily: versionFamily,
      groups: groups,
      nodeCount: context.nodeCount,
      partial: context.partial,
    );
  }

  VdevTopologyNode? _decodeNode(
    Object? raw,
    _DecodeContext context,
    int depth,
  ) {
    if (depth > maxDepth || context.nodeCount >= maxNodes) {
      context.partial = true;
      return null;
    }
    if (raw is! Map) {
      context.partial = true;
      return null;
    }
    final typeValue = raw['type'];
    if (typeValue is! String) {
      context.partial = true;
      return null;
    }
    final type = typeValue.toUpperCase();
    if (!context.allowedNodeTypes.contains(type)) {
      context.partial = true;
      return null;
    }
    final status = _status(raw['status']);
    if (status == null) {
      context.partial = true;
      return null;
    }

    final isLeaf = type == 'DISK';
    if (isLeaf) {
      final children = raw['children'];
      if (children != null && (children is! List || children.isNotEmpty)) {
        context.partial = true;
        return null;
      }
      context.nodeCount++;
      return VdevTopologyNode._(
        status: status,
        children: const [],
        deviceCount: 1,
      );
    }

    final rawChildren = raw['children'];
    if (rawChildren is! List) {
      context.partial = true;
      return null;
    }
    if (rawChildren.length > maxChildren) context.partial = true;

    context.nodeCount++;
    final children = <VdevTopologyNode>[];
    for (final rawChild in rawChildren.take(maxChildren)) {
      final child = _decodeNode(rawChild, context, depth + 1);
      if (child != null) children.add(child);
    }
    if (children.isEmpty) {
      context.nodeCount--;
      context.partial = true;
      return null;
    }
    return VdevTopologyNode._(
      status: status,
      children: children,
      deviceCount: children.fold(
        0,
        (count, child) => count + child.deviceCount,
      ),
    );
  }

  void _preflight(Object? root, _PreflightContext context) {
    final pending = <Object?>[root];
    while (pending.isNotEmpty) {
      final value = pending.removeLast();
      if (value is Map) {
        if (value.length > maxVisitedMaps) {
          throw const _FixtureRejection(
            VdevFixtureRejectionReason.traversalLimitExceeded,
          );
        }
        if (!context.containers.add(value)) {
          throw const _FixtureRejection(
            VdevFixtureRejectionReason.sharedContainer,
          );
        }
        if (++context.maps > maxVisitedMaps) {
          throw const _FixtureRejection(
            VdevFixtureRejectionReason.traversalLimitExceeded,
          );
        }
        for (final entry in value.entries) {
          if (entry.key is! String ||
              !_isSafeFixtureString(entry.key as String)) {
            throw const _FixtureRejection(
              VdevFixtureRejectionReason.malformedEnvelope,
            );
          }
          pending.add(entry.value);
        }
        continue;
      }
      if (value is List) {
        if (!context.containers.add(value)) {
          throw const _FixtureRejection(
            VdevFixtureRejectionReason.sharedContainer,
          );
        }
        if (++context.lists > maxVisitedLists) {
          throw const _FixtureRejection(
            VdevFixtureRejectionReason.traversalLimitExceeded,
          );
        }
        pending.addAll(value);
        continue;
      }
      if (value is String && !_isSafeFixtureString(value)) {
        throw const _FixtureRejection(
          VdevFixtureRejectionReason.malformedEnvelope,
        );
      }
      if (value != null &&
          value is! String &&
          value is! num &&
          value is! bool) {
        throw const _FixtureRejection(
          VdevFixtureRejectionReason.malformedEnvelope,
        );
      }
    }
  }
}

final class _DecodeContext {
  _DecodeContext(this.allowedNodeTypes);

  final Set<String> allowedNodeTypes;
  int nodeCount = 0;
  bool partial = false;
}

final class _PreflightContext {
  final Set<Object> containers = HashSet.identity();
  int maps = 0;
  int lists = 0;
}

final class _FixtureRejection implements Exception {
  const _FixtureRejection(this.reason);

  final VdevFixtureRejectionReason reason;
}

const _v25_04NodeTypes = <String>{
  'DISK',
  'MIRROR',
  'RAIDZ1',
  'RAIDZ2',
  'RAIDZ3',
  'DRAID1',
  'DRAID2',
  'DRAID3',
  'STRIPE',
};
const _v25_10NodeTypes = _v25_04NodeTypes;
const _v26PlusNodeTypes = _v25_04NodeTypes;

VdevTopologyGroupKind? _groupKind(String value) =>
    switch (value.toLowerCase()) {
      'data' => VdevTopologyGroupKind.data,
      'spare' => VdevTopologyGroupKind.spare,
      'cache' => VdevTopologyGroupKind.cache,
      'log' => VdevTopologyGroupKind.log,
      'special' => VdevTopologyGroupKind.special,
      'dedup' => VdevTopologyGroupKind.dedup,
      _ => null,
    };

VdevOperationalStatus? _status(Object? value) {
  if (value == null) return VdevOperationalStatus.unknown;
  if (value is! String) return null;
  return switch (value.toUpperCase()) {
    'ONLINE' || 'HEALTHY' => VdevOperationalStatus.online,
    'DEGRADED' || 'WARNING' => VdevOperationalStatus.degraded,
    'FAULTED' || 'CRITICAL' => VdevOperationalStatus.faulted,
    'OFFLINE' => VdevOperationalStatus.offline,
    'UNAVAIL' || 'UNAVAILABLE' => VdevOperationalStatus.unavailable,
    'UNKNOWN' => VdevOperationalStatus.unknown,
    _ => null,
  };
}

bool _isSafeFixtureString(String value) {
  if (value.length > VdevFixtureContract.maxStringUnits) return false;
  for (final rune in value.runes) {
    if (_isControl(rune) || _isDefaultIgnorable(rune)) return false;
  }
  for (var index = 0; index < value.length; index++) {
    final unit = value.codeUnitAt(index);
    if (unit >= 0xD800 && unit <= 0xDBFF) {
      if (++index >= value.length) return false;
      final next = value.codeUnitAt(index);
      if (next < 0xDC00 || next > 0xDFFF) return false;
    } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
      return false;
    }
  }
  final normalized = value.trim();
  if (normalized.isEmpty) return false;
  if (_looksSensitiveOrIdentifying(normalized)) return false;
  return true;
}

bool _looksSensitiveOrIdentifying(String value) {
  final lower = value.toLowerCase();
  if (const <String>{
    'password',
    'secret',
    'token',
    'api_key',
    'api-key',
    'credential',
    'private_key',
    'serial',
    'guid',
    'wwn',
    'device',
    'path',
    'enclosure',
    'slot',
    'host',
    'account',
    'request_id',
    'request-id',
  }.contains(lower)) {
    return true;
  }
  if (RegExp(
    r'(authorization\s*:|bearer\s+|basic\s+|pass(word)?\s*[=:]|api[_-]?key\s*[=:]|cookie\s*[=:]|secret\s*[=:]|token\s*[=:])',
  ).hasMatch(lower)) {
    return true;
  }
  if (RegExp(
    r'^eyj[a-z0-9_-]+\.[a-z0-9_-]+\.[a-z0-9_-]+$',
    caseSensitive: false,
  ).hasMatch(value)) {
    return true;
  }
  if (RegExp(
    r'^(akia|asia)[a-z0-9]{16}$',
    caseSensitive: false,
  ).hasMatch(value)) {
    return true;
  }
  if (RegExp(
    r'(https?://|wss?://|/dev/|\b(serial|guid|wwn|device|enclosure|slot|request[_-]?id|account|host)\s*[=:])',
  ).hasMatch(lower)) {
    return true;
  }
  return false;
}

bool _isControl(int rune) =>
    rune <= 0x1F ||
    (rune >= 0x7F && rune <= 0x9F) ||
    rune == 0x2028 ||
    rune == 0x2029;

bool _isDefaultIgnorable(int rune) =>
    rune == 0x00AD ||
    rune == 0x034F ||
    rune == 0x061C ||
    (rune >= 0x115F && rune <= 0x1160) ||
    (rune >= 0x17B4 && rune <= 0x17B5) ||
    (rune >= 0x180B && rune <= 0x180F) ||
    (rune >= 0x200B && rune <= 0x200F) ||
    (rune >= 0x202A && rune <= 0x202E) ||
    (rune >= 0x2060 && rune <= 0x206F) ||
    rune == 0x3164 ||
    (rune >= 0xFE00 && rune <= 0xFE0F) ||
    rune == 0xFEFF ||
    rune == 0xFFA0 ||
    (rune >= 0xFFF0 && rune <= 0xFFF8) ||
    (rune >= 0x1BCA0 && rune <= 0x1BCA3) ||
    (rune >= 0x1D173 && rune <= 0x1D17A) ||
    (rune >= 0xE0000 && rune <= 0xE0FFF);
