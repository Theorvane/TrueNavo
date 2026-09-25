import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _allMethods = {
  'service.start',
  'service.stop',
  'service.restart',
  'service.control',
  'pool.dataset.create',
  'pool.dataset.delete',
  'pool.dataset.attachments',
  'zfs.snapshot.create',
  'pool.snapshot.create',
  'core.get_jobs',
  'pool.query',
  'system.info',
};
const _start = ServiceControlCommand(
  service: 'cifs',
  action: ServiceControlAction.start,
);
const _create = CreateDatasetCommand(parent: 'tank', name: 'documents');
const _delete = DeleteDatasetCommand(dataset: 'tank/documents');
const _snapshot = CreateSnapshotCommand(
  dataset: 'tank/documents',
  name: 'manual-2026',
);

Matcher _reason(ManagementExceptionReason reason) => isA<ManagementException>()
    .having((error) => error.reason, 'reason', reason);

void main() {
  test(
    'management and inventory are unavailable before authentication finishes',
    () async {
      final harness = _Harness(automaticHandshake: false);
      addTearDown(harness.repository.close);
      expect(harness.repository.managementCapabilities.connected, isFalse);
      await expectLater(
        harness.repository.execute(_start),
        throwsA(_reason(ManagementExceptionReason.notAuthenticated)),
      );
      final connection = harness.connect();
      final login = await harness.transport.nextRequest();
      expect(login['method'], 'auth.login_ex');
      await expectLater(
        harness.repository.execute(_start),
        throwsA(_reason(ManagementExceptionReason.notAuthenticated)),
      );
      await expectLater(
        harness.repository.query('pool.query'),
        throwsA(isA<SessionQueryException>()),
      );
      harness.transport.respond(login, {'response_type': 'AUTH_ERR'});
      await expectLater(
        connection,
        throwsA(isA<AuthenticationStateException>()),
      );
      expect(harness.repository.managementCapabilities.connected, isFalse);
      expect(harness.transport.requests, hasLength(1));
    },
  );

  for (final version in [
    '25.04',
    'TrueNAS-SCALE-25.04.2.2',
    '25.10.1',
    'TrueNAS-25.10.2-U1',
    '26.0',
    '26.0.1',
  ]) {
    test('recognizes only supported release families: $version', () async {
      final h = await _connected(version: version);
      expect(h.repository.managementCapabilities.versionSupported, isTrue);
      expect(
        h.repository.managementCapabilities.availableActions,
        containsAll(ManagementAction.values),
      );
    });
  }
  for (final version in [
    'unknown',
    '24.10.2',
    '26.04',
    '27.0',
    '25.10-beta',
    '25.10-MASTER',
    '25.10\n',
    'prefix25.10',
    '25.100',
  ]) {
    test('fails closed for unsupported version $version', () async {
      final h = await _connected(version: version);
      expect(
        h.repository.managementCapabilities.supports(
          ManagementAction.datasetCreate,
        ),
        isFalse,
      );
      await expectLater(
        h.repository.execute(_create),
        throwsA(_reason(ManagementExceptionReason.unsupportedVersion)),
      );
      expect(h.transport.managementRequests, isEmpty);
    });
  }

  test('advertised methods are required independently, including safe preflight and job reads', () async {
    for (final missing in [
      'pool.dataset.create',
      'pool.dataset.attachments',
      'core.get_jobs',
    ]) {
      final h = await _connected(methods: _allMethods.difference({missing}));
      final command = switch (missing) {
        'pool.dataset.create' => _create,
        'pool.dataset.attachments' => _delete,
        _ => _start,
      };
      expect(
        h.repository.managementCapabilities.supports(command.managementAction),
        isFalse,
      );
      await expectLater(
        h.repository.execute(command),
        throwsA(_reason(ManagementExceptionReason.unavailableMethod)),
      );
      expect(h.transport.managementRequests, isEmpty);
    }
  });

  test(
    'legacy version cannot fall forward to newer service or snapshot endpoints',
    () async {
      final h = await _connected(
        version: '25.04.2',
        methods: {'service.control', 'core.get_jobs', 'pool.snapshot.create'},
      );
      for (final command in [_start, _snapshot]) {
        await expectLater(
          h.repository.execute(command),
          throwsA(_reason(ManagementExceptionReason.unavailableMethod)),
        );
      }
      expect(h.transport.managementRequests, isEmpty);
    },
  );

  for (final action in ServiceControlAction.values) {
    for (final success in [true, false]) {
      test(
        '25.04 ${action.name} uses legacy endpoint and $success result correctly',
        () async {
          final h = await _connected(
            version: '25.04.2',
            methods: {'service.${action.name}'},
          );
          final command = ServiceControlCommand(
            service: 'cifs',
            action: action,
          );
          final execution = h.repository.execute(command);
          final request = await h.transport.nextRequest();
          expect(request['method'], 'service.${action.name}');
          expect(request['params'], [
            'cifs',
            {'silent': false},
          ]);
          h.transport.respond(request, success);
          final result = await execution;
          expect(
            result.status,
            success ? ManagementStatus.completed : ManagementStatus.failed,
          );
          expect(h.transport.managementRequests, hasLength(1));
        },
      );
    }
    for (final version in ['25.10.1', '26.0']) {
      test(
        '$version ${action.name} submits one job and verifies the ID-filtered result',
        () async {
          final h = await _connected(version: version);
          final command = ServiceControlCommand(
            service: 'cifs',
            action: action,
          );
          final execution = h.repository.execute(command);
          final request = await h.transport.nextRequest();
          expect(request['method'], 'service.control');
          expect(request['params'], [
            action.name.toUpperCase(),
            'cifs',
            {'silent': false, 'timeout': 30},
          ]);
          h.transport.respond(request, 42);
          final job = await execution as ManagementJobSubmitted;
          expect(job.status, ManagementStatus.submitted);
          final polling = h.repository.pollJob(job);
          final poll = await h.transport.nextRequest();
          _expectJobRead(poll, 42);
          h.transport.respond(poll, [_jobRow(42, 'SUCCESS', true)]);
          expect(await polling, isA<ManagementCompleted>());
          expect(await h.repository.pollJob(job), isA<ManagementCompleted>());
          expect(
            h.transport.managementRequests,
            hasLength(2),
            reason: 'Terminal jobs are cached; mutations are never repeated.',
          );
        },
      );
    }
  }

  test(
    'running and waiting jobs remain submitted; false success is failure',
    () async {
      final h = await _connected();
      final job = await _submitJob(h);
      for (final state in ['WAITING', 'RUNNING', 'SUCCESS']) {
        final future = h.repository.pollJob(job);
        final request = await h.transport.nextRequest();
        _expectJobRead(request, job.jobId);
        h.transport.respond(request, [_jobRow(job.jobId, state, false)]);
        expect(
          (await future).status,
          state == 'SUCCESS'
              ? ManagementStatus.failed
              : ManagementStatus.submitted,
        );
      }
      expect(
        h.transport.managementRequests.where(
          (r) => r['method'] == 'service.control',
        ),
        hasLength(1),
      );
    },
  );

  for (final state in ['FAILED', 'ABORTED']) {
    test('$state job has a sanitized terminal failure', () async {
      final h = await _connected();
      final job = await _submitJob(h);
      final future = h.repository.pollJob(job);
      final request = await h.transport.nextRequest();
      h.transport.respond(request, [
        {
          ..._jobRow(job.jobId, state, null),
          'error': 'secret-api-key private details',
        },
      ]);
      final result = await future as ManagementFailed;
      expect(
        result.reason,
        state == 'ABORTED'
            ? ManagementFailureReason.aborted
            : ManagementFailureReason.operationFailed,
      );
      expect(result.userMessage, isNot(contains('secret')));
      expect(await h.repository.pollJob(job), same(result));
    });
  }

  test(
    'malformed, absent, wrong-ID, and wrong-method jobs never imply completion',
    () async {
      final h = await _connected();
      final job = await _submitJob(h);
      for (final response in <Object?>[
        null,
        {},
        [],
        [true],
        [_jobRow(999, 'SUCCESS', true)],
        [
          {..._jobRow(job.jobId, 'SUCCESS', true), 'method': 'pool.scrub'},
        ],
        [
          _jobRow(job.jobId, 'SUCCESS', true),
          _jobRow(job.jobId, 'SUCCESS', true),
        ],
        [_jobRow(job.jobId, 'UNKNOWN', true)],
        [_jobRow(job.jobId, 'SUCCESS', 'true')],
      ]) {
        final future = h.repository.pollJob(job);
        final request = await h.transport.nextRequest();
        h.transport.respond(request, response);
        expect(await future, isA<ManagementOutcomeUnknown>());
      }
    },
  );

  test('forged, copied and cross-session jobs cannot be polled', () async {
    final h = await _connected();
    final other = await _connected();
    final job = await _submitJob(h);
    final forged = ManagementJobSubmitted(job.command, jobId: job.jobId);
    expect(await h.repository.pollJob(forged), isA<ManagementOutcomeUnknown>());
    expect(
      await other.repository.pollJob(job),
      isA<ManagementOutcomeUnknown>(),
    );
    await h.repository.close();
    expect(await h.repository.pollJob(job), isA<ManagementOutcomeUnknown>());
    expect(h.transport.managementRequests, hasLength(1));
    expect(other.transport.managementRequests, isEmpty);
  });

  test('dataset creation has explicit filesystem, ancestor and encryption safety options', () async {
    final h = await _connected();
    final future = h.repository.execute(_create);
    final request = await h.transport.nextRequest();
    expect(request['method'], 'pool.dataset.create');
    expect(request['params'], [
      {
        'name': 'tank/documents',
        'type': 'FILESYSTEM',
        'create_ancestors': false,
        'inherit_encryption': true,
      },
    ]);
    h.transport.respond(request, {'id': 'tank/documents'});
    expect(await future, isA<ManagementCompleted>());
  });

  for (final version in ['25.04.2', '25.10.1', '26.0']) {
    test(
      '$version snapshot creation is single-dataset and nonrecursive',
      () async {
        final h = await _connected(version: version);
        final future = h.repository.execute(_snapshot);
        final request = await h.transport.nextRequest();
        expect(
          request['method'],
          version.startsWith('25.04')
              ? 'zfs.snapshot.create'
              : 'pool.snapshot.create',
        );
        expect(request['params'], [
          {
            'dataset': 'tank/documents',
            'name': 'manual-2026',
            'recursive': false,
          },
        ]);
        h.transport.respond(request, {'id': _snapshot.target});
        expect(await future, isA<ManagementCompleted>());
      },
    );
  }

  test('creation responses must confirm the exact requested target', () async {
    for (final command in [_create, _snapshot]) {
      for (final value in <Object?>[
        true,
        7,
        null,
        {},
        {'id': 'other'},
        {'name': command.target},
      ]) {
        final h = await _connected();
        final future = h.repository.execute(command);
        final request = await h.transport.nextRequest();
        h.transport.respond(request, value);
        expect(await future, isA<ManagementOutcomeUnknown>());
      }
    }
  });

  test('deletion checks dependencies first then uses nonrecursive, nonforce options', () async {
    final h = await _connected();
    final future = h.repository.execute(_delete);
    final preflight = await h.transport.nextRequest();
    expect(preflight['method'], 'pool.dataset.attachments');
    expect(preflight['params'], ['tank/documents']);
    expect(h.transport.managementRequests, hasLength(1));
    h.transport.respond(preflight, []);
    final deletion = await h.transport.nextRequest();
    expect(deletion['method'], 'pool.dataset.delete');
    expect(deletion['params'], [
      'tank/documents',
      {'recursive': false, 'force': false},
    ]);
    h.transport.respond(deletion, true);
    expect(await future, isA<ManagementCompleted>());
  });

  for (final attachments in <Object?>[
    null,
    {},
    false,
    [
      {
        'type': 'SMB',
        'attachments': ['documents'],
      },
    ],
  ]) {
    test(
      'unverified or attached resources block deletion: $attachments',
      () async {
        final h = await _connected();
        final future = h.repository.execute(_delete);
        final expected = expectLater(
          future,
          throwsA(
            _reason(
              attachments is List
                  ? ManagementExceptionReason.attachedResources
                  : ManagementExceptionReason.preflightFailed,
            ),
          ),
        );
        final preflight = await h.transport.nextRequest();
        h.transport.respond(preflight, attachments);
        await expected;
        expect(h.transport.managementRequests, hasLength(1));
      },
    );
  }

  test(
    'preflight errors and deadline expiry never dispatch deletion',
    () async {
      for (final timesOut in [false, true]) {
        final h = await _connected(timeout: const Duration(milliseconds: 15));
        final future = h.repository.execute(_delete);
        final expected = expectLater(
          future,
          throwsA(_reason(ManagementExceptionReason.preflightFailed)),
        );
        final request = await h.transport.nextRequest();
        if (!timesOut) h.transport.reject(request, errno: 13);
        await expected;
        if (timesOut) h.transport.respond(request, []);
        await Future<void>.delayed(Duration.zero);
        expect(h.transport.managementRequests, hasLength(1));
      }
    },
  );

  test(
    'disconnect during preflight cannot delete on an old or new session',
    () async {
      final h = await _connected();
      final execution = h.repository.execute(_delete);
      final expected = expectLater(
        execution,
        throwsA(isA<ManagementException>()),
      );
      await h.transport.nextRequest();
      await h.repository.close();
      await expected;
      expect(h.transport.managementRequests, hasLength(1));
    },
  );

  test(
    'dangerous or malformed names are refused before any read or mutation',
    () async {
      final h = await _connected();
      final commands = <ManagementCommand>[
        for (final name in [
          '',
          'tank',
          'tank/',
          '/tank/data',
          'tank//data',
          'tank/../data',
          'tank/.system',
          'tank/.system/log',
          'boot-pool/data',
          'freenas-boot/data',
          'tank/ix-apps/data',
          'tank/ix-applications',
          'tank/data\n',
          'tank/data@snap',
          'tank/data;shutdown',
          'tank/${'a' * 129}',
        ])
          DeleteDatasetCommand(dataset: name),
        for (final name in [
          '',
          '../data',
          '.system',
          'with spaces',
          'a/b',
          'x\n',
          'ix-apps',
        ])
          CreateDatasetCommand(parent: 'tank', name: name),
        const CreateDatasetCommand(parent: 'tank/.system', name: 'data'),
        const CreateSnapshotCommand(dataset: 'boot-pool', name: 'copy'),
        const CreateSnapshotCommand(dataset: 'tank/data', name: 'a@b'),
        const CreateSnapshotCommand(dataset: 'tank/data', name: 'bad\n'),
        for (final service in [
          '',
          'cifs\n',
          '../ssh',
          'ssh start',
          'x;reboot',
          'CIFS',
        ])
          ServiceControlCommand(
            service: service,
            action: ServiceControlAction.stop,
          ),
      ];
      for (final command in commands) {
        await expectLater(
          h.repository.execute(command),
          throwsA(_reason(ManagementExceptionReason.invalidInput)),
          reason: command.target,
        );
      }
      expect(h.transport.managementRequests, isEmpty);
    },
  );

  test('concurrent submission cannot issue a second mutation', () async {
    final h = await _connected();
    final first = h.repository.execute(_create);
    final request = await h.transport.nextRequest();
    await expectLater(
      h.repository.execute(_snapshot),
      throwsA(_reason(ManagementExceptionReason.busy)),
    );
    h.transport.respond(request, {'id': _create.target});
    expect(await first, isA<ManagementCompleted>());
    expect(h.transport.managementRequests, hasLength(1));
  });

  test('mutation timeout is unknown and a late response cannot reclassify or retry it', () async {
    final h = await _connected(timeout: const Duration(milliseconds: 15));
    final future = h.repository.execute(_create);
    final request = await h.transport.nextRequest();
    final result = await future;
    expect(result, isA<ManagementOutcomeUnknown>());
    h.transport.respond(request, {'id': _create.target});
    await Future<void>.delayed(Duration.zero);
    expect(result.status, ManagementStatus.unknown);
    expect(h.transport.managementRequests, hasLength(1));
  });

  test(
    'job read timeout is unknown and only reads may be explicitly polled again',
    () async {
      final h = await _connected(timeout: const Duration(milliseconds: 15));
      final job = await _submitJob(h);
      final polling = h.repository.pollJob(job);
      final firstRead = await h.transport.nextRequest();
      expect(await polling, isA<ManagementOutcomeUnknown>());
      h.transport.respond(firstRead, [_jobRow(job.jobId, 'SUCCESS', true)]);
      final nextPoll = h.repository.pollJob(job);
      final nextRead = await h.transport.nextRequest();
      h.transport.respond(nextRead, [_jobRow(job.jobId, 'SUCCESS', true)]);
      expect(await nextPoll, isA<ManagementCompleted>());
      expect(
        h.transport.managementRequests.where(
          (r) => r['method'] == 'service.control',
        ),
        hasLength(1),
      );
    },
  );

  test(
    'lost transport disables capabilities and unconfirmed mutation is unknown',
    () async {
      final h = await _connected();
      final execution = h.repository.execute(_create);
      await h.transport.nextRequest();
      await h.transport.close();
      expect(await execution, isA<ManagementOutcomeUnknown>());
      expect(h.repository.managementCapabilities.connected, isFalse);
      await expectLater(
        h.repository.execute(_snapshot),
        throwsA(_reason(ManagementExceptionReason.staleSession)),
      );
      await expectLater(
        h.repository.query('pool.query'),
        throwsA(isA<SessionQueryException>()),
      );
      expect(h.transport.managementRequests, hasLength(1));
    },
  );

  test(
    'remote errors are sanitized and permission failures are distinct',
    () async {
      final h = await _connected();
      for (final errno in [1, 13, 22]) {
        final execution = h.repository.execute(_create);
        final request = await h.transport.nextRequest();
        h.transport.reject(request, errno: errno);
        final result = await execution;
        if (errno == 22) {
          expect(result, isA<ManagementOutcomeUnknown>());
        } else {
          expect(
            (result as ManagementFailed).reason,
            ManagementFailureReason.permissionDenied,
          );
        }
        expect(result.userMessage, isNot(contains('secret')));
        expect(result.userMessage, isNot(contains('internal')));
      }
    },
  );

  test('invalid job submissions never imply accepted or completed', () async {
    for (final value in <Object?>[null, true, false, 0, -1, '42', {}, []]) {
      final h = await _connected();
      final future = h.repository.execute(_start);
      final request = await h.transport.nextRequest();
      h.transport.respond(request, value);
      expect(await future, isA<ManagementOutcomeUnknown>());
    }
  });

  test(
    'reconnecting invalidates old jobs even when the new NAS reuses job IDs',
    () async {
      final first = _Transport('25.10.1', _allMethods, true);
      final second = _Transport('26.0', _allMethods, true);
      final repository = TrueNasSessionRepository(
        connector: _RotatingConnector([first, second]),
      );
      addTearDown(repository.close);
      Future<ServerSummary> connect(String host) => repository.connect(
        serverInput: host,
        apiKey: 'test-secret',
        username: 'admin',
      );
      await connect('https://first.example');
      final execution = repository.execute(_start);
      final request = await first.nextRequest();
      first.respond(request, 42);
      final oldJob = await execution as ManagementJobSubmitted;
      await connect('https://second.example');
      expect(await repository.pollJob(oldJob), isA<ManagementOutcomeUnknown>());
      expect(second.managementRequests, isEmpty);
      final newExecution = repository.execute(_start);
      final newRequest = await second.nextRequest();
      second.respond(newRequest, 42);
      final newJob = await newExecution as ManagementJobSubmitted;
      final polling = repository.pollJob(newJob);
      final read = await second.nextRequest();
      second.respond(read, [_jobRow(42, 'SUCCESS', true)]);
      expect(await polling, isA<ManagementCompleted>());
      expect(await repository.pollJob(oldJob), isA<ManagementOutcomeUnknown>());
      expect(first.managementRequests, hasLength(1));
    },
  );

  test('read-only inventory interface still refuses all management and arbitrary reads', () async {
    final h = await _connected();
    for (final method in [
      'service.control',
      'pool.dataset.delete',
      'pool.dataset.attachments',
      'zfs.snapshot.create',
      'auth.me',
    ]) {
      await expectLater(
        h.repository.query(method),
        throwsA(isA<SessionQueryException>()),
      );
    }
    expect(h.transport.managementRequests, isEmpty);
  });

  test('untraceable mutation blocks later Quick and native share work despite late response', () async {
    final h = await _connected(
      timeout: const Duration(milliseconds: 30),
      shareMetadata: true,
      methods: {..._allMethods, ..._shareReads},
    );
    final pending = h.repository.execute(_create);
    final wire = await h.transport.nextRequest();
    expect(await pending, isA<ManagementOutcomeUnknown>());
    await _expectQuickFence(h);
    await expectLater(
      h.repository.loadSmbShares(),
      throwsA(
        isA<SmbSharesException>().having(
          (e) => e.reason,
          'reason',
          SmbSharesExceptionReason.busy,
        ),
      ),
    );
    await expectLater(
      h.repository.loadNfsShares(),
      throwsA(
        isA<NfsSharesException>().having(
          (e) => e.reason,
          'reason',
          NfsSharesExceptionReason.busy,
        ),
      ),
    );
    h.transport.respond(wire, {'id': _create.target});
    await Future<void>.delayed(Duration.zero);
    await _expectQuickFence(h);
    expect(h.transport.managementRequests.length, 1);
  });
  for (final terminal in ['SUCCESS', 'FAILED', 'ABORTED']) {
    test(
      'owned pending service job is pollable and $terminal releases fence',
      () async {
        final h = await _connected();
        final job = await _submitJob(h);
        await _expectQuickFence(h);
        for (final state in ['WAITING', 'RUNNING']) {
          final read = h.repository.pollJob(job);
          h.transport.respond(await h.transport.nextRequest(), [
            _jobRow(42, state, null),
          ]);
          expect(await read, same(job));
          await _expectQuickFence(h);
        }
        final read = h.repository.pollJob(job);
        h.transport.respond(await h.transport.nextRequest(), [
          _jobRow(42, terminal, true),
        ]);
        expect(
          (await read).status,
          terminal == 'SUCCESS'
              ? ManagementStatus.completed
              : ManagementStatus.failed,
        );
        final next = h.repository.execute(_create);
        h.transport.respond(await h.transport.nextRequest(), {
          'id': _create.target,
        });
        expect(await next, isA<ManagementCompleted>());
      },
    );
  }
  test('unknown poll and noninteger identity retain fence until exact terminal read', () async {
    final h = await _connected();
    final job = await _submitJob(h);
    for (final value in <Object?>[
      [],
      [
        {..._jobRow(42, 'SUCCESS', true), 'id': 42.0},
      ],
    ]) {
      final read = h.repository.pollJob(job);
      h.transport.respond(await h.transport.nextRequest(), value);
      expect(await read, isA<ManagementOutcomeUnknown>());
      await _expectQuickFence(h);
    }
    final denied = h.repository.pollJob(job);
    h.transport.reject(await h.transport.nextRequest(), errno: 13);
    expect(await denied, isA<ManagementOutcomeUnknown>());
    await _expectQuickFence(h);
    final read = h.repository.pollJob(job);
    h.transport.respond(await h.transport.nextRequest(), [
      _jobRow(42, 'SUCCESS', true),
    ]);
    expect(await read, isA<ManagementCompleted>());
    final next = h.repository.execute(_create);
    h.transport.respond(await h.transport.nextRequest(), {
      'id': _create.target,
    });
    expect(await next, isA<ManagementCompleted>());
  });
  for (final errno in <Object?>[22, null, 1.0, '13']) {
    test(
      'uncertain mutation RPC errno $errno latches without pretending rejection',
      () async {
        final h = await _connected();
        final pending = h.repository.execute(_create);
        h.transport.reject(await h.transport.nextRequest(), errno: errno);
        expect(await pending, isA<ManagementOutcomeUnknown>());
        await _expectQuickFence(h);
        expect(h.transport.managementRequests.length, 1);
      },
    );
  }
  test(
    'read-only deletion preflight failure does not latch a mutation fence',
    () async {
      final h = await _connected();
      final pending = h.repository.execute(_delete);
      final failed = expectLater(
        pending,
        throwsA(_reason(ManagementExceptionReason.preflightFailed)),
      );
      h.transport.reject(await h.transport.nextRequest(), errno: 22);
      await failed;
      final next = h.repository.execute(_create);
      h.transport.respond(await h.transport.nextRequest(), {
        'id': _create.target,
      });
      expect(await next, isA<ManagementCompleted>());
    },
  );
  test(
    'fresh session clears untraceable old mutation without replay',
    () async {
      final first = _Transport('25.10.1', _allMethods, true),
          second = _Transport('25.10.1', _allMethods, true);
      final repository = TrueNasSessionRepository(
        connector: _RotatingConnector([first, second]),
      );
      addTearDown(repository.close);
      Future<void> connect() async {
        await repository.connect(
          serverInput: 'https://nas.example',
          apiKey: 'fixture-key',
          username: 'admin',
        );
      }

      await connect();
      final original = repository.execute(_create);
      first.reject(await first.nextRequest(), errno: 22);
      expect(await original, isA<ManagementOutcomeUnknown>());
      await expectLater(
        repository.execute(_snapshot),
        throwsA(_reason(ManagementExceptionReason.busy)),
      );
      await connect();
      final next = repository.execute(_snapshot);
      second.respond(await second.nextRequest(), {'id': _snapshot.target});
      expect(await next, isA<ManagementCompleted>());
      expect(first.managementRequests.length, 1);
      expect(second.managementRequests.length, 1);
    },
  );
}

