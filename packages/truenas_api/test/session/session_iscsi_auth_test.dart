import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _secret = 'fixture-chap-secret-never-exposed';

void main() {
  test('parser retains only references and rejects incomplete responses', () {
    final inventory = IscsiAuthInventory.parse([
      {
        'id': 3,
        'tag': 9,
        'user': 'client-user',
        'peeruser': 'target-user',
        'discovery_auth': 'CHAP_MUTUAL',
        'secret': _secret,
        'peersecret': _secret,
      },
    ], DateTime.parse('2026-01-01T09:00:00+09:00'));
    expect(inventory.references.single.tag, 9);
    expect(inventory.references.single.peerUser, 'target-user');
    expect(inventory.observedAt.isUtc, isTrue);
    expect(inventory.references.single.toString(), isNot(contains(_secret)));
    expect(() => inventory.references.clear(), throwsUnsupportedError);
    expect(
      () => IscsiAuthInventory.parse([
        {'id': 1},
      ], DateTime.utc(2026)),
      throwsFormatException,
    );
    expect(
      () => IscsiAuthInventory.parse(
        List.filled(101, {'id': 1}),
        DateTime.utc(2026),
      ),
      throwsFormatException,
    );
  });

  test(
    'dedicated wire request selects references and discards extra secrets',
    () async {
      final wire = _Wire();
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      final references = await repo.loadIscsiAuthReferences();
      expect(references.references.single.user, 'client-user');
      expect(references.toString(), isNot(contains(_secret)));
      final query = wire.requests.singleWhere(
        (r) => r['method'] == 'iscsi.auth.query',
      );
      final options = (query['params'] as List)[1] as Map;
      expect(options['select'], [
        'id',
        'tag',
        'user',
        'peeruser',
        'discovery_auth',
      ]);
      expect(options['select'], isNot(contains('secret')));
      expect(options['limit'], 101);
      expect(
        () => repo.query('iscsi.auth.query'),
        throwsA(isA<SessionQueryException>()),
      );
      expect(repo.adminCatalog.method('iscsi.auth.query')?.supported, isFalse);
    },
  );

  test('unadvertised method sends no authentication query', () async {
    final wire = _Wire(advertiseAuth: false);
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    await repo.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    await expectLater(
      repo.loadIscsiAuthReferences(),
      throwsA(isA<IscsiAuthException>()),
    );
    expect(
      wire.requests.where((r) => r['method'] == 'iscsi.auth.query'),
      isEmpty,
    );
  });

  test(
    'malformed secret-bearing result fails without returning raw data',
    () async {
      final wire = _Wire()..malformed = true;
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      await expectLater(
        repo.loadIscsiAuthReferences(),
        throwsA(
          isA<IscsiAuthException>().having(
            (e) => e.userMessage,
            'userMessage',
            isNot(contains(_secret)),
          ),
        ),
      );
    },
  );

  test(
    'NVMe host query selects public identities and strips DH-CHAP keys',
    () async {
      final wire = _Wire(advertiseNvme: true);
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      final rows = await repo.loadNvmeHostReferences();
      expect(rows.hosts.single['hostnqn'], 'nqn.fixture:client');
      expect(rows.hosts.single.containsKey('dhchap_key'), false);
      expect(rows.mappings.single['host'], {'id': 3});
      expect(rows.toString(), isNot(contains(_secret)));
      final hostQuery = wire.requests.singleWhere(
        (r) => r['method'] == 'nvmet.host.query',
      );
      final mappingQuery = wire.requests.singleWhere(
        (r) => r['method'] == 'nvmet.host_subsys.query',
      );
      expect((hostQuery['params'] as List)[1], {
        'select': ['id', 'hostnqn'],
        'limit': 101,
      });
      expect((mappingQuery['params'] as List)[1], {
        'select': ['id', 'host.id', 'subsys.id'],
        'limit': 101,
      });
      expect(repo.adminCatalog.method('nvmet.host.query')?.supported, false);
    },
  );

  test('unadvertised NVMe association method sends no host read', () async {
    final wire = _Wire(advertiseNvme: true, advertiseNvmeMapping: false);
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    await repo.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    await expectLater(
      repo.loadNvmeHostReferences(),
      throwsA(isA<NvmeHostException>()),
    );
    expect(
      wire.requests.where(
        (r) => (r['method'] as String).startsWith('nvmet.host'),
      ),
      isEmpty,
    );
  });

  test(
    'NVMe association create projects only IDs from a secret-bearing response',
    () async {
      final wire = _Wire(advertiseNvme: true, advertiseNvmeCreate: true);
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      final created = await repo.createNvmeHostAssociation(
        hostId: 3,
        subsystemId: 2,
      );
      expect([created.id, created.hostId, created.subsystemId], [9, 3, 2]);
      expect(created.toString(), isNot(contains(_secret)));
      final call = wire.requests.singleWhere(
        (r) => r['method'] == 'nvmet.host_subsys.create',
      );
      expect(call['params'], [
        {'host_id': 3, 'subsys_id': 2},
      ]);
      expect(call.toString(), isNot(contains(_secret)));
    },
  );

  test('unadvertised NVMe association create sends no write', () async {
    final wire = _Wire(advertiseNvme: true);
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    await repo.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    await expectLater(
      repo.createNvmeHostAssociation(hostId: 3, subsystemId: 2),
      throwsA(isA<NvmeHostException>()),
    );
    expect(
      wire.requests.where((r) => r['method'] == 'nvmet.host_subsys.create'),
      isEmpty,
    );
  });

  test('NVMe port association create returns only public IDs', () async {
    final wire = _Wire(advertiseNvmePortCreate: true);
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    await repo.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    final created = await repo.createNvmePortAssociation(
      portId: 7,
      subsystemId: 2,
    );
    expect([created.id, created.portId, created.subsystemId], [10, 7, 2]);
    expect(created.toString(), isNot(contains(_secret)));
    final call = wire.requests.singleWhere(
      (r) => r['method'] == 'nvmet.port_subsys.create',
    );
    expect(call['params'], [
      {'port_id': 7, 'subsys_id': 2},
    ]);
  });

  test('unadvertised NVMe port association create sends no write', () async {
    final wire = _Wire();
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    await repo.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    await expectLater(
      repo.createNvmePortAssociation(portId: 7, subsystemId: 2),
      throwsA(isA<NvmeHostException>()),
    );
    expect(
      wire.requests.where((r) => r['method'] == 'nvmet.port_subsys.create'),
      isEmpty,
    );
  });
}

