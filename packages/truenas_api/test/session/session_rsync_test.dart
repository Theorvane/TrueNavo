import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _reads = {
  'rsynctask.query',
  'keychaincredential.query',
  'user.query',
  'pool.dataset.query',
  'filesystem.stat',
  'filesystem.statfs',
  'system.general.config',
  'failover.licensed',
  'core.get_jobs',
};
const _writes = {
  'rsynctask.create',
  'rsynctask.update',
  'rsynctask.delete',
  'rsynctask.run',
};
const _methods = {
  ..._reads,
  ..._writes,
  'pool.query',
  'pool.scrub.query',
  'pool.scrub.create',
  'disk.query',
  'device.get_info',
  'boot.get_disks',
  'disk.update',
  'cloudsync.credentials.query',
  'cloudsync.credentials.delete',
  'cloudsync.query',
  'cloud_backup.query',
  'alert.list',
  'alert.dismiss',
  'auth.me',
  'auth.sessions',
  'api_key.query',
  'api_key.create',
  'system.security.config',
  'system.version_short',
  'boot.get_state',
  'boot.environment.query',
  'update.status',
  'update.available_versions',
};
const _secret = 'synthetic-private-never-render';
final _public =
    'ssh-ed25519 ${base64Encode([0, 0, 0, 11, ...utf8.encode('ssh-ed25519'), 0, 0, 0, 32, ...List.filled(32, 17)])}';
Matcher _reason(RsyncExceptionReason r) =>
    isA<RsyncException>().having((e) => e.reason, 'reason', r);
