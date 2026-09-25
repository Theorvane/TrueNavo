import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const host = '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef';
const boot = '11111111-2222-4333-8444-555555555555';
const secret = 'SYNTHETIC_COMMAND_SECRET';
const reads = {
  'system.version_short',
  'system.host_id',
  'system.reboot.info',
  'system.state',
  'failover.licensed',
  'boot.get_state',
  'boot.environment.query',
  'core.get_jobs',
  'auth.me',
  'system.info',
  'directoryservices.config',
  'user.query',
  'cronjob.query',
};
Map<String, Object?> cronRow({
  int id = 1,
  bool enabled = false,
  String command = secret,
}) => {
  'id': id,
  'enabled': enabled,
  'description': 'Maintenance',
  'user': 'root',
  'schedule': {
    'minute': '0',
    'hour': '2',
    'dom': '*',
    'month': '*',
    'dow': '*',
  },
  'stdout': true,
  'stderr': true,
  'command': command,
};

class CronWire implements RpcTransport {
  final inbound = StreamController<String>(), calls = <Map<String, dynamic>>[];
  final methods = <String>{
        ...reads,
        'cronjob.create',
        'cronjob.update',
        'cronjob.run',
        'cronjob.delete',
      },
      metadata = <String, Map<String, Object?>>{
        'cronjob.run': {'job': true},
      },
      counts = <String, int>{};
  final values = <String, Object?>{
    'system.version_short': '25.10.1',
    'system.host_id': host,
    'system.reboot.info': {'boot_id': boot, 'reboot_required_reasons': []},
    'system.state': 'READY',
    'failover.licensed': false,
    'boot.get_state': {
      'name': 'boot-pool',
      'healthy': true,
      'status': 'ONLINE',
      'scan': null,
    },
    'boot.environment.query': [
      {
        'id': '25.10.1',
        'dataset': 'boot-pool/ROOT/25.10.1',
        'created': '2026-09-14T01:00:00',
        'used_bytes': 4000,
        'active': true,
        'activated': true,
        'keep': true,
        'can_activate': true,
      },
    ],
    'core.get_jobs': <Object?>[],
    'auth.me': {
      'privilege': {
        'roles': ['FULL_ADMIN'],
      },
      'private': secret,
    },
    'directoryservices.config': <String, Object?>{
      'enable': false,
      'service_type': null,
      'credential': null,
      'configuration': null,
      'kerberos_realm': null,
    },
    'user.query': <Object?>[
      <String, Object?>{
        'id': 1,
        'uid': 0,
        'username': 'root',
        'local': true,
        'locked': false,
      },
      <String, Object?>{
        'id': 2,
        'uid': 1000,
        'username': 'worker',
        'local': true,
        'locked': false,
      },
    ],
  };
  Object? rows = <Object?>[
    cronRow(),
    cronRow(id: 2, enabled: true, command: 'OTHER_HIDDEN_COMMAND'),
  ];
  String version = '25.10.1', timezone = 'Etc/UTC';
  bool current = true, mutate = true, overrideReceipt = false;
  Object? receipt;
  String? fault, hold, throwMethod;
  Completer<void>? held;
  void Function(String, int)? beforeReply;
  void Function()? afterWrite;
  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String frame) async {
    final call = jsonDecode(frame) as Map<String, dynamic>;
    calls.add(call);
    final method = call['method'] as String;
    counts[method] = (counts[method] ?? 0) + 1;
    beforeReply?.call(method, counts[method]!);
    if (method == hold) await held!.future;
    if (method == throwMethod) throw StateError(secret);
    if (method == fault) {
      if (!inbound.isClosed) {
        inbound.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': call['id'],
            'error': {'code': -32000, 'message': secret},
          }),
        );
      }
      return;
    }
    Object? value;
    final params = (call['params'] as List?) ?? const [];
    if (method == 'cronjob.query') {
      final options = params[1] as Map;
      if (options['get'] == true) {
        final id = ((params.first as List).single as List)[2];
        value = (rows as List)
            .cast<Map>()
            .where((r) => r['id'] == id)
            .firstOrNull;
      } else if (rows is List) {
        value = [
          for (final r in (rows as List))
            if (r is Map)
              {for (final k in options['select'] as List) k: r[k]}
            else
              r,
        ];
      } else {
        value = rows;
      }
    } else if ([
      'cronjob.create',
      'cronjob.update',
      'cronjob.delete',
    ].contains(method)) {
      final old = List<Map>.from(rows as List);
      if (method == 'cronjob.create') {
        value = {'id': 3, ...(params.single as Map)};
        if (mutate) rows = [...old, value];
      } else if (method == 'cronjob.update') {
        final id = params.first;
        value = {
          ...old.singleWhere((r) => r['id'] == id),
          ...(params[1] as Map),
        };
        if (mutate) {
          rows = [
            for (final r in old)
              if (r['id'] == id) value else r,
          ];
        }
      } else {
        value = true;
        if (mutate) {
          rows = [
            for (final r in old)
              if (r['id'] != params.first) r,
          ];
        }
      }
      afterWrite?.call();
      if (overrideReceipt) value = receipt;
    } else {
      value = switch (method) {
        'auth.login_ex' => {'response_type': 'SUCCESS'},
        'system.info' => {
          'version': version,
          'timezone': timezone,
          'license': {'private': secret},
        },
        'cronjob.run' => 7,
        'core.get_methods' => {
          for (final name in methods)
            name: {
              'job': false,
              'uploadable': false,
              'downloadable': false,
              'no_auth_required': false,
              'check_pipes': false,
              ...?metadata[name],
            },
        },
        _ => values[method],
      };
    }
    if (!inbound.isClosed) {
      inbound.add(
        jsonEncode({'jsonrpc': '2.0', 'id': call['id'], 'result': value}),
      );
    }
  }

  @override
  Future<void> close() async {
    if (!inbound.isClosed) await inbound.close();
  }
}

