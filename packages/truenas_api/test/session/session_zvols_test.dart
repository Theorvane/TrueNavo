import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _gib = 1073741824;
const _methods = {
  'pool.dataset.query',
  'pool.dataset.create',
  'pool.dataset.update',
  'pool.dataset.delete',
  'pool.dataset.attachments',
  'pool.dataset.recommended_zvol_blocksize',
  'pool.snapshot.query',
  'vm.device.query',
  'iscsi.extent.query',
  'nvmet.namespace.query',
};
Map<String, Object?> _prop(Object value, {String source = 'LOCAL'}) => {
  'rawvalue': value.toString(),
  'value': value.toString(),
  'parsed': value,
  'source': source,
  'source_info': null,
};
Map<String, Object?> _row(
  String id, {
  bool volume = false,
  String guid = '123',
}) => {
  'id': id,
  'type': volume ? 'VOLUME' : 'FILESYSTEM',
  'encrypted': false,
  'locked': false,
  'mountpoint': volume ? null : '/mnt/$id',
  'guid': _prop(guid),
  'creation': _prop(1700000000),
  'used': _prop(volume ? 10 * _gib : _gib),
  'referenced': _prop(_gib),
  'available': _prop(100 * _gib),
  'compression': _prop('lz4'),
  'sync': _prop('standard'),
  'readonly': _prop('off'),
  'reservation': _prop(0),
  'refreservation': _prop(0),
  'origin': _prop('-', source: 'NONE'),
  'user_properties': {
    'managedby': _prop('-'),
    'private_note': _prop('private metadata'),
  },
  if (volume) ...{
    'volsize': _prop(10 * _gib),
    'volblocksize': _prop(16384),
    'snapdev': _prop('hidden'),
  },
};
Matcher _reason(ZvolExceptionReason r) =>
    isA<ZvolException>().having((e) => e.reason, 'reason', r);
Future<ZvolReview> _create(_Harness h, {bool thin = false}) async {
  final i = await h.repo.loadZvols();
  return h.repo.reviewZvolCreate(
    ZvolCreate(
      parent: i.parents.single,
      name: 'new_disk',
      sizeBytes: 4 * _gib,
      thin: thin,
    ),
  );
}

Future<ZvolReview> _grow(_Harness h) async {
  final i = await h.repo.loadZvols();
  return h.repo.reviewZvolUpdate(
    ZvolUpdate(volume: i.volumes.single, sizeBytes: 20 * _gib),
  );
}

