import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _host =
        '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
    _boot = '11111111-2222-4333-8444-555555555555',
    _endpoint = 'wss://nas.example/api/current',
    _secret = 'synthetic-secret-never-display';
const _reads = {
  'system.version_short',
  'system.host_id',
  'system.reboot.info',
  'system.state',
  'failover.licensed',
  'boot.get_state',
  'boot.environment.query',
  'core.get_jobs',
};
const _methods = {..._reads, 'system.reboot', 'system.shutdown'};
const _peerMethods = {
  ..._methods,
  'alert.list',
  'alert.dismiss',
  'alert.restore',
  'disk.query',
  'device.get_info',
  'boot.get_disks',
  'disk.update',
  'pool.query',
  'pool.scrub.query',
  'pool.scrub.create',
  'cloudsync.credentials.query',
  'cloudsync.query',
  'cloud_backup.query',
  'cloudsync.credentials.create',
  'keychaincredential.query',
  'user.query',
  'pool.dataset.query',
  'filesystem.stat',
  'filesystem.statfs',
  'system.general.config',
  'rsynctask.query',
  'rsynctask.create',
  'pool.dataset.create',
  'auth.me',
  'auth.sessions',
  'api_key.query',
  'system.security.config',
  'api_key.create',
};
Map<String, Object?> _environment() => {
  'id': '25.10.1',
  'dataset': 'boot-pool/ROOT/25.10.1',
  'created': '2026-09-14T01:00:00',
  'used_bytes': 4000,
  'active': true,
  'activated': true,
  'keep': true,
  'can_activate': true,
};
Map<String, Object?> _alert() => {
  'id': '11111111-1111-4111-8111-111111111111',
  'uuid': '11111111-1111-4111-8111-111111111111',
  'klass': 'VolumeStatus',
  'source': 'VolumeStatus',
  'node': 'Controller A',
  'level': 'CRITICAL',
  'datetime': '2026-09-14T01:00:00',
  'last_occurrence': '2026-09-14T02:00:00',
  'dismissed': false,
  'one_shot': false,
  'text': _secret,
  'args': {'volume': _secret},
};
Matcher _reason(SystemPowerExceptionReason reason) =>
    isA<SystemPowerException>().having((e) => e.reason, 'reason', reason);
Future<_Harness> _connected({
  String version = '25.10.1',
  Set<String> methods = _methods,
  Map<String, Map<String, Object?>> metadata = const {},
}) async {
  final h = _Harness(version, methods, metadata);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'synthetic',
    username: 'admin',
    isConnectionCurrent: () => h.current,
  );
  return h;
}

SystemPowerRequest _request(
  SystemPowerInventory inventory, {
  SystemPowerAction action = SystemPowerAction.reboot,
  String reason = 'Planned maintenance',
}) => SystemPowerRequest(inventory: inventory, action: action, reason: reason);
Future<SystemPowerReview> _review(
  _Harness h, {
  SystemPowerAction action = SystemPowerAction.reboot,
}) async => h.repo.reviewSystemPower(
  _request(await h.repo.loadSystemPower(), action: action),
);

class _Harness {
  _Harness(
    String version,
    Set<String> methods,
    Map<String, Map<String, Object?>> metadata,
  ) : wire = _Wire(version, methods, metadata) {
    repo = TrueNasSessionRepository(
      connector: _Connector(wire),
      managementRequestTimeout: const Duration(milliseconds: 100),
      systemPowerNow: () => now,
    );
  }
  final _Wire wire;
  late final TrueNasSessionRepository repo;
  bool current = true;
  DateTime now = DateTime.utc(2026, 9, 14);
}

