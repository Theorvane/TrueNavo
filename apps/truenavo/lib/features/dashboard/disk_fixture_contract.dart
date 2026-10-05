import 'dart:convert';

import 'dashboard_capabilities.dart';

enum DiskFixtureStatus { complete, partial, rejected }

enum DiskFixtureRejectionReason {
  unsupportedVersion,
  malformedEnvelope,
  traversalLimitExceeded,
  jsonDepthExceeded,
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
  static const maxVisitedValues = 512;
  static const maxStringUnits = 32;
  static const maxEncodedUnits = 32768;
  static const maxJsonDepth = 16;

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

  DiskFixtureResult parse(Object? encodedFixture) {
    if (versionFamily == DashboardVersionFamily.unknownUnsupported) {
      return DiskFixtureResult._rejected(
        DiskFixtureRejectionReason.unsupportedVersion,
      );
    }
    try {
      if (encodedFixture is! String ||
          encodedFixture.length > maxEncodedUnits) {
        return DiskFixtureResult._rejected(
          DiskFixtureRejectionReason.malformedEnvelope,
        );
      }
      final scanner = _JsonDuplicateKeyScanner(encodedFixture);
      if (scanner.hasDuplicateKey) {
        return DiskFixtureResult._rejected(
          DiskFixtureRejectionReason.malformedEnvelope,
        );
      }
      final fixture = jsonDecode(encodedFixture);
      if (fixture is! Map || fixture['contract'] != _marker) {
        return DiskFixtureResult._rejected(
          DiskFixtureRejectionReason.malformedEnvelope,
        );
      }
      final context = _TraversalContext();
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
    } on _JsonDepthFailure {
      return DiskFixtureResult._rejected(
        DiskFixtureRejectionReason.jsonDepthExceeded,
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
    return entries == expected.length &&
        keys.length == expected.length &&
        keys.containsAll(expected);
  }
}

final class _TraversalContext {
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

final class _JsonDepthFailure implements Exception {
  const _JsonDepthFailure();
}

final class _JsonDuplicateKeyScanner {
  _JsonDuplicateKeyScanner(this.source);

  final String source;
  var _index = 0;
  var _duplicate = false;

  bool get hasDuplicateKey {
    _skipWhitespace();
    _value(0);
    _skipWhitespace();
    if (_index != source.length) throw const FormatException();
    return _duplicate;
  }

  void _value(int depth) {
    if (depth > DiskFixtureContract.maxJsonDepth) {
      throw const _JsonDepthFailure();
    }
    _skipWhitespace();
    if (_index >= source.length) throw const FormatException();
    switch (source.codeUnitAt(_index)) {
      case 0x7B:
        _object(depth);
      case 0x5B:
        _array(depth);
      case 0x22:
        _string();
      default:
        _scalar();
    }
  }

  void _object(int depth) {
    _expect(0x7B);
    _skipWhitespace();
    final keys = <String>{};
    if (_take(0x7D)) return;
    while (true) {
      final key = _string();
      if (!keys.add(key)) _duplicate = true;
      _skipWhitespace();
      _expect(0x3A);
      _value(depth + 1);
      _skipWhitespace();
      if (_take(0x7D)) return;
      _expect(0x2C);
      _skipWhitespace();
    }
  }

  void _array(int depth) {
    _expect(0x5B);
    _skipWhitespace();
    if (_take(0x5D)) return;
    while (true) {
      _value(depth + 1);
      _skipWhitespace();
      if (_take(0x5D)) return;
      _expect(0x2C);
    }
  }

  String _string() {
    final start = _index;
    _expect(0x22);
    var escaped = false;
    while (_index < source.length) {
      final unit = source.codeUnitAt(_index++);
      if (escaped) {
        if (unit == 0x75) {
          for (var count = 0; count < 4; count++) {
            if (_index >= source.length ||
                !_isHex(source.codeUnitAt(_index++))) {
              throw const FormatException();
            }
          }
        }
        escaped = false;
      } else if (unit == 0x5C) {
        escaped = true;
      } else if (unit == 0x22) {
        return jsonDecode(source.substring(start, _index)) as String;
      } else if (unit < 0x20) {
        throw const FormatException();
      }
    }
    throw const FormatException();
  }

  void _scalar() {
    final start = _index;
    while (_index < source.length &&
        !const {
          0x20,
          0x09,
          0x0A,
          0x0D,
          0x2C,
          0x5D,
          0x7D,
        }.contains(source.codeUnitAt(_index))) {
      _index++;
    }
    if (_index == start) throw const FormatException();
  }

  void _skipWhitespace() {
    while (_index < source.length &&
        const {0x20, 0x09, 0x0A, 0x0D}.contains(source.codeUnitAt(_index))) {
      _index++;
    }
  }

  bool _take(int unit) {
    if (_index < source.length && source.codeUnitAt(_index) == unit) {
      _index++;
      return true;
    }
    return false;
  }

  void _expect(int unit) {
    if (!_take(unit)) throw const FormatException();
  }

  bool _isHex(int unit) =>
      (unit >= 0x30 && unit <= 0x39) ||
      (unit >= 0x41 && unit <= 0x46) ||
      (unit >= 0x61 && unit <= 0x66);
}
