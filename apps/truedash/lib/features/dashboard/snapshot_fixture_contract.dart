import 'dart:convert';

import 'dashboard_capabilities.dart';

enum SnapshotFixtureStatus { complete, partial, rejected }

enum SnapshotFixtureRejectionReason {
  unsupportedVersion,
  malformedEnvelope,
  traversalLimitExceeded,
  jsonDepthExceeded,
  noSafeObservation,
}

enum SnapshotRecursionClass { recursive, nonRecursive, unknown }

enum SnapshotHoldClass { present, absent, unknown }

enum SnapshotRetentionClass { managed, unmanaged, unknown }

final class SnapshotInventorySnapshot {
  const SnapshotInventorySnapshot._({
    required this.versionFamily,
    required this.totalCount,
    required this.recursiveCount,
    required this.nonRecursiveCount,
    required this.unknownRecursionCount,
    required this.holdPresentCount,
    required this.holdAbsentCount,
    required this.unknownHoldCount,
    required this.managedRetentionCount,
    required this.unmanagedRetentionCount,
    required this.unknownRetentionCount,
    required this.partial,
  });

  final DashboardVersionFamily versionFamily;
  final int totalCount;
  final int recursiveCount;
  final int nonRecursiveCount;
  final int unknownRecursionCount;
  final int holdPresentCount;
  final int holdAbsentCount;
  final int unknownHoldCount;
  final int managedRetentionCount;
  final int unmanagedRetentionCount;
  final int unknownRetentionCount;
  final bool partial;
}

final class SnapshotFixtureResult {
  const SnapshotFixtureResult._({
    required this.status,
    this.snapshot,
    this.rejectionReason,
  });

  factory SnapshotFixtureResult._accepted(SnapshotInventorySnapshot snapshot) =>
      SnapshotFixtureResult._(
        status: snapshot.partial
            ? SnapshotFixtureStatus.partial
            : SnapshotFixtureStatus.complete,
        snapshot: snapshot,
      );

  factory SnapshotFixtureResult._rejected(
    SnapshotFixtureRejectionReason reason,
  ) => SnapshotFixtureResult._(
    status: SnapshotFixtureStatus.rejected,
    rejectionReason: reason,
  );

  final SnapshotFixtureStatus status;
  final SnapshotInventorySnapshot? snapshot;
  final SnapshotFixtureRejectionReason? rejectionReason;
}

/// Parses only bounded JSON containing an already-redacted static fixture.
final class SnapshotFixtureContract {
  const SnapshotFixtureContract._(this.versionFamily);

  static const maxRecords = 256;
  static const maxVisitedValues = 1024;
  static const maxStringUnits = 32;
  static const maxEncodedUnits = 65536;
  static const maxJsonDepth = 16;

  final DashboardVersionFamily versionFamily;
  bool get isRuntimeEnabled => false;

  factory SnapshotFixtureContract.select(
    DashboardVersionFamily versionFamily,
  ) => SnapshotFixtureContract._(versionFamily);

  String get _marker => switch (versionFamily) {
    DashboardVersionFamily.v25_04 => 'v25_04_snapshot_projection_v1',
    DashboardVersionFamily.v25_10 => 'v25_10_snapshot_projection_v1',
    DashboardVersionFamily.v26Plus => 'v26_plus_snapshot_projection_v1',
    DashboardVersionFamily.unknownUnsupported => '',
  };

  Map<String, SnapshotRecursionClass> get _recursion => switch (versionFamily) {
    DashboardVersionFamily.v25_04 => _v25_04Recursion,
    DashboardVersionFamily.v25_10 => _v25_10Recursion,
    DashboardVersionFamily.v26Plus => _v26PlusRecursion,
    DashboardVersionFamily.unknownUnsupported => const {},
  };
  Map<String, SnapshotHoldClass> get _holds => switch (versionFamily) {
    DashboardVersionFamily.v25_04 => _v25_04Holds,
    DashboardVersionFamily.v25_10 => _v25_10Holds,
    DashboardVersionFamily.v26Plus => _v26PlusHolds,
    DashboardVersionFamily.unknownUnsupported => const {},
  };
  Map<String, SnapshotRetentionClass> get _retention => switch (versionFamily) {
    DashboardVersionFamily.v25_04 => _v25_04Retention,
    DashboardVersionFamily.v25_10 => _v25_10Retention,
    DashboardVersionFamily.v26Plus => _v26PlusRetention,
    DashboardVersionFamily.unknownUnsupported => const {},
  };

