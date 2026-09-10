import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/dashboard/dashboard_capabilities.dart';
import 'package:truedash/features/dashboard/vdev_fixture_contract.dart';

void main() {
  const families = <DashboardVersionFamily>[
    DashboardVersionFamily.v25_04,
    DashboardVersionFamily.v25_10,
    DashboardVersionFamily.v26Plus,
  ];

  test('defines a fixture-only bounded API for every version family', () {
    for (final family in families) {
      final contract = VdevFixtureContract.select(family);
      expect(contract.versionFamily, family);
      expect(contract.isRuntimeEnabled, isFalse);
    }
    expect(VdevFixtureContract.maxDepth, 8);
    expect(VdevFixtureContract.maxChildren, 32);
    expect(VdevFixtureContract.maxNodes, 512);
    expect(VdevFixtureContract.maxVisitedMaps, 1024);
    expect(VdevFixtureContract.maxVisitedLists, 256);
    expect(VdevFixtureContract.maxStringUnits, 64);

    final rejected = VdevFixtureContract.select(
      DashboardVersionFamily.unknownUnsupported,
    ).parse(const {});
    expect(rejected.status, VdevFixtureStatus.rejected);
    expect(
      rejected.rejectionReason,
      VdevFixtureRejectionReason.unsupportedVersion,
    );
    expect(rejected.snapshot, isNull);
  });

  test('decodes minimal topology for every supported family', () {
    final fixtureNames = <DashboardVersionFamily, String>{
      DashboardVersionFamily.v25_04: 'v25_04_minimal.json',
      DashboardVersionFamily.v25_10: 'v25_10_minimal.json',
      DashboardVersionFamily.v26Plus: 'v26_plus_minimal.json',
    };
    for (final family in families) {
      final result = VdevFixtureContract.select(family)
          .parse(_fixture(fixtureNames[family]!));
      expect(result.status, VdevFixtureStatus.complete);
      expect(result.rejectionReason, isNull);
      final snapshot = result.snapshot!;
      expect(snapshot.versionFamily, family);
      expect(snapshot.partial, isFalse);
      expect(snapshot.groups.single.kind, VdevTopologyGroupKind.data);
      expect(
        snapshot.groups.single.roots.single.status,
        VdevOperationalStatus.online,
      );
      expect(snapshot.groups.single.roots.single.deviceCount, 2);
      expect(snapshot.nodeCount, 3);
    }
  });

  test('normalizes deterministic VDEV groups and states', () {
    final result = _contract.parse({
      'topology': {
        'dedup': [_leaf('FAULTED')],
        'special': [_leaf('OFFLINE')],
        'log': [_leaf('UNAVAIL')],
        'cache': [_leaf('DEGRADED')],
        'spare': [_leaf()],
        'data': [_leaf('ONLINE')],
      },
    });

    expect(result.status, VdevFixtureStatus.complete);
    expect(
      result.snapshot!.groups.map((group) => group.kind),
      VdevTopologyGroupKind.values,
    );
    expect(
      result.snapshot!.groups
          .expand((group) => group.roots)
          .map((node) => node.status),
      const [
        VdevOperationalStatus.online,
        VdevOperationalStatus.unknown,
        VdevOperationalStatus.degraded,
        VdevOperationalStatus.unavailable,
        VdevOperationalStatus.offline,
        VdevOperationalStatus.faulted,
      ],
    );
  });

  test('returns partial for a local malformed node when safe data remains', () {
    final result = _contract.parse({
      'topology': {
        'data': [
          _leaf('ONLINE'),
          {'type': 'UNKNOWN', 'status': 'ONLINE'},
          {'type': 'DISK', 'status': 'SERVER_TEXT'},
        ],
      },
    });

    expect(result.status, VdevFixtureStatus.partial);
    expect(result.snapshot!.partial, isTrue);
    expect(result.snapshot!.nodeCount, 1);
    expect(result.rejectionReason, isNull);
  });

  test('rejects unknown and duplicate logical groups', () {
    for (final topology in [
      {
        'unknown': [_leaf('ONLINE')],
      },
      {
        'data': [_leaf('ONLINE')],
        'DATA': [_leaf('ONLINE')],
      },
    ]) {
      final result = _contract.parse({'topology': topology});
      expect(result.status, VdevFixtureStatus.rejected);
      expect(
        result.rejectionReason,
        VdevFixtureRejectionReason.duplicateOrUnknownGroup,
      );
    }
  });

  test('rejects malformed envelopes and fixtures with no safe observation', () {
    expect(
      _contract.parse(const []).rejectionReason,
      VdevFixtureRejectionReason.malformedEnvelope,
    );
    expect(
      _contract.parse(const {'topology': 'bad'}).rejectionReason,
      VdevFixtureRejectionReason.malformedEnvelope,
    );
    expect(
      _contract.parse(const {'topology': <String, Object?>{}}).rejectionReason,
      VdevFixtureRejectionReason.noSafeObservation,
    );
  });

  test('enforces VDEV local traversal bounds', () {
    final roots32 = List.generate(32, (_) => _leaf('ONLINE'));
    final roots33 = List.generate(33, (_) => _leaf('ONLINE'));
    expect(
      _contract.parse({
        'topology': {'data': roots32},
      }).status,
      VdevFixtureStatus.complete,
    );
    final widthPartial = _contract.parse({
      'topology': {'data': roots33},
    });
    expect(widthPartial.status, VdevFixtureStatus.partial);
    expect(widthPartial.snapshot!.nodeCount, 32);

    final children32 = List.generate(32, (_) => _leaf('ONLINE'));
    final children33 = List.generate(33, (_) => _leaf('ONLINE'));
    expect(
      _contract.parse({
        'topology': {
          'data': [_branch(children32)],
        },
      }).status,
      VdevFixtureStatus.complete,
    );
    expect(
      _contract.parse({
        'topology': {
          'data': [_branch(children33)],
        },
      }).status,
      VdevFixtureStatus.partial,
    );

    expect(
      _contract.parse({
        'topology': {
          'data': [_chain(8)],
        },
      }).status,
      VdevFixtureStatus.complete,
    );
    final depthPartial = _contract.parse({
      'topology': {
        'data': [_leaf('ONLINE'), _chain(9)],
      },
    });
    expect(depthPartial.status, VdevFixtureStatus.partial);
    expect(depthPartial.snapshot!.nodeCount, 1);
  });

  test('caps retained nodes at 512 and marks the 513th partial', () {
    final exact = List.generate(
      16,
      (_) => _branch(List.generate(31, (_) => _leaf('ONLINE'))),
    );
    final over = [
      ...List.generate(
        15,
        (_) => _branch(List.generate(31, (_) => _leaf('ONLINE'))),
      ),
      _branch(List.generate(32, (_) => _leaf('ONLINE'))),
    ];
    final exactResult = _contract.parse({
      'topology': {'data': exact},
    });
    final overResult = _contract.parse({
      'topology': {'data': over},
    });
    expect(exactResult.status, VdevFixtureStatus.complete);
    expect(exactResult.snapshot!.nodeCount, 512);
    expect(overResult.status, VdevFixtureStatus.partial);
    expect(overResult.snapshot!.nodeCount, 512);
  });

  test('rejects hostile and shared fixture containers', () {
    expect(
      _contract.parse(_OversizedMap(1025)).rejectionReason,
      VdevFixtureRejectionReason.traversalLimitExceeded,
    );

    final selfMap = <String, Object?>{};
    selfMap['topology'] = selfMap;
    expect(
      _contract.parse(selfMap).rejectionReason,
      VdevFixtureRejectionReason.sharedContainer,
    );

    final sharedLeaf = _leaf('ONLINE');
    expect(
      _contract.parse({
        'topology': {
          'data': [sharedLeaf, sharedLeaf],
        },
      }).rejectionReason,
      VdevFixtureRejectionReason.sharedContainer,
    );

    final sharedList = <Object?>[_leaf('ONLINE')];
    expect(
      _contract.parse({
        'topology': {'data': sharedList, 'cache': sharedList},
      }).rejectionReason,
      VdevFixtureRejectionReason.sharedContainer,
    );
  });

  test('enforces global map and list traversal limits', () {
    Map<String, Object?> fixtureWithPadding(List<Object?> padding) => {
      'topology': {
        'data': [_leaf('ONLINE')],
      },
      'padding': padding,
    };

    // Root, topology, and leaf are three maps.
    final mapExact = fixtureWithPadding(
      List.generate(1021, (_) => <String, Object?>{}),
    );
    final mapOver = fixtureWithPadding(
      List.generate(1022, (_) => <String, Object?>{}),
    );
    expect(_contract.parse(mapExact).status, VdevFixtureStatus.complete);
    expect(
      _contract.parse(mapOver).rejectionReason,
      VdevFixtureRejectionReason.traversalLimitExceeded,
    );

    // Group roots and padding are two lists; 254 empty lists reach 256.
    final listExact = fixtureWithPadding(
      List.generate(254, (_) => <Object?>[]),
    );
    final listOver = fixtureWithPadding(List.generate(255, (_) => <Object?>[]));
    expect(_contract.parse(listExact).status, VdevFixtureStatus.complete);
    expect(
      _contract.parse(listOver).rejectionReason,
      VdevFixtureRejectionReason.traversalLimitExceeded,
    );
  });

  test('rejects sensitive and unsafe fixture strings', () {
    final unsafe = <String>[
      'Authorization: Bearer example-secret',
      'Authorization: Basic example-secret',
      'password=example',
      'api_key=example',
      'cookie=session',
      'eyJhbGciOiJIUzI1NiJ9.payload.signature',
      'AKIAIOSFODNN7EXAMPLE',
      'https://nas.example',
      '/dev/sda',
      'serial=ABC123',
      'wwn=5000c500',
      'guid=1234',
      'x' * 65,
      'line\nbreak',
      '\u202Ehidden',
      '\u115F',
      String.fromCharCode(0xE0001),
      String.fromCharCodes([0xD800]),
    ];
    for (final value in unsafe) {
      final result = _contract.parse({
        'topology': {
          'data': [
            {'type': 'DISK', 'status': 'ONLINE', 'metadata': value},
          ],
        },
      });
      expect(
        result.status,
        VdevFixtureStatus.rejected,
        reason: 'must reject unsafe fixture string',
      );
      expect(result.snapshot, isNull);
    }
  });

  test('rejects every Unicode default-ignorable code point', () {
    var checked = 0;
    for (final (start, end) in _defaultIgnorableRanges) {
      for (var rune = start; rune <= end; rune++) {
        final value = String.fromCharCode(rune);
        final result = _contract.parse({
          'topology': {
            'data': [
              {'type': 'DISK', 'status': 'ONLINE', 'metadata': value},
            ],
          },
        });
        expect(
          result.status,
          VdevFixtureStatus.rejected,
          reason: 'U+${rune.toRadixString(16).toUpperCase()}',
        );
        checked++;
      }
    }
    expect(checked, 4174);
  });

  test('rejects identifier and credential-shaped unknown keys', () {
    for (final key in const [
      'password',
      'api_key',
      'credential',
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
    ]) {
      final result = _contract.parse({
        'topology': {
          'data': [
            {'type': 'DISK', 'status': 'ONLINE', key: 'example'},
          ],
        },
      });
      expect(
        result.status,
        VdevFixtureStatus.rejected,
        reason: 'must reject unsafe fixture key',
      );
    }
  });

  test('allows safe ignored Unicode without retaining it', () {
    final result = _contract.parse({
      'topology': {
        'data': [
          {'type': 'DISK', 'status': 'ONLINE', 'note': 'safe 😀'},
        ],
      },
    });
    expect(result.status, VdevFixtureStatus.complete);
    expect(
      result.snapshot!.groups.single.roots.single.status,
      VdevOperationalStatus.online,
    );
  });

  test('copies output and exposes unmodifiable topology lists', () {
    final leaf = _leaf('ONLINE');
    final roots = <Object?>[leaf];
    final topology = <String, Object?>{'data': roots};
    final fixture = <String, Object?>{'topology': topology};
    final snapshot = _contract.parse(fixture).snapshot!;

    leaf['status'] = 'FAULTED';
    roots.clear();
    topology.clear();
    fixture.clear();

    expect(
      snapshot.groups.single.roots.single.status,
      VdevOperationalStatus.online,
    );
    expect(
      () => snapshot.groups.add(snapshot.groups.single),
      throwsUnsupportedError,
    );
    expect(
      () =>
          snapshot.groups.single.roots.add(snapshot.groups.single.roots.single),
      throwsUnsupportedError,
    );
    expect(
      () => snapshot.groups.single.roots.single.children.add(
        snapshot.groups.single.roots.single,
      ),
      throwsUnsupportedError,
    );
  });
}

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

VdevFixtureContract get _contract =>
    VdevFixtureContract.select(DashboardVersionFamily.v25_10);

Map<String, Object?> _leaf([String? status]) => {
  'type': 'DISK',
  'status': ?status,
};

Map<String, Object?> _branch(List<Object?> children) => {
  'type': 'MIRROR',
  'status': 'ONLINE',
  'children': children,
};

Map<String, Object?> _chain(int depth) =>
    depth == 1 ? _leaf('ONLINE') : _branch(<Object?>[_chain(depth - 1)]);

Object? _fixture(String name) =>
    jsonDecode(File('test/fixtures/dashboard/vdev/$name').readAsStringSync());

final class _OversizedMap extends MapBase<Object?, Object?> {
  _OversizedMap(this._length);

  final int _length;

  @override
  int get length => _length;

  @override
  Iterable<Object?> get keys => throw StateError('entries must not be read');

  @override
  Object? operator [](Object? key) =>
      throw StateError('values must not be read');

  @override
  void operator []=(Object? key, Object? value) =>
      throw StateError('map must not be mutated');

  @override
  void clear() => throw StateError('map must not be mutated');

  @override
  Object? remove(Object? key) => throw StateError('map must not be mutated');
}
