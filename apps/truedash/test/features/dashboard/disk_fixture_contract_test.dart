import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/dashboard/dashboard_capabilities.dart';
import 'package:truedash/features/dashboard/disk_fixture_contract.dart';

void main() {
  const families = [
    DashboardVersionFamily.v25_04,
    DashboardVersionFamily.v25_10,
    DashboardVersionFamily.v26Plus,
  ];

  test('defines a fixture-only bounded scalar aggregate API', () {
    for (final family in families) {
      final contract = DiskFixtureContract.select(family);
      expect(contract.versionFamily, family);
      expect(contract.isRuntimeEnabled, isFalse);
    }
    expect(DiskFixtureContract.maxRecords, 128);
    expect(DiskFixtureContract.maxVisitedMaps, 256);
    expect(DiskFixtureContract.maxVisitedLists, 16);
    expect(DiskFixtureContract.maxVisitedValues, 512);
    expect(DiskFixtureContract.maxStringUnits, 32);
    final rejected = DiskFixtureContract.select(
      DashboardVersionFamily.unknownUnsupported,
    ).parse(const {});
    expect(rejected.status, DiskFixtureStatus.rejected);
    expect(rejected.snapshot, isNull);
    expect(
      rejected.rejectionReason,
      DiskFixtureRejectionReason.unsupportedVersion,
    );
  });

  test('decodes each version fixture into anonymous counts', () {
    final fixtures = {
      DashboardVersionFamily.v25_04: 'v25_04_minimal.json',
      DashboardVersionFamily.v25_10: 'v25_10_minimal.json',
      DashboardVersionFamily.v26Plus: 'v26_plus_minimal.json',
    };
    for (final family in families) {
      final result = DiskFixtureContract.select(family)
          .parse(_fixture(fixtures[family]!));
      expect(result.status, DiskFixtureStatus.complete);
      final snapshot = result.snapshot!;
      expect(snapshot.versionFamily, family);
      expect(snapshot.totalCount, 1);
      expect(snapshot.rotationalCount + snapshot.unclassifiedCount, 1);
      expect(
        snapshot.assignedCount +
            snapshot.unassignedCount +
            snapshot.unknownMembershipCount,
        1,
      );
      expect(snapshot.partial, isFalse);
    }
  });

  test('rejects cross-family marker before touching disks', () {
    final result = _contract.parse({
      'contract': 'v25_04_disk_projection_v1',
      'disks': _UntouchableList(),
    });
    expect(result.status, DiskFixtureStatus.rejected);
    expect(
      result.rejectionReason,
      DiskFixtureRejectionReason.malformedEnvelope,
    );
  });

  test('aggregates every fixed media and membership token', () {
    final result = _contract.parse(
      _root([
        _disk('ROTATIONAL', 'ASSIGNED'),
        _disk('UNCLASSIFIED', 'UNASSIGNED'),
        _disk('ROTATIONAL', 'UNKNOWN'),
      ]),
    );
    final snapshot = result.snapshot!;
    expect(result.status, DiskFixtureStatus.complete);
    expect(snapshot.totalCount, 3);
    expect(snapshot.rotationalCount, 2);
    expect(snapshot.unclassifiedCount, 1);
    expect(snapshot.assignedCount, 1);
    expect(snapshot.unassignedCount, 1);
    expect(snapshot.unknownMembershipCount, 1);
  });

  test('returns partial when one attempted record is unsafe', () {
    for (final invalid in [
      'not-a-map',
      {'media': 'SSD', 'membership': 'ASSIGNED'},
      {'media': 'ROTATIONAL', 'membership': 'SERVER_TEXT'},
      {'media': 'ROTATIONAL', 'membership': 'ASSIGNED', 'serial': 'secret'},
      {'media': 'ROTATIONAL'},
    ]) {
      final result = _contract.parse(
        _root([_disk('ROTATIONAL', 'ASSIGNED'), invalid]),
      );
      expect(result.status, DiskFixtureStatus.partial);
      expect(result.snapshot!.totalCount, 1);
    }
  });

  test('rejects malformed envelopes and no-safe-record inputs', () {
    for (final fixture in [
      const <Object?>[],
      {'contract': 'v25_10_disk_projection_v1', 'disks': 'bad'},
      {'contract': 'v25_10_disk_projection_v1', 'disks': const []},
      {
        'contract': 'v25_10_disk_projection_v1',
        'disks': ['bad'],
      },
      {
        'contract': 'v25_10_disk_projection_v1',
        'disks': [_disk('ROTATIONAL', 'ASSIGNED')],
        'extra': true,
      },
    ]) {
      expect(_contract.parse(fixture).status, DiskFixtureStatus.rejected);
    }
  });

  test('stops at record 128 and never touches a hostile tail', () {
    final result = _contract.parse({
      'contract': 'v25_10_disk_projection_v1',
      'disks': _HugeDiskList(1000000000),
    });
    expect(result.status, DiskFixtureStatus.partial);
    expect(result.snapshot!.totalCount, 128);
  });

  test('accepts 128 records and marks record 129 partial', () {
    final exact = _contract.parse(
      _root(List.generate(128, (_) => _disk('ROTATIONAL', 'ASSIGNED'))),
    );
    final over = _contract.parse(
      _root(List.generate(129, (_) => _disk('ROTATIONAL', 'ASSIGNED'))),
    );
    expect(exact.status, DiskFixtureStatus.complete);
    expect(exact.snapshot!.totalCount, 128);
    expect(over.status, DiskFixtureStatus.partial);
    expect(over.snapshot!.totalCount, 128);
  });

  test('rejects shared records and deceptive map enumeration', () {
    final shared = _disk('ROTATIONAL', 'ASSIGNED');
    expect(
      _contract.parse(_root([shared, shared])).rejectionReason,
      DiskFixtureRejectionReason.sharedContainer,
    );
    final result = _contract.parse({
      'contract': 'v25_10_disk_projection_v1',
      'disks': [_DeceptiveRecordMap(513)],
    });
    expect(
      result.rejectionReason,
      DiskFixtureRejectionReason.traversalLimitExceeded,
    );
  });

  test('treats 32 units as safe and 33 as a local invalid record', () {
    final safe = _contract.parse(
      _root([
        _disk('ROTATIONAL', 'ASSIGNED'),
        {'media': 'ROTATIONAL', 'membership': 'A' * 32},
      ]),
    );
    final partial = _contract.parse(
      _root([
        _disk('ROTATIONAL', 'ASSIGNED'),
        {'media': 'ROTATIONAL', 'membership': 'A' * 33},
      ]),
    );
    expect(safe.status, DiskFixtureStatus.partial);
    expect(safe.snapshot!.totalCount, 1);
    expect(partial.status, DiskFixtureStatus.partial);
    expect(partial.snapshot!.totalCount, 1);
  });

  test('rejects sensitive identifier and hardware fields by exact shape', () {
    for (final key in const [
      'identifier',
      'name',
      'number',
      'serial',
      'lunid',
      'model',
      'vendor',
      'bus',
      'devname',
      'zfs_guid',
      'wwn',
      'enclosure',
      'slot',
      'pool',
      'description',
      'transfermode',
      'passwd',
      'passwords',
      'pools',
      'extra',
      'sed',
      'smartoptions',
    ]) {
      final result = _contract.parse(
        _root([
          _disk('ROTATIONAL', 'ASSIGNED'),
          {'media': 'ROTATIONAL', 'membership': 'ASSIGNED', key: 'value'},
        ]),
      );
      expect(result.status, DiskFixtureStatus.partial, reason: key);
      expect(result.snapshot!.totalCount, 1);
    }
  });

  test('rejects unsafe Unicode in admitted keys and values locally', () {
    final unsafe = [
      'line\nbreak',
      '\u202Ehidden',
      '\u115F',
      String.fromCharCode(0xE0001),
      String.fromCharCodes([0xD800]),
    ];
    for (final value in unsafe) {
      final result = _contract.parse(
        _root([
          _disk('ROTATIONAL', 'ASSIGNED'),
          {'media': 'ROTATIONAL', 'membership': value},
        ]),
      );
      expect(result.status, DiskFixtureStatus.partial);
      expect(result.snapshot!.totalCount, 1);
    }
  });

  test('rejects all Unicode 17 default-ignorable code points locally', () {
    var checked = 0;
    for (final (start, end) in _defaultIgnorableRanges) {
      for (var rune = start; rune <= end; rune++) {
        final result = _contract.parse(
          _root([
            _disk('ROTATIONAL', 'ASSIGNED'),
            {'media': 'ROTATIONAL', 'membership': String.fromCharCode(rune)},
          ]),
        );
        expect(result.status, DiskFixtureStatus.partial);
        expect(result.snapshot!.totalCount, 1);
        checked++;
      }
    }
    expect(checked, 4174);
  });

  test('source mutation and order cannot alter aggregate snapshots', () {
    final first = _disk('ROTATIONAL', 'ASSIGNED');
    final second = _disk('UNCLASSIFIED', 'UNKNOWN');
    final disks = <Object?>[first, second];
    final fixture = _root(disks);
    final snapshot = _contract.parse(fixture).snapshot!;
    first.clear();
    second.clear();
    disks.clear();
    fixture.clear();
    expect(snapshot.totalCount, 2);
    expect(snapshot.rotationalCount, 1);
    expect(snapshot.unclassifiedCount, 1);

    final reversed = _contract
        .parse(
          _root([
            _disk('UNCLASSIFIED', 'UNKNOWN'),
            _disk('ROTATIONAL', 'ASSIGNED'),
          ]),
        )
        .snapshot!;
    expect(reversed.totalCount, snapshot.totalCount);
    expect(reversed.rotationalCount, snapshot.rotationalCount);
    expect(reversed.unknownMembershipCount, snapshot.unknownMembershipCount);
  });
}