void main() {
  test('disconnected no read frames', () async {
    final w = _Wire();
    final r = TrueNasSessionRepository(connector: _Connector(w));
    addTearDown(r.close);
    expect(r.rsyncCapabilities.connected, isFalse);
    await expectLater(
      r.loadRsync(),
      throwsA(_reason(RsyncExceptionReason.notAuthenticated)),
    );
    expect(w.requests, isEmpty);
  });
  for (final version in [
    '24.10.2',
    '25.04.1',
    '26.04.0',
    '25.10-MASTER',
    '25.10.1-BETA.1',
  ]) {
    test('unsupported $version', () async {
      final h = await _connected(version: version);
      final n = h.w.requests.length;
      expect(h.r.rsyncCapabilities.supported, isFalse);
      await expectLater(
        h.r.loadRsync(),
        throwsA(_reason(RsyncExceptionReason.unsupportedVersion)),
      );
      expect(h.w.requests.length, n);
    });
  }
  for (final method in _reads) {
    test('missing read $method fails closed', () async {
      final h = await _connected(methods: {..._methods}..remove(method));
      expect(h.r.rsyncCapabilities.supported, isFalse);
      await expectLater(
        h.r.loadRsync(),
        throwsA(_reason(RsyncExceptionReason.unavailableMethod)),
      );
    });
  }
  for (final flags in [
    {'job': false},
    {'private': true},
    {'_private': true},
    {'uploadable': true},
    {'downloadable': true},
    {'no_auth_required': true},
  ]) {
    test('unsafe run metadata $flags', () async {
      final h = await _connected(overrides: {'rsynctask.run': flags});
      expect(h.r.rsyncCapabilities.canRun, isFalse);
    });
  }
  for (final method in {..._writes, 'rsynctask.commandline'}) {
    test('generic $method cannot bypass native policy', () async {
      final h = await _connected(methods: {..._methods, method});
      final spec = h.r.adminCatalog.method(method);
      if (spec == null) return;
      expect(spec.supported, isFalse);
      final n = h.w.requests.length;
      await expectLater(
        h.r.invokeAdmin(AdminRequest(method: spec, arguments: const [])),
        throwsA(isA<AdminException>()),
      );
      expect(h.w.requests.length, n);
    });
  }
  test('read projection never asks for task credentials attributes, keypair private or raw job logs', () async {
    final h = await _connected(), inv = await h.r.loadRsync();
    expect(inv.tasks.single.supported, isTrue);
    expect(inv.tasks.single.lastJobState, 'SUCCESS');
    expect(inv.users.single.username, 'backup');
    expect(inv.connections.single.destination, 'backup@remote.example:22');
    final tasks =
        h.w.requests.singleWhere(
              (r) => r['method'] == 'rsynctask.query',
            )['params']
            as List;
    final select = (tasks.last as Map)['select'] as List;
    expect(
      select,
      containsAll(['ssh_credentials.id', 'ssh_credentials.type', 'job.state']),
    );
    expect(select, isNot(contains('ssh_credentials')));
    expect(select, isNot(contains('job')));
    final keys = h.w.requests
        .where((r) => r['method'] == 'keychaincredential.query')
        .toList();
    expect(keys.length, 2);
    for (final key in keys) {
      final args = key['params'] as List;
      final type = ((args.first as List).single as List).last;
      final fields = (args.last as Map)['select'] as List;
      if (type == 'SSH_KEY_PAIR') {
        expect(fields, isNot(contains('attributes.private_key')));
      }
    }
    final user =
        h.w.requests.singleWhere((r) => r['method'] == 'user.query')['params']
            as List;
    expect((user.last as Map)['select'], [
      'id',
      'uid',
      'username',
      'local',
      'builtin',
      'locked',
    ]);
    expect(inv.tasks.single.settings!.path, '/mnt/tank/docs');
    expect(h.w.writes, isEmpty);
  });
  for (final action in [
    RsyncAction.create,
    RsyncAction.update,
    RsyncAction.enable,
    RsyncAction.disable,
    RsyncAction.delete,
  ]) {
    test('exact ${action.name} flags, receipt and postread', () async {
      final h = await _connected();
      if (action == RsyncAction.create) h.w.tasks.clear();
      if (action == RsyncAction.disable) h.w.tasks.single['enabled'] = true;
      final inv = await h.r.loadRsync(),
          review = await h.r.reviewRsync(_request(inv, action));
      expect(review.warnings.join(' '), contains('overwrite'));
      expect(review.warnings.join(' '), contains('no trailing slash'));
      expect(
        review.warnings.join(' '),
        contains('already exists as a directory'),
      );
      expect(
        review.warnings.join(' '),
        contains('If the destination is absent'),
      );
      expect(
        review.warnings.join(' '),
        contains('does not verify remote destination existence or layout'),
      );
      final result = await h.r.executeRsync(review, review.target);
      expect(result.outcome, RsyncOutcome.succeeded);
      final args = h.w.writes.single['params'] as List;
      if (action == RsyncAction.delete) {
        expect(args, [7]);
      } else {
        final patch = args.last as Map;
        expect(patch['validate_rpath'], false);
        expect(patch['ssh_keyscan'], false);
        if (action == RsyncAction.enable || action == RsyncAction.disable) {
          expect(patch, {
            'enabled': action == RsyncAction.enable,
            'validate_rpath': false,
            'ssh_keyscan': false,
          });
        } else {
          expect(patch['path'], '/mnt/tank/docs');
          expect(patch['direction'], 'PUSH');
          expect(patch['ssh_credentials'], 2);
          expect(patch['delete'], false);
          expect(patch['archive'], false);
          expect(patch['extra'], ['--one-file-system']);
          expect(patch.containsKey('job'), isFalse);
        }
      }
      await expectLater(
        h.r.executeRsync(review, review.target),
        throwsA(_reason(RsyncExceptionReason.staleReview)),
      );
      expect(h.w.writes.length, 1);
    });
  }
  test(
    'run exact owned job accepted, manual check terminal and no polling',
    () async {
      final h = await _connected(), result = await _execute(h, RsyncAction.run);
      expect(result.outcome, RsyncOutcome.accepted);
      expect(result.jobId, 90);
      expect(result.job!.taskId, 7);
      expect(result.job!.connectionId, 2);
      expect(h.w.writes.single['params'], [7]);
      final n = h.w.requests.length;
      await Future<void>.delayed(const Duration(milliseconds: 15));
      expect(h.w.requests.length, n);
      h.w.jobs.single['state'] = 'SUCCESS';
      h.w.tasks.single['job'] = {'state': 'SUCCESS', 'logs_excerpt': _secret};
      final done = await h.r.checkRsyncJob(result.job!);
      expect(done.outcome, RsyncOutcome.succeeded);
      expect(done.message, contains('does not prove'));
      expect(done.message, contains('vanished'));
      await expectLater(
        h.r.checkRsyncJob(result.job!),
        throwsA(_reason(RsyncExceptionReason.staleReview)),
      );
      expect(h.w.writes.length, 1);
    },
  );
  test(
    'waiting accepted remains locked and dashboard reads remain possible',
    () async {
      final h = await _connected();
      h.w.jobMode = 'WAITING';
      final result = await _execute(h, RsyncAction.run);
      expect(result.outcome, RsyncOutcome.accepted);
      expect(result.message, contains('waiting'));
      expect(await h.r.query('pool.query'), isA<List>());
      await _crossBlocked(h);
    },
  );
  test(
    'unknown job never returns accepted or succeeded after later valid check',
    () async {
      final h = await _connected(), result = await _execute(h, RsyncAction.run);
      h.w.failure = 'job-missing';
      expect(
        (await h.r.checkRsyncJob(result.job!)).outcome,
        RsyncOutcome.unknown,
      );
      h.w.failure = null;
      expect(
        (await h.r.checkRsyncJob(result.job!)).outcome,
        RsyncOutcome.unknown,
      );
      h.w.jobs.single['state'] = 'SUCCESS';
      expect(
        (await h.r.checkRsyncJob(result.job!)).outcome,
        RsyncOutcome.unknown,
      );
      await _crossBlocked(h);
    },
  );
  for (final unsupported in [
    'module',
    'pull',
    'home-key',
    'extra',
    'archive',
    'delete',
    'quiet',
    'permissions',
    'attributes',
    'unsafe-path',
    'unsafe-user',
    'unsafe-remote',
    'root-remote',
    'missing-keypair',
    'locked',
    'parent-dataset',
  ]) {
    test('unsupported $unsupported is safe read-only summary', () async {
      final h = await _connected();
      h.w.unsupported(unsupported);
      final inv = await h.r.loadRsync();
      expect(inv.tasks.single.supported, isFalse);
      expect(inv.tasks.single.settings, isNull);
      expect(inv.tasks.single.blockedReason, isNotNull);
      await expectLater(
        h.r.reviewRsync(_request(inv, RsyncAction.delete)),
        throwsA(_reason(RsyncExceptionReason.invalidRequest)),
      );
      expect(h.w.writes, isEmpty);
    });
  }
  for (final action in [
    RsyncAction.update,
    RsyncAction.delete,
    RsyncAction.run,
  ]) {
    test('enabled task cannot ${action.name}', () async {
      final h = await _connected();
      h.w.tasks.single['enabled'] = true;
      final inv = await h.r.loadRsync();
      await expectLater(
        h.r.reviewRsync(_request(inv, action)),
        throwsA(_reason(RsyncExceptionReason.invalidRequest)),
      );
      expect(h.w.writes, isEmpty);
    });
  }
  for (final mode in ['ha', 'job']) {
    test('$mode blocks review', () async {
      final h = await _connected();
      if (mode == 'ha') {
        h.w.ha = true;
      } else {
        h.w.jobs.add(_job(1, 'RUNNING', method: 'other.operation'));
      }
      final inv = await h.r.loadRsync();
      await expectLater(
        h.r.reviewRsync(_request(inv, RsyncAction.run)),
        throwsA(_reason(RsyncExceptionReason.invalidRequest)),
      );
      expect(h.w.writes, isEmpty);
    });
  }
  for (final drift in [
    'task',
    'host',
    'host-key',
    'public-key',
    'username',
    'uid',
    'dataset-guid',
    'dataset-lock',
    'timezone',
    'ha',
    'job',
    'inode',
    'symlink',
    'statfs',
    'readonly',
  ]) {
    test('fresh $drift drift rejects with zero write', () async {
      final h = await _connected(),
          inv = await h.r.loadRsync(),
          review = await h.r.reviewRsync(_request(inv, RsyncAction.run));
      h.w.drift(drift);
      final result = await h.r.executeRsync(review, review.target);
      expect(result.outcome, RsyncOutcome.rejected);
      expect(h.w.writes, isEmpty);
    });
  }
  test('forged review and forged job have zero frame authority', () async {
    final h = await _connected(), inv = await h.r.loadRsync();
    final review = RsyncReview(
      request: _request(inv, RsyncAction.run),
      endpoint: inv.endpoint,
      warnings: [],
    );
    final n = h.w.requests.length;
    await expectLater(
      h.r.executeRsync(review, review.target),
      throwsA(_reason(RsyncExceptionReason.staleReview)),
    );
    await expectLater(
      h.r.checkRsyncJob(
        RsyncJob(
          id: 90,
          taskId: 7,
          endpoint: inv.endpoint,
          path: '/mnt/tank/docs',
          connectionId: 2,
          remotePath: '/backups/docs',
        ),
      ),
      throwsA(_reason(RsyncExceptionReason.staleReview)),
    );
    expect(h.w.requests.length, n);
  });
  test('wrong confirmation consumes review', () async {
    final h = await _connected(),
        inv = await h.r.loadRsync(),
        review = await h.r.reviewRsync(_request(inv, RsyncAction.run));
    await expectLater(
      h.r.executeRsync(review, 'RUN'),
      throwsA(_reason(RsyncExceptionReason.staleReview)),
    );
    await expectLater(
      h.r.executeRsync(review, review.target),
      throwsA(_reason(RsyncExceptionReason.staleReview)),
    );
    expect(h.w.writes, isEmpty);
  });
  test('refresh invalidates review', () async {
    final h = await _connected(),
        inv = await h.r.loadRsync(),
        review = await h.r.reviewRsync(_request(inv, RsyncAction.run));
    await h.r.loadRsync();
    await expectLater(
      h.r.executeRsync(review, review.target),
      throwsA(_reason(RsyncExceptionReason.staleReview)),
    );
  });
  for (final failure in [
    'permission',
    'error',
    'timeout',
    'job-bool',
    'job-zero',
    'job-missing',
    'job-method',
    'job-args',
    'job-failed',
    'job-aborted',
    'job-result',
    'post-read',
    'post-path',
    'post-task',
    'post-trust',
  ]) {
    test('run postdispatch $failure unknown and shared fence', () async {
      final h = await _connected(timeout: const Duration(milliseconds: 75)),
          inv = await h.r.loadRsync(),
          review = await h.r.reviewRsync(_request(inv, RsyncAction.run));
      h.w.failure = failure;
      final result = await h.r.executeRsync(review, review.target);
      expect(result.outcome, RsyncOutcome.unknown);
      expect(result.message, isNot(contains(_secret)));
      expect(h.w.writes.length, 1);
      h.w.failure = null;
      await _crossBlocked(h);
    });
  }
  for (final failure in [
    'permission',
    'error',
    'timeout',
    'receipt',
    'wrong-id',
    'post-read',
    'post-path',
    'post-task',
    'post-trust',
    'delete-null',
  ]) {
    test('configuration postdispatch $failure unknown', () async {
      final h = await _connected(timeout: const Duration(milliseconds: 75)),
          inv = await h.r.loadRsync(),
          review = await h.r.reviewRsync(
            _request(
              inv,
              failure == 'delete-null'
                  ? RsyncAction.delete
                  : RsyncAction.update,
            ),
          );
      h.w.failure = failure;
      expect(
        (await h.r.executeRsync(review, review.target)).outcome,
        RsyncOutcome.unknown,
      );
      expect(h.w.writes.length, 1);
      h.w.failure = null;
      await _crossBlocked(h);
    });
  }
  for (final malformed in [
    'pair-type',
    'pair-private',
    'connection-type',
    'connection-private',
    'connection-host',
    'connection-user',
    'duplicate-user',
    'root-user',
    'locked-user',
    'directory-user',
    'dataset-guid',
    'duplicate-dataset',
    'task-bool-id',
    'duplicate-task',
    'task-extra-type',
    'task-bool',
    'task-description',
    'job-duplicate',
    'job-state',
    'job-method',
    'timezone',
    'ha',
  ]) {
    test('malformed $malformed inventory fails closed', () async {
      final h = await _connected();
      h.w.malformed = malformed;
      await expectLater(
        h.r.loadRsync(),
        throwsA(_reason(RsyncExceptionReason.invalidResponse)),
      );
      expect(h.w.writes, isEmpty);
    });
  }
  test(
    'a completed issued job ID cannot be reused as a new success receipt',
    () async {
      final h = await _connected();
      h.w.jobMode = 'SUCCESS';
      expect(
        (await _execute(h, RsyncAction.run)).outcome,
        RsyncOutcome.succeeded,
      );
      h.w.nextJob = 90;
      expect(
        (await _execute(h, RsyncAction.run)).outcome,
        RsyncOutcome.unknown,
      );
      expect(h.w.requests.last['method'], 'rsynctask.run');
      await _crossBlocked(h);
    },
  );
  test('session job receipt history is bounded to 64 runs', () async {
    final h = await _connected();
    h.w.jobMode = 'SUCCESS';
    for (var i = 0; i < 64; i++) {
      expect(
        (await _execute(h, RsyncAction.run)).outcome,
        RsyncOutcome.succeeded,
      );
    }
    final inv = await h.r.loadRsync(), n = h.w.requests.length;
    await expectLater(
      h.r.reviewRsync(_request(inv, RsyncAction.run)),
      throwsA(_reason(RsyncExceptionReason.invalidRequest)),
    );
    expect(h.w.requests.length, n);
    expect(h.w.writes.length, 64);
  });
  test('legacy empty extra can be updated but cannot run or enable before protection', () async {
    final h = await _connected();
    h.w.tasks.single['extra'] = <String>[];
    final inv = await h.r.loadRsync();
    expect(inv.tasks.single.crossFilesystemProtection, isFalse);
    expect(inv.tasks.single.supported, isTrue);
    for (final action in [RsyncAction.run, RsyncAction.enable]) {
      await expectLater(
        h.r.reviewRsync(_request(inv, action)),
        throwsA(_reason(RsyncExceptionReason.invalidRequest)),
      );
    }
    final r = RsyncRequest(
      inventory: inv,
      action: RsyncAction.update,
      task: inv.tasks.single,
      settings: inv.tasks.single.settings,
    );
    final review = await h.r.reviewRsync(r);
    expect(
      (await h.r.executeRsync(review, review.target)).outcome,
      RsyncOutcome.succeeded,
    );
    expect((h.w.writes.single['params'] as List).last['extra'], [
      '--one-file-system',
    ]);
  });
  test('legacy empty extra disable preserves empty protection state', () async {
    final h = await _connected();
    h.w.tasks.single['extra'] = <String>[];
    h.w.tasks.single['enabled'] = true;
    expect(
      (await _execute(h, RsyncAction.disable)).outcome,
      RsyncOutcome.succeeded,
    );
    expect(h.w.tasks.single['extra'], isEmpty);
  });
  test(
    'server omission of requested filesystem protection cannot succeed',
    () async {
      final h = await _connected();
      final inv = await h.r.loadRsync();
      final review = await h.r.reviewRsync(_request(inv, RsyncAction.update));
      h.w.failure = 'missing-protection';
      expect(
        (await h.r.executeRsync(review, review.target)).outcome,
        RsyncOutcome.unknown,
      );
      await _crossBlocked(h);
    },
  );
  test('preflight error redacted with no write', () async {
    final h = await _connected(),
        inv = await h.r.loadRsync(),
        review = await h.r.reviewRsync(_request(inv, RsyncAction.run));
    h.w.errorMethod = 'filesystem.stat';
    final result = await h.r.executeRsync(review, review.target);
    expect(result.outcome, RsyncOutcome.rejected);
    expect(result.message, isNot(contains(_secret)));
    expect(h.w.writes, isEmpty);
  });
  for (final path in [
    '/',
    '/root/backup',
    '/etc/config',
    '/backups',
    '/backups/../secret',
    '/backups/.hidden',
    '/backups/name/',
    '/backups/a b',
    r'/backups/$(id)',
    '/backups/quote"',
  ]) {
    test(
      'unsafe remote path $path rejected',
      () => expect(
        RsyncSettings(
          path: '/mnt/tank/docs',
          user: 'backup',
          connectionId: 2,
          remotePath: path,
        ).validationError,
        isNotNull,
      ),
    );
  }
  test('pending dispatch blocks all native writers', () async {
    final h = await _connected(timeout: const Duration(milliseconds: 100)),
        inv = await h.r.loadRsync(),
        review = await h.r.reviewRsync(_request(inv, RsyncAction.run));
    h.w.holdMethod = 'rsynctask.run';
    final future = h.r.executeRsync(review, review.target);
    await Future<void>.delayed(const Duration(milliseconds: 15));
    await _crossBlocked(h);
    expect((await future).outcome, RsyncOutcome.unknown);
  });
  for (final pending in [true, false]) {
    test(
      'cloud credential ${pending ? 'pending' : 'unknown'} blocks Rsync zero frames',
      () async {
        final h = await _connected(timeout: const Duration(milliseconds: 80)),
            inv = await h.r.loadRsync(),
            ci = await h.r.loadCloudCredentials();
        final review = await h.r.reviewCloudCredential(
          CloudCredentialRequest(
            inventory: ci,
            action: CloudCredentialAction.delete,
            credential: ci.credentials.single,
          ),
        );
        h.w.holdMethod = 'cloudsync.credentials.delete';
        final future = h.r.executeCloudCredential(review, review.target);
        if (pending) {
          await Future<void>.delayed(const Duration(milliseconds: 15));
        } else {
          await future;
        }
        final n = h.w.requests.length;
        await expectLater(
          h.r.reviewRsync(_request(inv, RsyncAction.run)),
          throwsA(_reason(RsyncExceptionReason.busy)),
        );
        expect(h.w.requests.length, n);
        if (pending) await future;
      },
    );
  }
}