class _Connector implements RpcConnector {
  const _Connector(this.wire);
  final CronWire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class CronHarness {
  CronHarness(this.wire) {
    repo = TrueNasSessionRepository(
      connector: _Connector(wire),
      cronTasksNow: () => now,
      managementRequestTimeout: const Duration(milliseconds: 500),
    );
  }
  final CronWire wire;
  late final TrueNasSessionRepository repo;
  DateTime now = DateTime.utc(2026, 9, 14);
  bool authorized = true;
}

Future<CronHarness> connected({void Function(CronWire)? configure}) async {
  final w = CronWire();
  configure?.call(w);
  final h = CronHarness(w);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'synthetic',
    username: 'admin',
    isConnectionCurrent: () => w.current,
  );
  return h;
}

CronTaskSettings settings({
  String user = 'root',
  String description = 'Changed maintenance',
  CronTaskSchedule schedule = const CronTaskSchedule(),
  bool hideStdout = true,
  bool hideStderr = true,
}) => CronTaskSettings(
  user: user,
  description: description,
  schedule: schedule,
  hideStdout: hideStdout,
  hideStderr: hideStderr,
);
CronTasksRequest request(
  CronTasksInventory i, {
  CronTasksAction action = CronTasksAction.edit,
  CronTaskCommand? command,
  CronTaskSettings? after,
}) => CronTasksRequest(
  inventory: i,
  action: action,
  task: action == CronTasksAction.create
      ? null
      : i.tasks.firstWhere(
          (t) =>
              t.enabled ==
              (action == CronTasksAction.disable ||
                  action == CronTasksAction.run),
        ),
  settings: action == CronTasksAction.edit || action == CronTasksAction.create
      ? after ?? settings()
      : null,
  command: command,
);
Future<CronTasksReview> review(
  CronHarness h, {
  CronTasksAction action = CronTasksAction.edit,
  CronTaskCommand? command,
}) async {
  final i = await h.repo.loadCronTasks();
  return h.repo.reviewCronTasks(request(i, action: action, command: command));
}

