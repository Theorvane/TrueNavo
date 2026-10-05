import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/dashboard/dashboard_capabilities.dart';
import 'package:truenavo/features/dashboard/snapshot_fixture_contract.dart';

void main() {
  const families = [
    DashboardVersionFamily.v25_04,
    DashboardVersionFamily.v25_10,
    DashboardVersionFamily.v26Plus,
  ];

  test('defines bounded fixture-only scalar API', () {
    for (final family in families) {
      expect(SnapshotFixtureContract.select(family).isRuntimeEnabled, isFalse);
    }
    expect(SnapshotFixtureContract.maxRecords, 256);
    expect(SnapshotFixtureContract.maxTypedEntries, 1024);
    expect(SnapshotFixtureContract.maxStringUnits, 32);
    expect(SnapshotFixtureContract.maxEncodedUnits, 65536);
    expect(SnapshotFixtureContract.maxJsonDepth, 16);
    final result = SnapshotFixtureContract.select(
      DashboardVersionFamily.unknownUnsupported,
    ).parse('{}');
    expect(result.status, SnapshotFixtureStatus.rejected);
    expect(result.snapshot, isNull);
    expect(
      result.rejectionReason,
      SnapshotFixtureRejectionReason.unsupportedVersion,
    );
  });

  test('decodes every version fixture into anonymous counts', () {
    final files = {
      DashboardVersionFamily.v25_04: 'v25_04_minimal.json',
      DashboardVersionFamily.v25_10: 'v25_10_minimal.json',
      DashboardVersionFamily.v26Plus: 'v26_plus_minimal.json',
    };
    for (final family in families) {
      final result = SnapshotFixtureContract.select(family)
          .parse(_fixture(files[family]!));
      expect(result.status, SnapshotFixtureStatus.complete);
      final s = result.snapshot!;
      expect(s.versionFamily, family);
      expect(s.totalCount, 1);
      expect(
        s.recursiveCount + s.nonRecursiveCount + s.unknownRecursionCount,
        1,
      );
      expect(s.holdPresentCount + s.holdAbsentCount + s.unknownHoldCount, 1);
      expect(
        s.managedRetentionCount +
            s.unmanagedRetentionCount +
            s.unknownRetentionCount,
        1,
      );
    }
  });

  test(
    'rejects cross-family marker and non-string poison inputs untouched',
    () {
      expect(
        _contract
            .parse(
              '{"contract":"v25_04_snapshot_projection_v1","snapshots":[]}',
            )
            .status,
        SnapshotFixtureStatus.rejected,
      );
      for (final input in <Object?>[_PoisonMap(), _PoisonList()]) {
        expect(_contract.parse(input).status, SnapshotFixtureStatus.rejected);
      }
    },
  );

  test('globally validates cross-family and over-record tails', () {
    final deep = '${'[' * 17}null${']' * 17}';
    final crossFamily =
        '{"contract":"v25_04_snapshot_projection_v1","snapshots":[$deep]}';
    expect(
      _contract.parse(crossFamily).rejectionReason,
      SnapshotFixtureRejectionReason.jsonDepthExceeded,
    );

    final safe = List.generate(
      256,
      (_) => '{"recursive":"RECURSIVE","hold":"PRESENT","retention":"MANAGED"}',
    ).join(',');
    final duplicateTail =
        '{"contract":"v25_10_snapshot_projection_v1","snapshots":[$safe,{"recursive":"RECURSIVE","recursive":"RECURSIVE","hold":"PRESENT","retention":"MANAGED"}]}';
    final deepTail =
        '{"contract":"v25_10_snapshot_projection_v1","snapshots":[$safe,$deep]}';
    expect(
      _contract.parse(duplicateTail).rejectionReason,
      SnapshotFixtureRejectionReason.malformedEnvelope,
    );
    expect(
      _contract.parse(deepTail).rejectionReason,
      SnapshotFixtureRejectionReason.jsonDepthExceeded,
    );
  });

  test('aggregates every fixed projection token', () {
    final s = _parse(
      _root([
        _record('RECURSIVE', 'PRESENT', 'MANAGED'),
        _record('NON_RECURSIVE', 'ABSENT', 'UNMANAGED'),
        _record('UNKNOWN', 'UNKNOWN', 'UNKNOWN'),
      ]),
    ).snapshot!;
    expect(s.totalCount, 3);
    expect(
      [s.recursiveCount, s.nonRecursiveCount, s.unknownRecursionCount],
      [1, 1, 1],
    );
    expect(
      [s.holdPresentCount, s.holdAbsentCount, s.unknownHoldCount],
      [1, 1, 1],
    );
    expect(
      [
        s.managedRetentionCount,
        s.unmanagedRetentionCount,
        s.unknownRetentionCount,
      ],
      [1, 1, 1],
    );
  });

  test('uses partial only when at least one safe record remains', () {
    for (final bad in [
      'bad',
      {'recursive': 'SERVER', 'hold': 'PRESENT', 'retention': 'MANAGED'},
      {'recursive': 'RECURSIVE', 'hold': 'PRESENT'},
      {
        'recursive': 'RECURSIVE',
        'hold': 'PRESENT',
        'retention': 'MANAGED',
        'name': 'tank@snap',
      },
    ]) {
      final result = _parse(
        _root([_record('RECURSIVE', 'PRESENT', 'MANAGED'), bad]),
      );
      expect(result.status, SnapshotFixtureStatus.partial);
      expect(result.snapshot!.totalCount, 1);
    }
    expect(_parse(_root(['bad'])).status, SnapshotFixtureStatus.rejected);
    expect(_parse(_root([])).status, SnapshotFixtureStatus.rejected);
  });

  test('enforces record 256 and 257 boundaries', () {
    final exact = _parse(
      _root(
        List.generate(256, (_) => _record('RECURSIVE', 'PRESENT', 'MANAGED')),
      ),
    );
    final over = _parse(
      _root(
        List.generate(257, (_) => _record('RECURSIVE', 'PRESENT', 'MANAGED')),
      ),
    );
    expect(exact.status, SnapshotFixtureStatus.complete);
    expect(exact.snapshot!.totalCount, 256);
    expect(over.status, SnapshotFixtureStatus.partial);
    expect(over.snapshot!.totalCount, 256);
  });

  test('rejects duplicate decoded keys', () {
    const root =
        '{"contract":"v25_10_snapshot_projection_v1","snapshots":[],"contract":"v25_10_snapshot_projection_v1"}';
    const record =
        '{"contract":"v25_10_snapshot_projection_v1","snapshots":[{"recursive":"RECURSIVE","hold":"PRESENT","retention":"MANAGED","h\\u006fld":"PRESENT"}]}';
    expect(_contract.parse(root).status, SnapshotFixtureStatus.rejected);
    expect(_contract.parse(record).status, SnapshotFixtureStatus.rejected);
  });

  test('enforces encoded and JSON depth lower and upper boundaries', () {
    final valid = jsonEncode(
      _root([_record('RECURSIVE', 'PRESENT', 'MANAGED')]),
    );
    final exact = valid.padRight(SnapshotFixtureContract.maxEncodedUnits);
    expect(_contract.parse(exact).status, SnapshotFixtureStatus.complete);
    expect(_contract.parse('$exact ').status, SnapshotFixtureStatus.rejected);
    final d16 = '${'[' * 16}null${']' * 16}';
    final d17 = '${'[' * 17}null${']' * 17}';
    expect(
      _contract.parse(d16).rejectionReason,
      SnapshotFixtureRejectionReason.malformedEnvelope,
    );
    expect(
      _contract.parse(d17).rejectionReason,
      SnapshotFixtureRejectionReason.jsonDepthExceeded,
    );
  });

  test('enforces typed entry 1024 and 1025 boundaries', () {
    String encoded(int recordEntries) {
      final fields = List.generate(
        recordEntries,
        (i) => '"field-$i":null',
      ).join(',');
      return '{"contract":"v25_10_snapshot_projection_v1","snapshots":[{$fields}]}';
    }

    // root contributes two entries; record 1022 reaches 1024.
    expect(
      _contract.parse(encoded(1022)).rejectionReason,
      SnapshotFixtureRejectionReason.noSafeObservation,
    );
    expect(
      _contract.parse(encoded(1023)).rejectionReason,
      SnapshotFixtureRejectionReason.traversalLimitExceeded,
    );
  });

  test('treats token 32 and 33 as local record failures', () {
    for (final length in [32, 33]) {
      final result = _parse(
        _root([
          _record('RECURSIVE', 'PRESENT', 'MANAGED'),
          _record('R' * length, 'PRESENT', 'MANAGED'),
        ]),
      );
      expect(result.status, SnapshotFixtureStatus.partial);
      expect(result.snapshot!.totalCount, 1);
    }
  });

  test('rejects sensitive and identifying fields in keys and values', () {
    const values = [
      'Authorization: Bearer example',
      'Authorization: Basic example',
      'api_key=example',
      'password=example',
      'cookie=session',
      'eyJhbGciOiJIUzI1NiJ9.payload.signature',
      'AKIAIOSFODNN7EXAMPLE',
      '192.168.0.123',
      '2001:db8::1',
      'https://nas.example/api/current',
      'nas.example.test',
      'account=admin',
      'request_id=1',
      '00000000-0000-0000-0000-000000000000',
      '01941f29-7c00-7cc3-98e1-2c3d4e5f6789',
      'tank/data@snap',
      'dataset=tank/data',
      'pool=tank',
      'createtxg=123',
      '2026-01-01T00:00:00Z',
      'properties',
      'property.value=secret',
      'property.source=LOCAL',
      'holds',
      'hold-tag=keep',
      'retention',
      'retention-detail=task',
      'origin=tank/base',
      'schedule=daily',
      'clone=child',
      'task=1',
      'replication=1',
      'rollback',
      'rename',
      'delete',
    ];
    for (final value in values) {
      final badValue = _parse(
        _root([
          _record('RECURSIVE', 'PRESENT', 'MANAGED'),
          _record(value, 'PRESENT', 'MANAGED'),
        ]),
      );
      final badKey = _parse(
        _root([
          _record('RECURSIVE', 'PRESENT', 'MANAGED'),
          {
            'recursive': 'RECURSIVE',
            'hold': 'PRESENT',
            'retention': 'MANAGED',
            value: null,
          },
        ]),
      );
      expect(badValue.status, SnapshotFixtureStatus.partial, reason: value);
      expect(badKey.status, SnapshotFixtureStatus.partial, reason: value);
      expect(badValue.snapshot!.totalCount, 1);
      expect(badKey.snapshot!.totalCount, 1);
    }
  });

  test('rejects malformed Unicode and all default ignorables locally', () {
    final unsafe = [
      'line\nbreak',
      '\u0085control',
      '\u202Ehidden',
      '   ',
      String.fromCharCodes([0xD800]),
    ];
    for (final v in unsafe) {
      final result = _parse(
        _root([
          _record('RECURSIVE', 'PRESENT', 'MANAGED'),
          _record(v, 'PRESENT', 'MANAGED'),
        ]),
      );
      expect(result.status, SnapshotFixtureStatus.partial);
    }
    var checked = 0;
    for (final (a, b) in _ranges) {
      for (var r = a; r <= b; r++) {
        final result = _parse(
          _root([
            _record('RECURSIVE', 'PRESENT', 'MANAGED'),
            _record(String.fromCharCode(r), 'PRESENT', 'MANAGED'),
          ]),
        );
        expect(result.status, SnapshotFixtureStatus.partial);
        checked++;
      }
    }
    expect(checked, 4174);
  });

  test(
    'aggregates are order independent and isolated from source mutation',
    () {
      final a = _record('RECURSIVE', 'PRESENT', 'MANAGED');
      final b = _record('UNKNOWN', 'ABSENT', 'UNMANAGED');
      final list = <Object?>[a, b];
      final root = _root(list);
      final first = _parse(root).snapshot!;
      a.clear();
      b.clear();
      list.clear();
      root.clear();
      final second = _parse(
        _root([
          _record('UNKNOWN', 'ABSENT', 'UNMANAGED'),
          _record('RECURSIVE', 'PRESENT', 'MANAGED'),
        ]),
      ).snapshot!;
      expect(first.totalCount, 2);
      expect(second.totalCount, 2);
      expect(first.recursiveCount, second.recursiveCount);
      expect(first.holdAbsentCount, second.holdAbsentCount);
      expect(first.managedRetentionCount, second.managedRetentionCount);
    },
  );
}

