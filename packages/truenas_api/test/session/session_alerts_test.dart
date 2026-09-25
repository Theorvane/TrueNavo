import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _id = '11111111-1111-4111-8111-111111111111',
    _secret = 'synthetic-secret-never-display',
    _endpoint = 'wss://nas.example/api/current';
const _methods = {
  'alert.list',
  'failover.licensed',
  'alert.dismiss',
  'alert.restore',
};
Map<String, Object?> _alert() => {
  'id': _id,
  'uuid': _id,
  'klass': 'VolumeStatus',
  'source': 'VolumeStatus',
  'node': 'Controller A',
  'level': 'CRITICAL',
  'datetime': '2026-09-14T01:00:00',
  'last_occurrence': '2026-09-14T02:00:00',
  'dismissed': false,
  'one_shot': false,
  'text': _secret,
  'formatted': '<script>$_secret</script>',
  'args': {'volume': _secret},
  'key': _secret,
  'mail': {'secret': _secret},
};
Matcher _reason(AlertsExceptionReason reason) =>
    isA<AlertsException>().having((e) => e.reason, 'reason', reason);
Future<_Harness> _connected({
  String version = '25.10.1',
  Set<String> methods = _methods,
  String? flag,
}) async {
  final h = _Harness(version, methods, flag);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'synthetic',
    username: 'admin',
    isConnectionCurrent: () => h.current,
  );
  return h;
}

Future<AlertReview> _review(
  _Harness h, {
  AlertAction action = AlertAction.dismiss,
}) async {
  final inv = await h.repo.loadAlerts();
  return h.repo.reviewAlert(
    AlertRequest(inventory: inv, action: action, alert: inv.alerts.single),
  );
}