const _shareReads = {
  'sharing.smb.query',
  'sharing.nfs.query',
  'nfs.config',
  'pool.dataset.query',
  'service.query',
};
Future<void> _expectQuickFence(_Harness h) async {
  final count = h.transport.managementRequests.length;
  for (final command in [_create, _snapshot]) {
    await expectLater(
      h.repository.execute(command),
      throwsA(_reason(ManagementExceptionReason.busy)),
    );
  }
  expect(h.transport.managementRequests.length, count);
}

void _expectJobRead(Map<String, Object?> request, int jobId) {
  expect(request['method'], 'core.get_jobs');
  expect(request['params'], [
    [
      ['id', '=', jobId],
    ],
    {
      'limit': 1,
      'select': ['id', 'method', 'state', 'result'],
    },
  ]);
}

Map<String, Object?> _jobRow(int id, String state, Object? result) => {
  'id': id,
  'method': 'service.control',
  'state': state,
  'result': result,
};

Future<ManagementJobSubmitted> _submitJob(_Harness h) async {
  final execution = h.repository.execute(_start);
  final request = await h.transport.nextRequest();
  h.transport.respond(request, 42);
  return await execution as ManagementJobSubmitted;
}

Future<_Harness> _connected({
  String version = '25.10.1',
  Set<String> methods = _allMethods,
  Duration timeout = const Duration(seconds: 1),
  bool shareMetadata = false,
}) async {
  final harness = _Harness(
    version: version,
    methods: methods,
    timeout: timeout,
    shareMetadata: shareMetadata,
  );
  addTearDown(harness.repository.close);
  await harness.connect();
  return harness;
}