DiskFixtureContract get _contract =>
    DiskFixtureContract.select(DashboardVersionFamily.v25_10);

Map<String, Object?> _root(List<Object?> disks) => {
  'contract': 'v25_10_disk_projection_v1',
  'disks': disks,
};
Map<String, Object?> _disk(String media, String membership) => {
  'media': media,
  'membership': membership,
};
Object? _fixture(String name) =>
    jsonDecode(File('test/fixtures/dashboard/disk/$name').readAsStringSync());

const _defaultIgnorableRanges = <(int, int)>[
  (0x00AD, 0x00AD),
  (0x034F, 0x034F),
  (0x061C, 0x061C),
  (0x115F, 0x1160),
  (0x17B4, 0x17B5),
  (0x180B, 0x180F),
  (0x200B, 0x200F),
  (0x202A, 0x202E),
  (0x2060, 0x206F),
  (0x3164, 0x3164),
  (0xFE00, 0xFE0F),
  (0xFEFF, 0xFEFF),
  (0xFFA0, 0xFFA0),
  (0xFFF0, 0xFFF8),
  (0x1BCA0, 0x1BCA3),
  (0x1D173, 0x1D17A),
  (0xE0000, 0xE0FFF),
];

final class _UntouchableList extends ListBase<Object?> {
  @override
  int get length => throw StateError('must not touch disks');
  @override
  set length(int value) => throw StateError('no mutation');
  @override
  Object? operator [](int index) => throw StateError('must not touch disks');
  @override
  void operator []=(int index, Object? value) =>
      throw StateError('no mutation');
}

final class _HugeDiskList extends ListBase<Object?> {
  _HugeDiskList(this.length);
  @override
  int length;
  @override
  Object? operator [](int index) {
    if (index < 128) return _disk('ROTATIONAL', 'ASSIGNED');
    throw StateError('tail must not be touched');
  }

  @override
  void operator []=(int index, Object? value) =>
      throw StateError('no mutation');
}

final class _DeceptiveRecordMap extends MapBase<Object?, Object?> {
  _DeceptiveRecordMap(this.count);
  final int count;
  @override
  int get length => 2;
  @override
  Iterable<Object?> get keys sync* {
    for (var i = 0; i < count; i++) {
      yield 'safe-$i';
    }
  }

  @override
  Object? operator [](Object? key) => 'value';
  @override
  void operator []=(Object? key, Object? value) =>
      throw StateError('no mutation');
  @override
  void clear() => throw StateError('no mutation');
  @override
  Object? remove(Object? key) => throw StateError('no mutation');
}