void main() {
  test(
    'pure class title mapper never echoes arbitrary or secret-bearing input',
    () {
      expect(alertClassTitle('VolumeStatus'), 'Pool health needs attention');
      for (final klass in [
        '',
        _secret,
        '<script>$_secret</script>',
        'VolumeStatus\n',
        'UnknownPlugin',
      ]) {
        expect(alertClassTitle(klass), 'Other alert class');
        expect(alertClassTitle(klass), isNot(contains(_secret)));
      }
    },
  );
  for (final pending in [false, true]) {
    test(
      '${pending ? 'pending' : 'unknown'} alert write fences credentials and auxiliary workflows',
      () async {
        final h = await _connected(
          methods: {
            ..._methods,
            'auth.me',
            'auth.sessions',
            'user.query',
            'api_key.query',
            'system.security.config',
            'api_key.create',
            'cloudsync.credentials.query',
            'cloudsync.query',
            'cloud_backup.query',
            'core.get_jobs',
            'cloudsync.credentials.create',
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
            'keychaincredential.query',
            'keychaincredential.used_by',
            'keychaincredential.create',
          },
        );
        final r = await _review(h);
        if (pending) {
          h.wire.held = Completer<void>();
        } else {
          h.wire.writeFault = 'remote';
        }
        final mutation = h.repo.executeAlert(r, r.target);
        await Future<void>.delayed(const Duration(milliseconds: 1));
        if (!pending) {
          expect((await mutation).outcome, AlertOutcome.unknown);
        }
        expect(h.wire.writes.length, 1);
        final boundary = h.wire.calls.length;
        await expectLater(
          h.repo.reviewSshCredential(
            SshCredentialRequest(
              inventory: SshCredentialInventory(
                endpoint: _endpoint,
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
          h.repo.reviewApiKey(
            ApiKeyRequest(
              inventory: ApiKeyInventory(
                endpoint: _endpoint,
                username: 'admin',
                userId: 1000,
                sessionId: 'sample',
                credentialType: 'LOGIN_PASSWORD',
                currentKeyId: null,
                accountEligible: true,
                stig: false,
                keys: const [],
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
          h.repo.reviewCloudCredential(
            CloudCredentialRequest(
              inventory: CloudCredentialInventory(
                endpoint: _endpoint,
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
          h.repo.reviewReplication(
            ReplicationRequest(
              inventory: ReplicationInventory(
                endpoint: _endpoint,
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
                endpoint: _endpoint,
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
                endpoint: _endpoint,
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
        expect(h.wire.calls.length, boundary);
        if (pending) {
          h.wire.held!.complete();
          expect((await mutation).outcome, AlertOutcome.succeeded);
        }
      },
    );
  }
  test('disconnected has no dispatch', () async {
    final h = _Harness('25.10.1', _methods, null);
    addTearDown(h.repo.close);
    expect(h.repo.alertsCapabilities.connected, false);
    await expectLater(
      h.repo.loadAlerts(),
      throwsA(_reason(AlertsExceptionReason.notAuthenticated)),
    );
    expect(h.wire.calls, isEmpty);
  });
  for (final version in ['25.04.2', '26.0', '25.10-BETA', '25.10.1\n']) {
    test('reject version $version without reads', () async {
      final h = await _connected(version: version),
          boundary = h.wire.calls.length;
      await expectLater(
        h.repo.loadAlerts(),
        throwsA(_reason(AlertsExceptionReason.unsupportedVersion)),
      );
      expect(h.wire.calls.length, boundary);
    });
  }
  for (final method in _methods) {
    test('missing $method capability fail closed', () async {
      final h = await _connected(methods: {..._methods}..remove(method)),
          c = h.repo.alertsCapabilities;
      if (method == 'alert.dismiss') {
        expect(c.canDismiss, false);
      } else if (method == 'alert.restore') {
        expect(c.canRestore, false);
      } else {
        expect(c.supported, false);
      }
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final flag in [
    'job',
    'private',
    '_private',
    'uploadable',
    'downloadable',
    'no_auth_required',
  ]) {
    test('unsafe $flag denies writes', () async {
      final h = await _connected(flag: flag);
      expect(h.repo.alertsCapabilities.canDismiss, false);
    });
  }
  test(
    'list zero args only and raw arbitrary content never enters display model',
    () async {
      final h = await _connected();
      final inventory = await h.repo.loadAlerts(), a = inventory.alerts.single;
      expect(a.title, 'Pool health needs attention');
      expect(a.sourceLabel, 'VolumeStatus');
      expect(a.firstSeen, DateTime.utc(2026, 9, 14, 1));
      expect(a.metrics, isEmpty);
      expect(a.toString(), isNot(contains(_secret)));
      expect(a.summary, isNot(contains(_secret)));
      expect(h.wire.calls.skip(4).map((r) => r['method']), [
        'failover.licensed',
        'alert.list',
      ]);
      expect(h.wire.calls.last['params'], []);
      expect(h.wire.writes, isEmpty);
    },
  );
  for (final klass in [
    'VolumeStatus',
    'BootPoolStatus',
    'ZpoolCapacityNotice',
    'ZpoolCapacityWarning',
    'ZpoolCapacityCritical',
    'DiskTemperatureTooHot',
    'NTPHealthCheck',
    'CertificateIsExpiring',
    'CertificateIsExpiringSoon',
    'CertificateExpired',
    'CertificateParsingFailed',
    'SMARTUncorrectedErrors',
    'SMARTFailedSelfTest',
    'SMARTSpareBlockCount',
    'SMARTEraseCycleCount',
  ]) {
    test('pinned plain class $klass safely dismisses with readback', () async {
      final h = await _connected();
      h.wire.row['klass'] = klass;
      h.wire.row['source'] = klass.startsWith('Zpool')
          ? 'ZpoolCapacity'
          : klass.startsWith('Certificate')
          ? 'CertificateChecks'
          : klass.startsWith('SMART')
          ? 'SMART'
          : klass == 'BootPoolStatus'
          ? 'VolumeStatus'
          : klass;
      final r = await _review(h);
      expect(
        (await h.repo.executeAlert(r, r.target)).outcome,
        AlertOutcome.succeeded,
      );
      expect(h.wire.writes.single['params'], [_id]);
      expect(h.wire.calls.where((r) => r['method'] == 'alert.list').length, 4);
    });
  }
  test('restore flips existing exact alert and verifies state', () async {
    final h = await _connected();
    h.wire.row['dismissed'] = true;
    final r = await _review(h, action: AlertAction.restore);
    expect(
      (await h.repo.executeAlert(r, r.target)).outcome,
      AlertOutcome.succeeded,
    );
    expect(h.wire.writes.single['method'], 'alert.restore');
    expect(h.wire.row['dismissed'], false);
  });
  for (final blocked in [
    'one-shot',
    'unknown-class',
    'source-mismatch',
    'node-B',
    'HA',
    'already-dismissed',
  ]) {
    test('$blocked cannot dismiss', () async {
      final h = await _connected();
      switch (blocked) {
        case 'one-shot':
          h.wire.row['one_shot'] = true;
        case 'unknown-class':
          h.wire.row['klass'] = 'ArbitraryPlugin';
        case 'source-mismatch':
          h.wire.row['source'] = 'Other';
        case 'node-B':
          h.wire.row['node'] = 'Controller B';
        case 'HA':
          h.wire.licensed = true;
        case 'already-dismissed':
          h.wire.row['dismissed'] = true;
      }
      await expectLater(
        _review(h),
        throwsA(_reason(AlertsExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('active alert cannot restore', () async {
    final h = await _connected();
    await expectLater(
      _review(h, action: AlertAction.restore),
      throwsA(_reason(AlertsExceptionReason.invalidRequest)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test(
    'unknown class/source render coded fallback not arbitrary identifiers',
    () async {
      final h = await _connected();
      h.wire.row['klass'] = 'SecretClass';
      h.wire.row['source'] = 'SecretSource';
      final a = (await h.repo.loadAlerts()).alerts.single;
      expect(a.title, 'Other alert class');
      expect(a.sourceLabel, 'Other source');
      expect(a.supported, false);
    },
  );
  test(
    'only known finite bounded numeric observations are projected',
    () async {
      final h = await _connected();
      h.wire.row['klass'] = 'ZpoolCapacityWarning';
      h.wire.row['source'] = 'ZpoolCapacity';
      h.wire.row['args'] = {
        'capacity': 92,
        'volume': _secret,
        'script': '<script>$_secret</script>',
      };
      expect((await h.repo.loadAlerts()).alerts.single.metrics, {
        'Reported pool capacity (%)': 92,
      });
      h.wire.row['args'] = {'capacity': _secret};
      expect((await h.repo.loadAlerts()).alerts.single.metrics, isEmpty);
      h.wire.row['args'] = {'capacity': 101};
      expect((await h.repo.loadAlerts()).alerts.single.metrics, isEmpty);
    },
  );
  test(
    'timestamp extended JSON accepted and naive ISO explicitly UTC',
    () async {
      final h = await _connected();
      h.wire.row['datetime'] = {
        r'$date': DateTime.utc(2026, 9, 14, 1).millisecondsSinceEpoch,
      };
      final a = (await h.repo.loadAlerts()).alerts.single;
      expect(a.firstSeen, DateTime.utc(2026, 9, 14, 1));
      expect(a.lastSeen.isUtc, true);
    },
  );
  for (final fault in [
    'row',
    'id',
    'uuid',
    'klass',
    'source',
    'node',
    'level',
    'dismissed',
    'one_shot',
    'first',
    'last',
    'chronology',
    'duplicate',
    'overflow',
    'ha-type',
  ]) {
    test('malformed $fault inventory fails closed', () async {
      final h = await _connected();
      h.wire.readFault = fault;
      await expectLater(
        h.repo.loadAlerts(),
        throwsA(_reason(AlertsExceptionReason.invalidResponse)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('read errors withheld no auto retry', () async {
    final h = await _connected();
    h.wire.readFault = 'remote';
    await expectLater(
      h.repo.loadAlerts(),
      throwsA(_reason(AlertsExceptionReason.unavailable)),
    );
    expect(h.wire.calls.where((r) => r['method'] == 'alert.list').length, 1);
    expect(h.wire.writes, isEmpty);
  });
  for (final field in [
    'uuid',
    'klass',
    'source',
    'node',
    'level',
    'datetime',
    'last_occurrence',
    'dismissed',
    'one_shot',
    'ha',
  ]) {
    test('$field changed before execute rejects with zero writes', () async {
      final h = await _connected();
      final r = await _review(h);
      h.wire.drift(field);
      expect(
        (await h.repo.executeAlert(r, r.target)).outcome,
        AlertOutcome.rejected,
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('unrelated alert arrival does not change target identity', () async {
    final h = await _connected();
    final r = await _review(h);
    h.wire.extra = [
      {
        ..._alert(),
        'id': '22222222-2222-4222-8222-222222222222',
        'uuid': '22222222-2222-4222-8222-222222222222',
      },
    ];
    expect(
      (await h.repo.executeAlert(r, r.target)).outcome,
      AlertOutcome.succeeded,
    );
  });
  test('forged inventory and review cannot dispatch', () async {
    final h = await _connected();
    final real = await h.repo.loadAlerts(),
        fake = AlertInventory(
          endpoint: _endpoint,
          failoverLicensed: false,
          alerts: real.alerts,
        ),
        request = AlertRequest(
          inventory: fake,
          action: AlertAction.dismiss,
          alert: real.alerts.single,
        );
    await expectLater(
      h.repo.reviewAlert(request),
      throwsA(_reason(AlertsExceptionReason.staleReview)),
    );
    final forged = AlertReview(
      request: request,
      endpoint: _endpoint,
      warnings: const [],
    );
    expect(
      (await h.repo.executeAlert(forged, forged.target)).outcome,
      AlertOutcome.rejected,
    );
    expect(h.wire.writes, isEmpty);
  });
  test('exact confirmation consumed once', () async {
    final h = await _connected();
    final r = await _review(h);
    expect(
      (await h.repo.executeAlert(r, '${r.target} ')).outcome,
      AlertOutcome.rejected,
    );
    expect(
      (await h.repo.executeAlert(r, r.target)).outcome,
      AlertOutcome.rejected,
    );
    expect(h.wire.writes, isEmpty);
  });
  test('refresh invalidates old review', () async {
    final h = await _connected();
    final r = await _review(h);
    await h.repo.loadAlerts();
    expect(
      (await h.repo.executeAlert(r, r.target)).outcome,
      AlertOutcome.rejected,
    );
    expect(h.wire.writes, isEmpty);
  });
  test('session expiry prevents dispatch', () async {
    final h = await _connected();
    final r = await _review(h);
    h.current = false;
    expect(
      (await h.repo.executeAlert(r, r.target)).outcome,
      AlertOutcome.rejected,
    );
    expect(h.wire.writes, isEmpty);
  });
  test('success cannot be replayed', () async {
    final h = await _connected();
    final r = await _review(h);
    await h.repo.executeAlert(r, r.target);
    expect(
      (await h.repo.executeAlert(r, r.target)).outcome,
      AlertOutcome.rejected,
    );
    expect(h.wire.writes.length, 1);
  });
  for (final fault in [
    'timeout',
    'remote',
    'receipt',
    'noop',
    'removed',
    'post-error',
    'post-uuid',
    'post-klass',
    'post-source',
    'post-node',
    'post-level',
    'post-datetime',
    'post-last_occurrence',
    'post-one_shot',
    'post-ha',
  ]) {
    test('$fault after dispatch remains unknown and locked', () async {
      final h = await _connected();
      final r = await _review(h);
      h.wire.writeFault = fault;
      final result = await h.repo.executeAlert(r, r.target);
      expect(result.outcome, AlertOutcome.unknown);
      expect(result.message, isNot(contains(_secret)));
      h.wire.writeFault = null;
      h.wire.readFault = null;
      h.wire.row = _alert();
      final inv = await h.repo.loadAlerts();
      await expectLater(
        h.repo.reviewAlert(
          AlertRequest(
            inventory: inv,
            action: AlertAction.dismiss,
            alert: inv.alerts.first,
          ),
        ),
        throwsA(_reason(AlertsExceptionReason.busy)),
      );
      expect(h.wire.writes.length, 1);
    });
  }
  for (final errno in [1, 13, 22, '13', null]) {
    test('post-dispatch error errno $errno cannot prove rejection', () async {
      final h = await _connected();
      final r = await _review(h);
      h.wire.writeFault = 'remote';
      h.wire.errno = errno;
      expect(
        (await h.repo.executeAlert(r, r.target)).outcome,
        AlertOutcome.unknown,
      );
    });
  }
  test('busy second execute cannot release first fence', () async {
    final h = await _connected();
    final r = await _review(h);
    h.wire.held = Completer<void>();
    final first = h.repo.executeAlert(r, r.target);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    expect(
      (await h.repo.executeAlert(r, r.target)).outcome,
      AlertOutcome.rejected,
    );
    await expectLater(
      h.repo.loadAlerts(),
      throwsA(_reason(AlertsExceptionReason.busy)),
    );
    h.wire.held!.complete();
    expect((await first).outcome, AlertOutcome.succeeded);
  });
}

class _Harness {
  _Harness(String version, Set<String> methods, String? flag)
    : wire = _Wire(version, methods, flag) {
    repo = TrueNasSessionRepository(
      connector: _Connector(wire),
      managementRequestTimeout: const Duration(milliseconds: 100),
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
  _Wire(this.version, this.methods, this.flag);
  final String version;
  final Set<String> methods;
  final String? flag;
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  Map<String, Object?> row = _alert();
  List<Object?> extra = [];
  bool licensed = false;
  String? readFault, writeFault;
  Object? errno;
  Completer<void>? held;
  List<Map<String, dynamic>> get writes => calls
      .where(
        (r) => r['method'] == 'alert.dismiss' || r['method'] == 'alert.restore',
      )
      .toList();
  @override
  Stream<String> get inboundFrames => inbound.stream;
  void drift(String field) {
    switch (field) {
      case 'uuid':
        row['id'] = '22222222-2222-4222-8222-222222222222';
        row['uuid'] = row['id'];
      case 'klass':
        row['klass'] = 'BootPoolStatus';
      case 'source':
        row['source'] = 'Different';
      case 'node':
        row['node'] = 'Controller B';
      case 'level':
        row['level'] = 'WARNING';
      case 'datetime':
        row['datetime'] = '2026-09-14T00:00:00';
      case 'last_occurrence':
        row['last_occurrence'] = '2026-09-14T03:00:00';
      case 'dismissed':
        row['dismissed'] = true;
      case 'one_shot':
        row['one_shot'] = true;
      case 'ha':
        licensed = true;
    }
  }

  @override
  Future<void> send(String frame) async {
    final r = jsonDecode(frame) as Map<String, dynamic>;
    calls.add(r);
    final method = r['method'] as String;
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
              if (m == 'alert.dismiss' && flag != null) flag!: true,
            },
        };
      case 'failover.licensed':
        result = readFault == 'ha-type' ? 'false' : licensed;
      case 'alert.list':
        if (readFault == 'remote') {
          _error(r);
          return;
        }
        result = [row, ...extra];
        switch (readFault) {
          case 'row':
            result = [null];
          case 'id':
            result = [
              {...row, 'id': 'bad'},
            ];
          case 'uuid':
            result = [
              {...row, 'uuid': '22222222-2222-4222-8222-222222222222'},
            ];
          case 'klass':
            result = [
              {...row, 'klass': '<script>$_secret</script>'},
            ];
          case 'source':
            result = [
              {...row, 'source': 'bad\nsource'},
            ];
          case 'node':
            result = [
              {...row, 'node': _secret},
            ];
          case 'level':
            result = [
              {...row, 'level': 'BAD'},
            ];
          case 'dismissed':
            result = [
              {...row, 'dismissed': null},
            ];
          case 'one_shot':
            result = [
              {...row, 'one_shot': 'false'},
            ];
          case 'first':
            result = [
              {...row, 'datetime': '2026-02-31T00:00:00'},
            ];
          case 'last':
            result = [
              {...row, 'last_occurrence': _secret},
            ];
          case 'chronology':
            result = [
              {...row, 'last_occurrence': '2026-09-13T00:00:00'},
            ];
          case 'duplicate':
            result = [row, row];
          case 'overflow':
            result = List.filled(513, row);
          case 'removed':
            result = [];
        }
      case 'alert.dismiss' || 'alert.restore':
        if (held != null) await held!.future;
        if (writeFault != 'noop') row['dismissed'] = method == 'alert.dismiss';
        switch (writeFault) {
          case 'timeout':
            return;
          case 'remote':
            _error(r);
            return;
          case 'receipt':
            result = true;
          case 'removed':
            readFault = 'removed';
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
        jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': result}),
      );
    }
  }

  void _error(Map r) {
    if (!inbound.isClosed) {
      inbound.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': r['id'],
          'error': {
            'code': -32000,
            'message': _secret,
            'data': {'errno': errno, 'trace': _secret},
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