final class _Harness {
  _Harness({
    String version = '25.10.1',
    Set<String> methods = _allMethods,
    Duration timeout = const Duration(seconds: 1),
    bool automaticHandshake = true,
    bool shareMetadata = false,
  }) {
    transport = _Transport(version, methods, automaticHandshake, shareMetadata);
    repository = TrueNasSessionRepository(
      connector: _Connector(transport),
      managementRequestTimeout: timeout,
    );
  }
  late final _Transport transport;
  late final TrueNasSessionRepository repository;
  Future<ServerSummary> connect() => repository.connect(
    serverInput: 'https://nas.example',
    apiKey: 'test-secret',
    username: 'admin',
  );
}

final class _Connector implements RpcConnector {
  const _Connector(this.transport);
  final RpcTransport transport;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => transport;
}

final class _RotatingConnector implements RpcConnector {
  _RotatingConnector(this.transports);
  final List<RpcTransport> transports;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => transports.removeAt(0);
}

final class _Transport implements RpcTransport {
  _Transport(
    this.version,
    this.methods,
    this.automaticHandshake, [
    this.shareMetadata = false,
  ]);
  final String version;
  final Set<String> methods;
  final bool automaticHandshake;
  final bool shareMetadata;
  final _inbound = StreamController<String>();
  final requests = <Map<String, Object?>>[];
  final _unread = <Map<String, Object?>>[];
  Completer<Map<String, Object?>>? _waiting;
  bool _closed = false;
  Iterable<Map<String, Object?>> get managementRequests => requests.where(
    (r) => !{
      'auth.login_ex',
      'auth.me',
      'system.info',
      'core.get_methods',
    }.contains(r['method']),
  );
  @override
  Stream<String> get inboundFrames => _inbound.stream;
  @override
  Future<void> send(String frame) async {
    final request = Map<String, Object?>.from(jsonDecode(frame) as Map);
    requests.add(request);
    final method = request['method'];
    if (automaticHandshake &&
        {
          'auth.login_ex',
          'auth.me',
          'system.info',
          'core.get_methods',
        }.contains(method)) {
      final result = switch (method) {
        'auth.login_ex' => {'response_type': 'SUCCESS'},
        'auth.me' => {'username': 'admin'},
        'system.info' => {'version': version},
        _ => {
          for (final method in methods)
            method: <String, Object?>{
              if (shareMetadata) ...{
                'accepts': <Object?>[],
                'returns': [
                  {'type': 'object', 'properties': <String, Object?>{}},
                ],
                'job': false,
                'no_auth_required': false,
                'filterable': false,
                'downloadable': false,
                'uploadable': false,
                'check_pipes': <Object?>[],
              },
            },
        },
      };
      respond(request, result);
    } else if (_waiting case final waiter?) {
      _waiting = null;
      waiter.complete(request);
    } else {
      _unread.add(request);
    }
  }

  Future<Map<String, Object?>> nextRequest() {
    if (_unread.isNotEmpty) return Future.value(_unread.removeAt(0));
    if (_waiting != null) {
      throw StateError('Only one request waiter is allowed.');
    }
    _waiting = Completer<Map<String, Object?>>();
    return _waiting!.future.timeout(const Duration(seconds: 2));
  }

  void respond(Map<String, Object?> request, Object? result) => _inbound.add(
    jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
  );
  void reject(Map<String, Object?> request, {required Object? errno}) =>
      _inbound.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': request['id'],
          'error': {
            'code': -32001,
            'message': 'secret-api-key internal server details',
            'data': {'errno': errno},
          },
        }),
      );
  @override
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    await _inbound.close();
  }
}
