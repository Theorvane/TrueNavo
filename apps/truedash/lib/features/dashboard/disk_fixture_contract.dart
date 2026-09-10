import 'dart:collection';

import 'dashboard_capabilities.dart';

enum DiskFixtureStatus { complete, partial, rejected }

enum DiskFixtureRejectionReason {
  unsupportedVersion,
  malformedEnvelope,
  traversalLimitExceeded,
  sharedContainer,
  noSafeObservation,
}

enum DiskMediaClass { rotational, unclassified }

enum DiskMembershipClass { assigned, unassigned, unknown }

final class DiskInventorySnapshot {
  const DiskInventorySnapshot._({
    required this.versionFamily,
    required this.totalCount,
    required this.rotationalCount,
    required this.unclassifiedCount,
    required this.assignedCount,
    required this.unassignedCount,
    required this.unknownMembershipCount,
    required this.partial,
  });

  final DashboardVersionFamily versionFamily;
  final int totalCount;
  final int rotationalCount;
  final int unclassifiedCount;
  final int assignedCount;
  final int unassignedCount;
  final int unknownMembershipCount;
  final bool partial;
}

final class DiskFixtureResult {
  const DiskFixtureResult._({
    required this.status,
    this.snapshot,
    this.rejectionReason,
  });

  factory DiskFixtureResult._accepted(DiskInventorySnapshot snapshot) =>
      DiskFixtureResult._(
        status: snapshot.partial
            ? DiskFixtureStatus.partial
            : DiskFixtureStatus.complete,
        snapshot: snapshot,
      );

  factory DiskFixtureResult._rejected(DiskFixtureRejectionReason reason) =>
      DiskFixtureResult._(
        status: DiskFixtureStatus.rejected,
        rejectionReason: reason,
      );

  final DiskFixtureStatus status;
  final DiskInventorySnapshot? snapshot;
  final DiskFixtureRejectionReason? rejectionReason;
}

/// Parses only static, already-redacted fixtures. It has no runtime transport.
final class DiskFixtureContract {
  const DiskFixtureContract._(this.versionFamily);

  static const maxRecords = 128;
  static const maxVisitedMaps = 256;
  static const maxVisitedLists = 16;
  static const maxVisitedValues = 512;
  static const maxStringUnits = 32;

  final DashboardVersionFamily versionFamily;

  bool get isRuntimeEnabled => false;

  factory DiskFixtureContract.select(DashboardVersionFamily versionFamily) =>
      DiskFixtureContract._(versionFamily);

  String get _marker => switch (versionFamily) {
    DashboardVersionFamily.v25_04 => 'v25_04_disk_projection_v1',
    DashboardVersionFamily.v25_10 => 'v25_10_disk_projection_v1',
    DashboardVersionFamily.v26Plus => 'v26_plus_disk_projection_v1',
    DashboardVersionFamily.unknownUnsupported => '',
  };

  Map<String, DiskMediaClass> get _media => switch (versionFamily) {
    DashboardVersionFamily.v25_04 => _v25_04Media,
    DashboardVersionFamily.v25_10 => _v25_10Media,
    DashboardVersionFamily.v26Plus => _v26PlusMedia,
    DashboardVersionFamily.unknownUnsupported => const {},
  };

  Map<String, DiskMembershipClass> get _membership => switch (versionFamily) {
    DashboardVersionFamily.v25_04 => _v25_04Membership,
    DashboardVersionFamily.v25_10 => _v25_10Membership,
    DashboardVersionFamily.v26Plus => _v26PlusMembership,
    DashboardVersionFamily.unknownUnsupported => const {},
  };

  DiskFixtureResult parse(Object? fixture) {
    if (versionFamily == DashboardVersionFamily.unknownUnsupported) {
      return DiskFixtureResult._rejected(
        DiskFixtureRejectionReason.unsupportedVersion,
      );
    }
    try {
      if (fixture is! Map || fixture['contract'] != _marker) {
        return DiskFixtureResult._rejected(
          DiskFixtureRejectionReason.malformedEnvelope,
        );
      }
      final context = _TraversalContext();
      _registerMap(fixture, context);
      if (!_hasExactKeys(fixture, const {'contract', 'disks'}, context)) {
        return DiskFixtureResult._rejected(
          DiskFixtureRejectionReason.malformedEnvelope,
        );
      }
      final disks = fixture['disks'];
      if (disks is! List) {
        return DiskFixtureResult._rejected(
          DiskFixtureRejectionReason.malformedEnvelope,
        );
      }
      _registerList(disks, context);
      var partial = disks.length > maxRecords;
      var total = 0;
      var rotational = 0;
      var unclassified = 0;
      var assigned = 0;
      var unassigned = 0;
      var unknown = 0;

      for (var index = 0; index < disks.length && index < maxRecords; index++) {
        if (++context.values > maxVisitedValues) {
          throw const _DiskFixtureFailure(
            DiskFixtureRejectionReason.traversalLimitExceeded,
          );
        }
        final raw = disks[index];
        final decoded = _decodeRecord(raw, context);
        if (decoded == null) {
          partial = true;
          continue;
        }
        total++;
        switch (decoded.$1) {
          case DiskMediaClass.rotational:
            rotational++;
          case DiskMediaClass.unclassified:
            unclassified++;
        }
        switch (decoded.$2) {
          case DiskMembershipClass.assigned:
            assigned++;
          case DiskMembershipClass.unassigned:
            unassigned++;
          case DiskMembershipClass.unknown:
            unknown++;
        }
      }
      if (total == 0) {
        return DiskFixtureResult._rejected(
          DiskFixtureRejectionReason.noSafeObservation,
        );
      }
      return DiskFixtureResult._accepted(
        DiskInventorySnapshot._(
          versionFamily: versionFamily,
          totalCount: total,
          rotationalCount: rotational,
          unclassifiedCount: unclassified,
          assignedCount: assigned,
          unassignedCount: unassigned,
          unknownMembershipCount: unknown,
          partial: partial,
        ),
      );
    } on _DiskFixtureFailure catch (error) {
      return DiskFixtureResult._rejected(error.reason);
    } on Object {
      return DiskFixtureResult._rejected(
        DiskFixtureRejectionReason.malformedEnvelope,
      );
    }
  }

