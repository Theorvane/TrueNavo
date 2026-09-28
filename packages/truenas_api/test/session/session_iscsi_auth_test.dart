import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _secret = 'fixture-chap-secret-never-exposed';

NvmeHostAuthentication _clearTarget() =>
    NvmeHostAuthenticationInventory.project([
      {
        'id': 3,
        'hostnqn': 'nqn.2026-09.example:old',
        'dhchap_key': _secret,
        'dhchap_ctrl_key': _secret,
        'dhchap_dhgroup': '4096-BIT',
        'dhchap_hash': 'SHA-256',
      },
    ]).hosts.single;

void main() {
  for (final raw in <Object?>[
    null,
    _secret,
    <Object?>[],
    [_secret, _secret],
  ]) {
    test(
      'exact authentication target rejects incomplete shape ${raw.runtimeType} ${raw is List ? raw.length : 0}',
      () async {
        final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true)
          ..overrideHostQuery = true
          ..hostQueryResult = raw;
        final repo = TrueNasSessionRepository(connector: _Connector(wire));
        addTearDown(repo.close);
        await repo.connect(
          serverInput: 'https://fixture.example',
          username: 'fixture-user',
          apiKey: 'fixture-key',
        );
        await expectLater(
          repo.loadNvmeHostAuthenticationTarget(3),
          throwsA(
            isA<NvmeHostException>().having(
              (e) => e.toString(),
              'safe error',
              isNot(contains(_secret)),
            ),
          ),
        );
        expect(
          wire.requests.where((r) => r['method'] == 'nvmet.host.update'),
          isEmpty,
        );
      },
    );
  }
  for (final id in [0, -1]) {
    test('invalid authentication target ID $id sends no read', () async {
      final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true);
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      await expectLater(
        repo.loadNvmeHostAuthenticationTarget(id),
        throwsA(isA<NvmeHostException>()),
      );
      expect(
        wire.requests.where(
          (r) => (r['method'] as String).startsWith('nvmet.'),
        ),
        isEmpty,
      );
    });
  }
  test(
    'disconnected authentication clearing never sends NVMe requests',
    () async {
      final wire = _Wire();
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await expectLater(
        repo.clearNvmeHostAuthentication(expected: _clearTarget()),
        throwsA(isA<NvmeHostException>()),
      );
      await expectLater(
        repo.loadNvmeHostAuthenticationTarget(3),
        throwsA(isA<NvmeHostException>()),
      );
      expect(wire.requests, isEmpty);
    },
  );
  test('protected authentication clearing sends only three nulls and strips all key values', () async {
    final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true);
    wire.hostRow.addAll({
      'dhchap_key': _secret,
      'dhchap_ctrl_key': _secret,
      'dhchap_dhgroup': '4096-BIT',
    });
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    await repo.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    final before = await repo.loadNvmeHostAuthenticationTarget(3);
    expect(before.sameReturnedSettings(_clearTarget()), true);
    expect(before.toString(), isNot(contains(_secret)));
    final cleared = await repo.clearNvmeHostAuthentication(expected: before);
    expect(
      [
        cleared.id,
        cleared.nqn,
        cleared.hash,
        cleared.hasReturnedAuthentication,
      ],
      [3, 'nqn.2026-09.example:old', 'SHA-256', false],
    );
    expect(cleared.toString(), isNot(contains(_secret)));
    final write = wire.requests.singleWhere(
      (r) => r['method'] == 'nvmet.host.update',
    );
    expect(write['params'], [
      3,
      {'dhchap_key': null, 'dhchap_ctrl_key': null, 'dhchap_dhgroup': null},
    ]);
    for (final read in wire.requests.where(
      (r) => r['method'] == 'nvmet.host.query',
    )) {
      expect(read['params'], [
        [
          ['id', '=', 3],
        ],
        {
          'select': [
            'id',
            'hostnqn',
            'dhchap_key',
            'dhchap_ctrl_key',
            'dhchap_dhgroup',
            'dhchap_hash',
          ],
          'limit': 2,
        },
      ]);
    }
    expect(
      wire.requests
          .where((r) => (r['method'] as String).startsWith('nvmet.'))
          .map((r) => r['method']),
      ['nvmet.host.query', 'nvmet.host.query', 'nvmet.host.update'],
    );
  });
  for (final changed in [
    'id',
    'hostnqn',
    'dhchap_hash',
    'dhchap_key',
    'dhchap_ctrl_key',
    'dhchap_dhgroup',
    'missing key',
    'invalid key',
    'missing update',
    'missing query',
  ]) {
    test('clearing SDK rejects $changed before writing', () async {
      final wire = _Wire(
        advertiseNvme: changed != 'missing query',
        advertiseNvmeHostUpdate: changed != 'missing update',
      );
      wire.hostRow.addAll({
        'dhchap_key': _secret,
        'dhchap_ctrl_key': _secret,
        'dhchap_dhgroup': '4096-BIT',
      });
      switch (changed) {
        case 'id':
          wire.hostRow['id'] = 999;
        case 'hostnqn':
          wire.hostRow['hostnqn'] = 'nqn.2026-09.example:other';
        case 'dhchap_hash':
          wire.hostRow['dhchap_hash'] = 'SHA-512';
        case 'dhchap_key':
          wire.hostRow['dhchap_key'] = null;
        case 'dhchap_ctrl_key':
          wire.hostRow['dhchap_ctrl_key'] = null;
        case 'dhchap_dhgroup':
          wire.hostRow['dhchap_dhgroup'] = '8192-BIT';
        case 'missing key':
          wire.hostRow.remove('dhchap_key');
        case 'invalid key':
          wire.hostRow['dhchap_key'] = {'unexpected_private': _secret};
      }
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      await expectLater(
        repo.clearNvmeHostAuthentication(expected: _clearTarget()),
        throwsA(
          isA<NvmeHostException>().having(
            (e) => e.toString(),
            'safe error',
            isNot(contains(_secret)),
          ),
        ),
      );
      expect(
        wire.requests.where((r) => r['method'] == 'nvmet.host.update'),
        isEmpty,
      );
    });
  }
  for (final failure in [
    'auth after update',
    'controller after update',
    'group after update',
    'hash after update',
    'ID after update',
    'NQN after update',
  ]) {
    test('clearing SDK rejects $failure after one update', () async {
      final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true)
        ..renameFailure = failure;
      wire.hostRow.addAll({
        'dhchap_key': _secret,
        'dhchap_ctrl_key': _secret,
        'dhchap_dhgroup': '4096-BIT',
      });
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      await expectLater(
        repo.clearNvmeHostAuthentication(expected: _clearTarget()),
        throwsA(isA<NvmeHostException>()),
      );
      expect(
        wire.requests.where((r) => r['method'] == 'nvmet.host.update'),
        hasLength(1),
      );
    });
  }
  test(
    'unset expected metadata rejects clearing without a host read',
    () async {
      final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true);
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      const unset = NvmeHostAuthentication(
        id: 3,
        nqn: 'nqn.2026-09.example:old',
        hash: 'SHA-256',
        group: null,
        hostKeyReturned: false,
        controllerKeyReturned: false,
      );
      await expectLater(
        repo.clearNvmeHostAuthentication(expected: unset),
        throwsA(isA<NvmeHostException>()),
      );
      expect(
        wire.requests.where(
          (r) => (r['method'] as String).startsWith('nvmet.'),
        ),
        isEmpty,
      );
    },
  );
  for (final input in [
    (0, 'SHA-256', 'SHA-384'),
    (-1, 'SHA-256', 'SHA-384'),
    (3, 'SHA-1', 'SHA-384'),
    (3, 'SHA-256', 'sha-384'),
    (3, 'SHA-256', 'SHA-256'),
  ]) {
    test('invalid hash SDK input $input sends no NVMe request', () async {
      final wire = _Wire(
        advertiseNvme: true,
        advertiseNvmeHostUpdate: true,
        advertiseNvmeHashes: true,
        advertiseNvmeGroups: true,
      );
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      await expectLater(
        repo.changeUncredentialedNvmeHostHash(
          id: input.$1,
          expectedNqn: 'nqn.2026-09.example:old',
          expectedHash: input.$2,
          newHash: input.$3,
        ),
        throwsA(isA<NvmeHostException>()),
      );
      expect(
        wire.requests.where(
          (r) => (r['method'] as String).startsWith('nvmet.'),
        ),
        isEmpty,
      );
    });
  }
  test(
    'hash-only SDK update privately preflights keys and preserves NQN',
    () async {
      final wire = _Wire(
        advertiseNvme: true,
        advertiseNvmeHostUpdate: true,
        advertiseNvmeHashes: true,
        advertiseNvmeGroups: true,
      );
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      final host = await repo.changeUncredentialedNvmeHostHash(
        id: 3,
        expectedNqn: 'nqn.2026-09.example:old',
        expectedHash: 'SHA-256',
        newHash: 'SHA-384',
      );
      expect(
        [host.id, host.nqn, host.hash],
        [3, 'nqn.2026-09.example:old', 'SHA-384'],
      );
      final write = wire.requests.singleWhere(
        (r) => r['method'] == 'nvmet.host.update',
      );
      expect(write['params'], [
        3,
        {'dhchap_hash': 'SHA-384'},
      ]);
      expect(host.toString(), isNot(contains(_secret)));
      expect(
        wire.requests
            .where((r) => (r['method'] as String).startsWith('nvmet.'))
            .map((r) => r['method']),
        [
          'nvmet.host.dhchap_hash_choices',
          'nvmet.host.dhchap_dhgroup_choices',
          'nvmet.host.query',
          'nvmet.host.update',
        ],
      );
    },
  );
  for (final change in [
    'dhchap_key',
    'dhchap_ctrl_key',
    'dhchap_dhgroup',
    'id',
    'hostnqn',
    'dhchap_hash',
    'choices',
    'malformed choices',
    'missing choices',
    'missing update',
  ]) {
    test('hash SDK rejects $change before writing', () async {
      final wire = _Wire(
        advertiseNvme: true,
        advertiseNvmeHostUpdate: change != 'missing update',
        advertiseNvmeHashes: change != 'missing choices',
        advertiseNvmeGroups: true,
      );
      if (wire.hostRow.containsKey(change)) {
        wire.hostRow[change] = switch (change) {
          'id' => 999,
          'dhchap_dhgroup' => '4096-BIT',
          'dhchap_hash' => 'SHA-512',
          _ => _secret,
        };
      }
      if (change == 'choices') wire.hashes = ['SHA-256'];
      if (change == 'malformed choices') wire.hashes = [_secret];
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      await expectLater(
        repo.changeUncredentialedNvmeHostHash(
          id: 3,
          expectedNqn: 'nqn.2026-09.example:old',
          expectedHash: 'SHA-256',
          newHash: 'SHA-384',
        ),
        throwsA(
          isA<NvmeHostException>().having(
            (e) => e.toString(),
            'safe',
            isNot(contains(_secret)),
          ),
        ),
      );
      expect(
        wire.requests.where((r) => r['method'] == 'nvmet.host.update'),
        isEmpty,
      );
    });
  }
  for (final failure in [
    'auth after update',
    'hash after update',
    'ID after update',
    'NQN after update',
  ]) {
    test(
      'hash SDK rejects unsafe returned fields $failure after exactly one write',
      () async {
        final wire = _Wire(
          advertiseNvme: true,
          advertiseNvmeHostUpdate: true,
          advertiseNvmeHashes: true,
          advertiseNvmeGroups: true,
        )..renameFailure = failure;
        final repo = TrueNasSessionRepository(connector: _Connector(wire));
        addTearDown(repo.close);
        await repo.connect(
          serverInput: 'https://fixture.example',
          username: 'fixture-user',
          apiKey: 'fixture-key',
        );
        await expectLater(
          repo.changeUncredentialedNvmeHostHash(
            id: 3,
            expectedNqn: 'nqn.2026-09.example:old',
            expectedHash: 'SHA-256',
            newHash: 'SHA-384',
          ),
          throwsA(isA<NvmeHostException>()),
        );
        expect(
          wire.requests.where((r) => r['method'] == 'nvmet.host.update'),
          hasLength(1),
        );
      },
    );
  }
  test(
    'algorithm discovery calls only two public parameterless reads',
    () async {
      final wire = _Wire(advertiseNvmeHashes: true, advertiseNvmeGroups: true)
        ..hashes = ['SHA-512', 'SHA-256']
        ..groups = ['8192-BIT'];
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      final value = await repo.loadNvmeHostAuthenticationChoices();
      expect(value.hashes, ['SHA-512', 'SHA-256']);
      expect(value.groups, ['8192-BIT']);
      expect(() => value.hashes.clear(), throwsUnsupportedError);
      expect(() => value.groups.clear(), throwsUnsupportedError);
      final calls = wire.requests
          .where((r) => (r['method'] as String).startsWith('nvmet.'))
          .toList();
      expect(calls.map((r) => r['method']), [
        'nvmet.host.dhchap_hash_choices',
        'nvmet.host.dhchap_dhgroup_choices',
      ]);
      for (final call in calls) {
        expect(call['params'], isEmpty);
      }
      for (final method in [
        'nvmet.host.dhchap_hash_choices',
        'nvmet.host.dhchap_dhgroup_choices',
      ]) {
        expect(repo.adminCatalog.method(method)?.supported, true);
      }
    },
  );
  for (final support in [(false, false), (true, false), (false, true)]) {
    test(
      'incomplete advertised algorithm support $support sends no reads',
      () async {
        final wire = _Wire(
          advertiseNvmeHashes: support.$1,
          advertiseNvmeGroups: support.$2,
        );
        final repo = TrueNasSessionRepository(connector: _Connector(wire));
        addTearDown(repo.close);
        await repo.connect(
          serverInput: 'https://fixture.example',
          username: 'fixture-user',
          apiKey: 'fixture-key',
        );
        await expectLater(
          repo.loadNvmeHostAuthenticationChoices(),
          throwsA(isA<NvmeHostChoicesException>()),
        );
        expect(
          wire.requests.where(
            (r) => (r['method'] as String).startsWith('nvmet.'),
          ),
          isEmpty,
        );
      },
    );
  }
  test('algorithm projection rejects duplicates unknown values and malformed shapes', () {
    for (final malformed in <Object?>[
      null,
      {},
      'SHA-256',
      [null],
      [256],
      [_secret],
      ['SHA-256', 'SHA-256'],
      ['SHA-256', 'SHA-384', 'SHA-512', 'SHA-256'],
    ]) {
      expect(
        () => NvmeHostAuthenticationChoices.project(malformed, []),
        throwsFormatException,
      );
    }
    for (final malformed in <Object?>[
      null,
      {},
      '2048-BIT',
      [null],
      [2048],
      [_secret],
      ['2048-BIT', '2048-BIT'],
      List.filled(6, '8192-BIT'),
    ]) {
      expect(
        () => NvmeHostAuthenticationChoices.project([], malformed),
        throwsFormatException,
      );
    }
    final empty = NvmeHostAuthenticationChoices.project([], []);
    expect(empty.hashes, isEmpty);
    expect(empty.groups, isEmpty);
  });
  test(
    'malformed algorithm wire result returns a fixed sanitized error',
    () async {
      final wire = _Wire(advertiseNvmeHashes: true, advertiseNvmeGroups: true)
        ..groups = [_secret];
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      await expectLater(
        repo.loadNvmeHostAuthenticationChoices(),
        throwsA(
          isA<NvmeHostChoicesException>().having(
            (e) => e.toString(),
            'safe error',
            isNot(contains(_secret)),
          ),
        ),
      );
    },
  );
  test('authentication inventory wire selects bounded fields and strips key values', () async {
    final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true);
    wire.hostRow['dhchap_key'] = _secret;
    wire.hostRow['dhchap_ctrl_key'] = _secret;
    wire.hostRow['dhchap_dhgroup'] = '4096-BIT';
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    await repo.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    final inventory = await repo.loadNvmeHostAuthentication();
    final host = inventory.hosts.single;
    expect(
      [
        host.id,
        host.nqn,
        host.hostKeyReturned,
        host.controllerKeyReturned,
        host.group,
        host.hash,
      ],
      [3, 'nqn.2026-09.example:old', true, true, '4096-BIT', 'SHA-256'],
    );
    expect(host.inconsistent, false);
    expect(host.toString(), isNot(contains(_secret)));
    expect(() => inventory.hosts.clear(), throwsUnsupportedError);
    final read = wire.requests.singleWhere(
      (r) => r['method'] == 'nvmet.host.query',
    );
    expect(read['params'], [
      [],
      {
        'select': [
          'id',
          'hostnqn',
          'dhchap_key',
          'dhchap_ctrl_key',
          'dhchap_dhgroup',
          'dhchap_hash',
        ],
        'limit': 101,
      },
    ]);
    expect(
      wire.requests.where(
        (r) =>
            (r['method'] as String).startsWith('nvmet.host') &&
            r['method'] != 'nvmet.host.query',
      ),
      isEmpty,
    );
  });
  test('unadvertised authentication inventory sends no host query', () async {
    final wire = _Wire();
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    await repo.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    await expectLater(
      repo.loadNvmeHostAuthentication(),
      throwsA(isA<NvmeHostException>()),
    );
    expect(
      wire.requests.where((r) => r['method'] == 'nvmet.host.query'),
      isEmpty,
    );
  });
  test('authentication projection distinguishes returned null nonempty and inconsistent fields', () {
    Map<String, Object?> row(int id) => {
      'id': id,
      'hostnqn': 'nqn.fixture:host$id',
      'dhchap_key': null,
      'dhchap_ctrl_key': null,
      'dhchap_dhgroup': null,
      'dhchap_hash': 'SHA-256',
    };
    final rows = NvmeHostAuthenticationInventory.project([
      row(1),
      {...row(2), 'dhchap_key': _secret},
      {...row(3), 'dhchap_key': _secret, 'dhchap_ctrl_key': _secret},
      {...row(4), 'dhchap_ctrl_key': _secret},
      {...row(5), 'dhchap_dhgroup': '2048-BIT'},
    ]).hosts;
    expect(rows.map((h) => h.inconsistent), [false, false, false, true, true]);
    expect(rows.map((h) => h.hostKeyReturned), [
      false,
      true,
      true,
      false,
      false,
    ]);
    expect(rows.toString(), isNot(contains(_secret)));
  });
  test('authentication projection rejects truncated missing malformed and duplicate metadata', () {
    final row = <String, Object?>{
      'id': 1,
      'hostnqn': 'nqn.fixture:host',
      'dhchap_key': null,
      'dhchap_ctrl_key': null,
      'dhchap_dhgroup': null,
      'dhchap_hash': 'SHA-256',
    };
    for (final key in row.keys) {
      expect(
        () =>
            NvmeHostAuthenticationInventory.project([Map.of(row)..remove(key)]),
        throwsFormatException,
      );
    }
    for (final key in ['dhchap_key', 'dhchap_ctrl_key']) {
      for (final value in ['', 1, false, 'bad\n', 'x' * 513]) {
        expect(
          () => NvmeHostAuthenticationInventory.project([
            {...row, key: value},
          ]),
          throwsFormatException,
        );
      }
    }
    for (final key in ['dhchap_hash', 'dhchap_dhgroup']) {
      expect(
        () => NvmeHostAuthenticationInventory.project([
          {...row, key: _secret},
        ]),
        throwsFormatException,
      );
    }
    for (final raw in [
      null,
      {},
      [row, row],
      List.filled(101, row),
    ]) {
      expect(
        () => NvmeHostAuthenticationInventory.project(raw),
        throwsFormatException,
      );
    }
    expect(NvmeHostAuthenticationInventory.project([]).hosts, isEmpty);
  });
  test(
    'protected host NQN edit selects one ID and sends only hostnqn',
    () async {
      final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true);
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      final before = await repo.loadUncredentialedNvmeHost(3);
      expect(
        [before.id, before.nqn, before.hash],
        [3, 'nqn.2026-09.example:old', 'SHA-256'],
      );
      final after = await repo.renameUncredentialedNvmeHost(
        id: 3,
        expectedNqn: before.nqn,
        expectedHash: before.hash,
        newNqn: 'nqn.2026-09.example:new',
      );
      expect(
        [after.id, after.nqn, after.hash],
        [3, 'nqn.2026-09.example:new', 'SHA-256'],
      );
      expect(after.toString(), isNot(contains(_secret)));
      final read = wire.requests.firstWhere(
        (r) => r['method'] == 'nvmet.host.query',
      );
      expect(read['params'], [
        [
          ['id', '=', 3],
        ],
        {
          'select': [
            'id',
            'hostnqn',
            'dhchap_key',
            'dhchap_ctrl_key',
            'dhchap_dhgroup',
            'dhchap_hash',
          ],
          'limit': 2,
        },
      ]);
      final write = wire.requests.singleWhere(
        (r) => r['method'] == 'nvmet.host.update',
      );
      expect(write['params'], [
        3,
        {'hostnqn': 'nqn.2026-09.example:new'},
      ]);
      expect(repo.adminCatalog.method('nvmet.host.update')?.supported, false);
    },
  );
  for (final changed in [
    'dhchap_key',
    'dhchap_ctrl_key',
    'dhchap_dhgroup',
    'dhchap_hash',
    'hostnqn',
    'id',
    'missing key',
  ]) {
    test(
      'protected rename rejects $changed before update without secret error',
      () async {
        final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true);
        if (changed == 'missing key') {
          wire.hostRow.remove('dhchap_key');
        } else {
          wire.hostRow[changed] = changed == 'id' ? 999 : _secret;
        }
        final repo = TrueNasSessionRepository(connector: _Connector(wire));
        addTearDown(repo.close);
        await repo.connect(
          serverInput: 'https://fixture.example',
          username: 'fixture-user',
          apiKey: 'fixture-key',
        );
        await expectLater(
          repo.renameUncredentialedNvmeHost(
            id: 3,
            expectedNqn: 'nqn.2026-09.example:old',
            expectedHash: 'SHA-256',
            newNqn: 'nqn.2026-09.example:new',
          ),
          throwsA(
            isA<NvmeHostException>().having(
              (e) => e.userMessage,
              'safe error',
              isNot(contains(_secret)),
            ),
          ),
        );
        expect(
          wire.requests.where((r) => r['method'] == 'nvmet.host.update'),
          isEmpty,
        );
      },
    );
  }
  for (final failure in [
    'auth after update',
    'hash after update',
    'ID after update',
    'NQN after update',
  ]) {
    test(
      '$failure rejects protected response after exactly one write',
      () async {
        final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true)
          ..renameFailure = failure;
        final repo = TrueNasSessionRepository(connector: _Connector(wire));
        addTearDown(repo.close);
        await repo.connect(
          serverInput: 'https://fixture.example',
          username: 'fixture-user',
          apiKey: 'fixture-key',
        );
        await expectLater(
          repo.renameUncredentialedNvmeHost(
            id: 3,
            expectedNqn: 'nqn.2026-09.example:old',
            expectedHash: 'SHA-256',
            newNqn: 'nqn.2026-09.example:new',
          ),
          throwsA(isA<NvmeHostException>()),
        );
        expect(
          wire.requests.where((r) => r['method'] == 'nvmet.host.update').length,
          1,
        );
      },
    );
  }
  test(
    'unadvertised rename and invalid arguments send no host update',
    () async {
      final wire = _Wire(advertiseNvme: true);
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      await expectLater(
        repo.renameUncredentialedNvmeHost(
          id: 3,
          expectedNqn: 'nqn.2026-09.example:old',
          expectedHash: 'SHA-256',
          newNqn: 'nqn.2026-09.example:new',
        ),
        throwsA(isA<NvmeHostException>()),
      );
      await expectLater(
        repo.loadUncredentialedNvmeHost(0),
        throwsA(isA<NvmeHostException>()),
      );
      expect(
        wire.requests.where(
          (r) => (r['method'] as String).startsWith('nvmet.host'),
        ),
        isEmpty,
      );
    },
  );
  test(
    'NVMe host registration projects only identity and rejects unexpected auth',
    () async {
      final wire = _Wire(advertiseNvmeHostCreate: true);
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      final created = await repo.createUnassociatedNvmeHost(
        hostNqn: 'nqn.2026-09.example:new',
      );
      expect([created.id, created.nqn], [11, 'nqn.2026-09.example:new']);
      expect(created.toString(), isNot(contains(_secret)));
      final call = wire.requests.singleWhere(
        (r) => r['method'] == 'nvmet.host.create',
      );
      expect(call['params'], [
        {
          'hostnqn': 'nqn.2026-09.example:new',
          'dhchap_key': null,
          'dhchap_ctrl_key': null,
          'dhchap_dhgroup': null,
        },
      ]);
      wire.malformed = true;
      await expectLater(
        repo.createUnassociatedNvmeHost(hostNqn: 'nqn.2026-09.example:new'),
        throwsA(
          isA<NvmeHostException>().having(
            (e) => e.userMessage,
            'safe error',
            isNot(contains(_secret)),
          ),
        ),
      );
      expect(repo.adminCatalog.method('nvmet.host.create')?.supported, false);
    },
  );
  test(
    'unadvertised host registration and invalid NQNs send no writes',
    () async {
      for (final advertised in [true, false]) {
        final wire = _Wire(advertiseNvmeHostCreate: advertised);
        final repo = TrueNasSessionRepository(connector: _Connector(wire));
        addTearDown(repo.close);
        await repo.connect(
          serverInput: 'https://fixture.example',
          username: 'fixture-user',
          apiKey: 'fixture-key',
        );
        for (final value
            in advertised
                ? [
                    'nqn.short',
                    ' nqn.2026-09.example:new',
                    'nqn.2026-09.example:new\n',
                    'nqn.2026-09.example:비밀',
                    'nqn.${'a' * 220}',
                  ]
                : ['nqn.2026-09.example:new']) {
          await expectLater(
            repo.createUnassociatedNvmeHost(hostNqn: value),
            throwsA(isA<NvmeHostException>()),
          );
        }
        expect(
          wire.requests.where((r) => r['method'] == 'nvmet.host.create'),
          isEmpty,
        );
      }
    },
  );
  test(
    'host create projection fails closed on unknown credentials and IDs',
    () {
      final base = <String, Object?>{
        'id': 11,
        'hostnqn': 'nqn.2026-09.example:new',
        'dhchap_key': null,
        'dhchap_ctrl_key': null,
        'dhchap_dhgroup': null,
      };
      for (final key in [
        'id',
        'hostnqn',
        'dhchap_key',
        'dhchap_ctrl_key',
        'dhchap_dhgroup',
      ]) {
        expect(
          () => NvmeHostCreated.project(Map.of(base)..remove(key)),
          throwsFormatException,
        );
      }
      expect(
        () => NvmeHostCreated.project({...base, 'id': 0}),
        throwsFormatException,
      );
      for (final key in ['dhchap_key', 'dhchap_ctrl_key', 'dhchap_dhgroup']) {
        expect(
          () => NvmeHostCreated.project({...base, key: _secret}),
          throwsFormatException,
        );
      }
    },
  );
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
    this.advertiseNvmeHostCreate = false,
    this.advertiseNvmeHostUpdate = false,
    this.advertiseNvmeHashes = false,
    this.advertiseNvmeGroups = false,
  });
  final bool advertiseAuth;
  final bool advertiseNvme, advertiseNvmeMapping;
  final bool advertiseNvmeCreate;
  final bool advertiseNvmePortCreate;
  final bool advertiseNvmeHostCreate;
  final bool advertiseNvmeHostUpdate;
  final bool advertiseNvmeHashes, advertiseNvmeGroups;
  Object? hashes = ['SHA-256', 'SHA-384', 'SHA-512'];
  Object? groups = ['2048-BIT', '3072-BIT', '4096-BIT', '6144-BIT', '8192-BIT'];
  String? renameFailure;
  bool overrideHostQuery = false;
  Object? hostQueryResult;
  final hostRow = <String, Object?>{
    'id': 3,
    'hostnqn': 'nqn.2026-09.example:old',
    'dhchap_key': null,
    'dhchap_ctrl_key': null,
    'dhchap_dhgroup': null,
    'dhchap_hash': 'SHA-256',
    'unexpected_private_data': _secret,
  };
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
        if (advertiseNvmeHostCreate) 'nvmet.host.create': _nvmeMetadata,
        if (advertiseNvmeHostUpdate) 'nvmet.host.update': _nvmeMetadata,
        if (advertiseNvmeHashes)
          'nvmet.host.dhchap_hash_choices': _nvmeMetadata,
        if (advertiseNvmeGroups)
          'nvmet.host.dhchap_dhgroup_choices': _nvmeMetadata,
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
      'nvmet.host.query' when overrideHostQuery => hostQueryResult,
      'nvmet.host.query' when advertiseNvmeHostUpdate => [Map.of(hostRow)],
      'nvmet.host.dhchap_hash_choices' => hashes,
      'nvmet.host.dhchap_dhgroup_choices' => groups,
      'nvmet.host.update' => _rename(request),
      'nvmet.host.query' => [
        {'id': 3, 'hostnqn': 'nqn.fixture:client', 'dhchap_key': _secret},
      ],
      'nvmet.host.create' => {
        'id': 11,
        'hostnqn': 'nqn.2026-09.example:new',
        'dhchap_key': malformed ? _secret : null,
        'dhchap_ctrl_key': null,
        'dhchap_dhgroup': null,
        'unexpected_private_data': _secret,
      },
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

  Object _rename(Map<String, dynamic> request) {
    final payload = (request['params'] as List)[1] as Map;
    if (payload.containsKey('hostnqn')) hostRow['hostnqn'] = payload['hostnqn'];
    if (payload.containsKey('dhchap_hash')) {
      hostRow['dhchap_hash'] = payload['dhchap_hash'];
    }
    for (final key in ['dhchap_key', 'dhchap_ctrl_key', 'dhchap_dhgroup']) {
      if (payload.containsKey(key)) hostRow[key] = payload[key];
    }
    switch (renameFailure) {
      case 'auth after update':
        hostRow['dhchap_key'] = _secret;
      case 'controller after update':
        hostRow['dhchap_ctrl_key'] = _secret;
      case 'group after update':
        hostRow['dhchap_dhgroup'] = '2048-BIT';
      case 'hash after update':
        hostRow['dhchap_hash'] = 'SHA-512';
      case 'ID after update':
        hostRow['id'] = 999;
      case 'NQN after update':
        hostRow['hostnqn'] = 'nqn.2026-09.example:wrong';
    }
    return Map.of(hostRow);
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
