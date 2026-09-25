import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _settings = ReplicationSettings(
  name: 'Local archive',
  source: 'tank/media',
  destination: 'backup/parent/archive',
);
const _reads = {
  'replication.query',
  'pool.dataset.query',
  'pool.filesystem_choices',
  'pool.snapshot.query',
  'core.get_jobs',
};
const _writes = {
  'replication.create',
  'replication.update',
  'replication.delete',
  'replication.run',
};
const _methods = {..._reads, ..._writes, 'pool.dataset.create'};
const _secret = 'synthetic-secret-never-display';
Matcher _reason(ReplicationExceptionReason r) =>
    isA<ReplicationException>().having((e) => e.reason, 'reason', r);

void main() {
  test('disconnected replication does not dispatch', () async {
    final wire = _Wire();
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    expect(repo.replicationCapabilities.connected, isFalse);
    await expectLater(
      repo.loadReplication(),
      throwsA(_reason(ReplicationExceptionReason.notAuthenticated)),
    );
    expect(wire.requests, isEmpty);
  });
  for (final version in ['25.04.2', '26.0.0', '25.10-BETA', '25.10.1\n']) {
    test('unsupported $version fails closed', () async {
      final h = await _connect(version: version);
      expect(h.repo.replicationCapabilities.supported, isFalse);
      await expectLater(
        h.repo.loadReplication(),
        throwsA(_reason(ReplicationExceptionReason.unsupportedVersion)),
      );
      expect(h.wire.requests, hasLength(4));
    });
  }
  for (final missing in _reads) {
    test('missing $missing blocks inventory', () async {
      final h = await _connect(methods: _methods.difference({missing}));
      expect(h.repo.replicationCapabilities.supported, isFalse);
      await expectLater(
        h.repo.loadReplication(),
        throwsA(_reason(ReplicationExceptionReason.unavailableMethod)),
      );
    });
  }
  for (final override in [
    {'job': false},
    {'job': null},
    {'uploadable': true},
    {'downloadable': true},
    {'private': true},
    {'_private': true},
    {'no_auth_required': true},
    {'check_pipes': true},
    {
      'check_pipes': ['input'],
    },
    {'check_pipes': 'input'},
  ]) {
    test('unsafe job metadata $override rejects run', () async {
      final h = await _connect(overrides: {'replication.run': override});
      expect(h.repo.replicationCapabilities.canRun, isFalse);
      expect(h.repo.replicationCapabilities.canCreate, isTrue);
    });
  }
  test(
    'bounded inventory is immutable and does not fetch or expose credentials',
    () async {
      final h = await _connect();
      final inventory = await h.repo.loadReplication();
      expect(inventory.tasks.single.available, isTrue);
      expect(inventory.datasets, hasLength(3));
      expect(() => inventory.tasks.clear(), throwsUnsupportedError);
      expect(() => inventory.datasets.clear(), throwsUnsupportedError);
      expect(h.wire.writes, isEmpty);
      expect(h.wire.requests.skip(4).map((r) => r['method']), [
        'replication.query',
        'pool.dataset.query',
        'pool.filesystem_choices',
        'core.get_jobs',
      ]);
      final request = h.wire.requests[4];
      expect((request['params'] as List)[1]['limit'], 129);
      final fields = jsonEncode((request['params'] as List)[1]['select']);
      expect(fields, isNot(contains('encryption_key"')));
      expect(fields, isNot(contains('encryption_key_location')));
      expect(fields, contains('ssh_credentials.id'));
    },
  );
  for (final patch in <Map<String, Object?>>[
    {'transport': 'SSH', 'credential_id': 10},
    {'recursive': true},
    {'auto': true},
    {'properties': true},
    {'encryption': true},
    {'allow_from_scratch': true},
    {'retries': 5},
    {'readonly': 'IGNORE'},
    {
      'periodic_snapshot_tasks': [
        {'id': 1},
      ],
    },
    {
      'properties_override': {'mountpoint': '/secret'},
    },
    {
      'source_datasets': ['tank/media', 'tank/other'],
    },
    {'name_regex': '.*'},
  ]) {
    test('advanced task $patch is visible but cannot be rewritten', () async {
      final h = await _connect();
      h.wire.tasks.single.addAll(patch);
      final inventory = await h.repo.loadReplication();
      final task = inventory.tasks.single;
      expect(task.available, isFalse);
      expect(task.settings, isNull);
      await expectLater(
        h.repo.reviewReplication(
          ReplicationRequest(
            inventory: inventory,
            task: task,
            action: ReplicationAction.delete,
          ),
        ),
        throwsA(_reason(ReplicationExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final replacement in ['', 'x\n', 'x' * 121]) {
    test('invalid name is rejected before review $replacement', () {
      expect(_settings.copyWith(name: replacement).validationError, isNotNull);
    });
  }
  for (final destination in [
    'tank/media',
    'tank/media/copy',
    'tank',
    'tank/ix-apps/copy',
    'tank/../copy',
    'backup/parent/archive\n',
  ]) {
    test('invalid or overlapping destination $destination is rejected', () {
      expect(
        _settings.copyWith(destination: destination).validationError,
        isNotNull,
      );
    });
  }
  for (final patch in <Map<String, Object?>>[
    {'locked': true},
    {'encrypted': true},
    {
      'managedby': {'rawvalue': 'external'},
    },
    {
      'readonly': {'rawvalue': 'off'},
    },
    {'type': 'VOLUME'},
  ]) {
    test('unsafe destination $patch blocks review', () async {
      final h = await _connect();
      h.wire.datasets.last.addAll(patch);
      await expectLater(
        _review(h),
        throwsA(_reason(ReplicationExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('manual local review has explicit retention and rollback warnings; no write', () async {
    final h = await _connect();
    final review = await _review(h);
    expect(review.sourceSnapshots, 1);
    expect(review.destinationSnapshots, 1);
    expect(review.createsDestination, isFalse);
    expect(review.warnings.join(' '), contains('roll back'));
    expect(review.warnings.join(' '), contains('NONE'));
    expect(review.target, 'RUN Local archive');
    expect(h.wire.writes, isEmpty);
    expect(h.wire.requests.last['params'], [
      [
        [
          'dataset',
          'in',
          ['tank/media', 'backup/parent/archive'],
        ],
      ],
      {
        'limit': 257,
        'select': ['id', 'dataset', 'properties'],
        'extra': {
          'properties': ['guid', 'createtxg'],
        },
      },
    ]);
  });
  test(
    'new destination is allowed only below known safe direct parent',
    () async {
      final h = await _connect();
      h.wire.datasets.removeLast();
      h.wire.snapshots.removeLast();
      final review = await _review(h);
      expect(review.createsDestination, isTrue);
      expect(
        review.warnings.join(' '),
        contains('create the exact destination'),
      );
      final result = await h.repo.executeReplication(review, review.target);
      expect(result.outcome, ReplicationOutcome.pending);
    },
  );
  test('missing direct parent blocks native creation', () async {
    final h = await _connect();
    h.wire.datasets.removeRange(1, 3);
    await expectLater(
      _review(h),
      throwsA(_reason(ReplicationExceptionReason.invalidRequest)),
    );
  });
  for (final missingCommon in ['empty', 'guid', 'name']) {
    test(
      'existing destination needs a common snapshot name and GUID: $missingCommon',
      () async {
        final h = await _connect();
        if (missingCommon == 'empty') h.wire.snapshots.removeLast();
        if (missingCommon == 'guid') {
          (h.wire.snapshots.last['properties'] as Map)['guid'] = {
            'rawvalue': '999',
          };
        }
        if (missingCommon == 'name') {
          h.wire.snapshots.last['id'] = 'backup/parent/archive@other';
        }
        await expectLater(
          _review(h),
          throwsA(_reason(ReplicationExceptionReason.invalidRequest)),
        );
        expect(h.wire.writes, isEmpty);
      },
    );
  }
  for (final policy in ['NONE', 'SOURCE', 'CUSTOM']) {
    test('create $policy exact manual settings and verify readback', () async {
      final h = await _connect();
      h.wire.tasks.clear();
      final review = await _review(
        h,
        action: ReplicationAction.create,
        settings: _settings.copyWith(
          retention: policy,
          lifetimeValue: 7,
          lifetimeUnit: 'DAY',
        ),
      );
      final result = await h.repo.executeReplication(review, review.target);
      expect(result.outcome, ReplicationOutcome.succeeded);
      final body = (h.wire.writes.single['params'] as List).single as Map;
      expect(body['direction'], 'PUSH');
      expect(body['transport'], 'LOCAL');
      expect(body['auto'], false);
      expect(body['schedule'], isNull);
      expect(body['periodic_snapshot_tasks'], isEmpty);
      expect(body['allow_from_scratch'], false);
      expect(body['retries'], 1);
      expect(body['retention_policy'], policy);
      expect(body['lifetime_value'], policy == 'CUSTOM' ? 7 : null);
      expect(h.wire.writes.single['method'], 'replication.create');
      await expectLater(
        h.repo.executeReplication(review, review.target),
        throwsA(_reason(ReplicationExceptionReason.staleReview)),
      );
    });
  }
  for (final action in [
    ReplicationAction.update,
    ReplicationAction.enable,
    ReplicationAction.disable,
    ReplicationAction.delete,
  ]) {
    test(
      '$action is exact reviewed configuration mutation with no run',
      () async {
        final h = await _connect();
        if (action == ReplicationAction.enable) {
          h.wire.tasks.single['enabled'] = false;
        }
        final review = await _review(
          h,
          action: action,
          settings: action == ReplicationAction.update
              ? _settings.copyWith(name: 'Renamed archive', retention: 'SOURCE')
              : null,
        );
        final result = await h.repo.executeReplication(review, review.target);
        expect(result.outcome, ReplicationOutcome.succeeded);
        expect(h.wire.writes, hasLength(1));
        final params = h.wire.writes.single['params'] as List;
        expect(params.first, 1);
        if (action == ReplicationAction.enable ||
            action == ReplicationAction.disable) {
          expect(params[1], {'enabled': action == ReplicationAction.enable});
        }
        expect(
          h.wire.writes.single['method'],
          action == ReplicationAction.delete
              ? 'replication.delete'
              : 'replication.update',
        );
      },
    );
  }
  test('forged inventory and review cannot cause reads or writes', () async {
    final h = await _connect();
    final inventory = await h.repo.loadReplication();
    final before = h.wire.requests.length;
    final fake = ReplicationInventory(
      endpoint: inventory.endpoint,
      tasks: inventory.tasks,
      datasets: inventory.datasets,
    );
    await expectLater(
      h.repo.reviewReplication(
        ReplicationRequest(
          inventory: fake,
          action: ReplicationAction.run,
          task: inventory.tasks.single,
        ),
      ),
      throwsA(_reason(ReplicationExceptionReason.staleReview)),
    );
    final forged = ReplicationReview(
      request: ReplicationRequest(
        inventory: inventory,
        task: inventory.tasks.single,
        action: ReplicationAction.run,
      ),
      endpoint: inventory.endpoint,
      warnings: [],
      sourceSnapshots: 1,
      destinationSnapshots: 1,
      createsDestination: false,
    );
    await expectLater(
      h.repo.executeReplication(forged, forged.target),
      throwsA(_reason(ReplicationExceptionReason.staleReview)),
    );
    expect(h.wire.requests.length, before);
  });
  test('wrong confirmation consumes the review', () async {
    final h = await _connect();
    final review = await _review(h);
    await expectLater(
      h.repo.executeReplication(review, '${review.target} '),
      throwsA(_reason(ReplicationExceptionReason.staleReview)),
    );
    await expectLater(
      h.repo.executeReplication(review, review.target),
      throwsA(_reason(ReplicationExceptionReason.staleReview)),
    );
    expect(h.wire.writes, isEmpty);
  });
  for (final drift in [
    'task',
    'guid',
    'snapshots',
    'readonly',
    'job',
    'child',
  ]) {
    test('$drift drift prevents dispatch', () async {
      final h = await _connect();
      final review = await _review(h);
      switch (drift) {
        case 'task':
          h.wire.tasks.single['name'] = 'Changed externally';
        case 'guid':
          h.wire.datasets.last['guid'] = {'rawvalue': '99'};
        case 'snapshots':
          h.wire.snapshots.add(_snapshot('tank/media@new', '22'));
        case 'readonly':
          h.wire.datasets.last['readonly'] = {'rawvalue': 'off'};
        case 'job':
          h.wire.jobs = [
            {'id': 77, 'method': 'replication.run', 'state': 'RUNNING'},
          ];
        case 'child':
          h.wire.datasets.add(
            _dataset('backup/parent/archive/child', '4', readonly: true),
          );
      }
      final result = await h.repo.executeReplication(review, review.target);
      expect(result.outcome, ReplicationOutcome.rejected);
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final receipt in <Object?>[
    null,
    true,
    0,
    -1,
    '42',
    42.0,
    9007199254740992,
  ]) {
    test('malformed job receipt $receipt preserves unknown fence', () async {
      final h = await _connect();
      h.wire.receipt = receipt;
      final review = await _review(h);
      final result = await h.repo.executeReplication(review, review.target);
      expect(result.outcome, ReplicationOutcome.unknown);
      await _fenced(h);
      expect(h.wire.writes, hasLength(1));
    });
  }
  for (final errno in <Object?>[5, '13', 13.0, null]) {
    test('non-exact permission error $errno is ambiguous and fenced', () async {
      final h = await _connect();
      h.wire.rejectMethod = 'replication.run';
      h.wire.errno = errno;
      final review = await _review(h);
      final result = await h.repo.executeReplication(review, review.target);
      expect(result.outcome, ReplicationOutcome.unknown);
      expect(result.message, isNot(contains(_secret)));
      await _fenced(h);
    });
  }
  for (final errno in [1, 13]) {
    test('exact permission denial $errno is safe and does not latch', () async {
      final h = await _connect();
      h.wire.rejectMethod = 'replication.run';
      h.wire.errno = errno;
      final review = await _review(h);
      final result = await h.repo.executeReplication(review, review.target);
      expect(result.outcome, ReplicationOutcome.rejected);
      expect(result.message, isNot(contains(_secret)));
      h.wire.rejectMethod = null;
      expect(await _review(h), isA<ReplicationReview>());
    });
  }
  test('timeout and late job receipt never retry or release fence', () async {
    final h = await _connect(timeout: const Duration(milliseconds: 30));
    h.wire.suppress = 'replication.run';
    final review = await _review(h);
    final result = await h.repo.executeReplication(review, review.target);
    expect(result.outcome, ReplicationOutcome.unknown);
    h.wire.respond(h.wire.writes.single, 42);
    await Future<void>.delayed(Duration.zero);
    await _fenced(h);
    expect(h.wire.writes, hasLength(1));
  });
  test('unknown readback after accepted create is fenced', () async {
    final h = await _connect();
    h.wire.tasks.clear();
    h.wire.badReadback = true;
    final review = await _review(
      h,
      action: ReplicationAction.create,
      settings: _settings,
    );
    expect(
      (await h.repo.executeReplication(review, review.target)).outcome,
      ReplicationOutcome.unknown,
    );
    await _fenced(h);
  });
  test('owned job has exact default-expanded args, bounded manual polling and null success', () async {
    final h = await _connect();
    final review = await _review(h);
    final result = await h.repo.executeReplication(review, review.target);
    final job = result.job!;
    expect(result.outcome, ReplicationOutcome.pending);
    expect(h.wire.writes.single['params'], [1]);
    await _fenced(h);
    final before = h.wire.requests.length;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(h.wire.requests.length, before);
    expect(
      (await h.repo.pollReplication(job)).outcome,
      ReplicationOutcome.pending,
    );
    h.wire.jobState = 'SUCCESS';
    expect(
      (await h.repo.pollReplication(job)).outcome,
      ReplicationOutcome.succeeded,
    );
    await expectLater(
      h.repo.pollReplication(job),
      throwsA(_reason(ReplicationExceptionReason.staleReview)),
    );
    expect(await _review(h), isA<ReplicationReview>());
    expect(h.wire.writes, hasLength(1));
  });
  for (final override in <Map<String, Object?>>[
    {'id': 41},
    {'id': 42.0},
    {'method': 'other.run'},
    {
      'arguments': [2, true],
    },
    {
      'arguments': [1, false],
    },
    {
      'arguments': [1.0, true],
    },
    {
      'arguments': [1],
    },
    {'state': 'SUCCESS', 'result': true},
    {'state': 'MYSTERY'},
  ]) {
    test(
      'unverifiable owned job $override stays locked and recoverable',
      () async {
        final h = await _connect();
        final review = await _review(h);
        final job = (await h.repo.executeReplication(
          review,
          review.target,
        )).job!;
        h.wire.jobOverride = override;
        final result = await h.repo.pollReplication(job);
        expect(result.outcome, ReplicationOutcome.unknown);
        expect(identical(result.job, job), isTrue);
        await _fenced(h);
        h.wire.jobOverride = {};
        h.wire.jobState = 'SUCCESS';
        expect(
          (await h.repo.pollReplication(job)).outcome,
          ReplicationOutcome.succeeded,
        );
      },
    );
  }
  for (final state in ['FAILED', 'ABORTED']) {
    test(
      'exact terminal $state releases owned lock but warns partial effects',
      () async {
        final h = await _connect();
        final review = await _review(h);
        final job = (await h.repo.executeReplication(
          review,
          review.target,
        )).job!;
        h.wire.jobState = state;
        final result = await h.repo.pollReplication(job);
        expect(result.outcome, ReplicationOutcome.failed);
        expect(result.message, contains('Partial'));
        expect(await _review(h), isA<ReplicationReview>());
      },
    );
  }
  test('forged job cannot query another task', () async {
    final h = await _connect();
    final before = h.wire.requests.length;
    await expectLater(
      h.repo.pollReplication(
        const ReplicationJob(
          id: 42,
          taskId: 1,
          taskName: 'Local archive',
          endpoint: 'https://synthetic.example',
        ),
      ),
      throwsA(_reason(ReplicationExceptionReason.staleReview)),
    );
    expect(h.wire.requests.length, before);
  });
  test('disconnect invalidates issued review without mutation', () async {
    final h = await _connect();
    final review = await _review(h);
    await h.repo.close();
    await expectLater(
      h.repo.executeReplication(review, review.target),
      throwsA(_reason(ReplicationExceptionReason.notAuthenticated)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test('replication fence blocks legacy dataset mutation', () async {
    final h = await _connect();
    final review = await _review(h);
    await h.repo.executeReplication(review, review.target);
    final count = h.wire.writes.length;
    await expectLater(
      h.repo.execute(const CreateDatasetCommand(parent: 'tank', name: 'other')),
      throwsA(
        isA<ManagementException>().having(
          (e) => e.reason,
          'reason',
          ManagementExceptionReason.busy,
        ),
      ),
    );
    expect(h.wire.writes.length, count);
  });
  for (final method in _writes) {
    test('generic schema path cannot bypass native $method review', () async {
      final h = await _connect();
      final spec = h.repo.adminCatalog.method(method)!;
      expect(spec.supported, isFalse);
      expect(
        spec.unsupportedReason,
        adminOperationDefinitions
            .singleWhere((p) => p.method == method)
            .blockedReason,
      );
      expect(spec.unsupportedReason, isNotNull);
      final boundary = h.wire.requests.length;
      await expectLater(
        h.repo.invokeAdmin(AdminRequest(method: spec, arguments: const [])),
        throwsA(
          isA<AdminException>().having(
            (e) => e.reason,
            'reason',
            AdminExceptionReason.unavailableMethod,
          ),
        ),
      );
      expect(h.wire.requests.length, boundary);
    });
  }
  for (final state in ['SUCCESS', 'FAILED', 'ABORTED']) {
    test('historical $state job does not disable an idle task', () async {
      final h = await _connect();
      h.wire.tasks.single.addAll({'last_job_id': 19, 'last_job_state': state});
      expect((await h.repo.loadReplication()).tasks.single.available, isTrue);
      expect(await _review(h), isA<ReplicationReview>());
    });
  }
  for (final state in ['RUNNING', 'WAITING', 'UNKNOWN', null]) {
    test(
      'nonterminal or unproved historical job $state blocks its task',
      () async {
        final h = await _connect();
        h.wire.tasks.single.addAll({
          'last_job_id': 19,
          'last_job_state': state,
        });
        expect(
          (await h.repo.loadReplication()).tasks.single.available,
          isFalse,
        );
        await expectLater(
          _review(h),
          throwsA(_reason(ReplicationExceptionReason.invalidRequest)),
        );
        expect(h.wire.writes, isEmpty);
      },
    );
  }
  for (final patch in <Map<String, Object?>>[
    {
      'guid': {'rawvalue': '0'},
    },
    {
      'guid': {'rawvalue': '18446744073709551616'},
    },
    {'locked': null},
    {'encrypted': null},
    {
      'readonly': {'rawvalue': 'maybe'},
    },
  ]) {
    test('malformed dataset safety $patch fails closed', () async {
      final h = await _connect();
      h.wire.datasets.last.addAll(patch);
      await expectLater(
        h.repo.loadReplication(),
        throwsA(_reason(ReplicationExceptionReason.invalidResponse)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('protected pool root also protects apparently unmarked child', () async {
    final h = await _connect();
    h.wire.datasets.add(
      _dataset('backup', '4')..['managedby'] = {'rawvalue': 'external'},
    );
    await expectLater(
      _review(h),
      throwsA(_reason(ReplicationExceptionReason.invalidRequest)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test('inventory refresh invalidates an earlier issued review', () async {
    final h = await _connect();
    final review = await _review(h);
    await h.repo.loadReplication();
    await expectLater(
      h.repo.executeReplication(review, review.target),
      throwsA(_reason(ReplicationExceptionReason.staleReview)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test('snapshot overflow is never accepted as a complete review', () async {
    final h = await _connect();
    h.wire.snapshots.addAll(
      List.generate(255, (i) => _snapshot('tank/media@s$i', '${100 + i}')),
    );
    await expectLater(
      _review(h),
      throwsA(_reason(ReplicationExceptionReason.invalidResponse)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test(
    'read failure is sanitized, harmless and never automatically retried',
    () async {
      final h = await _connect();
      h.wire.rejectMethod = 'replication.query';
      await expectLater(
        h.repo.loadReplication(),
        throwsA(_reason(ReplicationExceptionReason.unavailable)),
      );
      expect(
        h.wire.requests.where((r) => r['method'] == 'replication.query'),
        hasLength(1),
      );
      h.wire.rejectMethod = null;
      expect(await _review(h), isA<ReplicationReview>());
      expect(h.wire.writes, isEmpty);
    },
  );
  test('unrelated held remote task is not an active global transfer', () async {
    final h = await _connect();
    h.wire.tasks.add(
      _task()..addAll({
        'id': 2,
        'name': 'Held remote task',
        'transport': 'SSH',
        'credential_id': 20,
        'task_state': 'HOLD',
      }),
    );
    final inventory = await h.repo.loadReplication();
    expect(inventory.conflictingJob, isFalse);
    expect(inventory.tasks.last.available, isFalse);
    expect(
      await h.repo.reviewReplication(
        ReplicationRequest(
          inventory: inventory,
          action: ReplicationAction.run,
          task: inventory.tasks.first,
        ),
      ),
      isA<ReplicationReview>(),
    );
    expect(h.wire.writes, isEmpty);
  });
}

Future<void> _fenced(_Harness h) async {
  final inventory = await h.repo.loadReplication();
  await expectLater(
    h.repo.reviewReplication(
      ReplicationRequest(
        inventory: inventory,
        action: ReplicationAction.run,
        task: inventory.tasks.firstOrNull,
      ),
    ),
    throwsA(_reason(ReplicationExceptionReason.busy)),
  );
}

Future<ReplicationReview> _review(
  _Harness h, {
  ReplicationAction action = ReplicationAction.run,
  ReplicationSettings? settings,
}) async {
  final inventory = await h.repo.loadReplication();
  return h.repo.reviewReplication(
    ReplicationRequest(
      inventory: inventory,
      action: action,
      task: action == ReplicationAction.create ? null : inventory.tasks.single,
      settings: settings,
    ),
  );
}

final class _Harness {
  const _Harness(this.repo, this.wire);
  final TrueNasSessionRepository repo;
  final _Wire wire;
}

Future<_Harness> _connect({
  String version = '25.10.1',
  Set<String> methods = _methods,
  Map<String, Map<String, Object?>> overrides = const {},
  Duration timeout = const Duration(seconds: 2),
}) async {
  final wire = _Wire(version: version, methods: methods, overrides: overrides);
  final repo = TrueNasSessionRepository(
    connector: _Connector(wire),
    managementRequestTimeout: timeout,
  );
  addTearDown(repo.close);
  await repo.connect(
    serverInput: 'https://synthetic.example',
    username: 'fixture-user',
    apiKey: 'fixture-key',
  );
  return _Harness(repo, wire);
}

final class _Connector implements RpcConnector {
  const _Connector(this.wire);
  final _Wire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

Map<String, Object?> _dataset(
  String id,
  String guid, {
  bool readonly = false,
}) => {
  'id': id,
  'type': 'FILESYSTEM',
  'guid': {'rawvalue': guid},
  'locked': false,
  'encrypted': false,
  'readonly': {'rawvalue': readonly ? 'on' : 'off'},
  'managedby': {'rawvalue': '-'},
};
Map<String, Object?> _snapshot(String id, String guid) => {
  'id': id,
  'dataset': id.split('@').first,
  'properties': {
    'guid': {'rawvalue': guid},
    'createtxg': {'rawvalue': '123'},
  },
};
Map<String, Object?> _task() => {
  'id': 1,
  'name': 'Local archive',
  'direction': 'PUSH',
  'transport': 'LOCAL',
  'credential_id': null,
  'source_datasets': ['tank/media'],
  'target_dataset': 'backup/parent/archive',
  'recursive': false,
  'exclude': <String>[],
  'properties': false,
  'properties_exclude': <String>[],
  'properties_override': <String, String>{},
  'replicate': false,
  'encryption': false,
  'periodic_snapshot_tasks': <Object?>[],
  'naming_schema': <String>[],
  'also_include_naming_schema': ['auto-%Y-%m-%d_%H-%M'],
  'name_regex': null,
  'auto': false,
  'schedule': null,
  'restrict_schedule': null,
  'only_matching_schedule': false,
  'allow_from_scratch': false,
  'readonly': 'SET',
  'hold_pending_snapshots': false,
  'retention_policy': 'NONE',
  'lifetime_value': null,
  'lifetime_unit': null,
  'lifetimes': <Object?>[],
  'compression': null,
  'speed_limit': null,
  'large_block': true,
  'embed': false,
  'compressed': true,
  'retries': 1,
  'logging_level': null,
  'enabled': true,
  'sudo': false,
  'netcat_active_side': null,
  'netcat_active_side_listen_address': null,
  'netcat_active_side_port_min': null,
  'netcat_active_side_port_max': null,
  'netcat_passive_side_connect_address': null,
  'encryption_inherit': null,
  'encryption_key_format': null,
  'task_state': 'FINISHED',
  'last_job_id': null,
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
  final tasks = <Map<String, Object?>>[_task()];
  final datasets = <Map<String, Object?>>[
    _dataset('tank/media', '1'),
    _dataset('backup/parent', '2'),
    _dataset('backup/parent/archive', '3', readonly: true),
  ];
  final snapshots = <Map<String, Object?>>[
    _snapshot('tank/media@auto-2026-09-13_12-00', '20'),
    _snapshot('backup/parent/archive@auto-2026-09-13_12-00', '20'),
  ];
  List<Object?> jobs = [];
  Object? receipt = 42, errno = 13;
  String? rejectMethod, suppress;
  bool badReadback = false;
  String jobState = 'RUNNING';
  Map<String, Object?> jobOverride = {};
  final _incoming = StreamController<String>();
  List<Map<String, dynamic>> get writes => requests
      .where(
        (r) =>
            _writes.contains(r['method']) ||
            r['method'] == 'pool.dataset.create',
      )
      .toList();
  @override
  Stream<String> get inboundFrames => _incoming.stream;
  @override
  Future<void> send(String frame) async {
    final r = jsonDecode(frame) as Map<String, dynamic>;
    requests.add(r);
    final method = r['method'] as String;
    if (suppress == method) return;
    if (rejectMethod == method) {
      _incoming.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': r['id'],
          'error': {
            'code': -1,
            'message': _secret,
            'data': {'errno': errno, 'details': _secret},
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
        result = {'username': 'fixture-user'};
      case 'system.info':
        result = {'version': version};
      case 'core.get_methods':
        result = {
          for (final name in methods)
            name: {
              'job': name == 'replication.run',
              'no_auth_required': false,
              'uploadable': false,
              'downloadable': false,
              'filterable': false,
              'accepts': <Object?>[],
              'returns': [
                {'type': 'null'},
              ],
              'roles': ['FULL_ADMIN'],
              'check_pipes': <Object?>[],
              ...?overrides[name],
            },
        };
      case 'replication.query':
        result = tasks;
      case 'pool.dataset.query':
        result = datasets;
      case 'pool.filesystem_choices':
        result = datasets.map((d) => d['id']).toList();
      case 'pool.snapshot.query':
        result = snapshots;
      case 'core.get_jobs':
        final filters = (r['params'] as List).first as List;
        result = (filters.first as List).first == 'state'
            ? jobs
            : [
                {
                  'id': 42,
                  'method': 'replication.run',
                  'arguments': [1, true],
                  'state': jobState,
                  'progress': {'percent': 35},
                  'result': null,
                  ...jobOverride,
                },
              ];
      case 'replication.create':
        final body = Map<String, Object?>.from(
          (r['params'] as List).single as Map,
        );
        final task = _task()
          ..addAll(body)
          ..['id'] = 2;
        result = Map<String, Object?>.of(task);
        tasks.add(task);
        if (badReadback) task['name'] = 'Changed after dispatch';
      case 'replication.update':
        tasks.single.addAll(
          Map<String, Object?>.from((r['params'] as List)[1] as Map),
        );
        result = tasks.single;
      case 'replication.delete':
        tasks.clear();
        result = true;
      case 'replication.run':
        result = receipt;
      case 'pool.dataset.create':
        result = {'id': 'tank/other', 'name': 'tank/other'};
      default:
        throw StateError('Unexpected synthetic method $method');
    }
    respond(r, result);
  }

  void respond(Map<String, dynamic> r, Object? result) {
    if (!_incoming.isClosed) {
      _incoming.add(
        jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': result}),
      );
    }
  }

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}