  (DiskMediaClass, DiskMembershipClass)? _decodeRecord(
    Object? raw,
    _TraversalContext context,
  ) {
    if (raw is! Map) return null;
    _registerMap(raw, context);
    if (!_hasExactKeys(raw, const {'media', 'membership'}, context)) {
      return null;
    }
    final mediaValue = raw['media'];
    final membershipValue = raw['membership'];
    if (mediaValue is! String || membershipValue is! String) return null;
    if (!_isSafeToken(mediaValue) || !_isSafeToken(membershipValue)) {
      return null;
    }
    final media = _media[mediaValue];
    final membership = _membership[membershipValue];
    if (media == null || membership == null) return null;
    return (media, membership);
  }

  bool _hasExactKeys(
    Map value,
    Set<String> expected,
    _TraversalContext context,
  ) {
    final keys = <String>{};
    var entries = 0;
    for (final entry in value.entries) {
      if (++entries > maxVisitedValues || ++context.values > maxVisitedValues) {
        throw const _DiskFixtureFailure(
          DiskFixtureRejectionReason.traversalLimitExceeded,
        );
      }
      final key = entry.key;
      if (key is! String || !_isSafeToken(key)) return false;
      keys.add(key);
    }
    return keys.length == expected.length && keys.containsAll(expected);
  }

  void _registerMap(Map value, _TraversalContext context) {
    if (!context.containers.add(value)) {
      throw const _DiskFixtureFailure(
        DiskFixtureRejectionReason.sharedContainer,
      );
    }
    if (++context.maps > maxVisitedMaps) {
      throw const _DiskFixtureFailure(
        DiskFixtureRejectionReason.traversalLimitExceeded,
      );
    }
  }

  void _registerList(List value, _TraversalContext context) {
    if (!context.containers.add(value)) {
      throw const _DiskFixtureFailure(
        DiskFixtureRejectionReason.sharedContainer,
      );
    }
    if (++context.lists > maxVisitedLists) {
      throw const _DiskFixtureFailure(
        DiskFixtureRejectionReason.traversalLimitExceeded,
      );
    }
  }
}

final class _TraversalContext {
  final Set<Object> containers = HashSet.identity();
  int maps = 0;
  int lists = 0;
  int values = 0;
}

final class _DiskFixtureFailure implements Exception {
  const _DiskFixtureFailure(this.reason);
  final DiskFixtureRejectionReason reason;
}

const _v25_04Media = <String, DiskMediaClass>{
  'ROTATIONAL': DiskMediaClass.rotational,
  'UNCLASSIFIED': DiskMediaClass.unclassified,
};
const _v25_10Media = <String, DiskMediaClass>{
  'ROTATIONAL': DiskMediaClass.rotational,
  'UNCLASSIFIED': DiskMediaClass.unclassified,
};
const _v26PlusMedia = <String, DiskMediaClass>{
  'ROTATIONAL': DiskMediaClass.rotational,
  'UNCLASSIFIED': DiskMediaClass.unclassified,
};
const _v25_04Membership = <String, DiskMembershipClass>{
  'ASSIGNED': DiskMembershipClass.assigned,
  'UNASSIGNED': DiskMembershipClass.unassigned,
  'UNKNOWN': DiskMembershipClass.unknown,
};
const _v25_10Membership = <String, DiskMembershipClass>{
  'ASSIGNED': DiskMembershipClass.assigned,
  'UNASSIGNED': DiskMembershipClass.unassigned,
  'UNKNOWN': DiskMembershipClass.unknown,
};
const _v26PlusMembership = <String, DiskMembershipClass>{
  'ASSIGNED': DiskMembershipClass.assigned,
  'UNASSIGNED': DiskMembershipClass.unassigned,
  'UNKNOWN': DiskMembershipClass.unknown,
};

bool _isSafeToken(String value) {
  if (value.isEmpty || value.length > DiskFixtureContract.maxStringUnits) {
    return false;
  }
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
  return value.trim().isNotEmpty;
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