class _Connector implements RpcConnector {
  const _Connector(this.wire);
  final _Wire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class _Wire implements RpcTransport {
  _Wire(this.version, this.methods, this.metadata) {
    values['system.version_short'] = version;
  }
  final String version;
  final Set<String> methods;
  final Map<String, Map<String, Object?>> metadata;
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  final counts = <String, int>{};
  final values = <String, Object?>{
    'system.host_id': _host,
    'system.reboot.info': {
      'boot_id': _boot,
      'reboot_required_reasons': [
        {'code': 'FIPS', 'reason': _secret},
      ],
    },
    'system.state': 'READY',
    'failover.licensed': false,
    'boot.get_state': {
      'name': 'boot-pool',
      'healthy': true,
      'status': 'ONLINE',
      'scan': null,
      'topology': _secret,
    },
    'boot.environment.query': [_environment()],
    'core.get_jobs': <Object?>[],
    'alert.list': [_alert()],
  };
  Object? receipt = 71;
  String? faultMethod, fault;
  void Function(String method, int count)? beforeReply;
  Completer<void>? held;
  List<Map<String, dynamic>> get writes => calls
      .where(
        (c) =>
            c['method'] == 'system.reboot' || c['method'] == 'system.shutdown',
      )
      .toList();
  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String frame) async {
    final r = jsonDecode(frame) as Map<String, dynamic>;
    calls.add(r);
    final m = r['method'] as String;
    counts[m] = (counts[m] ?? 0) + 1;
    beforeReply?.call(m, counts[m]!);
    if (m == faultMethod) {
      if (held != null) await held!.future;
      if (fault == 'timeout') return;
      if (fault == 'disconnect') {
        await inbound.close();
        return;
      }
      if (fault == 'remote') {
        inbound.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': r['id'],
            'error': {
              'code': -32000,
              'message': _secret,
              'data': {'errno': 13, 'trace': _secret},
            },
          }),
        );
        return;
      }
    }
    Object? value;
    switch (m) {
      case 'auth.login_ex':
        value = {'response_type': 'SUCCESS'};
      case 'auth.me':
        value = {'username': 'admin'};
      case 'system.info':
        value = {
          'version': version,
          'hostname': 'nas',
          'system_product': 'Synthetic',
        };
      case 'core.get_methods':
        value = {
          for (final method in methods)
            method: {
              'job':
                  method == 'system.reboot' ||
                  method == 'system.shutdown' ||
                  method == 'rsynctask.run',
              'uploadable': false,
              'downloadable': false,
              'no_auth_required': false,
              ...?metadata[method],
            },
        };
      case 'system.reboot' || 'system.shutdown':
        value = receipt;
      case 'alert.dismiss':
        (values['alert.list'] as List).single['dismissed'] = true;
        value = null;
      default:
        if (!values.containsKey(m)) throw StateError('Unexpected RPC $m');
        value = values[m];
    }
    if (!inbound.isClosed) {
      inbound.add(
        jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': value}),
      );
    }
  }

  @override
  Future<void> close() async {
    if (!inbound.isClosed) await inbound.close();
  }
}

