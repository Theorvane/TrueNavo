import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _methods = {
  'interface.query',
  'interface.update',
  'interface.commit',
  'interface.checkin',
  'interface.checkin_waiting',
  'interface.has_pending_changes',
  'interface.rollback',
  'failover.licensed',
  'network.configuration.config',
  'interface.network_config_to_be_removed',
  'interface.services_restarted_on_sync',
  'app.used_host_ips',
  'pool.dataset.create',
  'system.info',
};
const _writeMethods = {
  'interface.update',
  'interface.commit',
  'interface.checkin',
  'interface.rollback',
  'interface.cancel_rollback',
};
final _communityMethods = {
  ..._methods.difference({'failover.licensed'}),
  'system.product_type',
};
Map<String, Object?> _row({String id = 'eno1'}) => {
  'id': id,
  'name': id,
  'type': 'PHYSICAL',
  'fake': false,
  'description': 'LAN',
  'ipv4_dhcp': false,
  'ipv6_auto': false,
  'mtu': 1500,
  'aliases': [
    {'type': 'INET', 'address': '192.168.1.10', 'netmask': 24},
  ],
  'state': {'link_state': 'LINK_STATE_UP', 'mtu': 1500},
  'bridge_members': <Object?>[],
  'lag_ports': <Object?>[],
  'vlan_parent_interface': null,
};
Matcher _reason(NetworkExceptionReason reason) =>
    isA<NetworkException>().having((e) => e.reason, 'reason', reason);