final class _Connector implements RpcConnector {
  _Connector(this.wire);
  final _Wire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

final class _Wire implements RpcTransport {
  _Wire({
    this.advertiseAuth = true,
    this.advertiseNvme = false,
    this.advertiseNvmeMapping = true,
    this.advertiseNvmeCreate = false,
    this.advertiseNvmePortCreate = false,
  });
  final bool advertiseAuth;
  final bool advertiseNvme, advertiseNvmeMapping;
  final bool advertiseNvmeCreate;
  final bool advertiseNvmePortCreate;
  bool malformed = false;
  final _incoming = StreamController<String>();
  final requests = <Map<String, dynamic>>[];

  @override
  Stream<String> get inboundFrames => _incoming.stream;

  @override
  Future<void> send(String frame) async {
    final request = jsonDecode(frame) as Map<String, dynamic>;
    requests.add(request);
    final result = switch (request['method']) {
      'auth.login_ex' => {'response_type': 'SUCCESS'},
      'auth.me' => {'pw_name': 'fixture-user'},
      'system.info' => {'version': '25.10.1'},
      'core.get_methods' => {
        if (advertiseAuth)
          'iscsi.auth.query': {
            'accepts': <Object?>[],
            'returns': [
              <String, Object?>{'type': 'array'},
            ],
            'job': false,
            'filterable': true,
            'no_auth_required': false,
            'uploadable': false,
            'downloadable': false,
            'roles': ['SHARING_ISCSI_AUTH_READ'],
          },
        if (advertiseNvme) 'nvmet.host.query': _nvmeMetadata,
        if (advertiseNvme && advertiseNvmeMapping)
          'nvmet.host_subsys.query': _nvmeMetadata,
        if (advertiseNvmeCreate) 'nvmet.host_subsys.create': _nvmeMetadata,
        if (advertiseNvmePortCreate) 'nvmet.port_subsys.create': _nvmeMetadata,
      },
      'iscsi.auth.query' =>
        malformed
            ? [
                {'id': 1, 'secret': _secret},
              ]
            : [
                {
                  'id': 3,
                  'tag': 9,
                  'user': 'client-user',
                  'peeruser': '',
                  'discovery_auth': 'CHAP',
                  // Deliberately violate select to prove SDK projection.
                  'secret': _secret,
                  'peersecret': _secret,
                },
              ],
      'nvmet.host.query' => [
        {'id': 3, 'hostnqn': 'nqn.fixture:client', 'dhchap_key': _secret},
      ],
      'nvmet.host_subsys.query' => [
        {
          'id': 4,
          'host': {'id': 3, 'dhchap_ctrl_key': _secret},
          'subsys': {'id': 2},
        },
      ],
      'nvmet.host_subsys.create' => {
        'id': 9,
        'host': {'id': 3, 'dhchap_key': _secret},
        'subsys': {'id': 2, 'serial': _secret},
      },
      'nvmet.port_subsys.create' => {
        'id': 10,
        'port': {'id': 7, 'addr_traddr': _secret},
        'subsys': {'id': 2, 'serial': _secret},
      },
      _ => throw StateError('Unexpected fixture method'),
    };
    _incoming.add(
      jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}

const _nvmeMetadata = <String, Object?>{
  'accepts': <Object?>[],
  'returns': [
    <String, Object?>{'type': 'array'},
  ],
  'job': false,
  'filterable': true,
  'no_auth_required': false,
  'uploadable': false,
  'downloadable': false,
  'roles': ['SHARING_NVME_TARGET_READ'],
};