SnapshotFixtureContract get _contract =>
    SnapshotFixtureContract.select(DashboardVersionFamily.v25_10);
Map<String, Object?> _root(List<Object?> snapshots) => {
  'contract': 'v25_10_snapshot_projection_v1',
  'snapshots': snapshots,
};
Map<String, Object?> _record(String recursive, String hold, String retention) =>
    {'recursive': recursive, 'hold': hold, 'retention': retention};
SnapshotFixtureResult _parse(Object? value) =>
    _contract.parse(jsonEncode(value));
String _fixture(String name) =>
    File('test/fixtures/dashboard/snapshot/$name').readAsStringSync();

const _ranges = <(int, int)>[
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

final class _PoisonMap extends MapBase<Object?, Object?> {
  @override
  int get length => throw StateError('untouched');
  @override
  Iterable<Object?> get keys => throw StateError('untouched');
  @override
  Object? operator [](Object? k) => throw StateError('untouched');
  @override
  void operator []=(Object? k, Object? v) => throw StateError('untouched');
  @override
  void clear() => throw StateError('untouched');
  @override
  Object? remove(Object? k) => throw StateError('untouched');
}

final class _PoisonList extends ListBase<Object?> {
  @override
  int get length => throw StateError('untouched');
  @override
  set length(int v) => throw StateError('untouched');
  @override
  Object? operator [](int i) => throw StateError('untouched');
  @override
  void operator []=(int i, Object? v) => throw StateError('untouched');
}
