import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _methods = {'core.get_jobs', 'core.job_abort', 'audit.query'};
Map<String, Object?> _job({int id = 12, String state = 'RUNNING'}) => {
  'id': id,
  'method': 'pool.scrub',
  'state': state,
  'abortable': true,
  'progress': {'percent': 42, 'description': 'secret-description'},
  'time_started': {r'$date': 1700000000000},
  'time_finished': null,
  'arguments': ['private-password'],
  'credentials': {'data': 'private-key'},
  'result': 'private-result',
  'logs_excerpt': 'private-log',
};
Map<String, Object?> _event() => {
  'audit_id': 'event-1',
  'message_timestamp': 1700000000,
  'timestamp': '2023-11-14T22:13:20Z',
  'username': 'admin',
  'address': '10.0.0.1',
  'service': 'MIDDLEWARE',
  'event': 'METHOD_CALL',
  'success': true,
  'event_data': {'password': 'private-password'},
  'service_data': {'token': 'private-token'},
};
final _audit = AuditQuery(
  from: DateTime.utc(2023, 11, 14),
  until: DateTime.utc(2023, 11, 15),
);

void main() {
  test('audit projects only validated method alias and withholds malformed payload text', () async {
    final h = await _connect();
    h.wire.events.single['method'] = 'pool.snapshot.create';
    expect(
      (await h.repo.loadAuditEvents(_audit)).entries.single.method,
      'pool.snapshot.create',
    );
    final args = (h.wire.activity.last['params'] as List).single as Map;
    expect(
      (args['query-options'] as Map)['select'],
      contains(equals(['event_data.method', 'method'])),
    );
    h.wire.events.single['method'] = 'private password text';
    expect(
      (await h.repo.loadAuditEvents(_audit)).entries.single.method,
      isNull,
    );
    h.wire.events.single['method'] = 'pool.snapshot.create';
    h.wire.events.single['event'] = 'AUTHENTICATION';
    expect(
      (await h.repo.loadAuditEvents(_audit)).entries.single.method,
      isNull,
    );
  });
  test(
    'audit supports numeric and unavailable IDs without inventing identity',
    () async {
      final h = await _connect();
      h.wire.events = [
        _event()..['audit_id'] = 123,
        _event()..['audit_id'] = null,
        _event()..['audit_id'] = null,
      ];
      final page = await h.repo.loadAuditEvents(_audit);
      expect(page.entries.map((event) => event.id), [
        '123',
        'Unavailable',
        'Unavailable',
      ]);
    },
  );
  test('disconnected activity never contacts the transport', () async {
    final h = _Harness();
    addTearDown(h.repo.close);
    expect(h.repo.activityCapabilities.supported, isFalse);
    await expectLater(
      h.repo.loadActivityJobs(const JobQuery()),
      throwsA(isA<ActivityException>()),
    );
    expect(h.wire.requests, isEmpty);
  });
  for (final version in ['25.04.1', '25.10-BETA.1', '26.0.0']) {
    test('version $version cannot read or cancel', () async {
      final h = await _connect(version: version);
      await expectLater(
        h.repo.loadActivityJobs(const JobQuery()),
        throwsA(isA<ActivityException>()),
      );
      expect(h.wire.activity, isEmpty);
    });
  }
  test('readonly role reads exact safe projection and never writes', () async {
    final h = await _connect(methods: {'core.get_jobs', 'audit.query'});
    final page = await h.repo.loadActivityJobs(const JobQuery());
    final audit = await h.repo.loadAuditEvents(_audit);
    expect(page.entries.single.progressPercent, 42);
    expect(audit.entries.single.username, 'admin');
    expect(h.repo.activityCapabilities.canCancelJobs, isFalse);
    await expectLater(
      h.repo.cancelActivityJob(page.entries.single, 'job 12'),
      throwsA(isA<ActivityException>()),
    );
    expect(h.wire.writes, isEmpty);
    final request = h.wire.activity.first;
    final options = (request['params'] as List).last as Map;
    expect(options['limit'], 26);
    expect(options['select'], [
      'id',
      'method',
      'state',
      'abortable',
      'progress.percent',
      'time_started',
      'time_finished',
    ]);
    expect(options['extra'], {'raw_result': false});
    expect(() => page.entries.clear(), throwsUnsupportedError);
    final auditArgs = (h.wire.activity.last['params'] as List).single as Map;
    expect(auditArgs['services'], ['MIDDLEWARE']);
    expect(auditArgs['remote_controller'], isFalse);
    expect(
      (auditArgs['query-options'] as Map)['select'],
      isNot(contains('event_data')),
    );
  });
  test('queries use bounded pages and exact filters', () async {
    final h = await _connect();
    h.wire.jobs = [for (var n = 1; n <= 60; n++) _job(id: n)];
    final page = await h.repo.loadActivityJobs(
      const JobQuery(
        page: 1,
        state: ActivityJobState.running,
        method: 'pool.scrub',
      ),
    );
    expect(page.entries.length, 25);
    expect(page.hasMore, isTrue);
    final params = h.wire.activity.single['params'] as List;
    expect(params.first, [
      ['state', '=', 'RUNNING'],
      ['method', '=', 'pool.scrub'],
    ]);
    expect((params.last as Map)['offset'], 25);
  });
  for (final query in [
    const JobQuery(page: -1),
    const JobQuery(page: 40),
    const JobQuery(method: '*'),
  ]) {
    test(
      'invalid job query is rejected before sending ${query.hashCode}',
      () async {
        final h = await _connect();
        await expectLater(
          h.repo.loadActivityJobs(query),
          throwsA(isA<ActivityException>()),
        );
        expect(h.wire.activity, isEmpty);
      },
    );
  }
  test('invalid audit interval is rejected before sending', () async {
    final h = await _connect();
    await expectLater(
      h.repo.loadAuditEvents(
        AuditQuery(from: DateTime.utc(2023), until: DateTime.utc(2024)),
      ),
      throwsA(isA<ActivityException>()),
    );
    expect(h.wire.activity, isEmpty);
  });
  test(
    'cancellation is one exact write followed by independent terminal read',
    () async {
      final h = await _connect();
      final job = (await h.repo.loadActivityJobs(const JobQuery()))
          .entries
          .single;
      final result = await h.repo.cancelActivityJob(job, job.confirmation);
      expect(result.outcome, JobCancelOutcome.verified);
      expect(result.message, contains('not rolled back'));
      expect(h.wire.writes.single['params'], [12]);
      expect(h.wire.activity.map((r) => r['method']), [
        'core.get_jobs',
        'core.get_jobs',
        'core.job_abort',
        'core.get_jobs',
      ]);
    },
  );
  test(
    'pending cancellation polls read-only, never repeats the mutation',
    () async {
      final h = await _connect();
      h.wire.cancelState = 'RUNNING';
      final job = (await h.repo.loadActivityJobs(const JobQuery()))
          .entries
          .single;
      final result = await h.repo.cancelActivityJob(job, job.confirmation);
      expect(result.outcome, JobCancelOutcome.pending);
      await expectLater(
        h.repo.execute(
          const ServiceControlCommand(
            service: 'ssh',
            action: ServiceControlAction.stop,
          ),
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
        h.repo.cancelActivityJob(job, job.confirmation),
        throwsA(isA<ActivityException>()),
      );
      h.wire.jobs.single['state'] = 'ABORTED';
      expect(
        (await h.repo.checkActivityCancellation(job)).outcome,
        JobCancelOutcome.verified,
      );
      expect(h.wire.writes.length, 1);
    },
  );
  test(
    'normal completion after cancel is not falsely described as aborted',
    () async {
      final h = await _connect();
      h.wire.cancelState = 'SUCCESS';
      final job = (await h.repo.loadActivityJobs(const JobQuery()))
          .entries
          .single;
      final result = await h.repo.cancelActivityJob(job, job.confirmation);
      expect(result.outcome, JobCancelOutcome.verified);
      expect(result.message, contains('finished as SUCCESS'));
    },
  );
  for (final change in ['identity', 'finished', 'not-abortable', 'missing']) {
    test('fresh $change prevents cancellation', () async {
      final h = await _connect();
      final job = (await h.repo.loadActivityJobs(const JobQuery()))
          .entries
          .single;
      switch (change) {
        case 'identity':
          h.wire.jobs.single['time_started'] = {r'$date': 1700000000001};
        case 'finished':
          h.wire.jobs.single['state'] = 'SUCCESS';
        case 'not-abortable':
          h.wire.jobs.single['abortable'] = false;
        case 'missing':
          h.wire.jobs.clear();
      }
      expect(
        (await h.repo.cancelActivityJob(job, job.confirmation)).outcome,
        JobCancelOutcome.rejected,
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('forged and reloaded handles cannot cancel', () async {
    final h = await _connect();
    final job = (await h.repo.loadActivityJobs(const JobQuery()))
        .entries
        .single;
    await h.repo.loadActivityJobs(const JobQuery());
    await expectLater(
      h.repo.cancelActivityJob(job, 'job 12'),
      throwsA(isA<ActivityException>()),
    );
    await expectLater(
      h.repo.cancelActivityJob(
        ActivityJob(
          id: 12,
          method: 'pool.scrub',
          state: ActivityJobState.running,
          abortable: true,
          startedAt: job.startedAt,
        ),
        'job 12',
      ),
      throwsA(isA<ActivityException>()),
    );
    expect(h.wire.writes, isEmpty);
  });
  for (final failure in ['timeout', 'error', 'bad-receipt', 'disappear']) {
    test('$failure after dispatch is unknown and locks writes', () async {
      final h = await _connect();
      h.wire.failure = failure;
      final job = (await h.repo.loadActivityJobs(const JobQuery()))
          .entries
          .single;
      final result = await h.repo.cancelActivityJob(job, job.confirmation);
      expect(result.outcome, JobCancelOutcome.unknown);
      expect(result.message, isNot(contains('secret-error')));
      await expectLater(
        h.repo.cancelActivityJob(job, job.confirmation),
        throwsA(isA<ActivityException>()),
      );
      expect(h.wire.writes.length, 1);
    });
  }
  test(
    'session replacement during preflight never sends cancellation',
    () async {
      final h = await _connect();
      final job = (await h.repo.loadActivityJobs(const JobQuery()))
          .entries
          .single;
      h.wire.onRead = () => h.current = false;
      expect(
        (await h.repo.cancelActivityJob(job, job.confirmation)).outcome,
        JobCancelOutcome.rejected,
      );
      expect(h.wire.writes, isEmpty);
    },
  );
  test('nonfinite progress or duplicate rows fail closed', () async {
    final h = await _connect();
    h.wire.jobs.single['progress'] = {'percent': 101};
    await expectLater(
      h.repo.loadActivityJobs(const JobQuery()),
      throwsA(isA<ActivityException>()),
    );
    h.wire.jobs = [_job(), _job()];
    await expectLater(
      h.repo.loadActivityJobs(const JobQuery()),
      throwsA(isA<ActivityException>()),
    );
  });
  test('audit filters are independently enforced on returned rows', () async {
    final h = await _connect();
    h.wire.events.single['service'] = 'SMB';
    await expectLater(
      h.repo.loadAuditEvents(_audit),
      throwsA(isA<ActivityException>()),
    );
    expect(h.wire.writes, isEmpty);
  });
}

Future<_Harness> _connect({
  String version = '25.10.1',
  Set<String> methods = _methods,
}) async {
  final h = _Harness(version: version, methods: methods);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://fixture.invalid',
    apiKey: 'fake-key',
    username: 'admin',
    isConnectionCurrent: () => h.current,
  );
  return h;
}

class _Harness {
  _Harness({String version = '25.10.1', Set<String> methods = _methods}) {
    wire = _Wire(version, methods);
    repo = TrueNasSessionRepository(
      connector: _Connector(wire),
      managementRequestTimeout: const Duration(milliseconds: 30),
    );
  }
  bool current = true;
  late final _Wire wire;
  late final TrueNasSessionRepository repo;
}

class _Connector implements RpcConnector {
  _Connector(this.wire);
  final RpcTransport wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class _Wire implements RpcTransport {
  _Wire(this.version, this.methods);
  final String version;
  final Set<String> methods;
  final inbound = StreamController<String>();
  final requests = <Map<String, Object?>>[];
  List<Map<String, Object?>> jobs = [_job()], events = [_event()];
  String cancelState = 'ABORTED';
  String? failure;
  void Function()? onRead;
  Iterable<Map<String, Object?>> get activity =>
      requests.where((r) => _methods.contains(r['method']));
  Iterable<Map<String, Object?>> get writes =>
      requests.where((r) => r['method'] == 'core.job_abort');
  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String frame) async {
    final request = Map<String, Object?>.from(jsonDecode(frame) as Map);
    requests.add(request);
    final params = request['params'] as List? ?? [];
    Object? result;
    switch (request['method']) {
      case 'auth.login_ex':
        result = {'response_type': 'SUCCESS'};
      case 'auth.me':
        result = {'username': 'admin'};
      case 'system.info':
        result = {'version': version};
      case 'core.get_methods':
        result = {
          for (final method in methods)
            method: {'accepts': [], 'returns': [], 'job': false},
        };
      case 'core.get_jobs':
        onRead?.call();
        var rows = jobs.toList();
        for (final filter in params.first as List) {
          rows = rows.where((row) => row[filter[0]] == filter[2]).toList();
        }
        final options = params.last as Map;
        result = rows
            .skip(options['offset'] as int? ?? 0)
            .take(options['limit'] as int)
            .toList();
      case 'audit.query':
        result = events;
      case 'core.job_abort':
        if (failure == 'timeout') return;
        if (failure == 'error') {
          inbound.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': request['id'],
              'error': {'code': -32001, 'message': 'secret-error'},
            }),
          );
          return;
        }
        jobs.single['state'] = cancelState;
        if (failure == 'disappear') jobs.clear();
        if (failure == 'bad-receipt') result = true;
    }
    inbound.add(
      jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() => inbound.close();
}
