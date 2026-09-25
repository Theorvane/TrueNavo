import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

import 'init_shutdown_tasks_fixtures.dart';

void main() {
  test(
    'inventory headers never load bodies paths comments or subscribe',
    () async {
      final h = await istConnected(), i = await h.repo.loadInitShutdownTasks();
      expect(i.tasks, hasLength(3));
      expect(i.tasks.last.blockedReason, contains('SCRIPT'));
      expect(
        h.wire.calls.where((c) => c['method'] == 'initshutdownscript.query'),
        everyElement(
          predicate<Map>((c) => (c['params'] as List).first.isEmpty),
        ),
      );
      expect(i.toString(), isNot(contains(istSecret)));
      expect(
        h.wire.calls.where(
          (c) =>
              istWrites.contains(c['method']) ||
              c['method'] == 'core.subscribe',
        ),
        isEmpty,
      );
    },
  );
  for (final action in InitShutdownTasksAction.values) {
    for (final phase
        in action == InitShutdownTasksAction.create ||
                action == InitShutdownTasksAction.replace
            ? InitShutdownTaskPhase.values
            : [InitShutdownTaskPhase.postinit]) {
      test(
        '${action.name} ${phase.name} minimal exact payload, readback and disposal',
        () async {
          final h = await istConnected(),
              r = await istReview(h, action, phase: phase),
              command = r.request.command;
          expect(r.commandReference, matches(RegExp(r'^[0-9a-f]{64}$')));
          expect(r.commandReference, isNot(contains(istSecret)));
          expect(r.warnings.join(' '), contains('wait budget'));
          expect(r.target, contains(istHost));
          expect(command?.isDisposed, isNot(true));
          final result = await istExecute(h, r);
          expect(result.outcome, InitShutdownTasksOutcome.completed);
          if (command != null) expect(command.isDisposed, true);
          final call = h.wire.calls.singleWhere(
                (c) => istWrites.contains(c['method']),
              ),
              params = call['params'] as List;
          switch (action) {
            case InitShutdownTasksAction.create:
              expect(params, [
                {
                  'type': 'COMMAND',
                  'command': '$istBody replaced',
                  'script': '',
                  'comment': '',
                  'when': phase.wireName,
                  'enabled': false,
                  'timeout': 20,
                },
              ]);
            case InitShutdownTasksAction.replace:
              expect(params, [
                1,
                {
                  'command': '$istBody replaced',
                  'when': phase.wireName,
                  'timeout': 20,
                },
              ]);
              expect(
                h.wire.rows.singleWhere((t) => t['id'] == 1)['comment'],
                contains(istSecret),
              );
            case InitShutdownTasksAction.enable:
              expect(params, [
                1,
                {'enabled': true},
              ]);
            case InitShutdownTasksAction.disable:
              expect(params, [
                2,
                {'enabled': false},
              ]);
            case InitShutdownTasksAction.delete:
              expect(params, [1]);
          }
          expect(
            (await istExecute(h, r)).outcome,
            InitShutdownTasksOutcome.rejected,
          );
          expect(
            h.wire.calls.where((c) => istWrites.contains(c['method'])),
            hasLength(1),
          );
          expect(
            h.wire.calls.where(
              (c) =>
                  c['method'] == 'initshutdownscript.execute_init_tasks' ||
                  c['method'] == 'service.control' ||
                  c['method'] == 'filesystem.stat',
            ),
            isEmpty,
          );
        },
      );
    }
    test(
      '${action.name} wrong typed target consumes review and command',
      () async {
        final h = await istConnected(), r = await istReview(h, action);
        expect(
          (await istExecute(h, r, target: '${r.target} ')).outcome,
          InitShutdownTasksOutcome.rejected,
        );
        expect(
          (await istExecute(h, r)).outcome,
          InitShutdownTasksOutcome.rejected,
        );
        expect(r.request.command?.isDisposed, isNot(false));
        expect(
          h.wire.calls.where((c) => istWrites.contains(c['method'])),
          isEmpty,
        );
      },
    );
    for (final age in [-1, 6]) {
      test('${action.name} age $age rejected', () async {
        final h = await istConnected(), r = await istReview(h, action);
        h.now = h.now.add(Duration(minutes: age));
        expect(
          (await istExecute(h, r)).outcome,
          InitShutdownTasksOutcome.rejected,
        );
      });
    }
  }
  for (final value in [
    '',
    ' ',
    '\n',
    'echo\nnext',
    'café',
    '********',
    '[REDACTED]',
    '<hidden>',
    'a' * 301,
  ]) {
    test(
      'invalid command shape length ${value.length} rejected without body disclosure',
      () {
        final c = InitShutdownTaskCommand(value);
        expect(c.validationError, isNotNull);
        expect(
          c.toString(),
          isNot(contains(value.isEmpty ? 'impossible' : value)),
        );
        c.dispose();
        expect(c.isDisposed, true);
      },
    );
  }
  test('exact 300-byte command accepted but never publicly readable', () {
    final c = InitShutdownTaskCommand('a' * 300);
    expect(c.validationError, isNull);
    expect(c.toString(), 'InitShutdownTaskCommand(redacted)');
    c.dispose();
    expect(c.validationError, isNotNull);
  });
  for (final timeout in [-1, 0, 301, 100000]) {
    test('app wait-budget bound $timeout', () {
      expect(
        InitShutdownTaskSettings(
          phase: InitShutdownTaskPhase.shutdown,
          timeoutSeconds: timeout,
        ).validationError,
        isNotNull,
      );
    });
  }
  for (final action in [
    InitShutdownTasksAction.replace,
    InitShutdownTasksAction.delete,
  ]) {
    test('${action.name} cannot implicitly disable', () async {
      final h = await istConnected(), i = await h.repo.loadInitShutdownTasks();
      final r = istRequest(i, action, task: i.tasks[1]);
      expect(r.validationError, isNotNull);
      await expectLater(
        h.repo.reviewInitShutdownTasks(r),
        throwsA(isA<InitShutdownTasksException>()),
      );
      r.command?.dispose();
    });
  }
  for (final action in InitShutdownTasksAction.values.where(
    (a) => a != InitShutdownTasksAction.create,
  )) {
    test('${action.name} SCRIPT always protected', () async {
      final h = await istConnected(), i = await h.repo.loadInitShutdownTasks();
      final r = istRequest(i, action, task: i.tasks.last);
      expect(r.validationError, isNotNull);
      await expectLater(
        h.repo.reviewInitShutdownTasks(r),
        throwsA(isA<InitShutdownTasksException>()),
      );
      expect(
        h.wire.calls.where(
          (c) =>
              c['method'] == 'filesystem.stat' ||
              istWrites.contains(c['method']),
        ),
        isEmpty,
      );
    });
  }
  for (final field in [
    'command',
    'script',
    'comment',
    'type',
    'when',
    'timeout',
    'extra',
  ]) {
    test(
      'selected private $field malformed or protected fails closed',
      () async {
        final h = await istConnected(),
            i = await h.repo.loadInitShutdownTasks();
        h.wire.rows.first[field] = switch (field) {
          'command' => '********',
          'script' => '/mnt/protected/script',
          'comment' => null,
          'type' => 'SCRIPT',
          'when' => 'UNKNOWN',
          'timeout' => '10',
          _ => true,
        };
        if (field == 'extra') {
          h.wire.beforeReply = (method, _) {
            if (method == 'initshutdownscript.query' &&
                ((h.wire.calls.last['params'] as List).first as List)
                    .isNotEmpty) {
              h.wire.queryOverride = [
                Map<String, Object?>.from(h.wire.rows.first),
              ];
            }
          };
        }
        final request = istRequest(i, InitShutdownTasksAction.replace);
        await expectLater(
          h.repo.reviewInitShutdownTasks(request),
          throwsA(isA<InitShutdownTasksException>()),
        );
        expect(request.command!.isDisposed, true);
        expect(
          h.wire.calls.where((c) => istWrites.contains(c['method'])),
          isEmpty,
        );
      },
    );
  }
  for (final method in istReads) {
    test('missing $method unavailable without reads', () async {
      final h = await istConnected(configure: (w) => w.methods.remove(method));
      expect(h.repo.initShutdownTasksCapabilities.supported, false);
      final count = h.wire.calls.length;
      await expectLater(
        h.repo.loadInitShutdownTasks(),
        throwsA(isA<InitShutdownTasksException>()),
      );
      expect(h.wire.calls.length, count);
    });
  }
  for (final method in istWrites) {
    for (final key in [
      'job',
      'uploadable',
      'downloadable',
      'no_auth_required',
      'private',
      'check_pipes',
    ]) {
      test('unsafe $method metadata $key', () async {
        final h = await istConnected(
          configure: (w) => w.metadata[method] = {key: true},
        );
        final caps = h.repo.initShutdownTasksCapabilities;
        expect(switch (method) {
          'initshutdownscript.create' => caps.canCreate,
          'initshutdownscript.delete' => caps.canDelete,
          _ => caps.canUpdate,
        }, false);
      });
    }
  }
  for (final gate in ['ha', 'role', 'state', 'jobs', 'boot', 'nextboot']) {
    test('$gate readonly admission', () async {
      final h = await istConnected(
        configure: (w) {
          switch (gate) {
            case 'ha':
              w.values['failover.licensed'] = true;
            case 'role':
              w.values['auth.me'] = {
                'privilege': {'roles': []},
              };
            case 'state':
              w.values['system.state'] = 'BOOTING';
            case 'jobs':
              w.values['core.get_jobs'] = [
                {
                  'id': 1,
                  'method': 'initshutdownscript.execute_init_tasks',
                  'state': 'RUNNING',
                },
              ];
            case 'boot':
              (w.values['boot.get_state'] as Map)['healthy'] = false;
            case 'nextboot':
              w.values['boot.environment.query'] = [
                {...istEnvironment(), 'activated': false},
                {
                  ...istEnvironment(),
                  'id': 'other',
                  'dataset': 'boot-pool/ROOT/other',
                  'active': false,
                },
              ];
          }
        },
      );
      final i = await h.repo.loadInitShutdownTasks();
      expect(i.blockedReason, isNotNull);
      await expectLater(
        h.repo.reviewInitShutdownTasks(
          istRequest(i, InitShutdownTasksAction.create),
        ),
        throwsA(isA<InitShutdownTasksException>()),
      );
    });
  }
  for (final version in [
    '25.04.2',
    '26.04.0',
    '25.10.1-MASTER',
    '25.10.1-RC.1',
  ]) {
    test('unsupported version $version', () async {
      final h = await istConnected(configure: (w) => w.version = version);
      expect(h.repo.initShutdownTasksCapabilities.supported, false);
      await expectLater(
        h.repo.loadInitShutdownTasks(),
        throwsA(isA<InitShutdownTasksException>()),
      );
    });
  }
  for (final cause in [
    'body',
    'comment',
    'emptytonull',
    'phase',
    'enabled',
    'host',
    'boot',
    'role',
    'otherheader',
  ]) {
    test('preflight drift $cause consumes without dispatch', () async {
      final h = await istConnected(),
          r = await istReview(h, InitShutdownTasksAction.replace);
      switch (cause) {
        case 'body':
          h.wire.rows.first['command'] = '$istBody changed';
        case 'comment':
          h.wire.rows.first['comment'] = 'changed';
        case 'emptytonull':
          h.wire.rows.first['script'] = null;
        case 'phase':
          h.wire.rows.first['when'] = 'SHUTDOWN';
        case 'enabled':
          h.wire.rows.first['enabled'] = true;
        case 'host':
          h.wire.values['system.host_id'] = 'f' * 64;
        case 'boot':
          (h.wire.values['system.reboot.info'] as Map)['boot_id'] =
              'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
        case 'role':
          h.wire.values['auth.me'] = {
            'privilege': {'roles': []},
          };
        case 'otherheader':
          h.wire.rows[2]['timeout'] = 11;
      }
      expect(
        (await istExecute(h, r)).outcome,
        InitShutdownTasksOutcome.rejected,
      );
      expect(r.request.command!.isDisposed, true);
      expect(
        h.wire.calls.where((c) => istWrites.contains(c['method'])),
        isEmpty,
      );
    });
  }
  for (final action in InitShutdownTasksAction.values) {
    for (final failure in ['rpc', 'receipt', 'readback', 'latecontext']) {
      test('${action.name} postdispatch $failure terminal no replay', () async {
        final h = await istConnected(), r = await istReview(h, action);
        final method = switch (action) {
          InitShutdownTasksAction.create => 'initshutdownscript.create',
          InitShutdownTasksAction.delete => 'initshutdownscript.delete',
          _ => 'initshutdownscript.update',
        };
        switch (failure) {
          case 'rpc':
            h.wire.fault = method;
          case 'receipt':
            h.wire.overrideReceipt = true;
            h.wire.receipt = false;
          case 'readback':
            h.wire.afterWrite = () => h.wire.rows.last['timeout'] = 99;
          case 'latecontext':
            h.wire.afterWrite = () => h.authorized = false;
        }
        expect(
          (await istExecute(h, r)).outcome,
          InitShutdownTasksOutcome.unknown,
        );
        expect(r.request.command?.isDisposed, isNot(false));
        final count = h.wire.calls.length;
        expect(
          (await istExecute(h, r)).outcome,
          InitShutdownTasksOutcome.rejected,
        );
        await expectLater(
          h.repo.loadInitShutdownTasks(),
          throwsA(isA<InitShutdownTasksException>()),
        );
        expect(h.wire.calls.length, count);
      });
    }
  }
  test('timeout after frame is unknown and does not retry', () async {
    final h = await istConnected(),
        r = await istReview(h, InitShutdownTasksAction.create);
    h.wire.hold = 'initshutdownscript.create';
    h.wire.held = Completer<void>();
    final result = await istExecute(h, r);
    expect(result.outcome, InitShutdownTasksOutcome.unknown);
    h.wire.held!.complete();
    await Future<void>.delayed(Duration.zero);
    expect(
      h.wire.calls.where((c) => istWrites.contains(c['method'])),
      hasLength(1),
    );
  });
  test('capsule disposal during held preflight rejects even if caller current true', () async {
    final h = await istConnected(),
        r = await istReview(h, InitShutdownTasksAction.create);
    h.wire.hold = 'auth.me';
    h.wire.held = Completer<void>();
    final future = istExecute(h, r);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    r.request.command!.dispose();
    h.wire.held!.complete();
    expect((await future).outcome, InitShutdownTasksOutcome.rejected);
    expect(h.wire.calls.where((c) => istWrites.contains(c['method'])), isEmpty);
  });
  test('reload disposes issued command and expires review', () async {
    final h = await istConnected(),
        r = await istReview(h, InitShutdownTasksAction.create);
    await h.repo.loadInitShutdownTasks();
    expect(r.request.command!.isDisposed, true);
    expect((await istExecute(h, r)).outcome, InitShutdownTasksOutcome.rejected);
  });
  test('close disposes issued command without additional frames', () async {
    final h = await istConnected(),
        r = await istReview(h, InitShutdownTasksAction.create);
    await h.repo.close();
    expect(r.request.command!.isDisposed, true);
  });
  test('no-op private replacement rejected and secret disposed', () async {
    final h = await istConnected(),
        i = await h.repo.loadInitShutdownTasks(),
        command = InitShutdownTaskCommand(istBody);
    final request = istRequest(
      i,
      InitShutdownTasksAction.replace,
      command: command,
      timeout: 10,
    );
    await expectLater(
      h.repo.reviewInitShutdownTasks(request),
      throwsA(isA<InitShutdownTasksException>()),
    );
    expect(command.isDisposed, true);
  });
  test('forged and reloaded inventory cannot mint review', () async {
    final h = await istConnected(), i = await h.repo.loadInitShutdownTasks();
    await h.repo.loadInitShutdownTasks();
    final command = InitShutdownTaskCommand(istBody);
    await expectLater(
      h.repo.reviewInitShutdownTasks(
        istRequest(i, InitShutdownTasksAction.create, command: command),
      ),
      throwsA(isA<InitShutdownTasksException>()),
    );
    expect(command.isDisposed, true);
  });
  test(
    'header query smuggling raw command fails instead of exposing it',
    () async {
      final h = await istConnected(
        configure: (w) => w.queryOverride = [istRow()],
      );
      await expectLater(
        h.repo.loadInitShutdownTasks(),
        throwsA(isA<InitShutdownTasksException>()),
      );
    },
  );
  test('error text and review string never contain command secret', () async {
    final h = await istConnected(),
        r = await istReview(h, InitShutdownTasksAction.create);
    expect(
      jsonEncode([
        r.toString(),
        r.request.toString(),
        r.request.command.toString(),
        r.warnings,
        r.commandReference,
      ]),
      isNot(contains(istSecret)),
    );
    h.wire.fault = 'auth.me';
    final result = await istExecute(h, r);
    expect(result.message, isNot(contains(istSecret)));
  });
}