  SnapshotFixtureResult parse(Object? encodedFixture) {
    if (versionFamily == DashboardVersionFamily.unknownUnsupported) {
      return SnapshotFixtureResult._rejected(
        SnapshotFixtureRejectionReason.unsupportedVersion,
      );
    }
    try {
      if (encodedFixture is! String ||
          encodedFixture.length > maxEncodedUnits) {
        return SnapshotFixtureResult._rejected(
          SnapshotFixtureRejectionReason.malformedEnvelope,
        );
      }
      final scanner = _JsonDuplicateKeyScanner(encodedFixture);
      if (scanner.hasDuplicateKey) {
        return SnapshotFixtureResult._rejected(
          SnapshotFixtureRejectionReason.malformedEnvelope,
        );
      }
      final fixture = jsonDecode(encodedFixture);
      if (fixture is! Map || fixture['contract'] != _marker) {
        return SnapshotFixtureResult._rejected(
          SnapshotFixtureRejectionReason.malformedEnvelope,
        );
      }
      final context = _TraversalContext();
      if (!_hasExactKeys(fixture, const {'contract', 'snapshots'}, context)) {
        return SnapshotFixtureResult._rejected(
          SnapshotFixtureRejectionReason.malformedEnvelope,
        );
      }
      final snapshots = fixture['snapshots'];
      if (snapshots is! List) {
        return SnapshotFixtureResult._rejected(
          SnapshotFixtureRejectionReason.malformedEnvelope,
        );
      }

      var partial = snapshots.length > maxRecords;
      var total = 0;
      var recursive = 0;
      var nonRecursive = 0;
      var unknownRecursion = 0;
      var holdPresent = 0;
      var holdAbsent = 0;
      var unknownHold = 0;
      var managed = 0;
      var unmanaged = 0;
      var unknownRetention = 0;

      for (
        var index = 0;
        index < snapshots.length && index < maxRecords;
        index++
      ) {
        final decoded = _decodeRecord(snapshots[index], context);
        if (decoded == null) {
          partial = true;
          continue;
        }
        total++;
        switch (decoded.$1) {
          case SnapshotRecursionClass.recursive:
            recursive++;
          case SnapshotRecursionClass.nonRecursive:
            nonRecursive++;
          case SnapshotRecursionClass.unknown:
            unknownRecursion++;
        }
        switch (decoded.$2) {
          case SnapshotHoldClass.present:
            holdPresent++;
          case SnapshotHoldClass.absent:
            holdAbsent++;
          case SnapshotHoldClass.unknown:
            unknownHold++;
        }
        switch (decoded.$3) {
          case SnapshotRetentionClass.managed:
            managed++;
          case SnapshotRetentionClass.unmanaged:
            unmanaged++;
          case SnapshotRetentionClass.unknown:
            unknownRetention++;
        }
      }
      if (total == 0) {
        return SnapshotFixtureResult._rejected(
          SnapshotFixtureRejectionReason.noSafeObservation,
        );
      }
      return SnapshotFixtureResult._accepted(
        SnapshotInventorySnapshot._(
          versionFamily: versionFamily,
          totalCount: total,
          recursiveCount: recursive,
          nonRecursiveCount: nonRecursive,
          unknownRecursionCount: unknownRecursion,
          holdPresentCount: holdPresent,
          holdAbsentCount: holdAbsent,
          unknownHoldCount: unknownHold,
          managedRetentionCount: managed,
          unmanagedRetentionCount: unmanaged,
          unknownRetentionCount: unknownRetention,
          partial: partial,
        ),
      );
    } on _JsonDepthFailure {
      return SnapshotFixtureResult._rejected(
        SnapshotFixtureRejectionReason.jsonDepthExceeded,
      );
    } on _SnapshotFixtureFailure catch (error) {
      return SnapshotFixtureResult._rejected(error.reason);
    } on Object {
      return SnapshotFixtureResult._rejected(
        SnapshotFixtureRejectionReason.malformedEnvelope,
      );
    }
  }

