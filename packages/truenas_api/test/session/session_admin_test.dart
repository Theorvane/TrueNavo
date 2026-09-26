import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

Map<String, Object?> _spec({
  List<Object?> accepts = const [],
  bool job = false,
  Map<String, Object?> returns = const {'type': 'object', 'properties': {}},
  Map<String, Object?> overrides = const {},
}) => {
  'accepts': accepts,
  'returns': [returns],
  'job': job,
  'no_auth_required': false,
  'filterable': false,
  'downloadable': false,
  'uploadable': false,
  'check_pipes': [],
  'roles': ['FULL_ADMIN'],
  ...overrides,
};
const _name = {
  '_name_': 'name',
  '_required_': true,
  'type': 'string',
  'minLength': 1,
};
final _metadata = <String, Object?>{
  'system.info': _spec(),
  'group.create': _spec(
    accepts: [
      {
        '_name_': 'data',
        '_required_': true,
        'type': 'object',
        'required': ['name'],
        'properties': {
          'name': {'type': 'string', 'minLength': 1},
          'password': {'type': 'string', 'secret': true},
          'special': {'type': 'string', 'secret': true},
          'nested': {
            'anyOf': [
              {
                'type': 'object',
                'properties': {
                  'opaque': {'type': 'string', 'secret': true},
                },
              },
              {
                'type': 'object',
                'properties': {
                  'opaque': {'type': 'string'},
                },
              },
            ],
          },
        },
      },
    ],
    returns: {
      'type': 'object',
      'properties': {
        'special': {'type': 'string', 'secret': true},
      },
    },
  ),
  'app.start': _spec(accepts: [_name], job: true),
  'core.get_jobs': _spec(),
  'user.create': _spec(),
  'core.bulk': _spec(),
  'secret.internal': _spec(),
  for (final name in [
    'sharing.smb.query',
    'sharing.nfs.query',
    'nfs.config',
    'pool.dataset.query',
    'service.query',
  ])
    name: _spec(),
};
Matcher _reason(AdminExceptionReason reason) =>
    isA<AdminException>().having((e) => e.reason, 'reason', reason);