RsyncRequest _request(RsyncInventory inv, RsyncAction action) => RsyncRequest(
  inventory: inv,
  action: action,
  task: action == RsyncAction.create ? null : inv.tasks.single,
  settings: {RsyncAction.create, RsyncAction.update}.contains(action)
      ? const RsyncSettings(
          path: '/mnt/tank/docs',
          user: 'backup',
          connectionId: 2,
          remotePath: '/backups/docs',
          description: 'updated copy',
          compress: false,
        )
      : null,
);
Future<RsyncResult> _execute(_Harness h, RsyncAction action) async {
  final inv = await h.r.loadRsync(),
      review = await h.r.reviewRsync(_request(inv, action));
  return h.r.executeRsync(review, review.target);
}

Future<void> _crossBlocked(_Harness h) async {
  final n = h.w.requests.length;
  const disk = DiskSnapshot(
    identifier: '{serial}fixture',
    name: 'sda',
    serial: 'fixture',
    lunid: null,
    sizeBytes: 1000,
    model: null,
    type: 'HDD',
    bus: 'ATA',
    description: '',
    hddStandby: 'ALWAYS ON',
    advancedPowerManagement: 'DISABLED',
    pool: null,
    zfsGuid: null,
    rotationRate: 7200,
  );
  await expectLater(
    h.r.reviewDisk(
      DiskRequest(
        inventory: DiskInventory(
          endpoint: 'wss://synthetic.example/api/current',
          failoverLicensed: false,
          disks: [],
        ),
        disk: disk,
        settings: disk.settings,
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
  final alert = AlertSnapshot(
    id: 'fixture-alert',
    klass: 'PoolCapacity',
    source: 'VolumeStatus',
    node: 'Controller A',
    level: 'WARNING',
    firstSeen: DateTime.utc(2026),
    lastSeen: DateTime.utc(2026),
    dismissed: false,
    oneShot: false,
  );
  await expectLater(
    h.r.reviewAlert(
      AlertRequest(
        inventory: AlertInventory(
          endpoint: 'wss://synthetic.example/api/current',
          failoverLicensed: false,
          alerts: [],
        ),
        action: AlertAction.dismiss,
        alert: alert,
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
    h.r.reviewApiKey(
      ApiKeyRequest(
        inventory: ApiKeyInventory(
          endpoint: 'wss://synthetic.example/api/current',
          username: 'fixture-user',
          userId: 42,
          sessionId: 'fixture',
          credentialType: 'LOGIN_PASSWORD',
          currentKeyId: null,
          accountEligible: true,
          stig: false,
          keys: [],
        ),
        action: ApiKeyAction.create,
        name: 'new-client',
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
  final p = const PoolMaintenancePool(
    id: 1,
    name: 'tank',
    guid: '12345',
    status: 'ONLINE',
    healthy: true,
    warning: false,
  );
  await expectLater(
    h.r.reviewPoolMaintenance(
      PoolMaintenanceRequest(
        inventory: PoolMaintenanceInventory(
          endpoint: 'wss://synthetic.example/api/current',
          pools: [p],
          schedules: [],
          timezone: 'UTC',
          failoverLicensed: false,
        ),
        action: PoolMaintenanceAction.createSchedule,
        pool: p,
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
    h.r.reviewCloudCredential(
      CloudCredentialRequest(
        inventory: CloudCredentialInventory(
          endpoint: 'wss://synthetic.example/api/current',
          credentials: [],
          references: [],
        ),
        action: CloudCredentialAction.delete,
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
    h.r.reviewSystemUpdate(
      SystemUpdateRequest(
        inventory: SystemUpdateInventory(
          endpoint: 'wss://synthetic.example/api/current',
          currentVersion: '25.10.1',
          bootPool: 'boot-pool',
          bootHealthy: true,
          failoverLicensed: false,
          conflictingJob: false,
          environments: [],
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
  expect(h.w.requests.length, n);
}

final class _Harness {
  const _Harness(this.r, this.w);
  final TrueNasSessionRepository r;
  final _Wire w;
}

Future<_Harness> _connected({
  String version = '25.10.1',
  Set<String> methods = _methods,
  Map<String, Map<String, Object?>> overrides = const {},
  Duration timeout = const Duration(seconds: 2),
}) async {
  final w = _Wire(version: version, methods: methods, overrides: overrides);
  final repo = TrueNasSessionRepository(
    connector: _Connector(w),
    managementRequestTimeout: timeout,
  );
  addTearDown(repo.close);
  await repo.connect(
    serverInput: 'https://synthetic.example',
    username: 'fixture-user',
    apiKey: 'synthetic-key',
  );
  return _Harness(repo, w);
}

final class _Connector implements RpcConnector {
  const _Connector(this.w);
  final _Wire w;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => w;
}

Map<String, Object?> _task() => {
  'id': 7,
  'path': '/mnt/tank/docs',
  'user': 'backup',
  'mode': 'SSH',
  'remotehost': null,
  'remoteport': null,
  'remotemodule': null,
  'ssh_credentials': {
    'id': 2,
    'type': 'SSH_CREDENTIALS',
    'attributes': {'private_key': _secret},
  },
  'remotepath': '/backups/docs',
  'direction': 'PUSH',
  'desc': 'copy docs',
  'schedule': {
    'minute': '0',
    'hour': '2',
    'dom': '*',
    'month': '*',
    'dow': '*',
  },
  'recursive': true,
  'times': true,
  'compress': true,
  'archive': false,
  'delete': false,
  'quiet': false,
  'preserveperm': false,
  'preserveattr': false,
  'delayupdates': true,
  'extra': <Object?>['--one-file-system'],
  'enabled': false,
  'locked': false,
  'job': {'state': 'SUCCESS', 'id': 999, 'logs_excerpt': _secret},
};
Map<String, Object?> _dataset() => {
  'id': 'tank/docs',
  'type': 'FILESYSTEM',
  'guid': {'value': '12345'},
  'mountpoint': '/mnt/tank/docs',
  'mounted': {'value': 'yes'},
  'locked': false,
  'readonly': {'value': 'off'},
  'key_loaded': true,
};
Map<String, Object?> _job(
  int id,
  String state, {
  String method = 'rsynctask.run',
}) => {
  'id': id,
  'method': method,
  'arguments': [7],
  'state': state,
  'result': null,
  'error': _secret,
  'logs_excerpt': _secret,
};

final class _Wire implements RpcTransport {
  _Wire({
    this.version = '25.10.1',
    this.methods = _methods,
    this.overrides = const {},
  });
  final String version;
  final Set<String> methods;
  final Map<String, Map<String, Object?>> overrides;
  final requests = <Map<String, dynamic>>[];
  final incoming = StreamController<String>();
  final pairs = <Map<String, Object?>>[
    {
      'id': 1,
      'type': 'SSH_KEY_PAIR',
      'attributes': {'public_key': _public, 'private_key': _secret},
    },
  ];
  final connections = <Map<String, Object?>>[
    {
      'id': 2,
      'name': 'remote-backup',
      'type': 'SSH_CREDENTIALS',
      'attributes': {
        'host': 'remote.example',
        'port': 22,
        'username': 'backup',
        'private_key': 1,
        'remote_host_key': _public,
        'connect_timeout': 10,
      },
    },
  ];
  final users = <Map<String, Object?>>[
    {
      'id': 3,
      'uid': 1000,
      'username': 'backup',
      'local': true,
      'builtin': false,
      'locked': false,
      'unixhash': _secret,
    },
  ];
  final datasets = <Map<String, Object?>>[_dataset()],
      tasks = <Map<String, Object?>>[_task()],
      jobs = <Map<String, Object?>>[];
  bool ha = false, mutated = false;
  String timezone = 'UTC', jobMode = 'RUNNING';
  int nextJob = 90;
  String? failure, malformed, errorMethod, holdMethod, pathDrift;
  List<Map<String, dynamic>> get writes =>
      requests.where((r) => _writes.contains(r['method'])).toList();
  @override
  Stream<String> get inboundFrames => incoming.stream;
  void unsupported(String name) {
    final t = tasks.single;
    switch (name) {
      case 'module':
        t['mode'] = 'MODULE';
      case 'pull':
        t['direction'] = 'PULL';
      case 'home-key':
        t['ssh_credentials'] = null;
      case 'extra':
        t['extra'] = ['--password-file=$_secret'];
      case 'archive':
        t['archive'] = true;
      case 'delete':
        t['delete'] = true;
      case 'quiet':
        t['quiet'] = true;
      case 'permissions':
        t['preserveperm'] = true;
      case 'attributes':
        t['preserveattr'] = true;
      case 'unsafe-path':
        t['path'] = '//private/$_secret';
      case 'unsafe-user':
        t['user'] = 'root';
      case 'unsafe-remote':
        t['remotepath'] = '/etc/secret';
      case 'root-remote':
        (connections.single['attributes'] as Map)['username'] = 'root';
      case 'missing-keypair':
        pairs.clear();
      case 'locked':
        t['locked'] = true;
      case 'parent-dataset':
        datasets.add({
          ..._dataset(),
          'id': 'tank/docs/child',
          'mountpoint': '/mnt/tank/docs/child',
          'guid': {'value': '54321'},
        });
    }
  }

  void drift(String name) {
    switch (name) {
      case 'task':
        tasks.single['desc'] = 'changed';
      case 'host':
        (connections.single['attributes'] as Map)['host'] = 'other.example';
      case 'host-key':
        (connections.single['attributes'] as Map)['remote_host_key'] = _public
            .replaceAll('ERER', 'EhIS');
      case 'public-key':
        (pairs.single['attributes'] as Map)['public_key'] = _public.replaceAll(
          'ERER',
          'EhIS',
        );
      case 'username':
        users.single['username'] = 'other';
      case 'uid':
        users.single['uid'] = 1001;
      case 'dataset-guid':
        datasets.single['guid'] = {'value': '99999'};
      case 'dataset-lock':
        datasets.single['locked'] = true;
      case 'timezone':
        timezone = 'Asia/Seoul';
      case 'ha':
        ha = true;
      case 'job':
        jobs.add(_job(91, 'RUNNING', method: 'other.operation'));
      default:
        pathDrift = name;
    }
  }

  void error(Map r) => incoming.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': r['id'],
      'error': {
        'code': -32000,
        'message': _secret,
        'data': {'errno': failure == 'permission' ? 13 : 5, 'secret': _secret},
      },
    }),
  );
  @override
  Future<void> send(String frame) async {
    final r = jsonDecode(frame) as Map<String, dynamic>;
    requests.add(r);
    final method = r['method'] as String;
    if (method == holdMethod ||
        _writes.contains(method) && failure == 'timeout') {
      return;
    }
    if (method == errorMethod ||
        _writes.contains(method) && {'permission', 'error'}.contains(failure) ||
        mutated && failure == 'post-read' && method == 'rsynctask.query') {
      error(r);
      return;
    }
    Object? result;
    switch (method) {
      case 'auth.login_ex':
        result = {'response_type': 'SUCCESS'};
      case 'auth.me':
        result = {'pw_name': 'fixture-user'};
      case 'system.info':
        result = {'version': version};
      case 'core.get_methods':
        result = {
          for (final name in methods)
            name: {
              'job': name == 'rsynctask.run',
              'uploadable': false,
              'downloadable': false,
              'no_auth_required': false,
              'roles': ['FULL_ADMIN'],
              'accepts': [],
              'returns': [],
              ...?overrides[name],
            },
        };
      case 'keychaincredential.query':
        final type =
            (((r['params'] as List).first as List).single as List).last;
        final values = jsonDecode(
          jsonEncode(type == 'SSH_KEY_PAIR' ? pairs : connections),
        ) as List;
        if (values.isNotEmpty) {
          final row = values.first as Map;
          final a = row['attributes'] as Map;
          if (type == 'SSH_KEY_PAIR') {
            if (malformed == 'pair-type') row['type'] = 'SSH_CREDENTIALS';
            if (malformed == 'pair-private') a['public_key'] = _secret;
          } else {
            if (malformed == 'connection-type') row['type'] = 'SSH_KEY_PAIR';
            if (malformed == 'connection-private') a['private_key'] = _secret;
            if (malformed == 'connection-host') a['host'] = 'host;id';
            if (malformed == 'connection-user') a['username'] = r'$(id)';
            if (mutated && failure == 'post-trust') {
              a['host'] = 'changed.example';
            }
          }
        }
        result = values;
      case 'user.query':
        final values = jsonDecode(jsonEncode(users)) as List;
        final u = values.single as Map;
        switch (malformed) {
          case 'duplicate-user':
            values.add(Map.of(u));
          case 'root-user':
            u['uid'] = 0;
          case 'locked-user':
            u['locked'] = true;
          case 'directory-user':
            u['local'] = false;
        }
        result = values;
      case 'pool.dataset.query':
        final values = jsonDecode(jsonEncode(datasets)) as List;
        if (malformed == 'dataset-guid') {
          (values.first as Map)['guid'] = {'value': 'bad'};
        }
        if (malformed == 'duplicate-dataset') values.add(values.first);
        result = values;
      case 'rsynctask.query':
        final values = jsonDecode(jsonEncode(tasks)) as List;
        if (values.isNotEmpty) {
          final t = values.first as Map;
          if (mutated && failure == 'post-task') t['desc'] = 'unexpected';
          switch (malformed) {
            case 'task-bool-id':
              t['id'] = true;
            case 'duplicate-task':
              values.add(Map.of(t));
            case 'task-extra-type':
              t['extra'] = _secret;
            case 'task-bool':
              t['delete'] = 'false';
            case 'task-description':
              t['desc'] = 'hello\n$_secret';
          }
        }
        result = values;
      case 'filesystem.stat':
        final path = (r['params'] as List).single as String;
        result = {
          'type': pathDrift == 'symlink' ? 'SYMLINK' : 'DIRECTORY',
          'realpath': path,
          'is_ctldir': false,
          'is_mountpoint': path == '/mnt/tank/docs',
          'dev': 42,
          'inode': pathDrift == 'inode' || mutated && failure == 'post-path'
              ? 999
              : 1,
          'mount_id': 3,
          'mode': 16877,
          'uid': 1000,
          'gid': 1000,
        };
      case 'filesystem.statfs':
        final path = (r['params'] as List).single as String;
        result = {
          'fstype': pathDrift == 'statfs' ? 'cifs' : 'zfs',
          'source': 'tank/docs',
          'dest': path,
          'fsid': 'fixture',
          'flags': pathDrift == 'readonly' ? ['RDONLY'] : ['RW'],
        };
      case 'system.general.config':
        result = {
          'timezone': malformed == 'timezone' ? true : timezone,
          'private_extra': _secret,
        };
      case 'failover.licensed':
        result = malformed == 'ha' ? _secret : ha;
      case 'core.get_jobs':
        final filters = (r['params'] as List).first as List;
        final ids = filters.where((f) => f[0] == 'id').toList();
        var values = jobs
            .where(
              (j) => ids.isNotEmpty
                  ? j['id'] == ids.single[2]
                  : {'WAITING', 'RUNNING'}.contains(j['state']),
            )
            .map((j) => Map<String, Object?>.of(j))
            .toList();
        if (malformed?.startsWith('job-') == true && values.isEmpty) {
          values = [_job(1, 'RUNNING')];
        }
        if (values.isNotEmpty) {
          final j = values.first;
          switch (malformed) {
            case 'job-duplicate':
              values.add(Map.of(j));
            case 'job-state':
              j['state'] = 'MISSING';
            case 'job-method':
              j['method'] = 'secret\n$_secret';
          }
          if (ids.isNotEmpty && mutated) {
            switch (failure) {
              case 'job-method':
                j['method'] = 'pool.export';
              case 'job-args':
                j['arguments'] = [8];
              case 'job-failed':
                j['state'] = 'FAILED';
              case 'job-aborted':
                j['state'] = 'ABORTED';
              case 'job-result':
                j['state'] = 'SUCCESS';
                j['result'] = true;
            }
          }
        }
        if (ids.isNotEmpty && failure == 'job-missing') values = [];
        result = values;
      case 'rsynctask.create':
        mutated = true;
        final p = (r['params'] as List).single as Map;
        final t = <String, Object?>{
          ...Map<String, Object?>.from(p),
          'id': 8,
          'locked': false,
          'job': null,
          'ssh_credentials': {
            'id': p['ssh_credentials'],
            'type': 'SSH_CREDENTIALS',
            'attributes': {'private_key': _secret},
          },
        };
        t.remove('validate_rpath');
        t.remove('ssh_keyscan');
        tasks.add(t);
        result = t;
      case 'rsynctask.update':
        mutated = true;
        final args = r['params'] as List,
            p = args.last as Map,
            t = tasks.singleWhere((t) => t['id'] == args.first);
        for (final key in p.keys) {
          if (!{'validate_rpath', 'ssh_keyscan'}.contains(key)) {
            t[key as String] = key == 'ssh_credentials'
                ? {
                    'id': p[key],
                    'type': 'SSH_CREDENTIALS',
                    'attributes': {'private_key': _secret},
                  }
                : p[key];
          }
        }
        if (failure == 'missing-protection') t['extra'] = <String>[];
        result = t;
      case 'rsynctask.delete':
        mutated = true;
        tasks.removeWhere((t) => t['id'] == (r['params'] as List).single);
        result = failure == 'delete-null' ? null : true;
      case 'rsynctask.run':
        mutated = true;
        final id = nextJob++;
        jobs.add(_job(id, jobMode));
        tasks.single['job'] = {'state': jobMode, 'logs_excerpt': _secret};
        result = failure == 'job-bool'
            ? true
            : failure == 'job-zero'
            ? 0
            : id;
      case 'pool.query':
        result = [];
      case 'cloudsync.credentials.query':
        result = [
          {
            'id': 4,
            'name': 'unused-s3',
            'provider': {'type': 'S3'},
          },
        ];
      case 'cloudsync.query':
      case 'cloud_backup.query':
        result = [];
      default:
        throw StateError('Unexpected synthetic RPC $method');
    }
    if (_writes.contains(method) &&
        method != 'rsynctask.run' &&
        result is Map) {
      if (failure == 'receipt') result = {'id': _secret};
      if (failure == 'wrong-id') result = {...result, 'id': 999};
    }
    incoming.add(
      jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() async {
    if (!incoming.isClosed) await incoming.close();
  }
}
