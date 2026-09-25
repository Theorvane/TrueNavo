import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _methods = {
  'vm.query',
  'vm.create',
  'vm.update',
  'vm.delete',
  'vm.start',
  'vm.stop',
  'vm.restart',
  'vm.poweroff',
  'vm.suspend',
  'vm.resume',
  'vm.maximum_supported_vcpus',
  'vm.get_available_memory',
  'vm.cpu_model_choices',
  'vm.device.disk_choices',
  'vm.device.nic_attach_choices',
  'vm.device.create',
  'vm.device.update',
  'vm.device.delete',
  'filesystem.stat',
  'pool.dataset.query',
  'core.get_jobs',
};
const _uuid = 'aabbccdd-1111-4111-8111-aabbccddeeff';
const _newUuid = 'aabbccdd-2222-4222-8222-aabbccddeeff';
Map<String, Object?> _row({
  int id = 1,
  String name = 'guest',
  String uuid = _uuid,
  String state = 'STOPPED',
}) => {
  'id': id,
  'uuid': uuid,
  'name': name,
  'description': '',
  'memory': 2048,
  'min_memory': null,
  'vcpus': 1,
  'cores': 1,
  'threads': 1,
  'autostart': false,
  'bootloader': 'UEFI',
  'cpu_mode': 'HOST-MODEL',
  'cpu_model': null,
  'shutdown_timeout': 90,
  'time': 'LOCAL',
  'ensure_display_device': true,
  'hyperv_enlightenments': false,
  'trusted_platform_module': false,
  'enable_secure_boot': false,
  'cpuset': '0-3',
  'bootloader_ovmf': 'OVMF_CODE_4M.fd',
  'status': {
    'state': state,
    'pid': state == 'RUNNING' ? 100 : null,
    'domain_state': 'fixture',
  },
  'devices': <Map<String, Object?>>[],
};
Map<String, Object?> _device({
  int id = 10,
  int vm = 1,
  String type = 'DISK',
  String path = '/dev/zvol/tank/used',
  int order = 1000,
}) => {
  'id': id,
  'vm': vm,
  'order': order,
  'attributes': {
    'dtype': type,
    if (type == 'DISK') 'path': path,
    'type': type == 'DISPLAY' ? 'SPICE' : 'VIRTIO',
    'unknown_preserved': 'hidden',
    if (type == 'DISPLAY') 'password': 'private-display-password',
  },
};
VmConfiguration _config({
  String name = 'guest',
  int memory = 4096,
  int cores = 1,
  bool autostart = false,
}) => VmConfiguration(
  name: name,
  memoryMiB: memory,
  cores: cores,
  autostart: autostart,
);
Matcher _reason(VmExceptionReason reason) =>
    isA<VmException>().having((e) => e.reason, 'reason', reason);
Future<VirtualMachine> _vm(_Harness h) async =>
    (await h.repo.loadVirtualMachines()).machines.first;