void main() {
  test(
    'listener IP choices reject incomplete maps before sanitization',
    () async {
      final h = await _connected(
        metadata: {
          'iscsi.portal.listen_ip_choices': _spec(
            returns: {
              'type': 'object',
              'additionalProperties': {'type': 'string'},
            },
          ),
        },
      );
      final oversized = h.repository.invokeAdmin(
        _request(h, method: 'iscsi.portal.listen_ip_choices'),
      );
      h.transport.respond(await h.transport.next(), {
        for (var i = 0; i < 101; i++) '192.0.2.$i': 'choice',
      });
      expect(await oversized, isA<AdminFailed>());

      final valid = h.repository.invokeAdmin(
        _request(h, method: 'iscsi.portal.listen_ip_choices'),
      );
      h.transport.respond(await h.transport.next(), {
        for (var i = 0; i < 100; i++) '192.0.2.$i': 'choice',
      });
      final result = await valid as AdminCompleted;
      expect((result.value as Map).length, 100);
    },
  );

  test(
    'extent detail rejects sanitized truncation before review use',
    () async {
      final h = await _connected(
        metadata: {
          'iscsi.extent.get_instance': _spec(
            accepts: [
              {'_name_': 'id', '_required_': true, 'type': 'integer'},
            ],
          ),
        },
      );
      for (final raw in [
        {'id': 5, 'name': 'disk', 'path': 'x' * 513},
        {'id': 5, 'name': 'disk', 'path': 'bad\u0000path'},
        {'id': 5, 'name': 'disk', 'nested': <String, Object?>{}},
        {for (var i = 0; i < 100; i++) 'field$i': 'value'},
      ]) {
        final pending = h.repository.invokeAdmin(
          _request(h, method: 'iscsi.extent.get_instance', arguments: [5]),
        );
        h.transport.respond(await h.transport.next(), raw);
        expect(await pending, isA<AdminFailed>());
      }
      final valid = h.repository.invokeAdmin(
        _request(h, method: 'iscsi.extent.get_instance', arguments: [5]),
      );
      h.transport.respond(await h.transport.next(), {
        'id': 5,
        'name': 'disk',
        'type': 'DISK',
        'comment': 'old',
        'enabled': true,
        'ro': false,
        'path': '/mnt/private',
      });
      expect(await valid, isA<AdminCompleted>());
    },
  );

  for (final method in [
    'alertservice.update',
    'alertservice.delete',
    'alertservice.test',
  ]) {
    test(
      '$method metadata cannot enable generic or readonly dispatch',
      () async {
        final h = await _connected(metadata: {method: _spec()});
        expect(h.repository.adminCatalog.method(method), isNull);
        await expectLater(
          h.repository.query(method),
          throwsA(isA<SessionQueryException>()),
        );
        expect(h.transport.calls, isEmpty);
      },
    );
  }
  test(
    'mail.send metadata cannot enable generic or readonly-query dispatch',
    () async {
      final h = await _connected(metadata: {'mail.send': _spec(job: true)});
      expect(h.repository.adminCatalog.method('mail.send'), isNull);
      await expectLater(
        h.repository.query('mail.send'),
        throwsA(isA<SessionQueryException>()),
      );
      expect(h.transport.calls, isEmpty);
    },
  );
  for (final method in [
    'alertservice.query',
    'cronjob.query',
    'cronjob.create',
    'cronjob.update',
    'cronjob.delete',
    'cronjob.run',
    'initshutdownscript.query',
    'initshutdownscript.create',
    'alertservice.create',
    'smb.config',
    'smb.update',
    'nfs.config',
    'nfs.update',
    'alertclasses.config',
    'alertclasses.update',
    'mail.config',
    'mail.update',
    'system.general.config',
    'system.general.update',
    'system.ntpserver.query',
    'system.ntpserver.create',
    'system.ntpserver.update',
    'system.ntpserver.delete',
  ]) {
    test(
      '$method cannot bypass its native settings gateway through generic RPC',
      () async {
        final h = await _connected(metadata: {method: _spec()});
        final advertised = h.repository.adminCatalog.method(method)!;
        expect(advertised.supported, isFalse);
        await expectLater(
          h.repository.invokeAdmin(
            AdminRequest(method: advertised, arguments: []),
          ),
          throwsA(_reason(AdminExceptionReason.unavailableMethod)),
        );
        expect(h.transport.calls, isEmpty);
      },
    );
  }
  for (final method in ['cronjob.query', 'initshutdownscript.query']) {
    test(
      '$method cannot expose stored commands through dashboard queries',
      () async {
        final h = await _connected(metadata: {method: _spec()});
        await expectLater(
          h.repository.query(method),
          throwsA(isA<SessionQueryException>()),
        );
        expect(h.transport.calls, isEmpty);
      },
    );
  }
  test('confirmation preserves full non-secret identity while request size is bounded', () async {
    final h = await _connected();
    final fullName = '${'a' * 800}/exact-suffix';
    final request = _request(h, method: 'app.start', arguments: [fullName]);
    expect(request.redactedArguments.single, fullName);
    expect(
      () => _request(h, arguments: ['x' * 65537]),
      throwsA(_reason(AdminExceptionReason.invalidInput)),
    );
    expect(
      () => _request(h, arguments: List.filled(33, null)),
      throwsA(_reason(AdminExceptionReason.invalidInput)),
    );
  });

  test(
    'array unions redact secret fields from every possible branch',
    () async {
      final h = await _connected(
        metadata: {
          'system.info': _spec(
            returns: {
              'anyOf': [
                {
                  'type': 'array',
                  'items': [
                    {
                      'type': 'object',
                      'properties': {
                        'opaque': {'type': 'string'},
                      },
                    },
                  ],
                },
                {
                  'type': 'array',
                  'items': [
                    {
                      'type': 'object',
                      'properties': {
                        'opaque': {'type': 'string', 'secret': true},
                      },
                    },
                  ],
                },
              ],
            },
          ),
        },
      );
      final pending = h.repository.invokeAdmin(_request(h));
      h.transport.respond(await h.transport.next(), [
        {'opaque': 'hidden-union'},
      ]);
      final result = await pending as AdminCompleted;
      expect(result.value, [
        {'opaque': '[redacted]'},
      ]);
    },
  );
  test('unauthenticated catalogue is empty and no write is possible', () async {
    final h = _Harness();
    addTearDown(h.repository.close);
    expect(h.repository.adminCatalog.connected, isFalse);
    final forged = AdminCatalog.fromMetadata(
      version: '25.10.1',
      metadata: _metadata,
    );
    await expectLater(
      h.repository.invokeAdmin(
        AdminRequest(method: forged.method('system.info')!, arguments: []),
      ),
      throwsA(_reason(AdminExceptionReason.notAuthenticated)),
    );
    expect(h.transport.requests, isEmpty);
  });

  test(
    'connect retains full authenticated metadata and immutable catalogue',
    () async {
      final h = await _connected();
      final catalog = h.repository.adminCatalog;
      expect(catalog.connected, isTrue);
      expect(catalog.versionSupported, isTrue);
      expect(catalog.method('group.create')!.supported, isTrue);
      expect(catalog.method('group.create')!.roles, {'FULL_ADMIN'});
      expect(catalog.method('group.create')!.parameters.single.name, 'data');
      expect(catalog.method('secret.internal'), isNull);
      expect(catalog.method('core.bulk'), isNull);
      expect(catalog.method('user.create')!.supported, isFalse);
      expect(() => catalog.methods.clear(), throwsUnsupportedError);
      await h.repository.close();
      expect(catalog.connected, isFalse);
    },
  );

  for (final version in [
    '25.04.2',
    '26.0.1',
    'unknown',
    '25.10-beta',
    '25.10\n',
  ]) {
    test('unverified administration adapter $version is blocked', () async {
      final h = await _connected(version: version);
      await expectLater(
        h.repository.invokeAdmin(_request(h)),
        throwsA(_reason(AdminExceptionReason.unsupportedVersion)),
      );
      expect(h.transport.calls, isEmpty);
    });
  }

  for (final override in [
    {'no_auth_required': true},
    {'private': true},
    {'uploadable': true},
    {'downloadable': true},
    {
      'check_pipes': ['input'],
    },
    {'job': null},
    {'accepts': null},
    {'returns': []},
  ]) {
    test(
      'incomplete or specialized metadata is unavailable: $override',
      () async {
        final h = await _connected(
          metadata: {'system.info': _spec(overrides: override)},
        );
        expect(
          h.repository.adminCatalog.method('system.info')!.supported,
          isFalse,
        );
        await expectLater(
          h.repository.invokeAdmin(_request(h)),
          throwsA(_reason(AdminExceptionReason.unavailableMethod)),
        );
        expect(h.transport.calls, isEmpty);
      },
    );
  }

  test('a name-only inventory list cannot grant administration', () async {
    final h = await _connected(metadata: ['system.info', 'group.create']);
    expect(h.repository.adminCatalog.methods, isEmpty);
    expect(TrueNasSessionRepository.readOnlyMethods, hasLength(6));
    await expectLater(
      h.repository.query('group.create'),
      throwsA(isA<SessionQueryException>()),
    );
  });

  test('schema spec identity is bound to the exact connection', () async {
    final first = await _connected();
    final second = await _connected();
    await expectLater(
      second.repository.invokeAdmin(_request(first)),
      throwsA(_reason(AdminExceptionReason.staleSession)),
    );
    expect(second.transport.calls, isEmpty);
    final copy = AdminCatalog.fromMetadata(
      version: '25.10.1',
      metadata: _metadata,
    );
    await expectLater(
      first.repository.invokeAdmin(
        AdminRequest(method: copy.method('system.info')!, arguments: []),
      ),
      throwsA(_reason(AdminExceptionReason.staleSession)),
    );
  });

  test('required unsupported schema refuses any JSON; optional unsupported is omitted', () async {
    final h = await _connected(
      metadata: {
        'system.info': _spec(
          accepts: [
            {'_name_': 'filter', '_required_': false},
          ],
        ),
        'group.create': _spec(
          accepts: [
            {'_name_': 'data', '_required_': true},
          ],
        ),
      },
    );
    expect(h.repository.adminCatalog.method('system.info')!.supported, isTrue);
    expect(
      h.repository.adminCatalog.method('group.create')!.supported,
      isFalse,
    );
    await expectLater(
      h.repository.invokeAdmin(_request(h, arguments: [{}])),
      throwsA(_reason(AdminExceptionReason.invalidInput)),
    );
    final pending = h.repository.invokeAdmin(_request(h));
    final wire = await h.transport.next();
    expect(wire['params'], []);
    h.transport.respond(wire, {});
    expect(await pending, isA<AdminCompleted>());
  });

  test('requests freeze args and validate before any wire write', () async {
    final h = await _connected();
    final args = <Object?>[
      {'name': 'operators'},
    ];
    final request = _request(h, method: 'group.create', arguments: args);
    (args.single as Map)['name'] = '';
    expect((request.arguments.single as Map)['name'], 'operators');
    for (final invalid in <List<Object?>>[
      [],
      [{}],
      [
        {'name': ''},
      ],
      [
        {'name': 'x', 'unknown': true},
      ],
      [true],
      [
        {'name': 'x'},
        2,
      ],
    ]) {
      await expectLater(
        h.repository.invokeAdmin(
          _request(h, method: 'group.create', arguments: invalid),
        ),
        throwsA(_reason(AdminExceptionReason.invalidInput)),
      );
    }
    expect(h.transport.calls, isEmpty);
    final pending = h.repository.invokeAdmin(request);
    final wire = await h.transport.next();
    expect(wire['params'], [
      {'name': 'operators'},
    ]);
    h.transport.respond(wire, {'id': 4});
    final result = await pending as AdminCompleted;
    expect(result.value, {'id': 4});
    expect(result.request.arguments, isEmpty);
  });

  test('confirmation and results redact metadata secrets, heuristic keys and union branches', () async {
    final h = await _connected();
    final request = _request(
      h,
      method: 'group.create',
      arguments: [
        {
          'name': 'operators',
          'password': 'hide-password',
          'special': 'hide-special',
          'nested': {'opaque': 'hide-union'},
        },
      ],
    );
    expect(request.redactedArguments.toString(), isNot(contains('hide-')));
    expect(request.toString(), isNot(contains('hide-')));
    final pending = h.repository.invokeAdmin(request);
    final wire = await h.transport.next();
    expect((wire['params'] as List).single, request.arguments.single);
    h.transport.respond(wire, {
      'id': 1,
      'password': 'hide-password',
      'special': 'hide-special',
      'other': {'api_key': 'hide-key', 'traceback': 'hide-debug'},
      'list': [
        {'private_key': 'hide-private'},
      ],
      'arguments': ['hide-args'],
    });
    final result = await pending as AdminCompleted;
    expect(result.value.toString(), isNot(contains('hide-')));
    expect(result.request.arguments, isEmpty);
  });

  test(
    'concurrent and repeated identical submissions do not duplicate mutations',
    () async {
      final h = await _connected();
      final request = _request(h);
      final pending = h.repository.invokeAdmin(request);
      final wire = await h.transport.next();
      await expectLater(
        h.repository.invokeAdmin(_request(h)),
        throwsA(_reason(AdminExceptionReason.busy)),
      );
      await expectLater(
        h.repository.execute(
          const CreateDatasetCommand(parent: 'tank', name: 'a'),
        ),
        throwsA(
          isA<ManagementException>().having(
            (e) => e.reason,
            'reason',
            ManagementExceptionReason.busy,
          ),
        ),
      );
      h.transport.respond(wire, {});
      await pending;
      await expectLater(
        h.repository.invokeAdmin(request),
        throwsA(_reason(AdminExceptionReason.duplicateRequest)),
      );
      expect(h.transport.calls, hasLength(1));
    },
  );

  test('read timeout is unknown without a durable mutation fence', () async {
    final h = await _connected(timeout: const Duration(milliseconds: 10));
    final result = await h.repository.invokeAdmin(_request(h));
    expect(result, isA<AdminOutcomeUnknown>());
    expect(h.transport.calls, hasLength(1));
    expect(result.request.arguments, isEmpty);
  });

  for (final errno in [1, 13, 22]) {
    test(
      'remote failure $errno never exposes remote payload or message',
      () async {
        final h = await _connected();
        final pending = h.repository.invokeAdmin(_request(h));
        final wire = await h.transport.next();
        h.transport.reject(wire, errno);
        final result = await pending as AdminFailed;
        expect(
          result.reason,
          errno == 22 ? AdminFailureReason.rejected : AdminFailureReason.denied,
        );
        expect(result.userMessage, isNot(contains('private-remote-data')));
      },
    );
  }

  test(
    'jobs require inspect capability and positive integer submission id',
    () async {
      final missing = await _connected(
        metadata: {
          'app.start': _spec(accepts: [_name], job: true),
        },
      );
      expect(
        missing.repository.adminCatalog.method('app.start')!.supported,
        isFalse,
      );
      for (final value in [null, true, 0, '42']) {
        final h = await _connected();
        final pending = h.repository.invokeAdmin(
          _request(h, method: 'app.start', arguments: ['photos']),
        );
        h.transport.respond(await h.transport.next(), value);
        expect(await pending, isA<AdminOutcomeUnknown>());
      }
    },
  );

  test('job polling is identity-bound and exact-id/method-filtered; SUCCESS accepts object', () async {
    final h = await _connected();
    final job = await _job(h);
    final fake = AdminJobSubmitted(job.request, jobId: job.jobId);
    expect(await h.repository.pollAdminJob(fake), isA<AdminOutcomeUnknown>());
    expect(h.transport.calls, hasLength(1));
    final polling = h.repository.pollAdminJob(job);
    final wire = await h.transport.next();
    expect(wire['method'], 'core.get_jobs');
    expect(wire['params'], [
      [
        ['id', '=', 42],
      ],
      {
        'limit': 1,
        'select': ['id', 'method', 'state', 'result'],
        'extra': {'raw_result': false},
      },
    ]);
    h.transport.respond(wire, [
      {
        'id': 42,
        'method': 'app.start',
        'state': 'SUCCESS',
        'result': {'started': 'photos', 'token': 'hidden'},
      },
    ]);
    final result = await polling as AdminCompleted;
    expect(result.value, {'started': 'photos', 'token': '[redacted]'});
    expect(await h.repository.pollAdminJob(job), same(result));
    expect(h.transport.calls, hasLength(2));
  });

  for (final mismatch in [
    {'id': 41},
    {'method': 'app.stop'},
    {'state': 'unexpected'},
  ]) {
    test('job mismatch $mismatch remains unknown with original id', () async {
      final h = await _connected();
      final job = await _job(h);
      final polling = h.repository.pollAdminJob(job);
      h.transport.respond(await h.transport.next(), [
        {
          'id': 42,
          'method': 'app.start',
          'state': 'SUCCESS',
          'result': null,
          ...mismatch,
        },
      ]);
      final result = await polling as AdminOutcomeUnknown;
      expect(result.jobId, 42);
    });
  }

  for (final state in ['RUNNING', 'WAITING', 'FAILED', 'ABORTED']) {
    test('job state $state does not imply premature success', () async {
      final h = await _connected();
      final job = await _job(h);
      final polling = h.repository.pollAdminJob(job);
      h.transport.respond(await h.transport.next(), [
        {
          'id': 42,
          'method': 'app.start',
          'state': state,
          'result': 'private-remote-data',
        },
      ]);
      final result = await polling;
      expect(
        result.status,
        ['RUNNING', 'WAITING'].contains(state)
            ? AdminStatus.submitted
            : AdminStatus.failed,
      );
      expect(result.userMessage, isNot(contains('private-remote-data')));
    });
  }

  test('disconnected job retains id and never polls replacement or closed transport', () async {
    final h = await _connected();
    final job = await _job(h);
    final other = await _connected();
    expect(
      await other.repository.pollAdminJob(job),
      isA<AdminOutcomeUnknown>(),
    );
    expect(other.transport.calls, isEmpty);
    await h.repository.close();
    final result = await h.repository.pollAdminJob(job) as AdminOutcomeUnknown;
    expect(result.jobId, 42);
    expect(h.transport.calls, hasLength(1));
  });

  test('inventory output is recursively bounded', () async {
    final h = await _connected();
    final pending = h.repository.invokeAdmin(_request(h));
    h.transport.respond(
      await h.transport.next(),
      List.generate(150, (i) => {'id': i, 'name': 'x' * 1000}),
    );
    final result = await pending as AdminCompleted;
    expect(result.value as List, hasLength(101));
    expect(((result.value as List).first as Map)['name'].length, 513);
  });

  test(
    'unknown mutation fences admin Quick SMB and NFS until a fresh session',
    () async {
      final h = await _connected(timeout: const Duration(milliseconds: 30));
      final pending = h.repository.invokeAdmin(
        _request(
          h,
          method: 'group.create',
          arguments: [
            {'name': 'operators'},
          ],
        ),
      );
      final original = await h.transport.next();
      expect(await pending, isA<AdminOutcomeUnknown>());
      await _expectAdminFence(h);
      h.transport.respond(original, {'id': 10});
      await Future<void>.delayed(Duration.zero);
      await _expectAdminFence(h);
      // Explicit harmless recovery reads remain possible, without clearing it.
      final read = h.repository.invokeAdmin(_request(h));
      h.transport.respond(await h.transport.next(), {});
      expect(await read, isA<AdminCompleted>());
      await _expectAdminFence(h);
      expect(h.transport.calls.length, 2);
    },
  );
  for (final errno in <Object?>[22, null, 1.0, '13']) {
    test(
      'effect-uncertain mutation RPC errno $errno retains shared fence',
      () async {
        final h = await _connected();
        final pending = h.repository.invokeAdmin(
          _request(
            h,
            method: 'group.create',
            arguments: [
              {'name': 'operators'},
            ],
          ),
        );
        h.transport.reject(await h.transport.next(), errno);
        final result = await pending;
        expect(result, isA<AdminOutcomeUnknown>());
        expect(result.userMessage, isNot(contains('private-remote-data')));
        await _expectAdminFence(h);
        expect(h.transport.calls.length, 1);
      },
    );
  }
  for (final errno in [1, 13]) {
    test(
      'explicit permission denial $errno does not retain a mutation fence',
      () async {
        final h = await _connected();
        final pending = h.repository.invokeAdmin(
          _request(
            h,
            method: 'group.create',
            arguments: [
              {'name': 'operators'},
            ],
          ),
        );
        h.transport.reject(await h.transport.next(), errno);
        expect(
          (await pending as AdminFailed).reason,
          AdminFailureReason.denied,
        );
        final next = h.repository.invokeAdmin(
          _request(
            h,
            method: 'group.create',
            arguments: [
              {'name': 'other'},
            ],
          ),
        );
        h.transport.respond(await h.transport.next(), {'id': 11});
        expect(await next, isA<AdminCompleted>());
      },
    );
  }
  for (final terminal in ['SUCCESS', 'FAILED', 'ABORTED']) {
    test(
      'owned pending mutation stays pollable and $terminal releases its shared fence',
      () async {
        final h = await _connected();
        final job = await _job(h);
        await _expectAdminFence(h);
        for (final state in ['WAITING', 'RUNNING']) {
          final read = h.repository.pollAdminJob(job);
          h.transport.respond(await h.transport.next(), [
            {'id': 42, 'method': 'app.start', 'state': state, 'result': null},
          ]);
          expect(await read, same(job));
          await _expectAdminFence(h);
        }
        final read = h.repository.pollAdminJob(job);
        h.transport.respond(await h.transport.next(), [
          {'id': 42, 'method': 'app.start', 'state': terminal, 'result': {}},
        ]);
        expect(
          (await read).status,
          terminal == 'SUCCESS' ? AdminStatus.completed : AdminStatus.failed,
        );
        final next = h.repository.invokeAdmin(
          _request(
            h,
            method: 'group.create',
            arguments: [
              {'name': 'after'},
            ],
          ),
        );
        h.transport.respond(await h.transport.next(), {'id': 2});
        expect(await next, isA<AdminCompleted>());
      },
    );
  }
  test('unknown poll and floating-point job identity keep pending fence; exact terminal recovers', () async {
    final h = await _connected();
    final job = await _job(h);
    for (final value in <Object?>[
      [],
      [
        {'id': 42.0, 'method': 'app.start', 'state': 'SUCCESS', 'result': {}},
      ],
    ]) {
      final read = h.repository.pollAdminJob(job);
      h.transport.respond(await h.transport.next(), value);
      expect(await read, isA<AdminOutcomeUnknown>());
      await _expectAdminFence(h);
    }
    final failedRead = h.repository.pollAdminJob(job);
    h.transport.reject(await h.transport.next(), 13);
    expect(await failedRead, isA<AdminOutcomeUnknown>());
    await _expectAdminFence(h);
    final finalRead = h.repository.pollAdminJob(job);
    h.transport.respond(await h.transport.next(), [
      {'id': 42, 'method': 'app.start', 'state': 'SUCCESS', 'result': {}},
    ]);
    expect(await finalRead, isA<AdminCompleted>());
    final next = h.repository.invokeAdmin(
      _request(
        h,
        method: 'group.create',
        arguments: [
          {'name': 'after'},
        ],
      ),
    );
    h.transport.respond(await h.transport.next(), {'id': 2});
    expect(await next, isA<AdminCompleted>());
  });
  test(
    'read failures and read-only jobs do not hold durable mutation fences',
    () async {
      final h = await _connected(
        metadata: {..._metadata, 'system.info': _spec(job: true)},
      );
      final failedRead = h.repository.invokeAdmin(_request(h));
      h.transport.reject(await h.transport.next(), 22);
      expect(await failedRead, isA<AdminFailed>());
      final read = h.repository.invokeAdmin(_request(h));
      h.transport.respond(await h.transport.next(), 5);
      expect(await read, isA<AdminJobSubmitted>());
      final mutation = h.repository.invokeAdmin(
        _request(
          h,
          method: 'group.create',
          arguments: [
            {'name': 'allowed'},
          ],
        ),
      );
      h.transport.respond(await h.transport.next(), {'id': 3});
      expect(await mutation, isA<AdminCompleted>());
    },
  );
  test(
    'bounded read-job cache never evicts the pending mutation handle',
    () async {
      final h = await _connected(
        metadata: {..._metadata, 'system.info': _spec(job: true)},
      );
      final job = await _job(h);
      for (var i = 0; i < 66; i++) {
        final read = h.repository.invokeAdmin(_request(h));
        h.transport.respond(await h.transport.next(), 100 + i);
        expect(await read, isA<AdminJobSubmitted>());
      }
      await _expectAdminFence(h);
      final poll = h.repository.pollAdminJob(job);
      h.transport.respond(await h.transport.next(), [
        {'id': 42, 'method': 'app.start', 'state': 'SUCCESS', 'result': {}},
      ]);
      expect(await poll, isA<AdminCompleted>());
      final next = h.repository.invokeAdmin(
        _request(
          h,
          method: 'group.create',
          arguments: [
            {'name': 'after'},
          ],
        ),
      );
      h.transport.respond(await h.transport.next(), {'id': 2});
      expect(await next, isA<AdminCompleted>());
    },
  );
  test(
    'fresh connection resets an untraceable mutation without replaying it',
    () async {
      final first = _Transport('25.10.1', _metadata),
          second = _Transport('25.10.1', _metadata);
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
      final old = AdminRequest(
        method: repository.adminCatalog.method('group.create')!,
        arguments: [
          {'name': 'before'},
        ],
      );
      final pending = repository.invokeAdmin(old);
      first.reject(await first.next(), 22);
      expect(await pending, isA<AdminOutcomeUnknown>());
      await connect();
      await expectLater(
        repository.invokeAdmin(old),
        throwsA(_reason(AdminExceptionReason.staleSession)),
      );
      final next = repository.invokeAdmin(
        AdminRequest(
          method: repository.adminCatalog.method('group.create')!,
          arguments: [
            {'name': 'after'},
          ],
        ),
      );
      second.respond(await second.next(), {'id': 2});
      expect(await next, isA<AdminCompleted>());
      expect(first.calls.length, 1);
      expect(second.calls.length, 1);
    },
  );
}