void main() {
  test(
    'network capability requires authentication and no initial write',
    () async {
      final h = _Harness();
      addTearDown(h.repository.close);
      expect(h.repository.networkCapabilities.connected, isFalse);
      await expectLater(
        h.repository.loadNetworkInventory(),
        throwsA(_reason(NetworkExceptionReason.notAuthenticated)),
      );
      expect(h.transport.requests, isEmpty);
    },
  );
  for (final version in [
    '24.10.2',
    '25.04.2',
    '26.0.1',
    '25.10-beta',
    '25.10\n',
  ]) {
    test('unknown or unverified version $version is unavailable', () async {
      final h = await _connected(version: version);
      expect(h.repository.networkCapabilities.supported, isFalse);
      await expectLater(
        h.repository.loadNetworkInventory(),
        throwsA(_reason(NetworkExceptionReason.unsupportedVersion)),
      );
      expect(h.transport.writes, isEmpty);
    });
  }
  test('every independently required safety method gates capability', () async {
    for (final method in _methods.difference({
      'pool.dataset.create',
      'system.info',
    })) {
      final h = await _connected(methods: _methods.difference({method}));
      expect(
        h.repository.networkCapabilities.supported,
        isFalse,
        reason: method,
      );
      await expectLater(
        h.repository.loadNetworkInventory(),
        throwsA(_reason(NetworkExceptionReason.unavailableMethod)),
      );
    }
  });
  test(
    'advertised Community Edition proof enables read-only inventory',
    () async {
      final h = await _connected(methods: _communityMethods);
      expect(h.repository.networkCapabilities.supported, isTrue);
      final inventory = await h.repository.loadNetworkInventory();
      expect(inventory.failoverLicensed, isFalse);
      expect(inventory.blockedReason, isNull);
      expect(inventory.interfaces.single.editable, isTrue);
      expect(h.transport.writes, isEmpty);
      expect(
        h.transport.requests
            .where((r) => r['method'] == 'system.product_type')
            .single['params'],
        isEmpty,
      );
      expect(
        h.transport.requests.where((r) => r['method'] == 'failover.licensed'),
        isEmpty,
      );
    },
  );
  test(
    'Community Edition proof does not bypass another missing safety method',
    () async {
      for (final method in _communityMethods.difference({
        'pool.dataset.create',
        'system.info',
      })) {
        final h = await _connected(
          methods: _communityMethods.difference({method}),
        );
        expect(
          h.repository.networkCapabilities.supported,
          isFalse,
          reason: method,
        );
        await expectLater(
          h.repository.loadNetworkInventory(),
          throwsA(_reason(NetworkExceptionReason.unavailableMethod)),
        );
        expect(h.transport.writes, isEmpty);
      }
    },
  );
  for (final product in <Object?>[
    'ENTERPRISE',
    'UNKNOWN',
    null,
    false,
    {},
    ['COMMUNITY_EDITION'],
  ]) {
    test(
      'unproven product type $product cannot authorize inventory or writes',
      () async {
        final h = await _connected(methods: _communityMethods);
        h.transport.productType = product;
        await expectLater(
          h.repository.loadNetworkInventory(),
          throwsA(
            _reason(
              product == 'ENTERPRISE'
                  ? NetworkExceptionReason.unsupportedInterface
                  : NetworkExceptionReason.invalidInput,
            ),
          ),
        );
        expect(h.transport.writes, isEmpty);
        expect(
          h.transport.requests.where((r) => r['method'] == 'interface.query'),
          isEmpty,
        );
      },
    );
  }
  test('denied or timed out product proof fails without writes', () async {
    for (final timeout in [false, true]) {
      final h = await _connected(
        methods: _communityMethods,
        timeout: const Duration(milliseconds: 10),
      );
      (timeout ? h.transport.suppressMethods : h.transport.rejectMethods).add(
        'system.product_type',
      );
      await expectLater(
        h.repository.loadNetworkInventory(),
        throwsA(_reason(NetworkExceptionReason.invalidInput)),
      );
      expect(h.transport.writes, isEmpty);
    }
  });
  test(
    'advertised direct HA proof is preferred and never falls back',
    () async {
      for (final licensed in <Object?>[false, true, null, 'false']) {
        final h = await _connected(
          methods: {..._methods, 'system.product_type'},
        );
        h.transport.licensed = licensed;
        if (licensed is bool) {
          final inventory = await h.repository.loadNetworkInventory();
          expect(inventory.failoverLicensed, licensed);
          expect(inventory.blockedReason, licensed ? isNotNull : isNull);
          if (licensed) {
            await expectLater(
              h.repository.beginNetworkTest(_request(inventory)),
              throwsA(_reason(NetworkExceptionReason.unsupportedInterface)),
            );
          }
        } else {
          await expectLater(
            h.repository.loadNetworkInventory(),
            throwsA(_reason(NetworkExceptionReason.invalidInput)),
          );
        }
        expect(
          h.transport.requests.where(
            (r) => r['method'] == 'system.product_type',
          ),
          isEmpty,
        );
        expect(h.transport.writes, isEmpty);
      }
      final h = await _connected(methods: {..._methods, 'system.product_type'});
      h.transport.rejectMethods.add('failover.licensed');
      await expectLater(
        h.repository.loadNetworkInventory(),
        throwsA(_reason(NetworkExceptionReason.invalidInput)),
      );
      expect(
        h.transport.requests.where((r) => r['method'] == 'system.product_type'),
        isEmpty,
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test('product changes after inventory prevent the first write', () async {
    for (final product in <Object?>['ENTERPRISE', 'UNKNOWN', null]) {
      final h = await _connected(methods: _communityMethods);
      final inventory = await h.repository.loadNetworkInventory();
      h.transport.productType = product;
      await expectLater(
        h.repository.beginNetworkTest(_request(inventory)),
        throwsA(isA<NetworkException>()),
      );
      expect(h.transport.writes, isEmpty);
      expect(
        h.transport.requests.where((r) => r['method'] == 'system.product_type'),
        hasLength(2),
      );
    }
  });
  test('Community Edition is reread throughout the fake transaction', () async {
    final h = await _connected(methods: _communityMethods);
    final transaction = (await _begin(h)).transaction!;
    expect(
      (await h.repository.keepNetworkTest(transaction)).phase,
      NetworkChangePhase.kept,
    );
    expect(
      h.transport.requests.where((r) => r['method'] == 'system.product_type'),
      hasLength(6),
    );
    expect(
      h.transport.requests.where((r) => r['method'] == 'failover.licensed'),
      isEmpty,
    );
    expect(h.transport.writes.map((r) => r['method']), [
      'interface.update',
      'interface.commit',
      'interface.checkin',
    ]);
  });
  test(
    'changed product after staging blocks commit and transaction control',
    () async {
      final h = await _connected(methods: _communityMethods);
      h.transport.afterUpdate = () => h.transport.productType = 'ENTERPRISE';
      final result = await _begin(h);
      expect(result.phase, NetworkChangePhase.unknown);
      expect(
        (await h.repository.keepNetworkTest(result.transaction!)).phase,
        NetworkChangePhase.unknown,
      );
      expect(
        (await h.repository.revertNetworkTest(result.transaction!)).phase,
        NetworkChangePhase.unknown,
      );
      expect(h.transport.writes.map((r) => r['method']), ['interface.update']);
    },
  );
  test('inventory is immutable, no writes, runtime fields not mistaken for aliases', () async {
    final h = await _connected();
    final inventory = await h.repository.loadNetworkInventory();
    expect(inventory.interfaces.single.aliases.single.address, '192.168.1.10');
    expect(inventory.interfaces.single.editable, isTrue);
    expect(inventory.blockedReason, isNull);
    expect(() => inventory.interfaces.clear(), throwsUnsupportedError);
    expect(
      () => inventory.interfaces.single.aliases.clear(),
      throwsUnsupportedError,
    );
    expect(h.transport.writes, isEmpty);
  });
  for (final kind in [
    'BRIDGE',
    'VLAN',
    'LINK_AGGREGATION',
    'fake',
    'ipv6',
    'ipv6_auto',
    'bridge-member',
    'bond-member',
    'vlan-parent',
  ]) {
    test('specialized configuration $kind cannot be changed', () async {
      final h = await _connected();
      switch (kind) {
        case 'fake':
          h.transport.rows.first['fake'] = true;
        case 'ipv6':
          h.transport.rows.first['aliases'] = [
            {'type': 'INET6', 'address': 'fd00::1', 'netmask': 64},
          ];
        case 'ipv6_auto':
          h.transport.rows.first['ipv6_auto'] = true;
        case 'bridge-member':
          h.transport.rows.add({
            ..._row(id: 'br0'),
            'type': 'BRIDGE',
            'bridge_members': ['eno1'],
          });
        case 'bond-member':
          h.transport.rows.add({
            ..._row(id: 'bond0'),
            'type': 'LINK_AGGREGATION',
            'lag_ports': ['eno1'],
          });
        case 'vlan-parent':
          h.transport.rows.add({
            ..._row(id: 'vlan1'),
            'type': 'VLAN',
            'vlan_parent_interface': 'eno1',
          });
        default:
          h.transport.rows.first['type'] = kind;
      }
      final inventory = await h.repository.loadNetworkInventory();
      expect(
        inventory.interfaces.firstWhere((i) => i.id == 'eno1').editable,
        isFalse,
      );
      await expectLater(
        h.repository.beginNetworkTest(_request(inventory)),
        throwsA(_reason(NetworkExceptionReason.unsupportedInterface)),
      );
      expect(h.transport.writes, isEmpty);
    });
  }
  test('HA and foreign pending changes cannot start a transaction', () async {
    final h = await _connected();
    h.transport.licensed = true;
    var inventory = await h.repository.loadNetworkInventory();
    expect(inventory.blockedReason, isNotNull);
    await expectLater(
      h.repository.beginNetworkTest(_request(inventory)),
      throwsA(_reason(NetworkExceptionReason.unsupportedInterface)),
    );
    h.transport.licensed = false;
    for (final waiting in [null, 0, 45]) {
      h.transport.pending = true;
      h.transport.waiting = waiting;
      inventory = await h.repository.loadNetworkInventory();
      await expectLater(
        h.repository.beginNetworkTest(_request(inventory)),
        throwsA(_reason(NetworkExceptionReason.foreignPendingChanges)),
      );
    }
    expect(h.transport.writes, isEmpty);
  });
  test(
    'faked inventory and inventory from another session are not authorization',
    () async {
      final h = await _connected();
      final other = await _connected();
      final inventory = await other.repository.loadNetworkInventory();
      await expectLater(
        h.repository.beginNetworkTest(_request(inventory)),
        throwsA(_reason(NetworkExceptionReason.staleInventory)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test(
    'fresh preflight checks every interface and global configuration',
    () async {
      for (final changed in [
        'other-interface',
        'global',
        'pending',
        'ha',
        'impact',
      ]) {
        final h = await _connected();
        h.transport.rows.add(_row(id: 'eno2'));
        final inventory = await h.repository.loadNetworkInventory();
        switch (changed) {
          case 'other-interface':
            h.transport.rows.last['description'] = 'changed remotely';
          case 'global':
            h.transport.config['ipv4gateway'] = '192.168.1.2';
          case 'pending':
            h.transport.pending = true;
          case 'ha':
            h.transport.licensed = true;
          case 'impact':
            h.transport.removals = ['nameserver1'];
        }
        await expectLater(
          h.repository.beginNetworkTest(_request(inventory)),
          throwsA(isA<NetworkException>()),
        );
        expect(h.transport.writes, isEmpty);
      }
    },
  );
  test(
    'runtime link changes do not invalidate configuration preflight',
    () async {
      final h = await _connected();
      final inventory = await h.repository.loadNetworkInventory();
      h.transport.rows.single['state'] = {'link_state': 'LINK_STATE_DOWN'};
      expect(
        (await h.repository.beginNetworkTest(_request(inventory))).phase,
        NetworkChangePhase.testing,
      );
    },
  );
  test('test sends only reviewed fields, then commit with fixed automatic rollback', () async {
    final h = await _connected();
    final inventory = await h.repository.loadNetworkInventory();
    final result = await h.repository.beginNetworkTest(_request(inventory));
    expect(result.phase, NetworkChangePhase.testing);
    expect(result.secondsRemaining, 55);
    expect(h.transport.writes.map((r) => r['method']), [
      'interface.update',
      'interface.commit',
    ]);
    expect(h.transport.writes.first['params'], [
      'eno1',
      {
        'description': 'Storage LAN',
        'ipv4_dhcp': false,
        'aliases': [
          {'type': 'INET', 'address': '192.168.1.20', 'netmask': 24},
        ],
        'mtu': 1500,
      },
    ]);
    expect(h.transport.writes.last['params'], [
      {'rollback': true, 'checkin_timeout': 60},
    ]);
  });
  test('DHCP edit explicitly clears only IPv4 aliases and preserves unrelated fields', () async {
    final h = await _connected();
    final inventory = await h.repository.loadNetworkInventory();
    final result = await h.repository.beginNetworkTest(
      _request(inventory, dhcp: true, aliases: []),
    );
    expect(result.phase, NetworkChangePhase.testing);
    expect((h.transport.writes.first['params'] as List)[1], {
      'description': 'Storage LAN',
      'ipv4_dhcp': true,
      'aliases': [],
      'mtu': 1500,
    });
  });
  test(
    'keep is explicit, single submit and verifies server post-state',
    () async {
      final h = await _connected();
      final t = (await _begin(h)).transaction!;
      expect(
        h.transport.writes.where((r) => r['method'] == 'interface.checkin'),
        isEmpty,
      );
      final result = await h.repository.keepNetworkTest(t);
      expect(result.phase, NetworkChangePhase.kept);
      expect(
        (await h.repository.keepNetworkTest(t)).phase,
        NetworkChangePhase.kept,
      );
      expect(
        h.transport.writes.where((r) => r['method'] == 'interface.checkin'),
        hasLength(1),
      );
    },
  );
  test('explicit revert verifies original configuration', () async {
    final h = await _connected();
    final t = (await _begin(h)).transaction!;
    expect(
      (await h.repository.revertNetworkTest(t)).phase,
      NetworkChangePhase.reverted,
    );
    expect(h.transport.rows.single['description'], 'LAN');
    expect(
      h.transport.writes.where((r) => r['method'] == 'interface.rollback'),
      hasLength(1),
    );
  });
  test(
    'server auto rollback is reported only after original config verified',
    () async {
      final h = await _connected();
      final t = (await _begin(h)).transaction!;
      h.transport.waiting = null;
      expect(
        (await h.repository.checkNetworkTest(t)).phase,
        NetworkChangePhase.unknown,
      );
      h.transport.restore();
      expect(
        (await h.repository.checkNetworkTest(t)).phase,
        NetworkChangePhase.reverted,
      );
      expect(h.transport.writes, hasLength(2));
    },
  );
  test(
    'timer zero or extended timer cannot be acknowledged or reverted',
    () async {
      for (final remaining in [0, null, 99]) {
        final h = await _connected();
        final t = (await _begin(h)).transaction!;
        h.transport.waiting = remaining;
        expect(
          (await h.repository.keepNetworkTest(t)).phase,
          NetworkChangePhase.unknown,
        );
        expect(
          (await h.repository.revertNetworkTest(t)).phase,
          NetworkChangePhase.unknown,
        );
        expect(h.transport.writes, hasLength(2));
      }
    },
  );
  test(
    'no pending and desired config does not infer kept without our checkin',
    () async {
      final h = await _connected();
      final t = (await _begin(h)).transaction!;
      h.transport.pending = false;
      h.transport.waiting = null;
      expect(
        (await h.repository.checkNetworkTest(t)).phase,
        NetworkChangePhase.unknown,
      );
    },
  );
  test(
    'foreign changes while testing block both global transaction writes',
    () async {
      for (final change in ['interface', 'global', 'ha']) {
        final h = await _connected();
        final t = (await _begin(h)).transaction!;
        switch (change) {
          case 'interface':
            h.transport.rows.single['description'] = 'foreign';
          case 'global':
            h.transport.config['hostname'] = 'foreign';
          case 'ha':
            h.transport.licensed = true;
        }
        expect(
          (await h.repository.keepNetworkTest(t)).phase,
          NetworkChangePhase.unknown,
        );
        expect(
          (await h.repository.revertNetworkTest(t)).phase,
          NetworkChangePhase.unknown,
        );
        expect(h.transport.writes, hasLength(2));
      }
    },
  );
  test('service exposure or gateway removal after staging never commits and permits owned explicit recovery', () async {
    for (final serviceImpact in [true, false]) {
      final h = await _connected();
      h.transport.afterUpdate = () {
        if (serviceImpact) {
          h.transport.services = [
            {
              'type': 'service',
              'service': 'nfs',
              'ips': ['192.168.1.10'],
            },
          ];
        } else {
          h.transport.removals = ['ipv4gateway'];
        }
      };
      final result = await _begin(h);
      expect(result.phase, NetworkChangePhase.unknown);
      expect(h.transport.writes, hasLength(1));
      expect(h.transport.waiting, isNull);
      expect(
        (await h.repository.keepNetworkTest(result.transaction!)).phase,
        NetworkChangePhase.unknown,
      );
      expect(
        (await h.repository.revertNetworkTest(result.transaction!)).phase,
        NetworkChangePhase.reverted,
      );
    }
  });
  test('app-bound removed IP is rejected before interface update', () async {
    for (final mapping in [
      {
        '192.168.1.10': ['photos'],
      },
      {
        'photos': ['192.168.1.10'],
      },
    ]) {
      final h = await _connected();
      h.transport.appIps = mapping;
      await expectLater(
        _begin(h),
        throwsA(_reason(NetworkExceptionReason.unsupportedInterface)),
      );
      expect(h.transport.writes, isEmpty);
    }
  });
  test('new app binding after staging blocks commit but allows explicit owned recovery', () async {
    final h = await _connected();
    h.transport.afterUpdate = () => h.transport.appIps = {
      '192.168.1.10': ['photos'],
    };
    final result = await _begin(h);
    expect(result.phase, NetworkChangePhase.unknown);
    expect(h.transport.writes, hasLength(1));
    expect(
      (await h.repository.revertNetworkTest(result.transaction!)).phase,
      NetworkChangePhase.reverted,
    );
  });
  test('interface alias order and global runtime state do not break ownership checks', () async {
    final h = await _connected();
    h.transport.config['state'] = {'ipv4gateway': '192.168.1.1'};
    final inventory = await h.repository.loadNetworkInventory();
    h.transport.config['state'] = {'ipv4gateway': '192.168.1.2'};
    h.transport.afterUpdate = () {
      h.transport.rows.single['aliases'] =
          (h.transport.rows.single['aliases'] as List).reversed.toList();
    };
    final result = await h.repository.beginNetworkTest(
      _request(
        inventory,
        aliases: [
          const NetworkAddress(address: '192.168.1.30', netmask: 24),
          const NetworkAddress(address: '192.168.1.20', netmask: 24),
        ],
      ),
    );
    expect(result.phase, NetworkChangePhase.testing);
    expect(
      (await h.repository.keepNetworkTest(result.transaction!)).phase,
      NetworkChangePhase.kept,
    );
  });
  test(
    'preflight remote errors become sanitized exceptions before any write',
    () async {
      for (final method in ['failover.licensed', 'interface.query']) {
        final h = await _connected();
        final request = _request(await h.repository.loadNetworkInventory());
        h.transport.rejectMethods.add(method);
        await expectLater(
          h.repository.beginNetworkTest(request),
          throwsA(_reason(NetworkExceptionReason.invalidInput)),
        );
        expect(h.transport.writes, isEmpty);
        final admin = AdminRequest(
          method: h.repository.adminCatalog.method('system.info')!,
          arguments: [],
        );
        expect(await h.repository.invokeAdmin(admin), isA<AdminCompleted>());
      }
    },
  );
  test(
    'update rejection is sanitized unknown and never auto rollback or retried',
    () async {
      final h = await _connected();
      h.transport.rejectMethods.add('interface.update');
      final result = await _begin(h);
      expect(result.phase, NetworkChangePhase.unknown);
      expect(result.userMessage, isNot(contains('private-remote')));
      expect(h.transport.writes.map((r) => r['method']), ['interface.update']);
      expect(
        (await h.repository.checkNetworkTest(result.transaction!)).phase,
        NetworkChangePhase.reverted,
      );
    },
  );
  test('lost update response holds lock and no commit or rollback is sent automatically', () async {
    final h = await _connected(timeout: const Duration(milliseconds: 40));
    h.transport.suppressMethods.add('interface.update');
    final result = await _begin(h);
    expect(result.phase, NetworkChangePhase.unknown);
    await expectLater(
      h.repository.execute(
        const CreateDatasetCommand(parent: 'tank', name: 'x'),
      ),
      throwsA(isA<ManagementException>()),
    );
    expect(h.transport.writes.map((r) => r['method']), ['interface.update']);
  });
  test('checkin rejection never retries or claims completion', () async {
    final h = await _connected();
    final t = (await _begin(h)).transaction!;
    h.transport.rejectMethods.add('interface.checkin');
    expect(
      (await h.repository.keepNetworkTest(t)).phase,
      NetworkChangePhase.unknown,
    );
    expect(
      (await h.repository.keepNetworkTest(t)).phase,
      NetworkChangePhase.unknown,
    );
    expect(
      h.transport.writes.where((r) => r['method'] == 'interface.checkin'),
      hasLength(1),
    );
  });
  test(
    'checkin successful reply with mismatched post-state is unknown',
    () async {
      final h = await _connected();
      final t = (await _begin(h)).transaction!;
      h.transport.afterCheckin = () =>
          h.transport.rows.single['description'] = 'foreign';
      expect(
        (await h.repository.keepNetworkTest(t)).phase,
        NetworkChangePhase.unknown,
      );
    },
  );
  test('forged handle and another session cannot operate the timer', () async {
    final h = await _connected();
    final other = await _connected();
    final t = (await _begin(h)).transaction!;
    final forged = NetworkTransaction(
      interfaceId: t.interfaceId,
      original: t.original,
      requested: t.requested,
    );
    await expectLater(
      h.repository.keepNetworkTest(forged),
      throwsA(_reason(NetworkExceptionReason.staleSession)),
    );
    await expectLater(
      other.repository.revertNetworkTest(t),
      throwsA(_reason(NetworkExceptionReason.staleSession)),
    );
    expect(h.transport.writes, hasLength(2));
    expect(other.transport.writes, isEmpty);
  });
  test(
    'disconnected original session cannot control outstanding transaction',
    () async {
      final h = await _connected();
      final t = (await _begin(h)).transaction!;
      await h.repository.close();
      await expectLater(
        h.repository.keepNetworkTest(t),
        throwsA(_reason(NetworkExceptionReason.notAuthenticated)),
      );
      expect(h.transport.writes, hasLength(2));
    },
  );
  test('SDK lock covers network preflight, testing, unknown and both older gateways', () async {
    final h = await _connected();
    final inventory = await h.repository.loadNetworkInventory();
    final request = _request(inventory);
    h.transport.suppressMethods.add('failover.licensed');
    final start = h.repository.beginNetworkTest(request);
    await expectLater(
      h.repository.beginNetworkTest(request),
      throwsA(_reason(NetworkExceptionReason.busy)),
    );
    await expectLater(
      h.repository.execute(
        const CreateDatasetCommand(parent: 'tank', name: 'x'),
      ),
      throwsA(
        isA<ManagementException>().having(
          (e) => e.reason,
          'reason',
          ManagementExceptionReason.busy,
        ),
      ),
    );
    final admin = AdminRequest(
      method: h.repository.adminCatalog.method('system.info')!,
      arguments: [],
    );
    await expectLater(
      h.repository.invokeAdmin(admin),
      throwsA(
        isA<AdminException>().having(
          (e) => e.reason,
          'reason',
          AdminExceptionReason.busy,
        ),
      ),
    );
    h.transport.suppressMethods.clear();
    h.transport.respond(h.transport.requests.last, false);
    final t = (await start).transaction!;
    await expectLater(
      h.repository.invokeAdmin(admin),
      throwsA(isA<AdminException>()),
    );
    h.transport.waiting = null;
    expect(
      (await h.repository.checkNetworkTest(t)).phase,
      NetworkChangePhase.unknown,
    );
    await expectLater(
      h.repository.execute(
        const CreateDatasetCommand(parent: 'tank', name: 'x'),
      ),
      throwsA(isA<ManagementException>()),
    );
    h.transport.restore();
    expect(
      (await h.repository.checkNetworkTest(t)).phase,
      NetworkChangePhase.reverted,
    );
    expect(await h.repository.invokeAdmin(admin), isA<AdminCompleted>());
  });
  test(
    'a pending legacy or generic submission blocks beginning network test',
    () async {
      for (final generic in [true, false]) {
        final h = await _connected();
        final inventory = await h.repository.loadNetworkInventory();
        h.transport.suppressMethods.add(
          generic ? 'system.info' : 'pool.dataset.create',
        );
        final Future<Object?> submitting = generic
            ? h.repository.invokeAdmin(
                AdminRequest(
                  method: h.repository.adminCatalog.method('system.info')!,
                  arguments: [],
                ),
              )
            : h.repository.execute(
                const CreateDatasetCommand(parent: 'tank', name: 'x'),
              );
        await expectLater(
          h.repository.beginNetworkTest(_request(inventory)),
          throwsA(_reason(NetworkExceptionReason.busy)),
        );
        h.transport.respond(
          h.transport.requests.last,
          generic ? {'version': '25.10.1'} : {'id': 'tank/x'},
        );
        await submitting;
        expect(h.transport.writes, isEmpty);
      }
    },
  );
  test(
    'input rejects unsafe addresses, duplicates, controls and bounds',
    () async {
      final h = await _connected();
      final inventory = await h.repository.loadNetworkInventory();
      for (final address in [
        '0.0.0.0',
        '127.0.0.1',
        '224.0.0.1',
        '255.255.255.255',
        '169.254.1.1',
        '192.168.001.1',
        '1.2.3',
        '1.2.3.999',
        '1.2.3.4\n',
      ]) {
        expect(
          _request(
            inventory,
            aliases: [NetworkAddress(address: address, netmask: 24)],
          ).validationError,
          isNotNull,
          reason: address,
        );
      }
      for (final request in [
        _request(inventory, description: 'x\u202ey'),
        _request(inventory, description: 'x' * 65),
        _request(inventory, mtu: 1000),
        _request(inventory, mtu: 9001),
        _request(inventory, aliases: []),
        _request(inventory, dhcp: true),
        _request(
          inventory,
          aliases: List.filled(
            2,
            const NetworkAddress(address: '192.168.1.20', netmask: 24),
          ),
        ),
        _request(
          inventory,
          aliases: [const NetworkAddress(address: '192.168.1.20', netmask: 0)],
        ),
      ]) {
        await expectLater(
          h.repository.beginNetworkTest(request),
          throwsA(_reason(NetworkExceptionReason.invalidInput)),
        );
      }
      expect(h.transport.writes, isEmpty);
    },
  );
}

NetworkChangeRequest _request(
  NetworkInventory inventory, {
  String description = 'Storage LAN',
  bool dhcp = false,
  int? mtu = 1500,
  List<NetworkAddress> aliases = const [
    NetworkAddress(address: '192.168.1.20', netmask: 24),
  ],
}) => NetworkChangeRequest(
  inventory: inventory,
  interfaceId: 'eno1',
  description: description,
  dhcp: dhcp,
  ipv4Aliases: aliases,
  mtu: mtu,
);
Future<NetworkChangeResult> _begin(_Harness h) async => h.repository
    .beginNetworkTest(_request(await h.repository.loadNetworkInventory()));
Future<_Harness> _connected({
  String version = '25.10.1',
  Set<String> methods = _methods,
  Duration timeout = const Duration(seconds: 1),
}) async {
  final h = _Harness(version: version, methods: methods, timeout: timeout);
  addTearDown(h.repository.close);
  await h.repository.connect(
    serverInput: 'https://nas.example',
    apiKey: 'fixture-key',
    username: 'admin',
  );
  return h;
}

final class _Harness {
  _Harness({
    String version = '25.10.1',
    Set<String> methods = _methods,
    Duration timeout = const Duration(seconds: 1),
  }) {
    transport = _Transport(version, methods);
    repository = TrueNasSessionRepository(
      connector: _Connector(transport),
      managementRequestTimeout: timeout,
    );
  }
  late final _Transport transport;
  late final TrueNasSessionRepository repository;
}

final class _Connector implements RpcConnector {
  const _Connector(this.transport);
  final RpcTransport transport;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => transport;
}

final class _Transport implements RpcTransport {
  _Transport(this.version, this.methods);
  final String version;
  final Set<String> methods;
  final _inbound = StreamController<String>();
  final requests = <Map<String, Object?>>[];
  List<Map<String, Object?>> rows = [_row()];
  List<Map<String, Object?>>? original;
  final config = <String, Object?>{
    'hostname': 'nas',
    'ipv4gateway': '192.168.1.1',
    'nameserver1': '192.168.1.1',
  };
  Object? licensed = false;
  Object? productType = 'COMMUNITY_EDITION';
  bool pending = false;
  int? waiting;
  List<Object?> removals = [];
  List<Object?> services = [];
  Map<String, Object?> appIps = {};
  final rejectMethods = <String>{};
  final suppressMethods = <String>{};
  void Function()? afterUpdate;
  void Function()? afterCheckin;
  bool closed = false;
  Iterable<Map<String, Object?>> get writes =>
      requests.where((r) => _writeMethods.contains(r['method']));
  @override
  Stream<String> get inboundFrames => _inbound.stream;
  @override
  Future<void> send(String frame) async {
    final r = Map<String, Object?>.from(jsonDecode(frame) as Map);
    requests.add(r);
    final method = r['method'] as String;
    if (suppressMethods.contains(method)) return;
    if (rejectMethods.contains(method)) {
      _inbound.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': r['id'],
          'error': {
            'code': -32001,
            'message': 'private-remote-data',
            'data': {'errno': 13},
          },
        }),
      );
      return;
    }
    Object? result;
    switch (method) {
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
              'returns': [
                {'type': 'object', 'properties': <String, Object?>{}},
              ],
              'job': false,
              'no_auth_required': false,
              'filterable': false,
              'downloadable': false,
              'uploadable': false,
            },
        };
      case 'failover.licensed':
        result = licensed;
      case 'system.product_type':
        result = productType;
      case 'interface.query':
        result = rows;
      case 'network.configuration.config':
        result = config;
      case 'interface.has_pending_changes':
        result = pending;
      case 'interface.checkin_waiting':
        result = waiting;
      case 'interface.network_config_to_be_removed':
        result = removals;
      case 'interface.services_restarted_on_sync':
        result = services;
      case 'app.used_host_ips':
        result = appIps;
      case 'interface.update':
        original = (jsonDecode(jsonEncode(rows)) as List)
            .map((r) => Map<String, Object?>.from(r as Map))
            .toList();
        final args = r['params'] as List;
        rows
            .firstWhere((row) => row['id'] == args[0])
            .addAll(Map<String, Object?>.from(args[1] as Map));
        pending = true;
        afterUpdate?.call();
        result = rows.firstWhere((row) => row['id'] == args[0]);
      case 'interface.commit':
        waiting = 55;
      case 'interface.checkin':
        pending = false;
        waiting = null;
        afterCheckin?.call();
      case 'interface.rollback':
        restore();
      default:
        result = null;
    }
    respond(r, result);
  }

  void restore() {
    if (original != null) rows = original!;
    pending = false;
    waiting = null;
    services = [];
    removals = [];
  }

  void respond(Map<String, Object?> request, Object? value) => _inbound.add(
    jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': value}),
  );
  @override
  Future<void> close() async {
    if (closed) return;
    closed = true;
    await _inbound.close();
  }
}