void main() {
  test('inventory is bounded and never projects display secrets', () async {
    final h = await _connect();
    h.transport.devices.add(_device(type: 'DISPLAY'));
    final vm = await _vm(h);
    expect(vm.devices.single.attributes, isNot(contains('password')));
    expect(
      '${vm.devices.single.attributes}',
      isNot(contains('private-display-password')),
    );
    expect(h.transport.requests.last['params'], [
      [],
      {'limit': 257},
    ]);
    expect(h.transport.writes, isEmpty);
  });
  test(
    'unknown stable-version contract and omitted methods fail before writes',
    () async {
      final h = await _connect(version: '26.04.0');
      expect(h.repo.virtualMachineCapabilities.supported, false);
      await expectLater(
        h.repo.loadVirtualMachines(),
        throwsA(_reason(VmExceptionReason.unsupported)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test(
    'read-only account can inspect inventory but cannot review mutation',
    () async {
      final h = await _connect(methods: {'vm.query'});
      final vm = await _vm(h);
      await expectLater(
        h.repo.reviewVmAction(vm, VmAction.delete),
        throwsA(_reason(VmExceptionReason.unavailable)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test('choices exclude every VM attached disk and return bytes', () async {
    final h = await _connect();
    h.transport.devices.add(_device());
    final choices = await h.repo.loadVmChoices();
    expect(choices.disks.map((d) => d.value), ['/dev/zvol/tank/free']);
    expect(choices.availableMemoryBytes, 16 * 1024 * 1024 * 1024);
  });
  test(
    'create has exact synchronous config payload and no hidden device writes',
    () async {
      final h = await _connect();
      final review = await h.repo.reviewVmCreate(_config(name: 'new_guest'));
      final result = await h.repo.executeVmReview(
        review,
        confirmation: 'new_guest',
      );
      expect(result.outcome, VmOperationOutcome.verified);
      expect(h.transport.writes.length, 1);
      final body = (h.transport.writes.single['params'] as List).single as Map;
      expect(body['autostart'], false);
      expect(body.containsKey('devices'), false);
      expect(body.containsKey('uuid'), false);
      expect(body['memory'], 4096);
    },
  );
  test('create name race rejects without a create attempt', () async {
    final h = await _connect();
    final review = await h.repo.reviewVmCreate(_config(name: 'new_guest'));
    h.transport.rows.add(_row(id: 2, name: 'new_guest', uuid: _newUuid));
    expect(
      (await h.repo.executeVmReview(review, confirmation: 'new_guest')).outcome,
      VmOperationOutcome.rejected,
    );
    expect(h.transport.writes, isEmpty);
  });
  test('update sends changed fields only and preserves display secrets and CPU affinity', () async {
    final h = await _connect();
    h.transport.devices.add(_device(type: 'DISPLAY'));
    final review = await h.repo.reviewVmUpdate(await _vm(h), _config());
    expect(
      (await h.repo.executeVmReview(review, confirmation: 'guest')).outcome,
      VmOperationOutcome.verified,
    );
    expect(h.transport.writes.single['params'], [
      1,
      {'memory': 4096},
    ]);
    expect(
      (h.transport.devices.single['attributes'] as Map)['password'],
      'private-display-password',
    );
    expect(h.transport.rows.single['cpuset'], '0-3');
    expect('${review.changes}', isNot(contains('private-display-password')));
  });
  for (final field in ['uuid', 'memory', 'cpuset', 'state', 'secret']) {
    test('$field drift rejects before update dispatch', () async {
      final h = await _connect();
      h.transport.devices.add(_device(type: 'DISPLAY'));
      final review = await h.repo.reviewVmUpdate(await _vm(h), _config());
      switch (field) {
        case 'uuid':
          h.transport.rows.single['uuid'] = _newUuid;
        case 'memory':
          h.transport.rows.single['memory'] = 3000;
        case 'cpuset':
          h.transport.rows.single['cpuset'] = '4-7';
        case 'state':
          (h.transport.rows.single['status'] as Map)['state'] = 'RUNNING';
        case 'secret':
          (h.transport.devices.single['attributes'] as Map)['password'] =
              'changed';
      }
      expect(
        (await h.repo.executeVmReview(review, confirmation: 'guest')).outcome,
        VmOperationOutcome.rejected,
      );
      expect(h.transport.writes, isEmpty);
    });
  }
  test(
    'unexpected unedited-field change after successful RPC locks unknown',
    () async {
      final h = await _connect();
      final review = await h.repo.reviewVmUpdate(await _vm(h), _config());
      h.transport.changeUneditedOnWrite = true;
      expect(
        (await h.repo.executeVmReview(review, confirmation: 'guest')).outcome,
        VmOperationOutcome.unknown,
      );
      final later = await h.repo.reviewVmAction(await _vm(h), VmAction.start);
      await expectLater(
        h.repo.executeVmReview(later, confirmation: 'guest'),
        throwsA(_reason(VmExceptionReason.busy)),
      );
      expect(h.transport.writes.length, 1);
    },
  );
  test('wrong confirmation consumes review with no dispatch', () async {
    final h = await _connect();
    final review = await h.repo.reviewVmUpdate(await _vm(h), _config());
    expect(
      (await h.repo.executeVmReview(review, confirmation: 'wrong')).outcome,
      VmOperationOutcome.rejected,
    );
    expect(
      (await h.repo.executeVmReview(review, confirmation: 'guest')).outcome,
      VmOperationOutcome.rejected,
    );
    expect(h.transport.writes, isEmpty);
  });
  test('fabricated review cannot dispatch', () async {
    final h = await _connect();
    final review = VmReview(
      title: 'delete',
      targetName: 'guest',
      identity: _uuid,
      changes: [],
      warnings: [],
    );
    expect(
      (await h.repo.executeVmReview(review, confirmation: 'guest')).outcome,
      VmOperationOutcome.rejected,
    );
    expect(h.transport.writes, isEmpty);
  });
  for (final action in VmAction.values) {
    test(
      '${action.name} uses exact identity and source result shape',
      () async {
        final h = await _connect();
        final initial = action == VmAction.resume
            ? 'SUSPENDED'
            : [VmAction.start, VmAction.delete].contains(action)
            ? 'STOPPED'
            : 'RUNNING';
        (h.transport.rows.single['status'] as Map)['state'] = initial;
        final review = await h.repo.reviewVmAction(await _vm(h), action);
        var result = await h.repo.executeVmReview(
          review,
          confirmation: 'guest',
        );
        if (action == VmAction.stop || action == VmAction.restart) {
          expect(result.outcome, VmOperationOutcome.submitted);
          result = await h.repo.pollVmOperation(result.operation!);
        }
        expect(result.outcome, VmOperationOutcome.verified);
        expect(h.transport.writes.length, 1);
        if (action == VmAction.start) {
          expect(h.transport.writes.single['params'], [
            1,
            {'overcommit': false},
          ]);
        }
        if (action == VmAction.stop) {
          expect(h.transport.writes.single['params'], [
            1,
            {'force': false, 'force_after_timeout': false},
          ]);
        }
        if (action == VmAction.delete) {
          expect(h.transport.writes.single['params'], [
            1,
            {'zvols': false, 'force': false},
          ]);
        }
        if (action == VmAction.restart) {
          expect(review.warnings.join(), contains('overcommit'));
          expect(review.warnings.join(), contains('forcibly'));
        }
      },
    );
  }
  test('running guest cannot be deleted even though backend silently powers it off', () async {
    final h = await _connect();
    (h.transport.rows.single['status'] as Map)['state'] = 'RUNNING';
    await expectLater(
      h.repo.reviewVmAction(await _vm(h), VmAction.delete),
      throwsA(_reason(VmExceptionReason.invalidInput)),
    );
    expect(h.transport.writes, isEmpty);
  });
  test('start rejects insufficient non-overcommitted memory', () async {
    final h = await _connect();
    h.transport.availableMemory = 1;
    await expectLater(
      h.repo.reviewVmAction(await _vm(h), VmAction.start),
      throwsA(_reason(VmExceptionReason.invalidInput)),
    );
    expect(h.transport.writes, isEmpty);
  });
  for (final mismatch in ['id', 'method', 'arguments', 'FAILED', 'ABORTED']) {
    test(
      'owned job $mismatch mismatch is unknown and not automatically retried',
      () async {
        final h = await _connect();
        (h.transport.rows.single['status'] as Map)['state'] = 'RUNNING';
        final review = await h.repo.reviewVmAction(await _vm(h), VmAction.stop);
        final submitted = await h.repo.executeVmReview(
          review,
          confirmation: 'guest',
        );
        h.transport.jobMismatch = mismatch;
        final result = await h.repo.pollVmOperation(submitted.operation!);
        expect(result.outcome, VmOperationOutcome.unknown);
        expect(result.userMessage, isNot(contains('private-display-password')));
        expect(h.transport.writes.length, 1);
      },
    );
  }
  test(
    'pending job can be checked and fabricated job cannot query anything',
    () async {
      final h = await _connect();
      (h.transport.rows.single['status'] as Map)['state'] = 'RUNNING';
      final review = await h.repo.reviewVmAction(await _vm(h), VmAction.stop);
      final submitted = await h.repo.executeVmReview(
        review,
        confirmation: 'guest',
      );
      final before = h.transport.requests.length;
      expect(
        (await h.repo.pollVmOperation(
          const VmOperationHandle(id: 80, targetName: 'guest'),
        )).outcome,
        VmOperationOutcome.unknown,
      );
      expect(h.transport.requests.length, before);
      h.transport.jobState = 'RUNNING';
      expect(
        (await h.repo.pollVmOperation(submitted.operation!)).outcome,
        VmOperationOutcome.running,
      );
      h.transport.jobState = 'SUCCESS';
      expect(
        (await h.repo.pollVmOperation(submitted.operation!)).outcome,
        VmOperationOutcome.verified,
      );
    },
  );
  for (final failure in ['timeout', 'remote']) {
    test(
      'synchronous $failure outcome remains unknown with one write',
      () async {
        final h = await _connect();
        final review = await h.repo.reviewVmUpdate(await _vm(h), _config());
        h.transport.failure = failure;
        expect(
          (await h.repo.executeVmReview(review, confirmation: 'guest')).outcome,
          VmOperationOutcome.unknown,
        );
        expect(h.transport.writes.length, 1);
      },
    );
  }
  test('disk create never requests backing-volume creation and confirms independent device readback', () async {
    final h = await _connect();
    final vm = await _vm(h);
    final disk = (await h.repo.loadVmChoices()).disks.firstWhere(
      (d) => d.value.endsWith('/free'),
    );
    final review = await h.repo.reviewVmDevice(
      vm,
      VmDeviceChange.disk(disk: disk),
    );
    expect(
      (await h.repo.executeVmReview(review, confirmation: 'guest')).outcome,
      VmOperationOutcome.verified,
    );
    expect(h.transport.writes.single['params'], [
      {
        'vm': 1,
        'order': 1001,
        'attributes': {
          'dtype': 'DISK',
          'type': 'VIRTIO',
          'path': '/dev/zvol/tank/free',
          'create_zvol': false,
        },
      },
    ]);
  });
  test('disk newly attached elsewhere invalidates review', () async {
    final h = await _connect();
    final vm = await _vm(h);
    final disk = (await h.repo.loadVmChoices()).disks.firstWhere(
      (d) => d.value.endsWith('/free'),
    );
    final review = await h.repo.reviewVmDevice(
      vm,
      VmDeviceChange.disk(disk: disk),
    );
    final other = _row(id: 2, name: 'other', uuid: _newUuid);
    (other['devices'] as List).add(_device(id: 20, vm: 2, path: disk.value));
    h.transport.rows.add(other);
    expect(
      (await h.repo.executeVmReview(review, confirmation: 'guest')).outcome,
      VmOperationOutcome.rejected,
    );
    expect(h.transport.writes, isEmpty);
  });
  test(
    'same-path recreated zvol invalidates attachment and start reviews',
    () async {
      final h = await _connect();
      final disk = (await h.repo.loadVmChoices()).disks.first;
      final review = await h.repo.reviewVmDevice(
        await _vm(h),
        VmDeviceChange.disk(disk: disk),
      );
      h.transport.zvolGuid = '999';
      expect(
        (await h.repo.executeVmReview(review, confirmation: 'guest')).outcome,
        VmOperationOutcome.rejected,
      );
      h.transport.devices.add(_device());
      final start = await h.repo.reviewVmAction(await _vm(h), VmAction.start);
      h.transport.zvolGuid = '1000';
      expect(
        (await h.repo.executeVmReview(start, confirmation: 'guest')).outcome,
        VmOperationOutcome.rejected,
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test(
    'NIC and local-only display creation use explicit reviewed network scope',
    () async {
      final h = await _connect();
      final nic = (await h.repo.loadVmChoices()).interfaces.single;
      final review = await h.repo.reviewVmDevice(
        await _vm(h),
        VmDeviceChange.nic(interface: nic, order: 1001),
      );
      expect(
        (await h.repo.executeVmReview(review, confirmation: 'guest')).outcome,
        VmOperationOutcome.verified,
      );
      final display = await h.repo.reviewVmDevice(
        await _vm(h),
        const VmDeviceChange.display(order: 1002),
      );
      expect(
        (await h.repo.executeVmReview(display, confirmation: 'guest')).outcome,
        VmOperationOutcome.verified,
      );
      final attrs =
          ((h.transport.writes.last['params'] as List).single
                  as Map)['attributes']
              as Map;
      expect(attrs['bind'], '127.0.0.1');
      expect(attrs['web'], false);
      expect(attrs.containsKey('password'), false);
    },
  );
  test('device detach retains every backing storage flag', () async {
    final h = await _connect();
    h.transport.devices.add(_device());
    final vm = await _vm(h);
    final review = await h.repo.reviewVmDevice(
      vm,
      VmDeviceChange.remove(device: vm.devices.single),
    );
    expect(
      (await h.repo.executeVmReview(review, confirmation: 'guest')).outcome,
      VmOperationOutcome.verified,
    );
    expect(h.transport.writes.single['params'], [
      10,
      {'force': false, 'raw_file': false, 'zvol': false},
    ]);
  });
  test(
    'order edit preserves display credential using attribute omission',
    () async {
      final h = await _connect();
      h.transport.devices.add(_device(type: 'DISPLAY'));
      final vm = await _vm(h);
      final review = await h.repo.reviewVmDevice(
        vm,
        VmDeviceChange.order(device: vm.devices.single, order: 2),
      );
      expect(
        (await h.repo.executeVmReview(review, confirmation: 'guest')).outcome,
        VmOperationOutcome.verified,
      );
      expect(h.transport.writes.single['params'], [
        10,
        {'order': 2},
      ]);
      expect(
        (h.transport.devices.single['attributes'] as Map)['password'],
        'private-display-password',
      );
    },
  );
  test('ISO mount or inode change invalidates a device review', () async {
    final h = await _connect();
    final review = await h.repo.reviewVmDevice(
      await _vm(h),
      const VmDeviceChange.cdrom(isoPath: '/mnt/tank/install.iso'),
    );
    h.transport.stat['mount_id'] = 8;
    expect(
      (await h.repo.executeVmReview(review, confirmation: 'guest')).outcome,
      VmOperationOutcome.rejected,
    );
    expect(h.transport.writes, isEmpty);
  });
  test('ISO attachment verifies exact existing file identity', () async {
    final h = await _connect();
    final review = await h.repo.reviewVmDevice(
      await _vm(h),
      const VmDeviceChange.cdrom(isoPath: '/mnt/tank/install.iso'),
    );
    expect(
      (await h.repo.executeVmReview(review, confirmation: 'guest')).outcome,
      VmOperationOutcome.verified,
    );
    expect(
      h.transport.requests
          .where((r) => r['method'] == 'filesystem.stat')
          .map((r) => (r['params'] as List).single)
          .toList(),
      [
        '/mnt',
        '/mnt/tank',
        '/mnt/tank/install.iso',
        '/mnt',
        '/mnt/tank',
        '/mnt/tank/install.iso',
      ],
    );
    expect(review.warnings.join(), contains('ownership'));
  });
  for (final ancestor in ['/mnt', '/mnt/tank']) {
    test(
      'ISO rejects symlink ancestor $ancestor despite unchanged leaf realpath',
      () async {
        final h = await _connect();
        h.transport.directories[ancestor]!['type'] = 'SYMLINK';
        h.transport.directories[ancestor]!['realpath'] = '/outside';
        expect(h.transport.stat['realpath'], '/mnt/tank/install.iso');
        await expectLater(
          h.repo.reviewVmDevice(
            await _vm(h),
            const VmDeviceChange.cdrom(isoPath: '/mnt/tank/install.iso'),
          ),
          throwsA(_reason(VmExceptionReason.invalidResponse)),
        );
        expect(
          h.transport.requests
              .where((r) => r['method'] == 'filesystem.stat')
              .any(
                (r) => (r['params'] as List).single == '/mnt/tank/install.iso',
              ),
          false,
        );
        expect(h.transport.writes, isEmpty);
      },
    );
  }
  test(
    'incomplete ancestor proof fails closed without reading the leaf',
    () async {
      final h = await _connect();
      h.transport.directories['/mnt/tank']!.remove('mount_id');
      await expectLater(
        h.repo.reviewVmDevice(
          await _vm(h),
          const VmDeviceChange.cdrom(isoPath: '/mnt/tank/install.iso'),
        ),
        throwsA(_reason(VmExceptionReason.invalidResponse)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test(
    'ancestor becoming a symlink after ISO review rejects dispatch',
    () async {
      final h = await _connect();
      final review = await h.repo.reviewVmDevice(
        await _vm(h),
        const VmDeviceChange.cdrom(isoPath: '/mnt/tank/install.iso'),
      );
      h.transport.directories['/mnt/tank']!['type'] = 'SYMLINK';
      expect(
        (await h.repo.executeVmReview(review, confirmation: 'guest')).outcome,
        VmOperationOutcome.rejected,
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  for (final field in ['inode', 'dev', 'mount_id']) {
    test(
      'ISO ancestor $field drift invalidates otherwise identical leaf',
      () async {
        final h = await _connect();
        final review = await h.repo.reviewVmDevice(
          await _vm(h),
          const VmDeviceChange.cdrom(isoPath: '/mnt/tank/install.iso'),
        );
        h.transport.directories['/mnt/tank']![field] = 999;
        expect(
          (await h.repo.executeVmReview(review, confirmation: 'guest')).outcome,
          VmOperationOutcome.rejected,
        );
        expect(h.transport.writes, isEmpty);
      },
    );
  }
  for (final type in ['RAW', 'CDROM']) {
    test(
      '$type guest start rechecks non-symlink ancestors before dispatch',
      () async {
        final h = await _connect();
        h.transport.devices.add(
          _device(type: type)
            ..['attributes'] = {'dtype': type, 'path': '/mnt/tank/install.iso'},
        );
        final review = await h.repo.reviewVmAction(
          await _vm(h),
          VmAction.start,
        );
        h.transport.directories['/mnt/tank']!['type'] = 'SYMLINK';
        expect(
          (await h.repo.executeVmReview(review, confirmation: 'guest')).outcome,
          VmOperationOutcome.rejected,
        );
        expect(h.transport.writes, isEmpty);
      },
    );
  }
  test(
    'deep or noncanonical ISO paths are rejected before stat discovery',
    () async {
      final h = await _connect();
      final vm = await _vm(h);
      for (final path in [
        '/mnt/${List.filled(31, 'deep').join('/')}/install.iso',
        '/mnt/tank/../install.iso',
        '/mnt/tank/./install.iso',
        '/mnt//install.iso',
      ]) {
        await expectLater(
          h.repo.reviewVmDevice(vm, VmDeviceChange.cdrom(isoPath: path)),
          throwsA(_reason(VmExceptionReason.invalidInput)),
        );
      }
      expect(
        h.transport.requests.where((r) => r['method'] == 'filesystem.stat'),
        isEmpty,
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test('disconnect invalidates all issued handles without a write', () async {
    final h = await _connect();
    final review = await h.repo.reviewVmUpdate(await _vm(h), _config());
    await h.repo.close();
    await expectLater(
      h.repo.executeVmReview(review, confirmation: 'guest'),
      throwsA(isA<VmException>()),
    );
    expect(h.transport.writes, isEmpty);
  });
}

Future<_Harness> _connect({
  String version = '25.10.1',
  Set<String> methods = _methods,
}) async {
  final h = _Harness(version, methods);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'fixture-key',
    username: 'admin',
  );
  return h;
}

class _Harness {
  _Harness(String version, Set<String> methods) {
    transport = _Transport(version, methods);
    repo = TrueNasSessionRepository(
      connector: _Connector(transport),
      managementRequestTimeout: const Duration(milliseconds: 80),
    );
  }
  late final TrueNasSessionRepository repo;
  late final _Transport transport;
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
  final rows = [_row()];
  List<Map<String, Object?>> get devices =>
      rows.first['devices'] as List<Map<String, Object?>>;
  final stat = <String, Object?>{
    'type': 'FILE',
    'realpath': '/mnt/tank/install.iso',
    'inode': 10,
    'dev': 1,
    'mount_id': 3,
    'size': 100,
    'mtime': 1.0,
    'ctime': 1.0,
  };
  final directories = <String, Map<String, Object?>>{
    '/mnt': {
      'type': 'DIRECTORY',
      'realpath': '/mnt',
      'inode': 1,
      'dev': 1,
      'mount_id': 1,
    },
    '/mnt/tank': {
      'type': 'DIRECTORY',
      'realpath': '/mnt/tank',
      'inode': 2,
      'dev': 2,
      'mount_id': 2,
    },
  };
  int availableMemory = 16 * 1024 * 1024 * 1024;
  String zvolGuid = '12345';
  String? failure, jobMismatch;
  bool changeUneditedOnWrite = false;
  String jobState = 'SUCCESS';
  Map<String, Object?>? job;
  Iterable<Map<String, Object?>> get writes => requests.where(
    (r) =>
        _methods.contains(r['method']) &&
        !{
          'vm.query',
          'vm.maximum_supported_vcpus',
          'vm.get_available_memory',
          'vm.cpu_model_choices',
          'vm.device.disk_choices',
          'vm.device.nic_attach_choices',
          'filesystem.stat',
          'pool.dataset.query',
          'core.get_jobs',
        }.contains(r['method']),
  );
  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String frame) async {
    final r = Map<String, Object?>.from(jsonDecode(frame) as Map);
    requests.add(r);
    final method = r['method'];
    final args = (r['params'] ?? []) as List;
    Object? result;
    if (writes.contains(r)) {
      if (failure == 'timeout') return;
      if (failure == 'remote') {
        inbound.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': r['id'],
            'error': {'code': -1, 'message': 'private-display-password'},
          }),
        );
        return;
      }
      if (method == 'vm.stop' || method == 'vm.restart') {
        job = r;
        result = 80;
      } else {
        result = _apply(r);
      }
      if (changeUneditedOnWrite && rows.isNotEmpty) {
        rows.first['cpuset'] = '4-7';
      }
    } else {
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
                'accepts': [],
                'returns': [],
                'job': m == 'vm.stop' || m == 'vm.restart',
                'no_auth_required': false,
              },
          };
        case 'vm.query':
          final filters = args.first as List;
          result = filters.isEmpty
              ? rows
              : rows
                    .where((v) => v['id'] == (filters.first as List).last)
                    .toList();
        case 'vm.maximum_supported_vcpus':
          result = 64;
        case 'vm.get_available_memory':
          result = availableMemory;
        case 'vm.cpu_model_choices':
          result = {'qemu64': 'qemu64'};
        case 'vm.device.disk_choices':
          result = {
            '/dev/zvol/tank/free': 'tank/free',
            '/dev/zvol/tank/used': 'tank/used',
          };
        case 'vm.device.nic_attach_choices':
          result = {'br0': 'Bridge br0'};
        case 'filesystem.stat':
          result = args.single == stat['realpath']
              ? stat
              : directories[args.single];
        case 'pool.dataset.query':
          result = [
            {
              'id': ((args.first as List).single as List).last,
              'type': 'VOLUME',
              'locked': false,
              'guid': {'rawvalue': zvolGuid},
              'creation': {'rawvalue': '123'},
              'volsize': {'rawvalue': '1073741824'},
              'readonly': {'rawvalue': 'off'},
            },
          ];
        case 'core.get_jobs':
          if (jobState == 'SUCCESS' && jobMismatch == null) _apply(job!);
          result = [
            {
              'id': jobMismatch == 'id' ? 81 : 80,
              'method': jobMismatch == 'method' ? 'vm.delete' : job!['method'],
              'arguments': jobMismatch == 'arguments' ? [2] : job!['params'],
              'state': ['FAILED', 'ABORTED'].contains(jobMismatch)
                  ? jobMismatch
                  : jobState,
              'error': 'private-display-password',
              'result': null,
            },
          ];
        default:
          result = <Object?>[];
      }
    }
    inbound.add(
      jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': result}),
    );
  }

  Object? _apply(Map<String, Object?> r) {
    final args = r['params'] as List;
    switch (r['method']) {
      case 'vm.create':
        final row = _row(
          id: 2,
          name: (args.single as Map)['name'] as String,
          uuid: _newUuid,
        )..addAll(Map<String, Object?>.from(args.single as Map));
        rows.add(row);
        return row;
      case 'vm.update':
        rows.first.addAll(Map<String, Object?>.from(args.last as Map));
        return rows.first;
      case 'vm.delete':
        rows.removeWhere((v) => v['id'] == args.first);
        return true;
      case 'vm.device.create':
        final body = args.single as Map;
        final attrs = Map<String, Object?>.from(body['attributes'] as Map)
          ..remove('create_zvol');
        final d = <String, Object?>{
          'id': 20 + devices.length,
          'vm': body['vm'],
          'order': body['order'],
          'attributes': attrs,
        };
        devices.add(d);
        return d;
      case 'vm.device.update':
        final d = devices.firstWhere((v) => v['id'] == args.first);
        final patch = args.last as Map;
        if (patch.containsKey('order')) d['order'] = patch['order'];
        if (patch['attributes'] is Map) {
          (d['attributes'] as Map).addAll(patch['attributes'] as Map);
        }
        return d;
      case 'vm.device.delete':
        devices.removeWhere((d) => d['id'] == args.first);
        return true;
      default:
        (rows.first['status'] as Map)['state'] = switch (r['method']) {
          'vm.start' || 'vm.restart' || 'vm.resume' => 'RUNNING',
          'vm.suspend' => 'SUSPENDED',
          _ => 'STOPPED',
        };
        return null;
    }
  }

  @override
  Future<void> close() async {
    if (!inbound.isClosed) await inbound.close();
  }
}