Future<void> _expectAdminFence(_Harness h) async {
  final count = h.transport.calls.length;
  await expectLater(
    h.repository.invokeAdmin(
      _request(
        h,
        method: 'group.create',
        arguments: [
          {'name': 'blocked'},
        ],
      ),
    ),
    throwsA(_reason(AdminExceptionReason.busy)),
  );
  await expectLater(
    h.repository.execute(
      const CreateDatasetCommand(parent: 'tank', name: 'blocked'),
    ),
    throwsA(
      isA<ManagementException>().having(
        (e) => e.reason,
        'reason',
        ManagementExceptionReason.busy,
      ),
    ),
  );
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
  expect(h.transport.calls.length, count);
}

AdminRequest _request(
  _Harness h, {
  String method = 'system.info',
  List<Object?> arguments = const [],
}) => AdminRequest(
  method: h.repository.adminCatalog.method(method)!,
  arguments: arguments,
);
Future<AdminJobSubmitted> _job(_Harness h) async {
  final pending = h.repository.invokeAdmin(
    _request(h, method: 'app.start', arguments: ['photos']),
  );
  h.transport.respond(await h.transport.next(), 42);
  return await pending as AdminJobSubmitted;
}

Future<_Harness> _connected({
  String version = '25.10.1',
  Object? metadata,
  Duration timeout = const Duration(seconds: 1),
}) async {
  final h = _Harness(
    version: version,
    metadata: metadata ?? _metadata,
    timeout: timeout,
  );
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
    Object? metadata,
    Duration timeout = const Duration(seconds: 1),
  }) {
    transport = _Transport(version, metadata ?? _metadata);
    repository = TrueNasSessionRepository(
      connector: _Connector(transport),
      managementRequestTimeout: timeout,
    );
  }
  late final TrueNasSessionRepository repository;
  late final _Transport transport;
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
  _Transport(this.version, this.metadata);
  final String version;
  final Object? metadata;
  final _inbound = StreamController<String>();
  final requests = <Map<String, Object?>>[];
  final _unread = <Map<String, Object?>>[];
  Completer<Map<String, Object?>>? _waiting;
  bool _closed = false;
  Iterable<Map<String, Object?>> get calls => requests.where(
    (r) =>
        !{
          'auth.login_ex',
          'auth.me',
          'system.info',
          'core.get_methods',
        }.contains(r['method']) ||
        requests.indexOf(r) > 3,
  );
  @override
  Stream<String> get inboundFrames => _inbound.stream;
  @override
  Future<void> send(String frame) async {
    final r = Map<String, Object?>.from(jsonDecode(frame) as Map);
    requests.add(r);
    if (requests.length <= 4) {
      respond(r, switch (r['method']) {
        'auth.login_ex' => {'response_type': 'SUCCESS'},
        'auth.me' => {'username': 'admin'},
        'system.info' => {'version': version},
        _ => metadata,
      });
    } else if (_waiting case final waiting?) {
      _waiting = null;
      waiting.complete(r);
    } else {
      _unread.add(r);
    }
  }

  Future<Map<String, Object?>> next() {
    if (_unread.isNotEmpty) return Future.value(_unread.removeAt(0));
    _waiting = Completer<Map<String, Object?>>();
    return _waiting!.future.timeout(const Duration(seconds: 2));
  }

  void respond(Map<String, Object?> request, Object? result) => _inbound.add(
    jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
  );
  void reject(Map<String, Object?> request, Object? errno) => _inbound.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': request['id'],
      'error': {
        'code': -32001,
        'message': 'private-remote-data',
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
