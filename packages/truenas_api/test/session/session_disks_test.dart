import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _id = '{serial_lunid}SERIAL01_5000abc',
    _secret = 'synthetic-secret-never-display';
const _methods = {
  'disk.query',
  'device.get_info',
  'boot.get_disks',
  'failover.licensed',
  'core.get_jobs',
  'disk.update',
};
Map<String, Object?> _row() => {
  'identifier': _id,
  'name': 'sda',
  'serial': 'SERIAL01',
  'lunid': '5000abc',
  'size': 12000000000000,
  'model': 'Sample HDD',
  'type': 'HDD',
  'bus': 'ATA',
  'description': 'Bay 1',
  'hddstandby': 'ALWAYS ON',
  'advpowermgmt': 'DISABLED',
  'pool': 'tank',
  'zfs_guid': '123456789',
  'rotationrate': 7200,
  'expiretime': null,
  'passwd': _secret,
  'kmip_uid': _secret,
  'smart': {'error': _secret},
  'temperature': 42,
  'partitions': [_secret],
};
Matcher _reason(DisksExceptionReason reason) =>
    isA<DisksException>().having((e) => e.reason, 'reason', reason);
Future<_Harness> _connected({
  String version = '25.10.1',
  Set<String> methods = _methods,
  String? flag,
  String flagMethod = 'disk.update',
}) async {
  final h = _Harness(version, methods, flag, flagMethod);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'synthetic',
    username: 'admin',
    isConnectionCurrent: () => h.current,
  );
  return h;
}

DiskRequest _request(DiskInventory inventory, {bool power = false}) =>
    DiskRequest(
      inventory: inventory,
      disk: inventory.disks.first,
      settings: DiskSettings(
        description: 'Bay 2',
        hddStandby: power ? '30' : inventory.disks.first.hddStandby,
        advancedPowerManagement: power
            ? '128'
            : inventory.disks.first.advancedPowerManagement,
      ),
    );
Future<DiskReview> _review(_Harness h, {bool power = false}) async =>
    h.repo.reviewDisk(_request(await h.repo.loadDisks(), power: power));

