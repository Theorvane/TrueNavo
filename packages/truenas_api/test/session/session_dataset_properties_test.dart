import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _methods = {
  'pool.dataset.query',
  'pool.dataset.update',
  'pool.dataset.attachments',
  'pool.dataset.create',
};
Map<String, Object?> _prop(
  String raw, {
  String source = 'LOCAL',
  String? from,
}) => {
  'rawvalue': raw,
  'value': raw.toUpperCase(),
  'parsed': int.tryParse(raw) ?? raw,
  'source': source,
  'source_info': from,
};
Map<String, Object?> _row(String id, {String guid = '123'}) => {
  'id': id,
  'name': id,
  'type': 'FILESYSTEM',
  'encrypted': false,
  'locked': false,
  'mountpoint': '/mnt/$id',
  'guid': _prop(guid),
  'filesystem_count': _prop(id == 'tank' ? '1' : '0'),
  'creation': _prop('1720000000'),
  'acltype': _prop('nfsv4'),
  'aclmode': _prop('passthrough'),
  'used': _prop('1073741824'),
  'referenced': _prop('536870912'),
  'available': _prop('10737418240'),
  for (final key in datasetByteProperties) key: _prop('0', source: 'DEFAULT'),
  'compression': _prop('lz4'),
  'atime': _prop('off'),
  'readonly': _prop('off'),
};
Matcher _reason(DatasetPropertiesExceptionReason reason) =>
    isA<DatasetPropertiesException>().having((e) => e.reason, 'reason', reason);