void main() {
  for (final guid in ['0', '18446744073709551616', '99999999999999999999']) {
    test('GUID $guid fails closed', () async {
      final h = await _connect();
      h.wire.rows.last['guid'] = _prop(guid);
      await expectLater(
        h.repo.loadZvols(),
        throwsA(_reason(ZvolExceptionReason.invalid)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('literal managedby none is a real marker, not absence', () async {
    final h = await _connect();
    (h.wire.rows.last['user_properties'] as Map)['managedby'] = _prop('none');
    final v = (await h.repo.loadZvols()).volumes.single;
    expect(v.editable, isFalse);
  });
  test('dependency query uses the 25.10.1 nested VM discriminator', () async {
    final h = await _connect();
    h.wire.vm = [
      {
        'id': 1,
        'attributes': {'dtype': 'RAW', 'path': '/mnt/tank/unrelated.img'},
      },
    ];
    await _grow(h);
    final p =
        h.wire.requests.singleWhere(
              (r) => r['method'] == 'vm.device.query',
            )['params']
            as List;
    expect(p.first, [
      [
        'attributes.dtype',
        'in',
        ['DISK', 'RAW'],
      ],
    ]);
    expect((p.last as Map)['select'], ['id', 'attributes']);
    expect(h.wire.writes, isEmpty);
  });
  test('disconnected never sends storage RPC', () async {
    final h = _Harness();
    addTearDown(h.repo.close);
    expect(h.repo.zvolCapabilities.supported, isFalse);
    await expectLater(
      h.repo.loadZvols(),
      throwsA(_reason(ZvolExceptionReason.notAuthenticated)),
    );
    expect(h.wire.requests, isEmpty);
  });
  for (final version in ['25.04.1', '25.10-BETA.1', '26.0.0']) {
    test('unsupported $version cannot load or mutate', () async {
      final h = await _connect(version: version);
      await expectLater(
        h.repo.loadZvols(),
        throwsA(_reason(ZvolExceptionReason.unsupportedVersion)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final missing in [
    'vm.device.query',
    'iscsi.extent.query',
    'nvmet.namespace.query',
    'pool.dataset.attachments',
  ]) {
    test(
      'missing $missing keeps read inventory but blocks management',
      () async {
        final h = await _connect(methods: _methods.difference({missing}));
        final i = await h.repo.loadZvols();
        expect(i.volumes.single.id, 'tank/disk');
        expect(h.repo.zvolCapabilities.canCreate, isFalse);
        expect(h.repo.zvolCapabilities.canUpdate, isFalse);
        await expectLater(
          h.repo.reviewZvolDelete(i.volumes.single),
          throwsA(_reason(ZvolExceptionReason.unavailableMethod)),
        );
        expect(h.wire.writes, isEmpty);
      },
    );
  }
  test('inventory is bounded immutable and does not write', () async {
    final h = await _connect();
    final i = await h.repo.loadZvols();
    expect(i.parents.single.availableBytes, 100 * _gib);
    expect(i.volumes.single.provisioning, 'Thin');
    expect(() => i.volumes.clear(), throwsUnsupportedError);
    final params = h.wire.requests.last['params'] as List;
    expect(params.first, [
      [
        'type',
        'in',
        ['FILESYSTEM', 'VOLUME'],
      ],
    ]);
    expect((params.last as Map)['limit'], 1025);
    expect(
      (params.last as Map)['select'],
      contains(equals(['user_properties.managedby', 'managedby'])),
    );
    expect(
      ((params.last as Map)['extra'] as Map)['retrieve_children'],
      isFalse,
    );
    expect(h.wire.writes, isEmpty);
  });
  for (final thin in [true, false]) {
    test(
      'create ${thin ? 'thin' : 'reserved'} exact unencrypted nonrecursive volume and readback',
      () async {
        final h = await _connect();
        final review = await _create(h, thin: thin);
        expect(h.wire.writes, isEmpty);
        final result = await h.repo.executeZvolReview(review, review.target);
        expect(result.outcome, ZvolOutcome.verified);
        final args = (h.wire.writes.single['params'] as List).single as Map;
        expect(args, containsPair('type', 'VOLUME'));
        expect(args, containsPair('force_size', false));
        expect(args, containsPair('create_ancestors', false));
        expect(args, containsPair('sparse', thin));
        expect(args, containsPair('encryption', false));
        expect(args.containsKey('encryption_options'), isFalse);
        await expectLater(
          h.repo.executeZvolReview(review, review.target),
          throwsA(_reason(ZvolExceptionReason.stale)),
        );
        expect(h.wire.writes.length, 1);
      },
    );
  }
  test('grow thin volume updates exact size without suppressing ZFS reservation calculation', () async {
    final h = await _connect();
    final review = await _grow(h);
    final result = await h.repo.executeZvolReview(review, review.target);
    expect(result.outcome, ZvolOutcome.verified);
    expect((h.wire.writes.single['params'] as List).last, {
      'volsize': 20 * _gib,
    });
  });
  for (final reservation in [_gib, 10 * _gib, 11 * _gib]) {
    test(
      'growth with $reservation reserved bytes is blocked without releasing space',
      () async {
        final h = await _connect();
        h.wire.rows.last['refreservation'] = _prop(reservation);
        await expectLater(
          _grow(h),
          throwsA(_reason(ZvolExceptionReason.invalid)),
        );
        expect(h.wire.writes, isEmpty);
      },
    );
  }
  test(
    'settings keep size block size encryption and reservations unchanged',
    () async {
      final h = await _connect();
      final v = (await h.repo.loadZvols()).volumes.single;
      final review = await h.repo.reviewZvolUpdate(
        ZvolUpdate(
          volume: v,
          compression: 'ZSTD',
          sync: 'ALWAYS',
          readonly: true,
        ),
      );
      expect(
        (await h.repo.executeZvolReview(review, review.target)).outcome,
        ZvolOutcome.verified,
      );
      expect((h.wire.writes.single['params'] as List).last, {
        'compression': 'ZSTD',
        'sync': 'ALWAYS',
        'readonly': 'ON',
      });
    },
  );
  test(
    'delete refuses recursive force and independently verifies absence',
    () async {
      final h = await _connect();
      final v = (await h.repo.loadZvols()).volumes.single;
      final review = await h.repo.reviewZvolDelete(v);
      expect(
        (await h.repo.executeZvolReview(review, review.target)).outcome,
        ZvolOutcome.verified,
      );
      expect(h.wire.writes.single['params'], [
        'tank/disk',
        {'recursive': false, 'force': false},
      ]);
    },
  );
  for (final size in [-1, 0, 1025, 9007199254740992, 81 * _gib]) {
    test('invalid or excessive create size $size cannot dispatch', () async {
      final h = await _connect();
      final p = (await h.repo.loadZvols()).parents.single;
      final request = ZvolCreate(parent: p, name: 'bad_disk', sizeBytes: size);
      expect(request.validationError, isNotNull);
      await expectLater(
        h.repo.reviewZvolCreate(request),
        throwsA(_reason(ZvolExceptionReason.invalid)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test(
    'shrink and partial reservation growth are rejected before dispatch',
    () async {
      final h = await _connect();
      var v = (await h.repo.loadZvols()).volumes.single;
      await expectLater(
        h.repo.reviewZvolUpdate(ZvolUpdate(volume: v, sizeBytes: _gib)),
        throwsA(_reason(ZvolExceptionReason.invalid)),
      );
      h.wire.rows.last['refreservation'] = _prop(_gib);
      v = (await h.repo.loadZvols()).volumes.single;
      await expectLater(
        h.repo.reviewZvolUpdate(ZvolUpdate(volume: v, sizeBytes: 20 * _gib)),
        throwsA(_reason(ZvolExceptionReason.invalid)),
      );
      expect(h.wire.writes, isEmpty);
    },
  );
  for (final source in [
    'encrypted',
    'managed',
    'readonly-parent',
    'clone',
    'mountpoint',
  ]) {
    test('$source blocks editable storage', () async {
      final h = await _connect();
      switch (source) {
        case 'encrypted':
          h.wire.rows.last['encrypted'] = true;
        case 'managed':
          (h.wire.rows.last['user_properties'] as Map)['managedby'] = _prop(
            'service',
          );
        case 'readonly-parent':
          h.wire.rows.first['readonly'] = _prop('on');
        case 'clone':
          h.wire.rows.last['origin'] = _prop('tank/base@snap', source: 'NONE');
        case 'mountpoint':
          h.wire.rows.last['mountpoint'] = '/tmp/other';
      }
      final v = (await h.repo.loadZvols()).volumes.single;
      expect(v.editable, isFalse);
      await expectLater(
        h.repo.reviewZvolDelete(v),
        throwsA(_reason(ZvolExceptionReason.invalid)),
      );
    });
  }
  test('forged and stale inventory or review handles are rejected', () async {
    final h = await _connect();
    final i = await h.repo.loadZvols();
    final fake = ZvolParent(
      id: i.parents.single.id,
      guid: i.parents.single.guid,
      availableBytes: 100 * _gib,
    );
    await expectLater(
      h.repo.reviewZvolCreate(
        ZvolCreate(parent: fake, name: 'x', sizeBytes: _gib),
      ),
      throwsA(_reason(ZvolExceptionReason.stale)),
    );
    final review = await _create(h);
    final forged = ZvolReview(
      action: review.action,
      target: review.target,
      identity: review.identity,
      changes: review.changes,
      warnings: review.warnings,
    );
    await expectLater(
      h.repo.executeZvolReview(forged, forged.target),
      throwsA(_reason(ZvolExceptionReason.stale)),
    );
    await h.repo.loadZvols();
    await expectLater(
      h.repo.executeZvolReview(review, review.target),
      throwsA(_reason(ZvolExceptionReason.stale)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test('wrong exact confirmation consumes review without write', () async {
    final h = await _connect();
    final review = await _create(h);
    await expectLater(
      h.repo.executeZvolReview(review, 'NEW_DISK'),
      throwsA(_reason(ZvolExceptionReason.stale)),
    );
    await expectLater(
      h.repo.executeZvolReview(review, review.target),
      throwsA(_reason(ZvolExceptionReason.stale)),
    );
    expect(h.wire.writes, isEmpty);
  });
  for (final drift in [
    'target-guid',
    'parent-guid',
    'compression',
    'capacity',
    'recommendation',
    'new-name',
  ]) {
    test('fresh $drift drift prevents reviewed mutation', () async {
      final h = await _connect();
      final creating = drift == 'recommendation' || drift == 'new-name';
      final review = creating ? await _create(h) : await _grow(h);
      switch (drift) {
        case 'target-guid':
          h.wire.rows.last['guid'] = _prop('999');
        case 'parent-guid':
          h.wire.rows.first['guid'] = _prop('999');
        case 'compression':
          h.wire.rows.last['compression'] = _prop('off');
        case 'capacity':
          h.wire.rows.first['available'] = _prop(0);
        case 'recommendation':
          h.wire.recommendation = '128K';
        case 'new-name':
          h.wire.rows.add(_row('tank/new_disk', volume: true, guid: '999'));
      }
      expect(
        (await h.repo.executeZvolReview(review, review.target)).outcome,
        ZvolOutcome.rejected,
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final dependency in ['vm', 'iscsi', 'nvme', 'attachment', 'snapshot']) {
    test(
      '$dependency dependency blocks deletion even if consumer disabled',
      () async {
        final h = await _connect();
        final v = (await h.repo.loadZvols()).volumes.single;
        switch (dependency) {
          case 'vm':
            h.wire.vm = [
              {
                'id': 1,
                'attributes': {'dtype': 'DISK', 'path': '/dev/zvol/tank/disk'},
              },
            ];
          case 'iscsi':
            h.wire.iscsi = [
              {
                'id': 1,
                'type': 'DISK',
                'disk': 'zvol/tank/disk',
                'enabled': false,
              },
            ];
          case 'nvme':
            h.wire.nvme = [
              {
                'id': 1,
                'device_type': 'ZVOL',
                'device_path': 'zvol/tank/disk',
                'enabled': false,
              },
            ];
          case 'attachment':
            h.wire.attachments = [
              {
                'type': 'VM',
                'attachments': ['disk'],
              },
            ];
          case 'snapshot':
            h.wire.snapshots = [
              {'id': 'tank/disk@snap'},
            ];
        }
        await expectLater(
          h.repo.reviewZvolDelete(v),
          throwsA(_reason(ZvolExceptionReason.dependency)),
        );
        expect(h.wire.writes, isEmpty);
      },
    );
  }
  test('attachment appearing after review prevents dispatch', () async {
    final h = await _connect();
    final review = await _grow(h);
    h.wire.nvme = [
      {
        'id': 1,
        'device_type': 'ZVOL',
        'device_path': 'zvol/tank/disk',
        'enabled': false,
      },
    ];
    expect(
      (await h.repo.executeZvolReview(review, review.target)).outcome,
      ZvolOutcome.rejected,
    );
    expect(h.wire.writes, isEmpty);
  });
  for (final fault in [
    'error',
    'timeout',
    'receipt',
    'post-guid',
    'post-property',
    'post-read',
  ]) {
    test('$fault after sending is unknown and never replayed', () async {
      final h = await _connect();
      final review = await _grow(h);
      h.wire.fault = fault;
      final result = await h.repo.executeZvolReview(review, review.target);
      expect(result.outcome, ZvolOutcome.unknown);
      expect(result.message, isNot(contains('remote-secret')));
      await expectLater(
        h.repo.executeZvolReview(review, review.target),
        throwsA(_reason(ZvolExceptionReason.busy)),
      );
      expect(h.wire.writes.length, 1);
    });
  }
  test('unknown Zvol operation holds shared SDK mutation guard', () async {
    final h = await _connect();
    final review = await _grow(h);
    h.wire.fault = 'receipt';
    await h.repo.executeZvolReview(review, review.target);
    await expectLater(
      h.repo.execute(
        const CreateDatasetCommand(parent: 'tank', name: 'not_sent'),
      ),
      throwsA(
        isA<ManagementException>().having(
          (e) => e.reason,
          'reason',
          ManagementExceptionReason.busy,
        ),
      ),
    );
    expect(h.wire.writes.length, 1);
  });
  test('expired original session cannot dispatch', () async {
    final h = await _connect();
    final review = await _grow(h);
    h.current = false;
    await expectLater(
      h.repo.executeZvolReview(review, review.target),
      throwsA(_reason(ZvolExceptionReason.notAuthenticated)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test('inventory truncation duplicate IDs and malformed dependency rows fail closed', () async {
    final h = await _connect();
    h.wire.rows.add(h.wire.rows.last);
    await expectLater(
      h.repo.loadZvols(),
      throwsA(_reason(ZvolExceptionReason.invalid)),
    );
    h.wire.rows.removeLast();
    final v = (await h.repo.loadZvols()).volumes.single;
    h.wire.vm = [
      {
        'id': 1,
        'dtype': 'DISPLAY',
        'attributes': {'password': 'private'},
      },
    ];
    await expectLater(
      h.repo.reviewZvolDelete(v),
      throwsA(_reason(ZvolExceptionReason.invalid)),
    );
    expect(h.wire.writes, isEmpty);
  });
}

Future<_Harness> _connect({
  String version = '25.10.1',
  Set<String> methods = _methods,
}) async {
  final h = _Harness(version: version, methods: methods);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://fixture.invalid',
    apiKey: 'fake-key',
    username: 'admin',
    isConnectionCurrent: () => h.current,
  );
  return h;
}

class _Harness {
  _Harness({String version = '25.10.1', Set<String> methods = _methods}) {
    wire = _Wire(version, methods);
    repo = TrueNasSessionRepository(
      connector: _Connector(wire),
      managementRequestTimeout: const Duration(milliseconds: 40),
    );
  }
  bool current = true;
  late final _Wire wire;
  late final TrueNasSessionRepository repo;
}

class _Connector implements RpcConnector {
  _Connector(this.wire);
  final RpcTransport wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class _Wire implements RpcTransport {
  _Wire(this.version, this.methods);
  final String version;
  final Set<String> methods;
  final inbound = StreamController<String>();
  final requests = <Map<String, Object?>>[];
  final rows = <Map<String, Object?>>[
    _row('tank', guid: '1'),
    _row('tank/disk', volume: true, guid: '2'),
  ];
  List<Map<String, Object?>> vm = [],
      iscsi = [],
      nvme = [],
      attachments = [],
      snapshots = [];
  String recommendation = '16K';
  String? fault;
  Iterable<Map<String, Object?>> get writes => requests.where(
    (r) => const {
      'pool.dataset.create',
      'pool.dataset.update',
      'pool.dataset.delete',
    }.contains(r['method']),
  );
  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String frame) async {
    final r = Map<String, Object?>.from(jsonDecode(frame) as Map);
    requests.add(r);
    final args = r['params'] as List? ?? [];
    Object? result;
    switch (r['method']) {
      case 'auth.login_ex':
        result = {'response_type': 'SUCCESS'};
      case 'auth.me':
        result = {'username': 'admin'};
      case 'system.info':
        result = {'version': version};
      case 'core.get_methods':
        result = {
          for (final m in methods)
            m: {'accepts': [], 'returns': [], 'job': false},
        };
      case 'pool.dataset.query':
        result = fault == 'post-read' && writes.isNotEmpty
            ? 'remote-secret'
            : [
                for (final row in rows)
                  {
                    ...row,
                    'managedby': (row['user_properties'] as Map)['managedby'],
                  },
              ];
      case 'pool.dataset.recommended_zvol_blocksize':
        result = recommendation;
      case 'pool.dataset.attachments':
        result = attachments;
      case 'vm.device.query':
        result = vm;
      case 'iscsi.extent.query':
        result = iscsi;
      case 'nvmet.namespace.query':
        result = nvme;
      case 'pool.snapshot.query':
        result = snapshots;
      case 'pool.dataset.create':
      case 'pool.dataset.update':
      case 'pool.dataset.delete':
        if (fault == 'timeout') return;
        if (fault == 'error') {
          inbound.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': r['id'],
              'error': {'code': -32001, 'message': 'remote-secret'},
            }),
          );
          return;
        }
        if (r['method'] == 'pool.dataset.delete') {
          rows.removeWhere((row) => row['id'] == args.first);
          result = true;
        } else if (r['method'] == 'pool.dataset.create') {
          final p = args.single as Map;
          final row = _row(p['name'] as String, volume: true, guid: '3');
          for (final key in [
            'volsize',
            'compression',
            'sync',
            'readonly',
            'snapdev',
          ]) {
            row[key] = _prop(p[key].toString().toLowerCase());
          }
          row['volblocksize'] = _prop(zvolBlockSizes[p['volblocksize']]!);
          row['refreservation'] = _prop(
            p['sparse'] == true ? 0 : (p['volsize'] as int) + 1024 * 1024,
          );
          rows.add(row);
          result = {'id': row['id'], 'type': row['type']};
        } else {
          final row = rows.singleWhere((row) => row['id'] == args.first);
          for (final e in (args.last as Map).entries) {
            row[e.key as String] = _prop(e.value.toString().toLowerCase());
          }
          result = {'id': row['id'], 'type': row['type']};
        }
        if (fault == 'receipt') result = 123;
        if (fault == 'post-guid') rows.last['guid'] = _prop('999');
        if (fault == 'post-property') rows.last['snapdev'] = _prop('visible');
    }
    inbound.add(
      jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() => inbound.close();
}