void main() {
  for (final pending in [true, false]) {
    test(
      '${pending ? 'pending' : 'unknown'} disk update fences other write families without frames',
      () async {
        const endpoint = 'wss://nas.example/api/current';
        final h = await _connected(
          methods: {
            ..._methods,
            'alert.list',
            'alert.dismiss',
            'alert.restore',
            'cloudsync.credentials.query',
            'cloudsync.query',
            'cloud_backup.query',
            'cloudsync.credentials.create',
            'keychaincredential.query',
            'keychaincredential.used_by',
            'keychaincredential.create',
            'replication.query',
            'pool.dataset.query',
            'pool.filesystem_choices',
            'pool.snapshot.query',
            'replication.delete',
            'filesystem.stat',
            'filesystem.statfs',
            'system.general.config',
            'cloudsync.delete',
            'system.version_short',
            'boot.get_state',
            'boot.environment.query',
            'update.status',
            'update.available_versions',
            'pool.dataset.create',
            'pool.query',
            'pool.scrub.query',
            'pool.scrub.create',
          },
        );
        final r = await _review(h);
        if (pending) {
          h.wire.held = Completer<void>();
        } else {
          h.wire.writeFault = 'permission';
        }
        final future = h.repo.executeDisk(r, r.target);
        await Future<void>.delayed(const Duration(milliseconds: 1));
        if (!pending) expect((await future).outcome, DiskOutcome.unknown);
        final n = h.wire.calls.length;
        const pool = PoolMaintenancePool(
          id: 1,
          name: 'tank',
          guid: '1234',
          status: 'ONLINE',
          healthy: true,
          warning: false,
        );
        await expectLater(
          h.repo.reviewPoolMaintenance(
            PoolMaintenanceRequest(
              inventory: PoolMaintenanceInventory(
                endpoint: endpoint,
                pools: const [pool],
                schedules: const [],
                timezone: 'UTC',
                failoverLicensed: false,
              ),
              action: PoolMaintenanceAction.createSchedule,
              pool: pool,
              settings: const PoolScrubScheduleSettings(),
            ),
          ),
          throwsA(
            isA<PoolMaintenanceException>().having(
              (e) => e.reason,
              'reason',
              PoolMaintenanceExceptionReason.busy,
            ),
          ),
        );
        final alert = AlertSnapshot(
          id: '11111111-1111-4111-8111-111111111111',
          klass: 'VolumeStatus',
          source: 'VolumeStatus',
          node: 'Controller A',
          level: 'CRITICAL',
          firstSeen: DateTime.utc(2026),
          lastSeen: DateTime.utc(2026),
          dismissed: false,
          oneShot: false,
        );
        await expectLater(
          h.repo.reviewAlert(
            AlertRequest(
              inventory: AlertInventory(
                endpoint: endpoint,
                failoverLicensed: false,
                alerts: [alert],
              ),
              alert: alert,
              action: AlertAction.dismiss,
            ),
          ),
          throwsA(
            isA<AlertsException>().having(
              (e) => e.reason,
              'reason',
              AlertsExceptionReason.busy,
            ),
          ),
        );
        await expectLater(
          h.repo.reviewCloudCredential(
            CloudCredentialRequest(
              inventory: CloudCredentialInventory(
                endpoint: endpoint,
                credentials: const [],
                references: const [],
              ),
              action: CloudCredentialAction.create,
              name: 'New',
              provider: 'S3',
            ),
          ),
          throwsA(
            isA<CloudCredentialsException>().having(
              (e) => e.reason,
              'reason',
              CloudCredentialsExceptionReason.busy,
            ),
          ),
        );
        await expectLater(
          h.repo.reviewSshCredential(
            SshCredentialRequest(
              inventory: SshCredentialInventory(
                endpoint: endpoint,
                credentials: const [],
              ),
              action: SshCredentialAction.importKeyPair,
              name: 'New',
            ),
          ),
          throwsA(
            isA<SshCredentialsException>().having(
              (e) => e.reason,
              'reason',
              SshCredentialsExceptionReason.busy,
            ),
          ),
        );
        await expectLater(
          h.repo.reviewReplication(
            ReplicationRequest(
              inventory: ReplicationInventory(
                endpoint: endpoint,
                tasks: const [],
                datasets: const [],
              ),
              action: ReplicationAction.delete,
            ),
          ),
          throwsA(
            isA<ReplicationException>().having(
              (e) => e.reason,
              'reason',
              ReplicationExceptionReason.busy,
            ),
          ),
        );
        await expectLater(
          h.repo.reviewCloudSync(
            CloudSyncRequest(
              inventory: CloudSyncInventory(
                endpoint: endpoint,
                timezone: 'UTC',
                tasks: const [],
                credentials: const [],
                datasets: const [],
              ),
              action: CloudSyncAction.delete,
            ),
          ),
          throwsA(
            isA<CloudSyncException>().having(
              (e) => e.reason,
              'reason',
              CloudSyncExceptionReason.busy,
            ),
          ),
        );
        await expectLater(
          h.repo.reviewSystemUpdate(
            SystemUpdateRequest(
              inventory: SystemUpdateInventory(
                endpoint: endpoint,
                currentVersion: '25.10.1',
                bootPool: 'boot-pool',
                bootHealthy: true,
                failoverLicensed: false,
                conflictingJob: false,
                environments: const [],
              ),
              action: SystemUpdateAction.check,
            ),
          ),
          throwsA(
            isA<SystemUpdatesException>().having(
              (e) => e.reason,
              'reason',
              SystemUpdatesExceptionReason.busy,
            ),
          ),
        );
        await expectLater(
          h.repo.execute(
            const CreateDatasetCommand(parent: 'tank', name: 'documents'),
          ),
          throwsA(
            isA<ManagementException>().having(
              (e) => e.reason,
              'reason',
              ManagementExceptionReason.busy,
            ),
          ),
        );
        expect(h.wire.calls.length, n);
        expect(h.wire.writes.length, 1);
        if (pending) {
          h.wire.held!.complete();
          expect((await future).outcome, DiskOutcome.succeeded);
        }
      },
    );
  }
  test('disconnected capability and reads fail without transport', () async {
    final h = _Harness('25.10.1', _methods, null, 'disk.update');
    expect(h.repo.disksCapabilities.connected, false);
    await expectLater(
      h.repo.loadDisks(),
      throwsA(_reason(DisksExceptionReason.notAuthenticated)),
    );
    expect(h.wire.calls, isEmpty);
    await h.repo.close();
  });
  test(
    'passive bounded projections and coded unknown health never retain secrets',
    () async {
      final h = await _connected(),
          inv = await h.repo.loadDisks(),
          d = inv.disks.single;
      expect(d.identifier, _id);
      expect(d.name, 'sda');
      expect(d.serial, 'SERIAL01');
      expect(d.pool, 'tank');
      expect(d.sizeBytes, 12000000000000);
      expect(d.identityVerified, true);
      expect(d.blockedReason, isNull);
      expect(d.temperatureCelsius, isNull);
      expect(d.smartStatus, contains('Not available'));
      expect(inv.warnings.join(), isNot(contains(_secret)));
      final query =
          h.wire.calls.singleWhere((c) => c['method'] == 'disk.query')['params']
              as List;
      expect(query.first, isEmpty);
      final options = query[1] as Map;
      expect(options['limit'], 513);
      expect(options['extra'], {
        'include_expired': false,
        'passwords': false,
        'pools': true,
      });
      expect(options['select'], [
        'identifier',
        'name',
        'serial',
        'lunid',
        'size',
        'model',
        'type',
        'bus',
        'description',
        'hddstandby',
        'advpowermgmt',
        'pool',
        'zfs_guid',
        'rotationrate',
        'expiretime',
      ]);
      expect(
        h.wire.calls.singleWhere(
          (c) => c['method'] == 'device.get_info',
        )['params'],
        [
          {'type': 'DISK', 'get_partitions': false, 'serials_only': true},
        ],
      );
      expect(
        h.wire.calls.map((c) => c['method']),
        isNot(contains('disk.temperatures')),
      );
      expect(h.wire.writes, isEmpty);
      expect(() => inv.disks.clear(), throwsUnsupportedError);
      expect(() => inv.warnings.clear(), throwsUnsupportedError);
    },
  );
  for (final version in [
    '24.10.2',
    '25.04.2',
    '25.10-BETA.1',
    '26.04.0',
    'unknown',
  ]) {
    test('$version cannot issue disk reads', () async {
      final h = await _connected(version: version), n = h.wire.calls.length;
      expect(h.repo.disksCapabilities.supported, false);
      await expectLater(
        h.repo.loadDisks(),
        throwsA(_reason(DisksExceptionReason.unsupportedVersion)),
      );
      expect(h.wire.calls.length, n);
    });
  }
  for (final method in _methods) {
    test('missing $method fails closed', () async {
      final h = await _connected(methods: {..._methods}..remove(method));
      if (method == 'disk.update') {
        final inv = await h.repo.loadDisks(), n = h.wire.calls.length;
        expect(h.repo.disksCapabilities.canUpdate, false);
        await expectLater(
          h.repo.reviewDisk(_request(inv)),
          throwsA(_reason(DisksExceptionReason.unavailableMethod)),
        );
        expect(h.wire.calls.length, n);
      } else {
        final n = h.wire.calls.length;
        await expectLater(
          h.repo.loadDisks(),
          throwsA(_reason(DisksExceptionReason.unavailableMethod)),
        );
        expect(h.wire.calls.length, n);
      }
    });
  }
  for (final flag in [
    'job',
    'uploadable',
    'downloadable',
    'private',
    '_private',
    'no_auth_required',
  ]) {
    test('unsafe metadata $flag blocks update', () async {
      final h = await _connected(flag: flag), inv = await h.repo.loadDisks();
      await expectLater(
        h.repo.reviewDisk(_request(inv)),
        throwsA(_reason(DisksExceptionReason.unavailableMethod)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final power in [false, true]) {
    test(
      '${power ? 'power' : 'description-only'} update sends only changed fields and verifies stored settings',
      () async {
        final h = await _connected(), r = await _review(h, power: power);
        expect(r.target, 'UPDATE $_id');
        expect(r.warnings.join(), contains('No automatic retry'));
        if (power) expect(r.warnings.join(), contains('60 seconds'));
        final result = await h.repo.executeDisk(r, r.target);
        expect(result.outcome, DiskOutcome.succeeded);
        expect(result.message, contains('stored settings'));
        expect(h.wire.writes.single['params'], [
          _id,
          {
            'description': 'Bay 2',
            if (power) 'hddstandby': '30',
            if (power) 'advpowermgmt': '128',
          },
        ]);
        expect(jsonEncode(h.wire.writes), isNot(contains(_secret)));
        expect(
          (await h.repo.executeDisk(r, r.target)).outcome,
          DiskOutcome.rejected,
        );
        expect(h.wire.writes.length, 1);
      },
    );
  }
  for (final standby in DiskSettings.standbyChoices) {
    test('official standby choice $standby validates', () {
      expect(
        DiskSettings(
          description: '',
          hddStandby: standby,
          advancedPowerManagement: 'DISABLED',
        ).validationError,
        isNull,
      );
    });
  }
  for (final apm in DiskSettings.apmChoices) {
    test('official APM choice $apm validates', () {
      expect(
        DiskSettings(
          description: 'Bay',
          hddStandby: 'ALWAYS ON',
          advancedPowerManagement: apm,
        ).validationError,
        isNull,
      );
    });
  }
  for (final bad in [
    const DiskSettings(
      description: 'line\nbreak',
      hddStandby: 'ALWAYS ON',
      advancedPowerManagement: 'DISABLED',
    ),
    const DiskSettings(
      description: 'control\u202e',
      hddStandby: 'ALWAYS ON',
      advancedPowerManagement: 'DISABLED',
    ),
    const DiskSettings(
      description: '',
      hddStandby: '1',
      advancedPowerManagement: 'DISABLED',
    ),
    const DiskSettings(
      description: '',
      hddStandby: 'ALWAYS ON',
      advancedPowerManagement: '255',
    ),
    DiskSettings(
      description: 'x' * 121,
      hddStandby: 'ALWAYS ON',
      advancedPowerManagement: 'DISABLED',
    ),
  ]) {
    test(
      'invalid typed settings rejected: ${bad.hddStandby}/${bad.advancedPowerManagement}/${bad.description.length}',
      () async {
        final h = await _connected(),
            inv = await h.repo.loadDisks(),
            n = h.wire.calls.length;
        expect(bad.validationError, isNotNull);
        await expectLater(
          h.repo.reviewDisk(
            DiskRequest(inventory: inv, disk: inv.disks.single, settings: bad),
          ),
          throwsA(_reason(DisksExceptionReason.invalidRequest)),
        );
        expect(h.wire.calls.length, n);
      },
    );
  }
  test('no-op request is blocked before reads', () async {
    final h = await _connected(),
        inv = await h.repo.loadDisks(),
        n = h.wire.calls.length;
    await expectLater(
      h.repo.reviewDisk(
        DiskRequest(
          inventory: inv,
          disk: inv.disks.single,
          settings: inv.disks.single.settings,
        ),
      ),
      throwsA(_reason(DisksExceptionReason.invalidRequest)),
    );
    expect(h.wire.calls.length, n);
  });
  for (final variant in ['SSD', 'NVME', 'boot', 'UNKNOWN']) {
    test(
      '$variant permits description only and refuses power change',
      () async {
        final h = await _connected();
        if (variant == 'SSD') h.wire.row['type'] = 'SSD';
        if (variant == 'NVME') h.wire.row['bus'] = 'NVME';
        if (variant == 'UNKNOWN') h.wire.row['type'] = null;
        if (variant == 'boot') h.wire.boot = ['sda'];
        final inv = await h.repo.loadDisks();
        expect(inv.disks.single.powerManagementBlockedReason, isNotNull);
        await expectLater(
          h.repo.reviewDisk(_request(inv, power: true)),
          throwsA(_reason(DisksExceptionReason.invalidRequest)),
        );
        final r = await h.repo.reviewDisk(_request(inv));
        expect(
          (await h.repo.executeDisk(r, r.target)).outcome,
          DiskOutcome.succeeded,
        );
      },
    );
  }
  for (final variant in [
    'missing-device',
    'wrong-device',
    'duplicate-device',
    'empty-serial',
    'device-id',
    'missing-size',
  ]) {
    test('$variant remains visible but cannot mutate', () async {
      final h = await _connected();
      switch (variant) {
        case 'missing-device':
          h.wire.devices = {};
        case 'wrong-device':
          h.wire.devices = {'sda': 'REPLACEMENT'};
        case 'duplicate-device':
          h.wire.devices = {'sda': 'SERIAL01', 'sdb': 'SERIAL01'};
        case 'empty-serial':
          h.wire.row['serial'] = '';
        case 'device-id':
          h.wire.row['identifier'] = '{devicename}sda';
        case 'missing-size':
          h.wire.row['size'] = null;
      }
      final inv = await h.repo.loadDisks();
      expect(inv.disks.single.blockedReason, isNotNull);
      await expectLater(
        h.repo.reviewDisk(_request(inv)),
        throwsA(_reason(DisksExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final fault in ['ha', 'jobs']) {
    test('$fault display-only inventory blocks reviews', () async {
      final h = await _connected();
      h.wire.drift(fault);
      final inv = await h.repo.loadDisks();
      expect(inv.blockedReason, isNotNull);
      await expectLater(
        h.repo.reviewDisk(_request(inv)),
        throwsA(_reason(DisksExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final fault in [
    'rows',
    'overflow',
    'duplicate-id',
    'duplicate-name',
    'identifier',
    'name',
    'serial',
    'size',
    'model',
    'type',
    'bus',
    'description',
    'hddstandby',
    'advpowermgmt',
    'pool',
    'zfs_guid',
    'rotationrate',
    'expiretime',
    'missing-field',
    'devices-type',
    'devices-size',
    'devices-name',
    'devices-serial',
    'boot-type',
    'boot-name',
    'boot-duplicate',
    'jobs-type',
    'jobs-size',
    'jobs-row',
    'jobs-id',
    'jobs-method',
    'jobs-state',
    'ha-type',
  ]) {
    test('malformed $fault is sanitized and fail-closed', () async {
      final h = await _connected();
      h.wire.readFault = fault;
      await expectLater(
        h.repo.loadDisks(),
        throwsA(_reason(DisksExceptionReason.invalidResponse)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final field in [
    'identifier',
    'name',
    'serial',
    'lunid',
    'size',
    'model',
    'type',
    'bus',
    'description',
    'hddstandby',
    'advpowermgmt',
    'pool',
    'zfs_guid',
    'rotationrate',
    'ha',
    'jobs',
    'boot',
    'device',
    'removed',
  ]) {
    test('fresh $field drift prevents dispatch and consumes review', () async {
      final h = await _connected(), r = await _review(h);
      h.wire.drift(field);
      expect(
        (await h.repo.executeDisk(r, r.target)).outcome,
        DiskOutcome.rejected,
      );
      expect(h.wire.writes, isEmpty);
      expect(
        (await h.repo.executeDisk(r, r.target)).outcome,
        DiskOutcome.rejected,
      );
    });
  }
  for (final fault in [
    'remote',
    'permission',
    'timeout',
    'null',
    'wrong-owner',
    'wrong-serial',
    'wrong-name',
    'wrong-settings',
    'no-op',
    'post-error',
    'post-ha',
    'post-jobs',
    'post-device',
    'post-pool',
    'post-size',
    'post-removed',
  ]) {
    test(
      'post-dispatch $fault is sticky unknown with no automatic replay',
      () async {
        final h = await _connected(), r = await _review(h);
        h.wire.writeFault = fault;
        final result = await h.repo.executeDisk(r, r.target);
        expect(result.outcome, DiskOutcome.unknown);
        expect(result.message, isNot(contains(_secret)));
        expect(h.wire.writes.length, 1);
        expect(
          (await h.repo.executeDisk(r, r.target)).outcome,
          DiskOutcome.rejected,
        );
        expect(h.wire.writes.length, 1);
      },
    );
  }
  test('remote read exception is sanitized and does not write', () async {
    final h = await _connected();
    h.wire.readFault = 'remote';
    try {
      await h.repo.loadDisks();
      fail('must throw');
    } on DisksException catch (e) {
      expect(e.reason, DisksExceptionReason.unavailable);
      expect('$e', isNot(contains(_secret)));
    }
    expect(h.wire.writes, isEmpty);
  });
  test('forged inventory and review cannot dispatch', () async {
    final h = await _connected(), inv = await h.repo.loadDisks();
    final forged = DiskInventory(
      endpoint: inv.endpoint,
      failoverLicensed: false,
      disks: inv.disks,
    );
    await expectLater(
      h.repo.reviewDisk(_request(forged)),
      throwsA(_reason(DisksExceptionReason.staleReview)),
    );
    final r = DiskReview(
      request: _request(inv),
      endpoint: inv.endpoint,
      warnings: const [],
    );
    expect(
      (await h.repo.executeDisk(r, r.target)).outcome,
      DiskOutcome.rejected,
    );
    expect(h.wire.writes, isEmpty);
  });
  test(
    'exact confirmation is required and failed attempt consumes review',
    () async {
      final h = await _connected(), r = await _review(h);
      expect(
        (await h.repo.executeDisk(r, '${r.target} ')).outcome,
        DiskOutcome.rejected,
      );
      expect(
        (await h.repo.executeDisk(r, r.target)).outcome,
        DiskOutcome.rejected,
      );
      expect(h.wire.writes, isEmpty);
    },
  );
  test('manual refresh invalidates the issued review', () async {
    final h = await _connected(), r = await _review(h);
    await h.repo.loadDisks();
    expect(
      (await h.repo.executeDisk(r, r.target)).outcome,
      DiskOutcome.rejected,
    );
    expect(h.wire.writes, isEmpty);
  });
  test('superseded review cannot dispatch', () async {
    final h = await _connected(), inv = await h.repo.loadDisks();
    final a = await h.repo.reviewDisk(_request(inv)),
        b = await h.repo.reviewDisk(_request(inv));
    expect(
      (await h.repo.executeDisk(a, a.target)).outcome,
      DiskOutcome.rejected,
    );
    expect(
      (await h.repo.executeDisk(b, b.target)).outcome,
      DiskOutcome.succeeded,
    );
  });
  test(
    'session replacement before dispatch sends zero additional frames',
    () async {
      final h = await _connected(),
          r = await _review(h),
          n = h.wire.calls.length;
      h.current = false;
      expect(
        (await h.repo.executeDisk(r, r.target)).outcome,
        DiskOutcome.rejected,
      );
      expect(h.wire.calls.length, n);
      expect(h.wire.writes, isEmpty);
    },
  );
  test('session replacement after submission is unknown', () async {
    final h = await _connected(), r = await _review(h);
    h.wire.held = Completer<void>();
    final future = h.repo.executeDisk(r, r.target);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    h.current = false;
    h.wire.held!.complete();
    expect((await future).outcome, DiskOutcome.unknown);
    expect(h.wire.writes.length, 1);
  });
  test('second execute and load cannot release an in-flight lock', () async {
    final h = await _connected(), r = await _review(h);
    h.wire.held = Completer<void>();
    final future = h.repo.executeDisk(r, r.target);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    final n = h.wire.calls.length;
    expect(
      (await h.repo.executeDisk(r, r.target)).outcome,
      DiskOutcome.rejected,
    );
    await expectLater(
      h.repo.loadDisks(),
      throwsA(_reason(DisksExceptionReason.busy)),
    );
    expect(h.wire.calls.length, n);
    h.wire.held!.complete();
    expect((await future).outcome, DiskOutcome.succeeded);
  });
  test('manual read after unknown does not clear mutation fence', () async {
    final h = await _connected(), r = await _review(h);
    h.wire.writeFault = 'permission';
    expect(
      (await h.repo.executeDisk(r, r.target)).outcome,
      DiskOutcome.unknown,
    );
    h.wire.writeFault = null;
    final inv = await h.repo.loadDisks(), n = h.wire.calls.length;
    await expectLater(
      h.repo.reviewDisk(_request(inv)),
      throwsA(_reason(DisksExceptionReason.busy)),
    );
    expect(h.wire.calls.length, n);
    expect(h.wire.writes.length, 1);
  });
}

class _Harness {
  _Harness(String version, Set<String> methods, String? flag, String flagMethod)
    : wire = _Wire(version, methods, flag, flagMethod) {
    repo = TrueNasSessionRepository(
      connector: _Connector(wire),
      managementRequestTimeout: const Duration(milliseconds: 250),
    );
  }
  final _Wire wire;
  late final TrueNasSessionRepository repo;
  bool current = true;
}

class _Connector implements RpcConnector {
  const _Connector(this.wire);
  final _Wire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class _Wire implements RpcTransport {
  _Wire(this.version, this.methods, this.flag, this.flagMethod);
  final String version, flagMethod;
  final Set<String> methods;
  final String? flag;
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  Map<String, Object?> row = _row();
  Object devices = {'sda': 'SERIAL01'}, boot = <Object?>[], jobs = <Object?>[];
  bool licensed = false, removed = false;
  String? readFault, writeFault;
  Completer<void>? held;
  List<Map<String, dynamic>> get writes =>
      calls.where((c) => c['method'] == 'disk.update').toList();
  @override
  Stream<String> get inboundFrames => inbound.stream;
  void drift(String field) {
    switch (field) {
      case 'identifier':
        row['identifier'] = '{serial}OTHER';
      case 'name':
        row['name'] = 'sdb';
      case 'serial':
        row['serial'] = 'OTHER';
      case 'lunid':
        row['lunid'] = '5000def';
      case 'size':
        row['size'] = 10000000000000;
      case 'model':
        row['model'] = 'Replacement';
      case 'type':
        row['type'] = 'SSD';
      case 'bus':
        row['bus'] = 'SAS';
      case 'description':
        row['description'] = 'Changed';
      case 'hddstandby':
        row['hddstandby'] = '60';
      case 'advpowermgmt':
        row['advpowermgmt'] = '254';
      case 'pool':
        row['pool'] = 'other';
      case 'zfs_guid':
        row['zfs_guid'] = '9999';
      case 'rotationrate':
        row['rotationrate'] = 5400;
      case 'ha':
        licensed = true;
      case 'jobs':
        jobs = [
          {
            'id': 1,
            'method': 'pool.scrub',
            'state': 'RUNNING',
            'arguments': [_secret],
          },
        ];
      case 'boot':
        boot = ['sda'];
      case 'device':
        devices = {'sda': 'REPLACED'};
      case 'removed':
        removed = true;
    }
  }

  @override
  Future<void> send(String frame) async {
    final request = jsonDecode(frame) as Map<String, dynamic>;
    calls.add(request);
    final method = request['method'] as String;
    Object? result;
    switch (method) {
      case 'auth.login_ex':
        result = {'response_type': 'SUCCESS'};
      case 'auth.me':
        result = {'username': 'admin'};
      case 'system.info':
        result = {
          'version': version,
          'hostname': 'nas',
          'system_product': 'Test',
        };
      case 'core.get_methods':
        result = {
          for (final m in methods)
            m: {
              'job': false,
              'uploadable': false,
              'downloadable': false,
              'no_auth_required': false,
              if (m == flagMethod && flag != null) flag!: true,
            },
        };
      case 'failover.licensed':
        result = readFault == 'ha-type' ? 'false' : licensed;
      case 'disk.query':
        if (readFault == 'remote') {
          _error(request);
          return;
        }
        final candidate = {...row};
        result = removed ? [] : [candidate];
        switch (readFault) {
          case 'rows':
            result = {};
          case 'overflow':
            result = List.filled(513, candidate);
          case 'duplicate-id':
            result = [
              candidate,
              {...candidate, 'name': 'sdb'},
            ];
          case 'duplicate-name':
            result = [
              candidate,
              {...candidate, 'identifier': '{serial}OTHER'},
            ];
          case 'identifier':
            candidate['identifier'] = 'bad\n$_secret';
          case 'name':
            candidate['name'] = '/dev/sda';
          case 'serial':
            candidate['serial'] = _secret * 256;
          case 'size':
            candidate['size'] = -1;
          case 'model':
            candidate['model'] = 'bad\n$_secret';
          case 'type':
            candidate['type'] = '<script>';
          case 'bus':
            candidate['bus'] = [];
          case 'description':
            candidate['description'] = 'bad\u0000$_secret';
          case 'hddstandby':
            candidate['hddstandby'] = '0';
          case 'advpowermgmt':
            candidate['advpowermgmt'] = '255';
          case 'pool':
            candidate['pool'] = {};
          case 'zfs_guid':
            candidate['zfs_guid'] = -1;
          case 'rotationrate':
            candidate['rotationrate'] = 1.5;
          case 'expiretime':
            candidate['expiretime'] = '2026-09-14';
          case 'missing-field':
            candidate.remove('pool');
        }
      case 'device.get_info':
        result = switch (readFault) {
          'devices-type' => [],
          'devices-size' => {for (var i = 0; i < 513; i++) 'sda$i': 'serial$i'},
          'devices-name' => {'/dev/sda': 'SERIAL01'},
          'devices-serial' => {'sda': {}},
          _ => devices,
        };
      case 'boot.get_disks':
        result = switch (readFault) {
          'boot-type' => {},
          'boot-name' => ['/dev/sda'],
          'boot-duplicate' => ['sda', 'sda'],
          _ => boot,
        };
      case 'core.get_jobs':
        const job = {'id': 1, 'method': 'pool.scrub', 'state': 'RUNNING'};
        result = switch (readFault) {
          'jobs-type' => {},
          'jobs-size' => List.filled(129, job),
          'jobs-row' => [null],
          'jobs-id' => [
            {...job, 'id': 0},
          ],
          'jobs-method' => [
            {...job, 'method': 'bad\n$_secret'},
          ],
          'jobs-state' => [
            {...job, 'state': 'SUCCESS'},
          ],
          _ => jobs,
        };
      case 'disk.update':
        if (held != null) await held!.future;
        if (writeFault != 'no-op') {
          row.addAll(
            Map<String, Object?>.from((request['params'] as List)[1] as Map),
          );
        }
        result = {...row, 'pool': null};
        switch (writeFault) {
          case 'remote' || 'permission':
            _error(request);
            return;
          case 'timeout':
            return;
          case 'null':
            result = null;
          case 'wrong-owner':
            (result as Map)['identifier'] = '{serial}OTHER';
          case 'wrong-serial':
            (result as Map)['serial'] = 'OTHER';
          case 'wrong-name':
            (result as Map)['name'] = 'sdb';
          case 'wrong-settings':
            (result as Map)['description'] = 'Other';
          case 'post-error':
            readFault = 'remote';
          default:
            if (writeFault?.startsWith('post-') == true) {
              drift(writeFault!.substring(5));
            }
        }
      default:
        throw StateError('Unexpected method $method');
    }
    if (!inbound.isClosed) {
      inbound.add(
        jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
      );
    }
  }

  void _error(Map request) {
    if (!inbound.isClosed) {
      inbound.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': request['id'],
          'error': {
            'code': -32000,
            'message': _secret,
            'data': {
              'errno': writeFault == 'permission' ? 13 : 5,
              'trace': _secret,
            },
          },
        }),
      );
    }
  }

  @override
  Future<void> close() async {
    await inbound.close();
  }
}