Future<void> _assertPeerFences(_Harness h) async {
  final n = h.wire.calls.length;
  const disk = DiskSnapshot(
    identifier: '{serial}SERIAL',
    name: 'sda',
    serial: 'SERIAL',
    lunid: null,
    sizeBytes: 4000,
    model: null,
    type: 'HDD',
    bus: 'ATA',
    description: '',
    hddStandby: 'ALWAYS ON',
    advancedPowerManagement: 'DISABLED',
    pool: null,
    zfsGuid: null,
    rotationRate: 7200,
    identityVerified: true,
  );
  await expectLater(
    h.repo.reviewDisk(
      DiskRequest(
        inventory: DiskInventory(
          endpoint: _endpoint,
          failoverLicensed: false,
          disks: const [disk],
        ),
        disk: disk,
        settings: const DiskSettings(
          description: 'changed',
          hddStandby: 'ALWAYS ON',
          advancedPowerManagement: 'DISABLED',
        ),
      ),
    ),
    throwsA(
      isA<DisksException>().having(
        (e) => e.reason,
        'reason',
        DisksExceptionReason.busy,
      ),
    ),
  );
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
          endpoint: _endpoint,
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
  await expectLater(
    h.repo.reviewRsync(
      RsyncRequest(
        inventory: RsyncInventory(
          endpoint: _endpoint,
          timezone: 'UTC',
          failoverLicensed: false,
          tasks: [],
          connections: [],
          users: [],
          datasets: [],
        ),
        action: RsyncAction.create,
      ),
    ),
    throwsA(
      isA<RsyncException>().having(
        (e) => e.reason,
        'reason',
        RsyncExceptionReason.busy,
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
          endpoint: _endpoint,
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
          endpoint: _endpoint,
          credentials: [],
          references: [],
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
    h.repo.reviewApiKey(
      ApiKeyRequest(
        inventory: ApiKeyInventory(
          endpoint: _endpoint,
          username: 'admin',
          userId: 1,
          sessionId: '1',
          credentialType: 'LOGIN_PASSWORD',
          currentKeyId: null,
          accountEligible: true,
          stig: false,
          keys: [],
        ),
        action: ApiKeyAction.create,
        name: 'New',
      ),
    ),
    throwsA(
      isA<ApiKeysException>().having(
        (e) => e.reason,
        'reason',
        ApiKeysExceptionReason.busy,
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
}

void main() {
  for (final stage in ['pending', 'accepted', 'unknown']) {
    test(
      '$stage power fences peer helpers without any additional frame',
      () async {
        final h = await _connected(methods: _peerMethods);
        final r = await _review(h);
        if (stage == 'pending') {
          h.wire.faultMethod = 'system.reboot';
          h.wire.held = Completer<void>();
        } else if (stage == 'unknown') {
          h.wire.receipt = null;
        }
        final future = h.repo.executeSystemPower(r, r.target);
        await Future<void>.delayed(const Duration(milliseconds: 1));
        if (stage != 'pending') await future;
        await _assertPeerFences(h);
        if (stage == 'pending') {
          h.wire.held!.complete();
          expect((await future).outcome, SystemPowerOutcome.accepted);
        }
        expect(h.wire.writes.length, 1);
      },
    );
  }
  for (final pending in [true, false]) {
    test(
      '${pending ? 'pending' : 'unknown'} alert fences every power step before RPC',
      () async {
        final h = await _connected(methods: _peerMethods);
        final r = await _review(h);
        final inv = await h.repo.loadAlerts();
        final ar = await h.repo.reviewAlert(
          AlertRequest(
            inventory: inv,
            action: AlertAction.dismiss,
            alert: inv.alerts.single,
          ),
        );
        h.wire.faultMethod = 'alert.dismiss';
        if (pending) {
          h.wire.held = Completer<void>();
        } else {
          h.wire.fault = 'remote';
        }
        final future = h.repo.executeAlert(ar, ar.target);
        await Future<void>.delayed(const Duration(milliseconds: 1));
        if (!pending) expect((await future).outcome, AlertOutcome.unknown);
        final n = h.wire.calls.length;
        await expectLater(
          h.repo.loadSystemPower(),
          throwsA(_reason(SystemPowerExceptionReason.busy)),
        );
        await expectLater(
          h.repo.reviewSystemPower(r.request),
          throwsA(_reason(SystemPowerExceptionReason.busy)),
        );
        expect(
          (await h.repo.executeSystemPower(r, r.target)).outcome,
          SystemPowerOutcome.rejected,
        );
        expect(h.wire.calls.length, n);
        expect(h.wire.writes, isEmpty);
        if (pending) {
          h.wire.held!.complete();
          await future;
        }
      },
    );
  }
  for (final change in [
    const Duration(minutes: 6),
    const Duration(seconds: -1),
  ]) {
    for (final duringPreflight in [false, true]) {
      test(
        'lease clock $change ${duringPreflight ? 'during' : 'before'} preflight rejects without power frame',
        () async {
          final h = await _connected();
          final r = await _review(h);
          if (duringPreflight) {
            h.wire.beforeReply = (m, _) {
              if (m == 'core.get_jobs') h.now = h.now.add(change);
            };
          } else {
            h.now = h.now.add(change);
          }
          final n = h.wire.calls.length;
          expect(
            (await h.repo.executeSystemPower(r, r.target)).outcome,
            SystemPowerOutcome.rejected,
          );
          expect(h.wire.writes, isEmpty);
          if (!duringPreflight) expect(h.wire.calls.length, n);
          final after = h.wire.calls.length;
          expect(
            (await h.repo.executeSystemPower(r, r.target)).outcome,
            SystemPowerOutcome.rejected,
          );
          expect(h.wire.calls.length, after);
        },
      );
    }
  }
  for (final stage in ['before-read', 'during-read', 'during-write']) {
    test('session change $stage never reports completion or replays', () async {
      final h = await _connected();
      final r = await _review(h);
      if (stage == 'before-read') {
        h.current = false;
      } else {
        h.wire.beforeReply = (m, _) {
          if (m ==
              (stage == 'during-read' ? 'core.get_jobs' : 'system.reboot')) {
            h.current = false;
          }
        };
      }
      expect(
        (await h.repo.executeSystemPower(r, r.target)).outcome,
        stage == 'during-write'
            ? SystemPowerOutcome.unknown
            : SystemPowerOutcome.rejected,
      );
      expect(h.wire.writes.length, stage == 'during-write' ? 1 : 0);
      final n = h.wire.calls.length;
      h.current = true;
      expect(
        (await h.repo.executeSystemPower(r, r.target)).outcome,
        SystemPowerOutcome.rejected,
      );
      expect(h.wire.calls.length, n);
    });
  }
  test('late inventory on ended session never enters issued set', () async {
    final h = await _connected();
    h.wire.beforeReply = (m, _) {
      if (m == 'core.get_jobs') h.current = false;
    };
    await expectLater(
      h.repo.loadSystemPower(),
      throwsA(_reason(SystemPowerExceptionReason.notAuthenticated)),
    );
    expect(h.wire.writes, isEmpty);
  });
  for (final identity in [
    'host',
    'boot',
    'version',
    'environment',
    'keep',
    'reasons',
  ]) {
    for (final duringReview in [false, true]) {
      test(
        '$identity drift ${duringReview ? 'before review' : 'before submit'} rejects',
        () async {
          final h = await _connected();
          final i = await h.repo.loadSystemPower();
          final r = duringReview
              ? null
              : await h.repo.reviewSystemPower(_request(i));
          switch (identity) {
            case 'host':
              h.wire.values['system.host_id'] = 'f' * 64;
            case 'boot':
              (h.wire.values['system.reboot.info'] as Map)['boot_id'] =
                  'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
            case 'version':
              h.wire.values['system.version_short'] = '25.10.2';
            case 'environment':
              (h.wire.values['boot.environment.query'] as List)
                      .single['created'] =
                  '2026-09-13T01:00:00';
            case 'keep':
              (h.wire.values['boot.environment.query'] as List).single['keep'] =
                  false;
            case 'reasons':
              (h.wire.values['system.reboot.info']
                      as Map)['reboot_required_reasons'] =
                  [];
          }
          if (duringReview) {
            await expectLater(
              h.repo.reviewSystemPower(_request(i)),
              throwsA(isA<SystemPowerException>()),
            );
          } else {
            expect(
              (await h.repo.executeSystemPower(r!, r.target)).outcome,
              SystemPowerOutcome.rejected,
            );
          }
          expect(h.wire.writes, isEmpty);
        },
      );
    }
  }
  for (final identity in ['host', 'boot', 'state']) {
    test(
      'mixed $identity snapshot is rejected by end identity check',
      () async {
        final h = await _connected();
        h.wire.beforeReply = (m, _) {
          if (m == 'core.get_jobs') {
            switch (identity) {
              case 'host':
                h.wire.values['system.host_id'] = 'f' * 64;
              case 'boot':
                (h.wire.values['system.reboot.info'] as Map)['boot_id'] =
                    'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
              case 'state':
                h.wire.values['system.state'] = 'SHUTTING_DOWN';
            }
          }
        };
        await expectLater(
          h.repo.loadSystemPower(),
          throwsA(_reason(SystemPowerExceptionReason.staleReview)),
        );
        expect(h.wire.writes, isEmpty);
      },
    );
  }
  for (final fault in ['remote', 'timeout']) {
    test('preflight $fault is rejected and sanitized without write', () async {
      final h = await _connected();
      final r = await _review(h);
      h.wire.faultMethod = 'boot.get_state';
      h.wire.fault = fault;
      final result = await h.repo.executeSystemPower(r, r.target);
      expect(result.outcome, SystemPowerOutcome.rejected);
      expect(result.message, isNot(contains(_secret)));
      expect(h.wire.writes, isEmpty);
    });
  }
  test(
    'wrong confirmation consumes the one-use review without frames',
    () async {
      final h = await _connected();
      final r = await _review(h);
      final n = h.wire.calls.length;
      expect(
        (await h.repo.executeSystemPower(r, '${r.target} ')).outcome,
        SystemPowerOutcome.rejected,
      );
      expect(
        (await h.repo.executeSystemPower(r, r.target)).outcome,
        SystemPowerOutcome.rejected,
      );
      expect(h.wire.calls.length, n);
    },
  );
  test('forged and foreign review cannot dispatch', () async {
    final h = await _connected(), other = await _connected();
    final r = await _review(h);
    final fake = SystemPowerReview(
      request: r.request,
      endpoint: _endpoint,
      warnings: [],
    );
    final n = h.wire.calls.length, otherN = other.wire.calls.length;
    expect(
      (await h.repo.executeSystemPower(fake, fake.target)).outcome,
      SystemPowerOutcome.rejected,
    );
    expect(
      (await other.repo.executeSystemPower(r, r.target)).outcome,
      SystemPowerOutcome.rejected,
    );
    await expectLater(
      other.repo.reviewSystemPower(r.request),
      throwsA(_reason(SystemPowerExceptionReason.staleReview)),
    );
    expect(h.wire.calls.length, n);
    expect(other.wire.calls.length, otherN);
  });
  test('refresh and newer review invalidate old leases', () async {
    final h = await _connected();
    final r = await _review(h);
    await h.repo.loadSystemPower();
    final n = h.wire.calls.length;
    expect(
      (await h.repo.executeSystemPower(r, r.target)).outcome,
      SystemPowerOutcome.rejected,
    );
    expect(h.wire.calls.length, n);
    final r2 = await _review(h);
    await h.repo.reviewSystemPower(r2.request);
    final after = h.wire.calls.length;
    expect(
      (await h.repo.executeSystemPower(r2, r2.target)).outcome,
      SystemPowerOutcome.rejected,
    );
    expect(h.wire.calls.length, after);
  });
  final invalidReads = <String, (String, Object?)>{
    'host null': ('system.host_id', null),
    'host empty': ('system.host_id', ''),
    'host short': ('system.host_id', '1234'),
    'host control': ('system.host_id', '$_host\n'),
    'host uppercase': ('system.host_id', _host.toUpperCase()),
    'version changed': ('system.version_short', '25.10.2'),
    'state invalid': ('system.state', 'OK'),
    'ha malformed': ('failover.licensed', 'false'),
    'boot type': ('boot.get_state', []),
    'boot absent scan': (
      'boot.get_state',
      {'name': 'boot-pool', 'healthy': true, 'status': 'ONLINE'},
    ),
    'boot bad scan': (
      'boot.get_state',
      {
        'name': 'boot-pool',
        'healthy': true,
        'status': 'ONLINE',
        'scan': {'state': 'UNKNOWN'},
      },
    ),
    'boot bad health': (
      'boot.get_state',
      {
        'name': 'boot-pool',
        'healthy': 'true',
        'status': 'ONLINE',
        'scan': null,
      },
    ),
    'boot bad name': (
      'boot.get_state',
      {
        'name': 'boot-pool\n',
        'healthy': true,
        'status': 'ONLINE',
        'scan': null,
      },
    ),
    'environment type': ('boot.environment.query', {}),
    'environment overflow': (
      'boot.environment.query',
      List.filled(129, _environment()),
    ),
    'environment duplicate': (
      'boot.environment.query',
      [_environment(), _environment()],
    ),
    'environment bool': (
      'boot.environment.query',
      [
        {..._environment(), 'active': 'true'},
      ],
    ),
    'environment bad date': (
      'boot.environment.query',
      [
        {..._environment(), 'created': '2026-02-30T00:00:00'},
      ],
    ),
    'environment foreign pool': (
      'boot.environment.query',
      [
        {..._environment(), 'dataset': 'other/ROOT/25.10.1'},
      ],
    ),
    'environment missing field': (
      'boot.environment.query',
      [
        {..._environment()}..remove('activated'),
      ],
    ),
    'jobs type': ('core.get_jobs', {}),
    'jobs overflow': (
      'core.get_jobs',
      List.filled(129, {'id': 1, 'method': 'pool.scrub', 'state': 'RUNNING'}),
    ),
    'jobs duplicate': (
      'core.get_jobs',
      List.filled(2, {'id': 1, 'method': 'pool.scrub', 'state': 'RUNNING'}),
    ),
    'job negative id': (
      'core.get_jobs',
      [
        {'id': -1, 'method': 'pool.scrub', 'state': 'RUNNING'},
      ],
    ),
    'job unknown state': (
      'core.get_jobs',
      [
        {'id': 1, 'method': 'pool.scrub', 'state': 'SUCCESS'},
      ],
    ),
    'job malformed method': (
      'core.get_jobs',
      [
        {'id': 1, 'method': 'pool.scrub\n', 'state': 'RUNNING'},
      ],
    ),
    'reboot malformed': ('system.reboot.info', null),
    'reboot null identity': (
      'system.reboot.info',
      {'boot_id': null, 'reboot_required_reasons': []},
    ),
    'reboot identity control': (
      'system.reboot.info',
      {'boot_id': '$_boot\n', 'reboot_required_reasons': []},
    ),
    'reboot reason overflow': (
      'system.reboot.info',
      {
        'boot_id': _boot,
        'reboot_required_reasons': List.filled(65, {'code': 'FIPS'}),
      },
    ),
    'reboot reason duplicate': (
      'system.reboot.info',
      {
        'boot_id': _boot,
        'reboot_required_reasons': List.filled(2, {'code': 'FIPS'}),
      },
    ),
    'reboot reason control': (
      'system.reboot.info',
      {
        'boot_id': _boot,
        'reboot_required_reasons': [
          {'code': 'FIPS\n'},
        ],
      },
    ),
  };
  for (final entry in invalidReads.entries) {
    test('invalid ${entry.key} is unavailable and never actionable', () async {
      final h = await _connected();
      h.wire.values[entry.value.$1] = entry.value.$2;
      await expectLater(
        h.repo.loadSystemPower(),
        throwsA(_reason(SystemPowerExceptionReason.invalidResponse)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  final blockers = <String, (String, Object?)>{
    'HA': ('failover.licensed', true),
    'BOOTING': ('system.state', 'BOOTING'),
    'SHUTTING_DOWN': ('system.state', 'SHUTTING_DOWN'),
    'any active job': (
      'core.get_jobs',
      [
        {
          'id': 91,
          'method': 'cloudsync.sync',
          'state': 'RUNNING',
          'arguments': _secret,
        },
      ],
    ),
    'any waiting job': (
      'core.get_jobs',
      [
        {'id': 91, 'method': 'app.pull_images', 'state': 'WAITING'},
      ],
    ),
    'unhealthy boot': (
      'boot.get_state',
      {'name': 'boot-pool', 'healthy': false, 'status': 'ONLINE', 'scan': null},
    ),
    'degraded boot': (
      'boot.get_state',
      {
        'name': 'boot-pool',
        'healthy': true,
        'status': 'DEGRADED',
        'scan': null,
      },
    ),
    'active scan': (
      'boot.get_state',
      {
        'name': 'boot-pool',
        'healthy': true,
        'status': 'ONLINE',
        'scan': {'state': 'SCANNING'},
      },
    ),
    'no environments': ('boot.environment.query', []),
    'no active': (
      'boot.environment.query',
      [
        {..._environment(), 'active': false},
      ],
    ),
    'no next': (
      'boot.environment.query',
      [
        {..._environment(), 'activated': false},
      ],
    ),
    'cannot activate': (
      'boot.environment.query',
      [
        {..._environment(), 'can_activate': false},
      ],
    ),
    'different next': (
      'boot.environment.query',
      [
        {..._environment(), 'activated': false},
        {
          ..._environment(),
          'id': '25.10.2',
          'dataset': 'boot-pool/ROOT/25.10.2',
          'active': false,
        },
      ],
    ),
    'multiple active': (
      'boot.environment.query',
      [
        _environment(),
        {
          ..._environment(),
          'id': '25.10.2',
          'dataset': 'boot-pool/ROOT/25.10.2',
          'activated': false,
        },
      ],
    ),
  };
  for (final entry in blockers.entries) {
    test(
      '${entry.key} blocks read-issued review with no further frames',
      () async {
        final h = await _connected();
        h.wire.values[entry.value.$1] = entry.value.$2;
        final i = await h.repo.loadSystemPower();
        expect(i.blockedReason, isNotNull);
        final n = h.wire.calls.length;
        await expectLater(
          h.repo.reviewSystemPower(_request(i)),
          throwsA(_reason(SystemPowerExceptionReason.invalidRequest)),
        );
        expect(h.wire.calls.length, n);
      },
    );
    test('${entry.key} arriving after review prevents dispatch', () async {
      final h = await _connected();
      final r = await _review(h);
      h.wire.values[entry.value.$1] = entry.value.$2;
      expect(
        (await h.repo.executeSystemPower(r, r.target)).outcome,
        SystemPowerOutcome.rejected,
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final version in ['24.10.2', '25.04.2', '25.10.1-RC.1', '26.04.0']) {
    test('unsupported $version performs no readiness frames', () async {
      final h = await _connected(version: version);
      final n = h.wire.calls.length;
      expect(h.repo.systemPowerCapabilities.supported, false);
      await expectLater(
        h.repo.loadSystemPower(),
        throwsA(_reason(SystemPowerExceptionReason.unsupportedVersion)),
      );
      expect(h.wire.calls.length, n);
    });
  }
  for (final missing in _reads) {
    test('missing $missing fails closed without frames', () async {
      final h = await _connected(methods: {..._methods}..remove(missing));
      final n = h.wire.calls.length;
      await expectLater(
        h.repo.loadSystemPower(),
        throwsA(_reason(SystemPowerExceptionReason.unavailableMethod)),
      );
      expect(h.wire.calls.length, n);
    });
  }
  for (final action in SystemPowerAction.values) {
    test('missing ${action.name} prevents review without frames', () async {
      final h = await _connected(
        methods: {..._methods}..remove('system.${action.name}'),
      );
      final i = await h.repo.loadSystemPower();
      final n = h.wire.calls.length;
      expect(h.repo.systemPowerCapabilities.supports(action), false);
      await expectLater(
        h.repo.reviewSystemPower(_request(i, action: action)),
        throwsA(_reason(SystemPowerExceptionReason.unavailableMethod)),
      );
      expect(h.wire.calls.length, n);
    });
    for (final flag in [
      'job',
      'uploadable',
      'downloadable',
      'private',
      '_private',
      'no_auth_required',
    ]) {
      test('${action.name} unsafe metadata $flag prevents dispatch', () async {
        final h = await _connected(
          metadata: {
            'system.${action.name}': {flag: flag == 'job' ? false : true},
          },
        );
        final i = await h.repo.loadSystemPower();
        final n = h.wire.calls.length;
        await expectLater(
          h.repo.reviewSystemPower(_request(i, action: action)),
          throwsA(_reason(SystemPowerExceptionReason.unavailableMethod)),
        );
        expect(h.wire.calls.length, n);
      });
    }
    test(
      '${action.name} sends only immediate reviewed reason and accepts scheduling',
      () async {
        final h = await _connected();
        final r = await _review(h, action: action);
        expect(r.target, '${action.name.toUpperCase()} $_host');
        expect(r.endpoint, _endpoint);
        expect(r.warnings.join(), contains('scheduling only'));
        expect(r.warnings.join(), isNot(contains(_secret)));
        expect(() => r.warnings.clear(), throwsUnsupportedError);
        final n = h.wire.calls.length;
        final result = await h.repo.executeSystemPower(r, r.target);
        expect(result.outcome, SystemPowerOutcome.accepted);
        expect(result.jobId, 71);
        expect(result.message, contains('unverified'));
        expect(h.wire.calls.length, n + 12);
        expect(h.wire.writes.single['method'], 'system.${action.name}');
        expect(h.wire.writes.single['params'], [
          'Planned maintenance',
          {'delay': null},
        ]);
        final after = h.wire.calls.length;
        expect(
          (await h.repo.executeSystemPower(r, r.target)).outcome,
          SystemPowerOutcome.rejected,
        );
        await expectLater(
          h.repo.loadSystemPower(),
          throwsA(_reason(SystemPowerExceptionReason.busy)),
        );
        await expectLater(
          h.repo.reviewSystemPower(r.request),
          throwsA(_reason(SystemPowerExceptionReason.busy)),
        );
        expect(h.wire.calls.length, after);
        expect(h.wire.writes.length, 1);
      },
    );
    for (final receipt in [
      null,
      true,
      false,
      0,
      -1,
      1.5,
      '71',
      9007199254740992,
      <Object?>[],
      <String, Object?>{'job_id': 71},
    ]) {
      test(
        '${action.name} malformed receipt $receipt remains unknown without replay',
        () async {
          final h = await _connected();
          final r = await _review(h, action: action);
          h.wire.receipt = receipt;
          final result = await h.repo.executeSystemPower(r, r.target);
          expect(result.outcome, SystemPowerOutcome.unknown);
          expect(result.jobId, isNull);
          expect(result.message, isNot(contains(_secret)));
          final n = h.wire.calls.length;
          await expectLater(
            h.repo.loadSystemPower(),
            throwsA(_reason(SystemPowerExceptionReason.busy)),
          );
          expect(
            (await h.repo.executeSystemPower(r, r.target)).outcome,
            SystemPowerOutcome.rejected,
          );
          expect(h.wire.calls.length, n);
          expect(h.wire.writes.length, 1);
        },
      );
    }
    for (final fault in ['remote', 'timeout', 'disconnect']) {
      test(
        '${action.name} $fault after dispatch is unknown, never completion',
        () async {
          final h = await _connected();
          final r = await _review(h, action: action);
          h.wire.faultMethod = 'system.${action.name}';
          h.wire.fault = fault;
          final result = await h.repo.executeSystemPower(r, r.target);
          expect(result.outcome, SystemPowerOutcome.unknown);
          expect(result.message, contains('not proof'));
          expect(result.message, isNot(contains(_secret)));
          final n = h.wire.calls.length;
          expect(
            (await h.repo.executeSystemPower(r, r.target)).outcome,
            SystemPowerOutcome.rejected,
          );
          expect(h.wire.calls.length, n);
          expect(h.wire.writes.length, 1);
        },
      );
    }
  }
  for (final reason in [
    '',
    ' ',
    ' trailing ',
    'a' * 257,
    'bad\nreason',
    'bad\u0000reason',
    'bad\u202ereason',
    'bad\u2066reason',
  ]) {
    test(
      'invalid audit reason ${reason.codeUnits} emits no review frames',
      () async {
        final h = await _connected();
        final i = await h.repo.loadSystemPower();
        final n = h.wire.calls.length;
        await expectLater(
          h.repo.reviewSystemPower(_request(i, reason: reason)),
          throwsA(_reason(SystemPowerExceptionReason.invalidRequest)),
        );
        expect(h.wire.calls.length, n);
      },
    );
  }
  test('disconnected read and execute have no transport frames', () async {
    final h = _Harness('25.10.1', _methods, {});
    addTearDown(h.repo.close);
    expect(h.repo.systemPowerCapabilities.connected, false);
    await expectLater(
      h.repo.loadSystemPower(),
      throwsA(_reason(SystemPowerExceptionReason.notAuthenticated)),
    );
    expect(h.wire.calls, isEmpty);
  });
  test(
    'bounded projected passive reads discard raw details and immutable lists',
    () async {
      final h = await _connected();
      final n = h.wire.calls.length;
      final i = await h.repo.loadSystemPower();
      expect(i.endpoint, _endpoint);
      expect(i.hostId, _host);
      expect(i.bootId, _boot);
      expect(i.blockedReason, isNull);
      expect(i.rebootReasonCodes, ['FIPS']);
      expect(i.currentEnvironment?.id, '25.10.1');
      expect(i.nextEnvironment?.id, '25.10.1');
      expect(() => i.environments.clear(), throwsUnsupportedError);
      expect(() => i.rebootReasonCodes.clear(), throwsUnsupportedError);
      final calls = h.wire.calls.skip(n).toList();
      expect(calls.length, 11);
      expect(calls.every((c) => _reads.contains(c['method'])), true);
      expect(
        calls.singleWhere((c) => c['method'] == 'core.get_jobs')['params'],
        [
          [
            [
              'state',
              'in',
              ['WAITING', 'RUNNING'],
            ],
          ],
          {
            'limit': 129,
            'select': ['id', 'method', 'state'],
          },
        ],
      );
      expect(
        calls.singleWhere(
          (c) => c['method'] == 'boot.environment.query',
        )['params'],
        [
          [],
          {
            'limit': 129,
            'select': [
              'id',
              'dataset',
              'created',
              'used_bytes',
              'active',
              'activated',
              'keep',
              'can_activate',
            ],
          },
        ],
      );
      expect(jsonEncode(calls), isNot(contains(_secret)));
      expect(h.wire.writes, isEmpty);
    },
  );
}
