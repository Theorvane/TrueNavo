import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _reads = {
  'pool.query',
  'pool.scrub.query',
  'core.get_jobs',
  'system.general.config',
  'failover.licensed',
};
const _writes = {
  'pool.scrub.scrub',
  'pool.scrub.create',
  'pool.scrub.update',
  'pool.scrub.delete',
};
const _methods = {
  ..._reads,
  ..._writes,
  'pool.dataset.create',
  'cloudsync.credentials.query',
  'cloudsync.credentials.delete',
  'cloudsync.query',
  'cloud_backup.query',
  'disk.query',
  'device.get_info',
  'boot.get_disks',
  'disk.update',
  'alert.list',
  'alert.dismiss',
  'alert.restore',
  'auth.me',
  'auth.sessions',
  'user.query',
  'api_key.query',
  'system.security.config',
  'api_key.create',
  'system.version_short',
  'boot.get_state',
  'boot.environment.query',
  'update.status',
  'update.available_versions',
};
const _private = 'synthetic-remote-detail-do-not-display';
Matcher _reason(PoolMaintenanceExceptionReason r) =>
    isA<PoolMaintenanceException>().having((e) => e.reason, 'reason', r);
void main() {
  test('disconnected load has no frame', () async {
    final w = _Wire();
    final r = TrueNasSessionRepository(connector: _Connector(w));
    addTearDown(r.close);
    expect(r.poolMaintenanceCapabilities.connected, isFalse);
    await expectLater(
      r.loadPoolMaintenance(),
      throwsA(_reason(PoolMaintenanceExceptionReason.notAuthenticated)),
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
    test('unsupported $version no maintenance reads', () async {
      final h = await _connected(version: version);
      final n = h.w.requests.length;
      expect(h.r.poolMaintenanceCapabilities.supported, isFalse);
      await expectLater(
        h.r.loadPoolMaintenance(),
        throwsA(_reason(PoolMaintenanceExceptionReason.unsupportedVersion)),
      );
      expect(h.w.requests.length, n);
    });
  }
  for (final method in _reads) {
    test('missing $method fails capability', () async {
      final h = await _connected(methods: {..._methods}..remove(method));
      expect(h.r.poolMaintenanceCapabilities.supported, isFalse);
      await expectLater(
        h.r.loadPoolMaintenance(),
        throwsA(_reason(PoolMaintenanceExceptionReason.unavailableMethod)),
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
    test('scrub metadata rejects $flags', () async {
      final h = await _connected(overrides: {'pool.scrub.scrub': flags});
      expect(h.r.poolMaintenanceCapabilities.canScrub, isFalse);
    });
  }
  for (final method in {
    ..._writes,
    'pool.scrub',
    'pool.scrub.run',
    'pool.create',
    'pool.export',
    'pool.expand',
    'pool.upgrade',
  }) {
    test('generic $method cannot bypass native review', () async {
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
  test(
    'bounded pool and schedule projections omit topology paths and raw errors',
    () async {
      final h = await _connected();
      final inv = await h.r.loadPoolMaintenance();
      expect(inv.pools.single.name, 'tank');
      expect(inv.schedules.single.settings.cron.expression, '0 3 * * 7');
      expect(inv.timezone, 'UTC');
      expect(inv.failoverLicensed, isFalse);
      expect(
        h.w.requests.where((r) => r['method'] == 'pool.query').single['params'],
        [
          [],
          {
            'limit': 65,
            'select': [
              'id',
              'name',
              'guid',
              'status',
              'healthy',
              'warning',
              'scan',
              'expand',
              'size',
              'allocated',
              'free',
            ],
          },
        ],
      );
      expect(
        h.w.requests
            .where((r) => r['method'] == 'pool.scrub.query')
            .single['params'],
        [
          [],
          {
            'limit': 65,
            'select': [
              'id',
              'pool',
              'pool_name',
              'threshold',
              'description',
              'schedule',
              'enabled',
            ],
          },
        ],
      );
      expect(inv.pools.single.scan!.state, 'NONE');
      expect(inv.pools.single.scan!.percentage, 0);
    },
  );
  test(
    'scan UTC naive and extended dates normalize; pause is a datetime',
    () async {
      final h = await _connected();
      h.w.scanRunning(paused: true);
      final inv = await h.r.loadPoolMaintenance();
      final s = inv.pools.single.scan!;
      expect(s.startTime, DateTime.utc(2026, 9, 14, 1));
      expect(s.paused, isTrue);
      expect(s.pauseTime, DateTime.utc(2026, 9, 14, 1, 1));
      final review = await h.r.reviewPoolMaintenance(
        _request(inv, PoolMaintenanceAction.stopScrub),
      );
      expect(review.target, contains('2026-09-14T01:00:00.000Z'));
    },
  );
  test('active arbitrary jobs do not project arguments', () async {
    final h = await _connected();
    h.w.jobs.add(
      _job(
        41,
        'RUNNING',
        method: 'arbitrary.secret.operation',
        args: [_private],
      ),
    );
    final inv = await h.r.loadPoolMaintenance();
    expect(inv.jobs.single.action, isNull);
    final calls = h.w.requests
        .where((r) => r['method'] == 'core.get_jobs')
        .toList();
    expect(calls.length, 1);
    expect((calls.single['params'] as List).last['select'], [
      'id',
      'method',
      'state',
    ]);
    await expectLater(
      h.r.reviewPoolMaintenance(
        _request(inv, PoolMaintenanceAction.startScrub),
      ),
      throwsA(_reason(PoolMaintenanceExceptionReason.invalidRequest)),
    );
  });
  test(
    'STOP allows target wrapper and child START but not unrelated jobs',
    () async {
      final h = await _connected();
      h.w.scanRunning();
      h.w.jobs.addAll([
        _job(41, 'RUNNING', method: 'pool.scrub', args: [1, 'START']),
        _job(42, 'RUNNING'),
      ]);
      final inv = await h.r.loadPoolMaintenance();
      expect(inv.jobs.every((j) => j.starts(inv.pools.single)), isTrue);
      expect(
        (await h.r.reviewPoolMaintenance(
          _request(inv, PoolMaintenanceAction.stopScrub),
        )).action,
        PoolMaintenanceAction.stopScrub,
      );
      for (final call in h.w.requests.where(
        (r) => r['method'] == 'core.get_jobs',
      )) {
        final args = call['params'] as List;
        if ((args.last['select'] as List).contains('arguments')) {
          expect((args.first as List).any((f) => f[0] == 'method'), isTrue);
        }
      }
    },
  );
  for (final action in [
    PoolMaintenanceAction.createSchedule,
    PoolMaintenanceAction.updateSchedule,
    PoolMaintenanceAction.deleteSchedule,
    PoolMaintenanceAction.enableSchedule,
    PoolMaintenanceAction.disableSchedule,
  ]) {
    test('exact ${action.name} payload receipt post-read single-use', () async {
      final h = await _connected();
      if (action == PoolMaintenanceAction.createSchedule) h.w.schedules.clear();
      if (action == PoolMaintenanceAction.enableSchedule) {
        h.w.schedules.single['enabled'] = false;
      }
      final inv = await h.r.loadPoolMaintenance();
      final request = _request(inv, action);
      final review = await h.r.reviewPoolMaintenance(request);
      expect(review.warnings.join(' '), contains('cron'));
      final result = await h.r.executePoolMaintenance(review, review.target);
      expect(result.outcome, PoolMaintenanceOutcome.succeeded);
      expect(result.job, isNull);
      final expected = switch (action) {
        PoolMaintenanceAction.createSchedule => [
          {'pool': 1, ..._settingsWire},
        ],
        PoolMaintenanceAction.updateSchedule => [10, _settingsWire],
        PoolMaintenanceAction.deleteSchedule => [10],
        PoolMaintenanceAction.enableSchedule => [
          10,
          {'enabled': true},
        ],
        _ => [
          10,
          {'enabled': false},
        ],
      };
      expect(h.w.writes.single['params'], expected);
      await expectLater(
        h.r.executePoolMaintenance(review, review.target),
        throwsA(_reason(PoolMaintenanceExceptionReason.staleReview)),
      );
      expect(h.w.writes.length, 1);
    });
  }
  test('START accepted exact owned job then explicit finish check', () async {
    final h = await _connected();
    final inv = await h.r.loadPoolMaintenance();
    final review = await h.r.reviewPoolMaintenance(
      _request(inv, PoolMaintenanceAction.startScrub),
    );
    final result = await h.r.executePoolMaintenance(review, review.target);
    expect(result.outcome, PoolMaintenanceOutcome.accepted);
    expect(result.jobId, 100);
    expect(h.w.writes.single['params'], ['tank', 'START']);
    expect(result.message, contains('not completion'));
    final n = h.w.requests.length;
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(h.w.requests.length, n);
    h.w.finish(100);
    final done = await h.r.checkPoolMaintenanceJob(result.job!);
    expect(done.outcome, PoolMaintenanceOutcome.succeeded);
    expect(done.message, contains('FINISHED'));
    await expectLater(
      h.r.checkPoolMaintenanceJob(result.job!),
      throwsA(_reason(PoolMaintenanceExceptionReason.staleReview)),
    );
  });
  test('waiting accepted is not completion and still locks others', () async {
    final h = await _connected();
    h.w.jobMode = 'WAITING';
    final inv = await h.r.loadPoolMaintenance();
    final review = await h.r.reviewPoolMaintenance(
      _request(inv, PoolMaintenanceAction.startScrub),
    );
    final result = await h.r.executePoolMaintenance(review, review.target);
    expect(result.outcome, PoolMaintenanceOutcome.accepted);
    expect(result.message, contains('waiting'));
    await _crossBlocked(h);
  });
  test(
    'START accepted permits exact STOP; STOP checks earlier owned START too',
    () async {
      final h = await _connected();
      final first = await _execute(h, PoolMaintenanceAction.startScrub);
      expect(first.outcome, PoolMaintenanceOutcome.accepted);
      final stopped = await _execute(h, PoolMaintenanceAction.stopScrub);
      expect(stopped.outcome, PoolMaintenanceOutcome.accepted);
      expect(stopped.jobId, 101);
      h.w.finish(101, canceled: true);
      final awaiting = await h.r.checkPoolMaintenanceJob(stopped.job!);
      expect(awaiting.outcome, PoolMaintenanceOutcome.accepted);
      expect(awaiting.message, contains('earlier'));
      h.w.jobs.firstWhere((j) => j['id'] == 100)['state'] = 'SUCCESS';
      final done = await h.r.checkPoolMaintenanceJob(stopped.job!);
      expect(done.outcome, PoolMaintenanceOutcome.succeeded);
      expect(done.message, contains('CANCELED'));
      await expectLater(
        h.r.checkPoolMaintenanceJob(first.job!),
        throwsA(_reason(PoolMaintenanceExceptionReason.staleReview)),
      );
      expect(h.w.writes.length, 2);
    },
  );
  test(
    'external paused scrub can be STOPped with exact scan identity',
    () async {
      final h = await _connected();
      h.w.scanRunning(paused: true);
      h.w.jobMode = 'SUCCESS';
      final result = await _execute(h, PoolMaintenanceAction.stopScrub);
      expect(result.outcome, PoolMaintenanceOutcome.succeeded);
      expect(h.w.writes.single['params'], ['tank', 'STOP']);
    },
  );
  test('terminal paused START is not presented as scrub complete', () async {
    final h = await _connected();
    final result = await _execute(h, PoolMaintenanceAction.startScrub);
    h.w.jobs.single['state'] = 'SUCCESS';
    h.w.scanRunning(paused: true);
    final done = await h.r.checkPoolMaintenanceJob(result.job!);
    expect(done.outcome, PoolMaintenanceOutcome.succeeded);
    expect(done.message, contains('not complete'));
  });
  for (final mode in [
    'ha',
    'offline',
    'degraded',
    'warning',
    'unhealthy',
    'expanding',
    'resilver',
    'other-scan',
    'other-job',
    'wrong-start-job',
  ]) {
    test('$mode blocks reviews without effects', () async {
      final h = await _connected();
      h.w.block(mode);
      final inv = await h.r.loadPoolMaintenance();
      await expectLater(
        h.r.reviewPoolMaintenance(
          _request(
            inv,
            mode == 'wrong-start-job'
                ? PoolMaintenanceAction.stopScrub
                : PoolMaintenanceAction.startScrub,
          ),
        ),
        throwsA(_reason(PoolMaintenanceExceptionReason.invalidRequest)),
      );
      expect(h.w.writes, isEmpty);
    });
  }
  for (final mode in [
    'guid',
    'name',
    'status',
    'scan-start',
    'scan-pause',
    'schedule',
    'timezone',
    'job',
    'pool-added',
  ]) {
    test('fresh $mode drift prevents submission', () async {
      final h = await _connected();
      final stop = mode.startsWith('scan-');
      if (stop) h.w.scanRunning();
      final inv = await h.r.loadPoolMaintenance();
      final review = await h.r.reviewPoolMaintenance(
        _request(
          inv,
          stop
              ? PoolMaintenanceAction.stopScrub
              : PoolMaintenanceAction.startScrub,
        ),
      );
      h.w.drift(mode);
      final result = await h.r.executePoolMaintenance(review, review.target);
      expect(result.outcome, PoolMaintenanceOutcome.rejected);
      expect(h.w.writes, isEmpty);
    });
  }
  test(
    'scan progress and capacity drift do not change STOP identity',
    () async {
      final h = await _connected();
      h.w.scanRunning();
      final inv = await h.r.loadPoolMaintenance();
      final review = await h.r.reviewPoolMaintenance(
        _request(inv, PoolMaintenanceAction.stopScrub),
      );
      h.w.scan['percentage'] = 82.5;
      h.w.pool['free'] = 500;
      h.w.pool['allocated'] = 500;
      final result = await h.r.executePoolMaintenance(review, review.target);
      expect(result.outcome, PoolMaintenanceOutcome.accepted);
    },
  );
  test('wrong confirmation consumes review without effect', () async {
    final h = await _connected();
    final inv = await h.r.loadPoolMaintenance();
    final review = await h.r.reviewPoolMaintenance(
      _request(inv, PoolMaintenanceAction.startScrub),
    );
    await expectLater(
      h.r.executePoolMaintenance(review, 'START'),
      throwsA(_reason(PoolMaintenanceExceptionReason.staleReview)),
    );
    await expectLater(
      h.r.executePoolMaintenance(review, review.target),
      throwsA(_reason(PoolMaintenanceExceptionReason.staleReview)),
    );
    expect(h.w.writes, isEmpty);
  });
  test('public forged review and job never gain authority', () async {
    final h = await _connected();
    final inv = await h.r.loadPoolMaintenance();
    final fake = PoolMaintenanceReview(
      request: _request(inv, PoolMaintenanceAction.startScrub),
      endpoint: inv.endpoint,
      warnings: [],
    );
    final n = h.w.requests.length;
    await expectLater(
      h.r.executePoolMaintenance(fake, fake.target),
      throwsA(_reason(PoolMaintenanceExceptionReason.staleReview)),
    );
    await expectLater(
      h.r.checkPoolMaintenanceJob(
        PoolMaintenanceJob(
          id: 1,
          poolId: 1,
          endpoint: inv.endpoint,
          poolName: 'tank',
          poolGuid: '12345',
          action: PoolMaintenanceAction.startScrub,
        ),
      ),
      throwsA(_reason(PoolMaintenanceExceptionReason.staleReview)),
    );
    expect(h.w.requests.length, n);
  });
  test('inventory refresh invalidates issued review', () async {
    final h = await _connected();
    final inv = await h.r.loadPoolMaintenance();
    final review = await h.r.reviewPoolMaintenance(
      _request(inv, PoolMaintenanceAction.startScrub),
    );
    await h.r.loadPoolMaintenance();
    await expectLater(
      h.r.executePoolMaintenance(review, review.target),
      throwsA(_reason(PoolMaintenanceExceptionReason.staleReview)),
    );
  });
  for (final failure in [
    'permission',
    'error',
    'timeout',
    'job-bool',
    'job-zero',
    'job-wrong-method',
    'job-wrong-args',
    'job-failed',
    'job-aborted',
    'job-missing',
    'job-bad-result',
    'post-pool',
    'post-read',
  ]) {
    test(
      'post-dispatch $failure is unknown with durable shared fence',
      () async {
        final h = await _connected(timeout: const Duration(milliseconds: 70));
        final inv = await h.r.loadPoolMaintenance();
        final review = await h.r.reviewPoolMaintenance(
          _request(inv, PoolMaintenanceAction.startScrub),
        );
        h.w.failure = failure;
        final result = await h.r.executePoolMaintenance(review, review.target);
        expect(result.outcome, PoolMaintenanceOutcome.unknown);
        expect(result.message, isNot(contains(_private)));
        expect(h.w.writes.length, 1);
        h.w.failure = null;
        await h.r.loadPoolMaintenance();
        await _crossBlocked(h);
      },
    );
  }
  for (final failure in [
    'permission',
    'error',
    'timeout',
    'receipt',
    'wrong-id',
    'post-pool',
    'post-read',
    'post-schedule',
    'delete-null',
  ]) {
    test('schedule $failure postdispatch cannot be replayed', () async {
      final h = await _connected(timeout: const Duration(milliseconds: 70));
      final inv = await h.r.loadPoolMaintenance();
      final review = await h.r.reviewPoolMaintenance(
        _request(
          inv,
          failure == 'delete-null'
              ? PoolMaintenanceAction.deleteSchedule
              : PoolMaintenanceAction.updateSchedule,
        ),
      );
      h.w.failure = failure;
      final result = await h.r.executePoolMaintenance(review, review.target);
      expect(result.outcome, PoolMaintenanceOutcome.unknown);
      expect(h.w.writes.length, 1);
      h.w.failure = null;
      await _crossBlocked(h);
    });
  }
  for (final malformed in [
    'pool-bool-id',
    'duplicate-pool',
    'duplicate-guid',
    'pool-secret-name',
    'pool-negative-size',
    'pool-missing-scan',
    'pool-missing-expand',
    'pool-scan-bool-pause',
    'pool-bad-date',
    'pool-bad-percent',
    'pool-scan-resilver-pause',
    'schedule-duplicate',
    'schedule-wrong-pool',
    'schedule-wrong-name',
    'schedule-negative-threshold',
    'schedule-cron',
    'schedule-missing-enabled',
    'job-duplicate',
    'job-secret-method',
    'job-bad-state',
    'job-bad-args',
    'general',
    'ha',
  ]) {
    test('malformed $malformed read fails closed', () async {
      final h = await _connected();
      h.w.malformed = malformed;
      await expectLater(
        h.r.loadPoolMaintenance(),
        throwsA(_reason(PoolMaintenanceExceptionReason.invalidResponse)),
      );
      expect(h.w.writes, isEmpty);
    });
  }
  test('preflight error is redacted rejected without write', () async {
    final h = await _connected();
    final inv = await h.r.loadPoolMaintenance();
    final review = await h.r.reviewPoolMaintenance(
      _request(inv, PoolMaintenanceAction.startScrub),
    );
    h.w.errorMethod = 'pool.query';
    final result = await h.r.executePoolMaintenance(review, review.target);
    expect(result.outcome, PoolMaintenanceOutcome.rejected);
    expect(result.message, isNot(contains(_private)));
    expect(h.w.writes, isEmpty);
  });
  for (final cron in [
    const PoolScrubCron(minute: '60'),
    const PoolScrubCron(hour: '24'),
    const PoolScrubCron(dom: '31', month: '2', dow: '*'),
    const PoolScrubCron(dow: 'MON'),
    const PoolScrubCron(minute: '*/0'),
    const PoolScrubCron(minute: '1;reboot'),
  ]) {
    test(
      'invalid cron ${cron.expression} is rejected',
      () => expect(cron.validationError, isNotNull),
    );
  }
  for (final cron in [
    const PoolScrubCron(),
    const PoolScrubCron(minute: '*/15', hour: '0-23/2'),
    const PoolScrubCron(dom: '29', month: '2', dow: '*'),
    const PoolScrubCron(dow: '0,7'),
  ]) {
    test(
      'bounded valid cron ${cron.expression}',
      () => expect(cron.validationError, isNull),
    );
  }
  test(
    'accepted scrub blocks cloud credential reviews and legacy writes',
    () async {
      final h = await _connected();
      expect(
        (await _execute(h, PoolMaintenanceAction.startScrub)).outcome,
        PoolMaintenanceOutcome.accepted,
      );
      await _crossBlocked(h);
    },
  );
  test(
    'dashboard pool read remains available while accepted job fences writes',
    () async {
      final h = await _connected();
      await _execute(h, PoolMaintenanceAction.startScrub);
      final count = h.w.writes.length;
      expect(await h.r.query('pool.query'), isA<List>());
      expect(h.w.writes.length, count);
      await _crossBlocked(h);
    },
  );
  test('unknown owned job stays unknown even after later valid running or terminal reads', () async {
    final h = await _connected();
    final result = await _execute(h, PoolMaintenanceAction.startScrub);
    h.w.failure = 'job-missing';
    expect(
      (await h.r.checkPoolMaintenanceJob(result.job!)).outcome,
      PoolMaintenanceOutcome.unknown,
    );
    h.w.failure = null;
    expect(
      (await h.r.checkPoolMaintenanceJob(result.job!)).outcome,
      PoolMaintenanceOutcome.unknown,
    );
    h.w.finish(result.jobId!);
    expect(
      (await h.r.checkPoolMaintenanceJob(result.job!)).outcome,
      PoolMaintenanceOutcome.unknown,
    );
    await _crossBlocked(h);
  });
  test('owned START never rebinds to a different later scan', () async {
    final h = await _connected();
    final result = await _execute(h, PoolMaintenanceAction.startScrub);
    h.w.scan['start_time'] = '2026-09-14T01:00:01';
    expect(
      (await h.r.checkPoolMaintenanceJob(result.job!)).outcome,
      PoolMaintenanceOutcome.unknown,
    );
    await _crossBlocked(h);
  });
  test('owned START fence never permits STOP of a replacement scan', () async {
    final h = await _connected();
    await _execute(h, PoolMaintenanceAction.startScrub);
    h.w.scan['start_time'] = '2026-09-14T01:00:01';
    final inv = await h.r.loadPoolMaintenance();
    final n = h.w.requests.length;
    await expectLater(
      h.r.reviewPoolMaintenance(_request(inv, PoolMaintenanceAction.stopScrub)),
      throwsA(_reason(PoolMaintenanceExceptionReason.busy)),
    );
    expect(h.w.requests.length, n);
    expect(h.w.writes.length, 1);
  });
  test(
    'waiting owned START requires explicit observation before STOP',
    () async {
      final h = await _connected();
      h.w.jobMode = 'WAITING';
      final accepted = await _execute(h, PoolMaintenanceAction.startScrub);
      h.w.scanRunning();
      h.w.jobs.single['state'] = 'RUNNING';
      final inv = await h.r.loadPoolMaintenance();
      await expectLater(
        h.r.reviewPoolMaintenance(
          _request(inv, PoolMaintenanceAction.stopScrub),
        ),
        throwsA(_reason(PoolMaintenanceExceptionReason.busy)),
      );
      expect(
        (await h.r.checkPoolMaintenanceJob(accepted.job!)).outcome,
        PoolMaintenanceOutcome.accepted,
      );
      final fresh = await h.r.loadPoolMaintenance();
      expect(
        (await h.r.reviewPoolMaintenance(
          _request(fresh, PoolMaintenanceAction.stopScrub),
        )).action,
        PoolMaintenanceAction.stopScrub,
      );
    },
  );
  test('internal scheduled default START argument is understood only for scrub method', () async {
    final h = await _connected();
    h.w.scanRunning();
    h.w.jobs.add(_job(41, 'RUNNING', args: ['tank']));
    final inv = await h.r.loadPoolMaintenance();
    expect(inv.jobs.single.action, 'START');
    expect(
      (await h.r.reviewPoolMaintenance(
        _request(inv, PoolMaintenanceAction.stopScrub),
      )).action,
      PoolMaintenanceAction.stopScrub,
    );
  });
  test(
    'pending dispatch fences all supported native writer families',
    () async {
      final h = await _connected(timeout: const Duration(milliseconds: 100));
      final inv = await h.r.loadPoolMaintenance();
      final review = await h.r.reviewPoolMaintenance(
        _request(inv, PoolMaintenanceAction.startScrub),
      );
      h.w.holdMethod = 'pool.scrub.scrub';
      final future = h.r.executePoolMaintenance(review, review.target);
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await _crossBlocked(h);
      expect((await future).outcome, PoolMaintenanceOutcome.unknown);
    },
  );
  test(
    'pool and schedule inventory capacities never silently truncate',
    () async {
      final h = await _connected();
      h.w.pools.addAll(
        List.generate(
          64,
          (i) => {
            ..._pool(i + 2),
            'name': 'pool${i + 2}',
            'guid': '${90000 + i}',
          },
        ),
      );
      await expectLater(
        h.r.loadPoolMaintenance(),
        throwsA(_reason(PoolMaintenanceExceptionReason.invalidResponse)),
      );
    },
  );
  test('new schedule on already scheduled pool is blocked', () async {
    final h = await _connected();
    final inv = await h.r.loadPoolMaintenance();
    await expectLater(
      h.r.reviewPoolMaintenance(
        _request(inv, PoolMaintenanceAction.createSchedule),
      ),
      throwsA(_reason(PoolMaintenanceExceptionReason.invalidRequest)),
    );
    expect(h.w.writes, isEmpty);
  });
  for (final pending in [true, false]) {
    test(
      'cloud credential ${pending ? 'pending' : 'unknown'} blocks pool zero frames',
      () async {
        final h = await _connected(timeout: const Duration(milliseconds: 70));
        final poolInv = await h.r.loadPoolMaintenance();
        final ci = await h.r.loadCloudCredentials();
        final cr = await h.r.reviewCloudCredential(
          CloudCredentialRequest(
            inventory: ci,
            action: CloudCredentialAction.delete,
            credential: ci.credentials.single,
          ),
        );
        h.w.holdMethod = 'cloudsync.credentials.delete';
        final future = h.r.executeCloudCredential(cr, cr.target);
        if (pending) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        } else {
          expect((await future).outcome, CloudCredentialOutcome.unknown);
        }
        final n = h.w.requests.length;
        await expectLater(
          h.r.reviewPoolMaintenance(
            _request(poolInv, PoolMaintenanceAction.startScrub),
          ),
          throwsA(_reason(PoolMaintenanceExceptionReason.busy)),
        );
        expect(h.w.requests.length, n);
        if (pending) await future;
      },
    );
  }
}

const _settings = PoolScrubScheduleSettings(
  threshold: 14,
  description: 'weekly verification',
  cron: PoolScrubCron(minute: '15', hour: '2', dow: '6'),
  enabled: false,
);
const _settingsWire = {
  'threshold': 14,
  'description': 'weekly verification',
  'schedule': {
    'minute': '15',
    'hour': '2',
    'dom': '*',
    'month': '*',
    'dow': '6',
  },
  'enabled': false,
};
PoolMaintenanceRequest _request(
  PoolMaintenanceInventory inv,
  PoolMaintenanceAction action,
) => PoolMaintenanceRequest(
  inventory: inv,
  action: action,
  pool: inv.pools.first,
  schedule:
      const [
        PoolMaintenanceAction.startScrub,
        PoolMaintenanceAction.stopScrub,
        PoolMaintenanceAction.createSchedule,
      ].contains(action)
      ? null
      : inv.schedules.first,
  settings:
      const [
        PoolMaintenanceAction.createSchedule,
        PoolMaintenanceAction.updateSchedule,
      ].contains(action)
      ? _settings
      : null,
);
Future<PoolMaintenanceResult> _execute(
  _Harness h,
  PoolMaintenanceAction action,
) async {
  final inv = await h.r.loadPoolMaintenance();
  final review = await h.r.reviewPoolMaintenance(_request(inv, action));
  return h.r.executePoolMaintenance(review, review.target);
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
  final method = h.r.adminCatalog.method('pool.dataset.create');
  if (method != null && method.supported) {
    await expectLater(
      h.r.invokeAdmin(AdminRequest(method: method, arguments: const [])),
      throwsA(isA<AdminException>()),
    );
  }
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
  final r = TrueNasSessionRepository(
    connector: _Connector(w),
    managementRequestTimeout: timeout,
  );
  addTearDown(r.close);
  await r.connect(
    serverInput: 'https://synthetic.example',
    username: 'synthetic-user',
    apiKey: 'synthetic-key',
  );
  return _Harness(r, w);
}

final class _Connector implements RpcConnector {
  const _Connector(this.w);
  final _Wire w;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => w;
}

Map<String, Object?> _pool(int id) => {
  'id': id,
  'name': id == 1 ? 'tank' : 'backup',
  'guid': id == 1 ? '12345' : '67890',
  'status': 'ONLINE',
  'healthy': true,
  'warning': false,
  'scan': _scan(),
  'expand': {'state': 'NONE'},
  'size': 1000,
  'allocated': 400,
  'free': 600,
  'topology': _private,
  'status_detail': _private,
};
Map<String, Object?> _scan() => {
  'function': null,
  'state': 'NONE',
  'start_time': '1970-01-01T00:00:00',
  'end_time': '1970-01-01T00:00:00',
  'pause': null,
  'percentage': 0,
  'errors': 0,
  'total_secs_left': null,
};
Map<String, Object?> _schedule(int id) => {
  'id': id,
  'pool': 1,
  'pool_name': 'tank',
  'threshold': 35,
  'description': 'weekly',
  'schedule': {
    'minute': '0',
    'hour': '3',
    'dom': '*',
    'month': '*',
    'dow': '7',
  },
  'enabled': true,
};
Map<String, Object?> _job(
  int id,
  String state, {
  String method = 'pool.scrub.scrub',
  List<Object?> args = const ['tank', 'START'],
}) => {
  'id': id,
  'method': method,
  'state': state,
  'arguments': args,
  'result': null,
  'error': _private,
  'logs_excerpt': _private,
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
  final _incoming = StreamController<String>();
  final requests = <Map<String, dynamic>>[];
  final pools = <Map<String, Object?>>[_pool(1)],
      schedules = <Map<String, Object?>>[_schedule(10)],
      jobs = <Map<String, Object?>>[];
  Map<String, Object?> get pool => pools.first;
  Map get scan => pool['scan'] as Map;
  bool ha = false, mutated = false;
  String timezone = 'UTC', jobMode = 'RUNNING';
  String? failure, malformed, errorMethod, holdMethod;
  int nextJob = 100;
  List<Map<String, dynamic>> get writes =>
      requests.where((r) => _writes.contains(r['method'])).toList();
  @override
  Stream<String> get inboundFrames => _incoming.stream;
  void scanRunning({bool paused = false}) {
    pool['scan'] = {
      ..._scan(),
      'function': 'SCRUB',
      'state': 'SCANNING',
      'start_time': '2026-09-14T01:00:00',
      'end_time': null,
      'percentage': 23.5,
      'pause': paused
          ? {r'$date': DateTime.utc(2026, 9, 14, 1, 1).millisecondsSinceEpoch}
          : null,
      'total_secs_left': 500,
    };
  }

  void finish(int id, {bool canceled = false}) {
    jobs.firstWhere((j) => j['id'] == id)['state'] = 'SUCCESS';
    scan['state'] = canceled ? 'CANCELED' : 'FINISHED';
    scan['end_time'] = '2026-09-14T02:00:00';
    scan['pause'] = null;
    scan['total_secs_left'] = null;
  }

  void block(String mode) {
    switch (mode) {
      case 'ha':
        ha = true;
      case 'offline':
        pool['status'] = 'OFFLINE';
        pool['healthy'] = false;
      case 'degraded':
        pool['status'] = 'DEGRADED';
      case 'warning':
        pool['warning'] = true;
      case 'unhealthy':
        pool['healthy'] = false;
      case 'expanding':
        pool['expand'] = {'state': 'SCANNING'};
      case 'resilver':
        scanRunning();
        scan['function'] = 'RESILVER';
      case 'other-scan':
        final p = _pool(2);
        scanRunning();
        p['scan'] = Map.of(scan);
        pool['scan'] = _scan();
        pools.add(p);
      case 'other-job':
        jobs.add(_job(41, 'RUNNING', method: 'replication.run'));
      case 'wrong-start-job':
        scanRunning();
        jobs.add(_job(41, 'RUNNING', args: ['backup', 'START']));
    }
  }

  void drift(String mode) {
    switch (mode) {
      case 'guid':
        pool['guid'] = '99999';
      case 'name':
        pool['name'] = 'renamed';
        schedules.single['pool_name'] = 'renamed';
      case 'status':
        pool['warning'] = true;
      case 'scan-start':
        scan['start_time'] = '2026-09-14T01:00:01';
      case 'scan-pause':
        scan['pause'] = '2026-09-14T01:01:00';
      case 'schedule':
        schedules.single['threshold'] = 40;
      case 'timezone':
        timezone = 'Asia/Seoul';
      case 'job':
        jobs.add(_job(50, 'RUNNING', method: 'other.operation'));
      case 'pool-added':
        pools.add(_pool(2));
    }
  }

  void error(Map r) => _incoming.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': r['id'],
      'error': {
        'code': -32000,
        'message': _private,
        'data': {'errno': failure == 'permission' ? 13 : 5, 'secret': _private},
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
        mutated && failure == 'post-read' && method == 'pool.query') {
      error(r);
      return;
    }
    Object? result;
    switch (method) {
      case 'auth.login_ex':
        result = {'response_type': 'SUCCESS'};
      case 'auth.me':
        result = {'pw_name': 'synthetic-user'};
      case 'system.info':
        result = {
          'version': version,
          'hostname': 'synthetic',
          'system_product': 'Synthetic',
          'cores': 2,
          'physmem': 1024,
          'uptime_seconds': 30,
        };
      case 'core.get_methods':
        result = {
          for (final name in methods)
            name: {
              'job': name == 'pool.scrub.scrub',
              'uploadable': false,
              'downloadable': false,
              'no_auth_required': false,
              'accepts': [],
              'returns': [],
              'roles': ['FULL_ADMIN'],
              ...?(overrides[name]),
            },
        };
      case 'pool.query':
        final values = jsonDecode(jsonEncode(pools)) as List;
        final p = values.first as Map;
        final s = p['scan'] as Map;
        if (mutated && failure == 'post-pool') p['guid'] = '98765';
        switch (malformed) {
          case 'pool-bool-id':
            p['id'] = true;
          case 'duplicate-pool':
            values.add(Map.of(p));
          case 'duplicate-guid':
            values.add({..._pool(2), 'guid': '12345'});
          case 'pool-secret-name':
            p['name'] = 'tank\n$_private';
          case 'pool-negative-size':
            p['size'] = -1;
          case 'pool-missing-scan':
            p.remove('scan');
          case 'pool-missing-expand':
            p.remove('expand');
          case 'pool-scan-bool-pause':
            s['pause'] = false;
          case 'pool-bad-date':
            s['start_time'] = '2026-02-30T00:00:00Z';
          case 'pool-bad-percent':
            s['percentage'] = _private;
          case 'pool-scan-resilver-pause':
            s['function'] = 'RESILVER';
            s['state'] = 'SCANNING';
            s['start_time'] = '2026-09-14T01:00:00Z';
            s['end_time'] = null;
            s['pause'] = '2026-09-14T01:01:00Z';
        }
        result = values;
      case 'pool.scrub.query':
        final values = jsonDecode(jsonEncode(schedules)) as List;
        if (values.isNotEmpty) {
          final s = values.first as Map;
          if (mutated && failure == 'post-schedule') {
            s['description'] = 'unexpected';
          }
          switch (malformed) {
            case 'schedule-duplicate':
              values.add(Map.of(s));
            case 'schedule-wrong-pool':
              s['pool'] = 9;
            case 'schedule-wrong-name':
              s['pool_name'] = 'backup';
            case 'schedule-negative-threshold':
              s['threshold'] = -1;
            case 'schedule-cron':
              (s['schedule'] as Map)['minute'] = '@reboot';
            case 'schedule-missing-enabled':
              s.remove('enabled');
          }
        }
        result = values;
      case 'system.general.config':
        result = {
          'timezone': malformed == 'general' ? true : timezone,
          'unused': _private,
        };
      case 'failover.licensed':
        result = malformed == 'ha' ? _private : ha;
      case 'core.get_jobs':
        final args = r['params'] as List;
        final filters = args.first as List;
        final idFilter = filters.where((f) => f[0] == 'id').toList();
        var values = jobs
            .where(
              (j) => idFilter.isNotEmpty
                  ? j['id'] == idFilter.first[2]
                  : {'WAITING', 'RUNNING'}.contains(j['state']),
            )
            .map((j) => Map<String, Object?>.of(j))
            .toList();
        if (idFilter.isNotEmpty && mutated) {
          if (failure == 'job-missing') values = [];
          if (values.isNotEmpty) {
            final j = values.first;
            switch (failure) {
              case 'job-wrong-method':
                j['method'] = 'pool.export';
              case 'job-wrong-args':
                j['arguments'] = ['backup', 'START'];
              case 'job-failed':
                j['state'] = 'FAILED';
              case 'job-aborted':
                j['state'] = 'ABORTED';
              case 'job-bad-result':
                j['state'] = 'SUCCESS';
                j['result'] = true;
            }
          }
        }
        if (malformed?.startsWith('job-') == true && values.isEmpty) {
          values = [_job(41, 'RUNNING')];
        }
        switch (malformed) {
          case 'job-duplicate':
            values.add(Map.of(values.first));
          case 'job-secret-method':
            values.first['method'] = 'private\n$_private';
          case 'job-bad-state':
            values.first['state'] = 'UNKNOWN';
          case 'job-bad-args':
            values.first['arguments'] = [true, 'START'];
        }
        result = values;
      case 'pool.scrub.scrub':
        mutated = true;
        final args = r['params'] as List;
        final id = nextJob++;
        jobs.add(_job(id, jobMode, args: List<Object?>.from(args)));
        if (jobMode != 'WAITING') {
          if (args[1] == 'START') scanRunning();
          if (jobMode == 'SUCCESS') finish(id, canceled: args[1] == 'STOP');
        }
        result = failure == 'job-bool'
            ? true
            : failure == 'job-zero'
            ? 0
            : id;
      case 'pool.scrub.create':
        mutated = true;
        final payload = (r['params'] as List).single as Map;
        final task = <String, Object?>{
          'id': 11,
          'pool_name': 'tank',
          ...Map<String, Object?>.from(payload),
        };
        schedules.add(task);
        result = task;
      case 'pool.scrub.update':
        mutated = true;
        final args = r['params'] as List;
        final task = schedules.singleWhere((s) => s['id'] == args.first);
        task.addAll(Map<String, Object?>.from(args[1] as Map));
        result = task;
      case 'pool.scrub.delete':
        mutated = true;
        schedules.removeWhere((s) => s['id'] == (r['params'] as List).single);
        result = failure == 'delete-null' ? null : true;
      case 'cloudsync.credentials.query':
        result = [
          {
            'id': 5,
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
        method != 'pool.scrub.scrub' &&
        result is Map) {
      if (failure == 'receipt') result = {'id': _private};
      if (failure == 'wrong-id') result = {...result, 'id': 999};
    }
    _incoming.add(
      jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}