Future<CronTasksResult> execute(
  CronHarness h,
  CronTasksReview r, {
  String? confirmation,
}) => h.repo.executeCronTasks(
  r,
  confirmation ?? r.target,
  isCurrent: () => h.authorized,
);
int writes(CronHarness h) => h.wire.calls
    .where(
      (c) => [
        'cronjob.create',
        'cronjob.update',
        'cronjob.run',
        'cronjob.delete',
      ].contains(c['method']),
    )
    .length;
void main() {
  for (final phase in [
    'invalid',
    'reviewError',
    'replacement',
    'reload',
    'close',
    'executeRejected',
    'executeCompleted',
    'executeUnknown',
  ]) {
    test('SDK owns and wipes command on $phase', () async {
      final h = await connected(),
          command = CronTaskCommand.fromText('printf private');
      addTearDown(command.dispose);
      final i = await h.repo.loadCronTasks();
      if (phase == 'invalid') {
        expect(
          h.repo.reviewCronTasks(
            CronTasksRequest(
              inventory: i,
              action: CronTasksAction.create,
              command: command,
            ),
          ),
          throwsA(isA<CronTasksException>()),
        );
        await Future<void>.delayed(Duration.zero);
        expect(command.isDisposed, isTrue);
        return;
      }
      if (phase == 'reviewError') {
        h.wire.fault = 'system.host_id';
        expect(
          h.repo.reviewCronTasks(request(i, command: command)),
          throwsA(isA<CronTasksException>()),
        );
        await Future<void>.delayed(Duration.zero);
        expect(command.isDisposed, isTrue);
        return;
      }
      final r = await h.repo.reviewCronTasks(request(i, command: command));
      expect(command.isDisposed, isFalse);
      switch (phase) {
        case 'replacement':
          await h.repo.reviewCronTasks(request(i));
        case 'reload':
          await h.repo.loadCronTasks();
        case 'close':
          await h.repo.close();
        case 'executeRejected':
          await execute(h, r, confirmation: 'wrong');
        case 'executeCompleted':
          await execute(h, r);
        case 'executeUnknown':
          h.wire.fault = 'cronjob.update';
          await execute(h, r);
      }
      expect(command.isDisposed, isTrue);
      expect(command.byteLength, 0);
    });
  }
  test(
    'busy duplicate does not erase current pending command ownership',
    () async {
      final h = await connected(),
          command = CronTaskCommand.fromText('printf private');
      addTearDown(command.dispose);
      final i = await h.repo.loadCronTasks(),
          req = request(i, command: command);
      h.wire.hold = 'cronjob.query';
      h.wire.held = Completer<void>();
      final pending = h.repo.reviewCronTasks(req);
      await Future<void>.delayed(Duration.zero);
      expect(h.repo.reviewCronTasks(req), throwsA(isA<CronTasksException>()));
      await Future<void>.delayed(Duration.zero);
      expect(command.isDisposed, isFalse);
      h.wire.held!.complete();
      await pending;
      expect(command.isDisposed, isFalse);
      await h.repo.close();
      expect(command.isDisposed, isTrue);
    },
  );
  test('postdispatch timeout is unknown once, not a retry', () async {
    final h = await connected();
    final r = await review(h);
    h.wire.hold = 'cronjob.update';
    h.wire.held = Completer<void>();
    final result = await execute(h, r);
    expect(result.outcome, CronTasksOutcome.unknown);
    expect(writes(h), 1);
    h.wire.held!.complete();
    expect(h.repo.loadCronTasks(), throwsA(isA<CronTasksException>()));
  });
  for (final action in CronTasksAction.values) {
    test('exact $action lifecycle and fresh saved readback', () async {
      final h = await connected(),
          command = action == CronTasksAction.create
              ? CronTaskCommand.fromText('printf synthetic')
              : null;
      addTearDown(() => command?.dispose());
      final r = await review(h, action: action, command: command);
      expect(writes(h), 0);
      expect((await execute(h, r)).outcome, CronTasksOutcome.completed);
      expect(writes(h), 1);
      final call = h.wire.calls.singleWhere(
        (c) => [
          'cronjob.create',
          'cronjob.update',
          'cronjob.delete',
          'cronjob.run',
        ].contains(c['method']),
      );
      switch (action) {
        case CronTasksAction.create:
          expect((call['params'] as List).single, {
            'enabled': false,
            'description': 'Changed maintenance',
            'user': 'root',
            'schedule': {
              'minute': '0',
              'hour': '2',
              'dom': '*',
              'month': '*',
              'dow': '*',
            },
            'stdout': true,
            'stderr': true,
            'command': 'printf synthetic',
          });
        case CronTasksAction.edit:
          expect(call['params'], [
            1,
            {'description': 'Changed maintenance'},
          ]);
        case CronTasksAction.enable:
          expect(call['params'], [
            1,
            {'enabled': true},
          ]);
        case CronTasksAction.disable:
          expect(call['params'], [
            2,
            {'enabled': false},
          ]);
        case CronTasksAction.delete:
          expect(call['params'], [1]);
        case CronTasksAction.run:
          expect(call['params'], [2, true]);
      }
      expect((await execute(h, r)).outcome, CronTasksOutcome.rejected);
      expect(writes(h), 1);
    });
  }
  test('load headers never fetch command or private account fields', () async {
    final h = await connected();
    final i = await h.repo.loadCronTasks();
    expect(i.blockedReason, isNull);
    expect(i.timezone, 'Etc/UTC');
    expect(() => i.tasks.clear(), throwsUnsupportedError);
    expect(() => i.users.clear(), throwsUnsupportedError);
    expect(
      h.wire.calls
          .where((c) => c['method'] == 'cronjob.query')
          .single['params'],
      [
        [],
        {
          'limit': 257,
          'select': [
            'id',
            'enabled',
            'description',
            'user',
            'schedule',
            'stdout',
            'stderr',
          ],
        },
      ],
    );
    expect(
      h.wire.calls.map((c) => c['method']),
      isNot(
        anyOf(
          contains('cronjob.run'),
          contains('directoryservices.status'),
          contains('user.get_user_obj'),
        ),
      ),
    );
  });
  test('write-only replacement capsule never exposes plaintext', () async {
    final h = await connected(),
        command = CronTaskCommand.fromText('printf NEW_SECRET');
    addTearDown(command.dispose);
    expect(command.toString(), isNot(contains('NEW_SECRET')));
    final r = await review(h, command: command);
    expect(r.warnings.join(), isNot(contains('NEW_SECRET')));
    expect((await execute(h, r)).outcome, CronTasksOutcome.completed);
    expect(
      (h.wire.calls.singleWhere(
            (c) => c['method'] == 'cronjob.update',
          )['params']
          as List)[1],
      {'description': 'Changed maintenance', 'command': 'printf NEW_SECRET'},
    );
  });
  for (final text in [
    '',
    ' ',
    'x\n',
    'x\r',
    'x\t',
    'x\u0000',
    'x\u007f',
    'x' * 4097,
    '한' * 1366,
  ]) {
    test('command rejects bound/control ${text.length}', () {
      expect(CronTaskCommand.validationErrorFor(text), isNotNull);
      expect(
        () => CronTaskCommand.fromText(text),
        throwsA(isA<CronTasksException>()),
      );
    });
  }
  test('command boundary and idempotent disposal', () {
    final c = CronTaskCommand.fromText('x' * 4096);
    expect(c.byteLength, 4096);
    expect(c.isDisposed, isFalse);
    c.dispose();
    c.dispose();
    expect(c.byteLength, 0);
    expect(c.isDisposed, isTrue);
  });
  for (final field in ['minute', 'hour', 'dom', 'month', 'dow']) {
    for (final value in [
      '*\n',
      '@daily',
      '*/0',
      '1/2',
      '999',
      '1 2',
      'mon',
      '1;id',
    ]) {
      test('schedule $field invalid ${jsonEncode(value)}', () {
        final s = CronTaskSchedule(
          minute: field == 'minute' ? value : '0',
          hour: field == 'hour' ? value : '2',
          dom: field == 'dom' ? value : '*',
          month: field == 'month' ? value : '*',
          dow: field == 'dow' ? value : '*',
        );
        expect(s.validationError, isNotNull);
      });
    }
  }
  for (final s in [
    const CronTaskSchedule(minute: '*/5'),
    const CronTaskSchedule(hour: '0-20/2'),
    const CronTaskSchedule(dom: '1,15'),
    const CronTaskSchedule(dow: '0,7'),
    const CronTaskSchedule(dom: '29', month: '2'),
  ]) {
    test('supported numeric schedule ${s.expression}', () {
      expect(s.validationError, isNull);
    });
  }
  for (final s in [
    const CronTaskSchedule(dom: '30', month: '2'),
    const CronTaskSchedule(dom: '1', dow: '1'),
  ]) {
    test('ambiguous/impossible schedule ${s.expression}', () {
      expect(s.validationError, isNotNull);
    });
  }
  for (final method in reads) {
    test('missing metadata $method gates all', () async {
      final h = await connected(configure: (w) => w.methods.remove(method));
      expect(h.repo.cronTasksCapabilities.supported, isFalse);
      expect(h.repo.loadCronTasks(), throwsA(isA<CronTasksException>()));
    });
  }
  for (final action in CronTasksAction.values) {
    for (final flag in [
      'job',
      'uploadable',
      'downloadable',
      'no_auth_required',
      'private',
    ]) {
      test('metadata $action $flag gate', () async {
        final name = action == CronTasksAction.create
            ? 'cronjob.create'
            : action == CronTasksAction.delete
            ? 'cronjob.delete'
            : action == CronTasksAction.run
            ? 'cronjob.run'
            : 'cronjob.update';
        final h = await connected(
          configure: (w) => w.metadata[name] = {
            flag: action == CronTasksAction.run && flag == 'job' ? false : true,
          },
        );
        expect(h.repo.cronTasksCapabilities.allows(action), isFalse);
      });
    }
  }
  for (final version in ['24.10.2', '25.04.1', '25.10-BETA.1', '26.04.0']) {
    test('stable version $version protected', () async {
      final h = await connected(configure: (w) => w.version = version);
      expect(h.repo.cronTasksCapabilities.supported, isFalse);
    });
  }
  for (final mode in [
    'command',
    'hidden',
    'description',
    'enabled',
    'schedule',
    'user',
    'stdout',
    'stderr',
  ]) {
    test('selected row $mode drift invalidates', () async {
      final h = await connected();
      final r = await review(h);
      final row = (h.wire.rows as List).first as Map;
      row[mode] = switch (mode) {
        'enabled' => true,
        'stdout' || 'stderr' => false,
        'schedule' => {
          'minute': '1',
          'hour': '2',
          'dom': '*',
          'month': '*',
          'dow': '*',
        },
        _ => 'CHANGED',
      };
      expect((await execute(h, r)).outcome, CronTasksOutcome.rejected);
      expect(writes(h), 0);
    });
  }
  for (final mode in ['timezone', 'uid', 'username', 'locked', 'directory']) {
    test('private dependencies $mode drift rejects', () async {
      final h = await connected();
      final r = await review(h);
      if (mode == 'timezone') {
        h.wire.timezone = 'Asia/Seoul';
      } else if (mode == 'directory') {
        (h.wire.values['directoryservices.config'] as Map)['hidden'] = secret;
      } else {
        ((h.wire.values['user.query'] as List).first
            as Map)[mode] = switch (mode) {
          'uid' => 123,
          'locked' => true,
          _ => 'renamed',
        };
      }
      expect((await execute(h, r)).outcome, CronTasksOutcome.rejected);
      expect(writes(h), 0);
    });
  }
  for (final phase in ['review', 'preflight']) {
    test('disposed command at late $phase prevents dispatch', () async {
      final h = await connected(),
          command = CronTaskCommand.fromText('printf new');
      addTearDown(command.dispose);
      if (phase == 'review') {
        final i = await h.repo.loadCronTasks();
        h.wire.beforeReply = (m, n) {
          if (m == 'cronjob.query') command.dispose();
        };
        expect(
          h.repo.reviewCronTasks(request(i, command: command)),
          throwsA(isA<CronTasksException>()),
        );
      } else {
        final r = await review(h, command: command);
        h.wire.beforeReply = (m, n) {
          if (m == 'cronjob.query') command.dispose();
        };
        expect((await execute(h, r)).outcome, CronTasksOutcome.rejected);
      }
      expect(writes(h), 0);
    });
  }
  for (final mode in ['age', 'route', 'session']) {
    test('late $mode final guards', () async {
      final h = await connected();
      final r = await review(h);
      h.wire.beforeReply = (m, n) {
        if (m == 'cronjob.query' &&
            (h.wire.calls.last['params'] as List)[1]['get'] == true) {
          if (mode == 'age') {
            h.now = h.now.add(const Duration(minutes: 6));
          } else if (mode == 'route') {
            h.authorized = false;
          } else {
            h.wire.current = false;
          }
        }
      };
      expect((await execute(h, r)).outcome, CronTasksOutcome.rejected);
      expect(writes(h), 0);
    });
  }
  for (final age in [-1, 301]) {
    test('lease age $age consumes', () async {
      final h = await connected();
      final r = await review(h);
      h.now = h.now.add(Duration(seconds: age));
      expect((await execute(h, r)).outcome, CronTasksOutcome.rejected);
      expect(writes(h), 0);
    });
  }
  for (final action in CronTasksAction.values.where(
    (v) => v != CronTasksAction.run,
  )) {
    for (final mode in ['rpc', 'transport', 'receipt', 'readback', 'route']) {
      test('$action dispatched $mode unknown and fenced', () async {
        final h = await connected(),
            command = action == CronTasksAction.create
                ? CronTaskCommand.fromText('printf new')
                : null;
        addTearDown(() => command?.dispose());
        final r = await review(h, action: action, command: command);
        final method = action == CronTasksAction.create
            ? 'cronjob.create'
            : action == CronTasksAction.delete
            ? 'cronjob.delete'
            : 'cronjob.update';
        switch (mode) {
          case 'rpc':
            h.wire.fault = method;
          case 'transport':
            h.wire.throwMethod = method;
          case 'receipt':
            h.wire.overrideReceipt = true;
          case 'readback':
            h.wire.mutate = false;
          case 'route':
            h.wire.afterWrite = () => h.authorized = false;
        }
        final result = await execute(h, r);
        expect(result.outcome, CronTasksOutcome.unknown);
        expect(result.message, isNot(contains(secret)));
        expect(h.repo.loadCronTasks(), throwsA(isA<CronTasksException>()));
        expect(writes(h), 1);
      });
    }
  }
  for (final method in reads) {
    test('read failure $method sanitized', () async {
      final h = await connected();
      h.wire.fault = method;
      expect(
        h.repo.loadCronTasks(),
        throwsA(
          isA<CronTasksException>().having(
            (e) => e.toString(),
            'message',
            isNot(contains(secret)),
          ),
        ),
      );
    });
  }
}