  (SnapshotRecursionClass, SnapshotHoldClass, SnapshotRetentionClass)?
  _decodeRecord(Object? raw, _TraversalContext context) {
    if (raw is! Map ||
        !_hasExactKeys(raw, const {
          'recursive',
          'hold',
          'retention',
        }, context)) {
      return null;
    }
    final recursionValue = raw['recursive'];
    final holdValue = raw['hold'];
    final retentionValue = raw['retention'];
    if (recursionValue is! String ||
        holdValue is! String ||
        retentionValue is! String) {
      return null;
    }
    if (!_isSafeToken(recursionValue) ||
        !_isSafeToken(holdValue) ||
        !_isSafeToken(retentionValue)) {
      return null;
    }
    final recursion = _recursion[recursionValue];
    final hold = _holds[holdValue];
    final retention = _retention[retentionValue];
    if (recursion == null || hold == null || retention == null) return null;
    return (recursion, hold, retention);
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
        throw const _SnapshotFixtureFailure(
          SnapshotFixtureRejectionReason.traversalLimitExceeded,
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

final class _SnapshotFixtureFailure implements Exception {
  const _SnapshotFixtureFailure(this.reason);
  final SnapshotFixtureRejectionReason reason;
}

const _v25_04Recursion = <String, SnapshotRecursionClass>{
  'RECURSIVE': SnapshotRecursionClass.recursive,
  'NON_RECURSIVE': SnapshotRecursionClass.nonRecursive,
  'UNKNOWN': SnapshotRecursionClass.unknown,
};
const _v25_10Recursion = <String, SnapshotRecursionClass>{
  'RECURSIVE': SnapshotRecursionClass.recursive,
  'NON_RECURSIVE': SnapshotRecursionClass.nonRecursive,
  'UNKNOWN': SnapshotRecursionClass.unknown,
};
const _v26PlusRecursion = <String, SnapshotRecursionClass>{
  'RECURSIVE': SnapshotRecursionClass.recursive,
  'NON_RECURSIVE': SnapshotRecursionClass.nonRecursive,
  'UNKNOWN': SnapshotRecursionClass.unknown,
};
const _v25_04Holds = <String, SnapshotHoldClass>{
  'PRESENT': SnapshotHoldClass.present,
  'ABSENT': SnapshotHoldClass.absent,
  'UNKNOWN': SnapshotHoldClass.unknown,
};
const _v25_10Holds = <String, SnapshotHoldClass>{
  'PRESENT': SnapshotHoldClass.present,
  'ABSENT': SnapshotHoldClass.absent,
  'UNKNOWN': SnapshotHoldClass.unknown,
};
const _v26PlusHolds = <String, SnapshotHoldClass>{
  'PRESENT': SnapshotHoldClass.present,
  'ABSENT': SnapshotHoldClass.absent,
  'UNKNOWN': SnapshotHoldClass.unknown,
};
const _v25_04Retention = <String, SnapshotRetentionClass>{
  'MANAGED': SnapshotRetentionClass.managed,
  'UNMANAGED': SnapshotRetentionClass.unmanaged,
  'UNKNOWN': SnapshotRetentionClass.unknown,
};
const _v25_10Retention = <String, SnapshotRetentionClass>{
  'MANAGED': SnapshotRetentionClass.managed,
  'UNMANAGED': SnapshotRetentionClass.unmanaged,
  'UNKNOWN': SnapshotRetentionClass.unknown,
};
const _v26PlusRetention = <String, SnapshotRetentionClass>{
  'MANAGED': SnapshotRetentionClass.managed,
  'UNMANAGED': SnapshotRetentionClass.unmanaged,
  'UNKNOWN': SnapshotRetentionClass.unknown,
};

final class _JsonDepthFailure implements Exception {
  const _JsonDepthFailure();
}

bool _isSafeToken(String value) {
  if (value.isEmpty || value.length > SnapshotFixtureContract.maxStringUnits) {
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
    if (depth > SnapshotFixtureContract.maxJsonDepth) {
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