void main() {
  test(
    'managed marker is projected from real nested user properties',
    () async {
      final h = await _connect();
      h.transport.rows.last['user_properties'] = {
        'managedby': _prop('external-manager'),
      };
      final values = await h.repo.loadDatasetProperties();
      expect(values.last.editable, isFalse);
      final options = (h.transport.requests.last['params'] as List).last as Map;
      expect(
        options['select'],
        contains(equals(['user_properties.managedby', 'managedby'])),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test(
    'disconnected capability and API fail before sending anything',
    () async {
      final h = _Harness();
      addTearDown(h.repo.close);
      expect(h.repo.datasetPropertiesCapabilities.connected, isFalse);
      await expectLater(
        h.repo.loadDatasetProperties(),
        throwsA(_reason(DatasetPropertiesExceptionReason.notAuthenticated)),
      );
      expect(h.transport.requests, isEmpty);
    },
  );
  for (final version in ['25.04.2', '25.10-BETA', '26.0.1']) {
    test('unsupported release $version cannot load properties', () async {
      final h = await _connect(version: version);
      expect(h.repo.datasetPropertiesCapabilities.supported, isFalse);
      await expectLater(
        h.repo.loadDatasetProperties(),
        throwsA(_reason(DatasetPropertiesExceptionReason.unsupportedVersion)),
      );
    });
  }
  for (final method in _methods.difference({'pool.dataset.create'})) {
    test('missing $method gates capability', () async {
      final h = await _connect(methods: _methods.difference({method}));
      expect(h.repo.datasetPropertiesCapabilities.supported, isFalse);
    });
  }
  test('flat discovery uses a nonempty filesystem filter, exact props and bounded limit', () async {
    final h = await _connect();
    final list = await h.repo.loadDatasetProperties();
    expect(list.length, 2);
    expect(list.first.editable, isFalse);
    expect(list.last.editable, isTrue);
    expect(list.last.properties['quota']!.value, 0);
    expect(() => list.clear(), throwsUnsupportedError);
    expect(() => list.last.properties.clear(), throwsUnsupportedError);
    final args = h.transport.requests.last['params'] as List;
    expect(args[0], [
      [
        'type',
        'in',
        ['FILESYSTEM', 'VOLUME'],
      ],
    ]);
    final options = args[1] as Map;
    expect(options['limit'], 1025);
    expect((options['extra'] as Map)['retrieve_children'], isFalse);
    expect(
      (options['extra'] as Map)['properties'],
      containsAll(['guid', 'referenced', 'quota']),
    );
    expect(h.transport.writes, isEmpty);
  });
  for (final field in [
    'guid',
    'used',
    'quota',
    'compression',
    'readonly',
    'creation',
    'acltype',
  ]) {
    test('missing $field prevents unverified inventory', () async {
      final h = await _connect();
      h.transport.rows.last.remove(field);
      await expectLater(
        h.repo.loadDatasetProperties(),
        throwsA(_reason(DatasetPropertiesExceptionReason.invalidResponse)),
      );
      expect(h.transport.writes, isEmpty);
    });
  }
  for (final changes in <Map<String, Object>>[
    {'quota': -1},
    {'quota': 1},
    {'refquota': 'INHERIT'},
    {'reservation': 'INHERIT'},
    {'quota': 9007199254740992},
    {'compression': 'EVIL'},
    {'compression': 'ZSTD-FAST-1'},
    {'encryption': true},
    {'mountpoint': '/tmp'},
    {'acltype': 'OFF'},
    {},
  ]) {
    test('invalid or out of scope changes $changes never write', () async {
      final h = await _connect();
      final s = (await h.repo.loadDatasetProperties()).last;
      final request = DatasetPropertyUpdate(snapshot: s, changes: changes);
      expect(request.validationError, isNotNull);
      await expectLater(
        h.repo.updateDatasetProperties(request),
        throwsA(_reason(DatasetPropertiesExceptionReason.invalidRequest)),
      );
      expect(h.transport.writes, isEmpty);
    });
  }
  test(
    'quota reservation dependencies and available capacity are validated',
    () async {
      final h = await _connect();
      final s = (await h.repo.loadDatasetProperties()).last;
      for (final changes in <Map<String, Object>>[
        {'quota': 1073741824, 'reservation': 2147483648},
        {'refquota': 1073741824, 'refreservation': 2147483648},
        {'reservation': 21474836480},
      ]) {
        expect(
          DatasetPropertyUpdate(snapshot: s, changes: changes).validationError,
          isNotNull,
        );
      }
    },
  );
  test(
    'only changes are sent and response is independently read back',
    () async {
      final h = await _connect();
      final s = (await h.repo.loadDatasetProperties()).last;
      final result = await h.repo.updateDatasetProperties(
        DatasetPropertyUpdate(
          snapshot: s,
          changes: {'quota': 2147483648, 'compression': 'ZSTD-3'},
        ),
      );
      expect(result.outcome, DatasetPropertyOutcome.verified);
      expect(h.transport.writes.single['params'], [
        'tank/data',
        {'quota': 2147483648, 'compression': 'ZSTD-3'},
      ]);
      expect(h.transport.requests.last['method'], 'pool.dataset.query');
    },
  );
  test(
    'inherit resolves parent effective value and verifies nonlocal source',
    () async {
      final h = await _connect();
      h.transport.rows.first['compression'] = _prop('zstd');
      final s = (await h.repo.loadDatasetProperties()).last;
      final result = await h.repo.updateDatasetProperties(
        DatasetPropertyUpdate(snapshot: s, changes: {'compression': 'INHERIT'}),
      );
      expect(result.outcome, DatasetPropertyOutcome.verified);
      expect(h.transport.writes.single['params'], [
        'tank/data',
        {'compression': 'INHERIT'},
      ]);
    },
  );
  test('reload invalidates an old reviewed object', () async {
    final h = await _connect();
    final s = (await h.repo.loadDatasetProperties()).last;
    await h.repo.loadDatasetProperties();
    await expectLater(
      h.repo.updateDatasetProperties(
        DatasetPropertyUpdate(snapshot: s, changes: {'atime': 'ON'}),
      ),
      throwsA(_reason(DatasetPropertiesExceptionReason.staleSnapshot)),
    );
    expect(h.transport.writes, isEmpty);
  });
  for (final drift in ['target', 'parent', 'guid', 'acl', 'descendant']) {
    test('$drift drift rejects before update', () async {
      final h = await _connect();
      final s = (await h.repo.loadDatasetProperties()).last;
      switch (drift) {
        case 'target':
          h.transport.rows.last['atime'] = _prop('on');
        case 'parent':
          h.transport.rows.first['compression'] = _prop('zstd');
        case 'guid':
          h.transport.rows.last['guid'] = _prop('999');
        case 'acl':
          h.transport.rows.last['aclmode'] = _prop('restricted');
        case 'descendant':
          h.transport.rows.add(_row('tank/data/child', guid: '999'));
      }
      final result = await h.repo.updateDatasetProperties(
        DatasetPropertyUpdate(snapshot: s, changes: {'quota': 2147483648}),
      );
      expect(result.outcome, DatasetPropertyOutcome.rejected);
      expect(h.transport.writes, isEmpty);
    });
  }
  test('capacity is revalidated after review without treating telemetry as config drift', () async {
    final h = await _connect();
    final s = (await h.repo.loadDatasetProperties()).last;
    h.transport.rows.last['used'] = _prop('3221225472');
    final result = await h.repo.updateDatasetProperties(
      DatasetPropertyUpdate(snapshot: s, changes: {'quota': 2147483648}),
    );
    expect(result.outcome, DatasetPropertyOutcome.rejected);
    expect(h.transport.writes, isEmpty);
  });
  test('readonly checks attachments and blocks attached datasets', () async {
    final h = await _connect();
    h.transport.attachments = [
      {
        'type': 'SMB Share',
        'attachments': ['media'],
      },
    ];
    final s = (await h.repo.loadDatasetProperties()).last;
    final result = await h.repo.updateDatasetProperties(
      DatasetPropertyUpdate(snapshot: s, changes: {'readonly': 'ON'}),
    );
    expect(result.outcome, DatasetPropertyOutcome.rejected);
    expect(h.transport.writes, isEmpty);
  });
  test('leaf readonly change checks twice and verifies state', () async {
    final h = await _connect();
    final s = (await h.repo.loadDatasetProperties()).last;
    final result = await h.repo.updateDatasetProperties(
      DatasetPropertyUpdate(snapshot: s, changes: {'readonly': 'ON'}),
    );
    expect(result.outcome, DatasetPropertyOutcome.verified);
    expect(
      h.transport.requests.where(
        (r) => r['method'] == 'pool.dataset.attachments',
      ),
      hasLength(1),
    );
  });
  test('inherited behavior changes with descendants are blocked', () async {
    final h = await _connect();
    h.transport.rows.add(_row('tank/data/child', guid: '999'));
    final s = (await h.repo.loadDatasetProperties())[1];
    expect(
      DatasetPropertyUpdate(
        snapshot: s,
        changes: {'compression': 'ZSTD'},
      ).validationError,
      isNotNull,
    );
  });
  for (final special in [
    'encrypted',
    'locked',
    'mountpoint',
    'managedby',
    'internal',
  ]) {
    test('$special datasets are visibly blocked', () async {
      final h = await _connect();
      final row = h.transport.rows.last;
      if (special == 'encrypted' || special == 'locked') {
        row[special] = true;
      }
      if (special == 'mountpoint') {
        row['mountpoint'] = '/elsewhere';
      }
      if (special == 'managedby') {
        row['managedby'] = _prop('application');
      }
      if (special == 'internal') {
        row['id'] = 'tank/ix-apps';
        row['mountpoint'] = '/mnt/tank/ix-apps';
      }
      expect((await h.repo.loadDatasetProperties()).last.editable, isFalse);
    });
  }
  for (final failure in ['timeout', 'mismatch', 'error']) {
    test(
      'post-send $failure is unknown, never retried, and holds shared mutation gate',
      () async {
        final h = await _connect();
        final s = (await h.repo.loadDatasetProperties()).last;
        h.transport.failure = failure;
        final request = DatasetPropertyUpdate(
          snapshot: s,
          changes: {'atime': 'ON'},
        );
        final result = await h.repo.updateDatasetProperties(request);
        expect(result.outcome, DatasetPropertyOutcome.unknown);
        expect(h.transport.writes, hasLength(1));
        await expectLater(
          h.repo.updateDatasetProperties(request),
          throwsA(_reason(DatasetPropertiesExceptionReason.busy)),
        );
        await expectLater(
          h.repo.execute(
            const CreateDatasetCommand(parent: 'tank', name: 'new'),
          ),
          throwsA(
            isA<ManagementException>().having(
              (e) => e.reason,
              'reason',
              ManagementExceptionReason.busy,
            ),
          ),
        );
      },
    );
  }
  test(
    'volume descendants prevent false leaf edits and remain in drift checks',
    () async {
      final h = await _connect();
      final before = (await h.repo.loadDatasetProperties()).last;
      final volume = _row('tank/data/disk', guid: '888')
        ..['type'] = 'VOLUME'
        ..['mountpoint'] = null;
      for (final key in ['atime', 'quota', 'refquota', 'acltype', 'aclmode']) {
        volume.remove(key);
      }
      h.transport.rows.add(volume);
      final staleResult = await h.repo.updateDatasetProperties(
        DatasetPropertyUpdate(
          snapshot: before,
          changes: {'compression': 'ZSTD'},
        ),
      );
      expect(staleResult.outcome, DatasetPropertyOutcome.rejected);
      final snapshots = await h.repo.loadDatasetProperties();
      expect(
        snapshots,
        hasLength(2),
      ); // Volumes are guarded, not filesystem editors.
      final parent = snapshots.last;
      expect(parent.descendants, ['tank/data/disk']);
      for (final changes in [
        {'compression': 'ZSTD'},
        {'readonly': 'ON'},
        {'atime': 'INHERIT'},
      ]) {
        final request = DatasetPropertyUpdate(
          snapshot: parent,
          changes: changes,
        );
        expect(request.validationError, isNotNull);
        await expectLater(
          h.repo.updateDatasetProperties(request),
          throwsA(_reason(DatasetPropertiesExceptionReason.invalidRequest)),
        );
      }
      expect(h.transport.writes, isEmpty);
    },
  );
  test(
    'unsupported existing compression blocks one row without losing inventory',
    () async {
      final h = await _connect();
      h.transport.rows.last['compression'] = _prop('gzip-5');
      final rows = await h.repo.loadDatasetProperties();
      expect(rows, hasLength(2));
      expect(rows.last.editable, isFalse);
      expect(rows.last.properties['compression']!.value, 'GZIP-5');
    },
  );
  test(
    'unknown or hidden descendant count prevents false leaf behavior changes',
    () async {
      final h = await _connect();
      for (final raw in [
        null,
        _prop('none'),
        _prop('18446744073709551615'),
        _prop('1'),
      ]) {
        h.transport.rows.last['filesystem_count'] = raw;
        final s = (await h.repo.loadDatasetProperties()).last;
        expect(s.verifiedLeaf, isFalse);
        expect(
          DatasetPropertyUpdate(
            snapshot: s,
            changes: {'compression': 'ZSTD'},
          ).validationError,
          isNotNull,
        );
        expect(
          DatasetPropertyUpdate(
            snapshot: s,
            changes: {'quota': 2147483648},
          ).validationError,
          isNull,
        );
      }
      expect(h.transport.writes, isEmpty);
    },
  );
  test('latest capacity observed after attachments prevents combined readonly quota write', () async {
    final h = await _connect();
    final s = (await h.repo.loadDatasetProperties()).last;
    h.transport.onAttachments = () {
      h.transport.rows.last['used'] = _prop('3221225472');
    };
    final result = await h.repo.updateDatasetProperties(
      DatasetPropertyUpdate(
        snapshot: s,
        changes: {'readonly': 'ON', 'quota': 2147483648},
      ),
    );
    expect(result.outcome, DatasetPropertyOutcome.rejected);
    expect(h.transport.writes, isEmpty);
  });
  test('unrelated inherited provenance cannot be used as a baseline', () async {
    final h = await _connect();
    h.transport.rows.last['compression'] = _prop(
      'lz4',
      source: 'INHERITED',
      from: 'other/pool',
    );
    await expectLater(
      h.repo.loadDatasetProperties(),
      throwsA(_reason(DatasetPropertiesExceptionReason.invalidResponse)),
    );
    expect(h.transport.writes, isEmpty);
  });
  test('simultaneous writes reject duplicate submission', () async {
    final h = await _connect();
    final s = (await h.repo.loadDatasetProperties()).last;
    h.transport.failure = 'timeout';
    final request = DatasetPropertyUpdate(
      snapshot: s,
      changes: {'atime': 'ON'},
    );
    final pending = h.repo.updateDatasetProperties(request);
    await expectLater(
      h.repo.updateDatasetProperties(request),
      throwsA(_reason(DatasetPropertiesExceptionReason.busy)),
    );
    await pending;
    expect(h.transport.writes, hasLength(1));
  });
}

Future<_Harness> _connect({
  String version = '25.10.1',
  Set<String> methods = _methods,
}) async {
  final h = _Harness(version: version, methods: methods);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'fixture-key',
    username: 'admin',
  );
  return h;
}

class _Harness {
  _Harness({String version = '25.10.1', Set<String> methods = _methods}) {
    transport = _Transport(version, methods);
    repo = TrueNasSessionRepository(
      connector: _Connector(transport),
      managementRequestTimeout: const Duration(milliseconds: 50),
    );
  }
  late final _Transport transport;
  late final TrueNasSessionRepository repo;
}

class _Connector implements RpcConnector {
  _Connector(this.transport);
  final RpcTransport transport;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => transport;
}

class _Transport implements RpcTransport {
  _Transport(this.version, this.methods);
  final String version;
  final Set<String> methods;
  final inbound = StreamController<String>();
  final requests = <Map<String, Object?>>[];
  final rows = [_row('tank', guid: '100'), _row('tank/data')];
  List<Object?> attachments = [];
  void Function()? onAttachments;
  String? failure;
  Iterable<Map<String, Object?>> get writes =>
      requests.where((r) => r['method'] == 'pool.dataset.update');
  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String frame) async {
    final r = Map<String, Object?>.from(jsonDecode(frame) as Map);
    requests.add(r);
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
            m: {
              'accepts': <Object?>[],
              'returns': <Object?>[],
              'job': false,
              'no_auth_required': false,
            },
        };
      case 'pool.dataset.query':
        result = [
          for (final row in rows)
            {
              ...row,
              if (row['user_properties'] is Map)
                'managedby': (row['user_properties'] as Map)['managedby'],
            },
        ];
      case 'pool.dataset.attachments':
        onAttachments?.call();
        result = attachments;
      case 'pool.dataset.update':
        if (failure == 'timeout') return;
        if (failure == 'error') {
          inbound.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': r['id'],
              'error': {'code': -32001, 'message': 'private-secret'},
            }),
          );
          return;
        }
        if (failure != 'mismatch') {
          final params = r['params'] as List;
          final row = rows.firstWhere((item) => item['id'] == params[0]);
          for (final entry in (params[1] as Map).entries) {
            final parent = rows.first;
            row[entry.key as String] = entry.value == 'INHERIT'
                ? _prop(
                    (parent[entry.key] as Map)['rawvalue'] as String,
                    source: 'INHERITED',
                    from: parent['id'] as String,
                  )
                : _prop(entry.value.toString().toLowerCase());
          }
        }
        result = rows.last;
    }
    inbound.add(
      jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() async {
    await inbound.close();
  }
}
