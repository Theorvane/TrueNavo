import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

import 'init_shutdown_tasks_fixtures.dart' as f;
import 'session_cron_tasks_test.dart' as cron;

const _forbidden = {
  'initshutdownscript.execute_init_tasks',
  'initshutdownscript.execute_task',
  'initshutdownscript.get_cmd',
  'filesystem.stat',
  'filesystem.get',
  'filesystem.setperm',
  'core.job_abort',
  'core.job_download_logs',
  'core.subscribe',
  'cronjob.run',
  'system.reboot',
  'system.shutdown',
  'service.control',
};

List<Map<String, dynamic>> _writes(f.InitShutdownHarness h) =>
    h.wire.calls.where((c) => f.istWrites.contains(c['method'])).toList();

void _noEffects(f.InitShutdownHarness h) {
  expect(
    h.wire.calls.map((c) => c['method']).toSet().intersection(_forbidden),
    isEmpty,
  );
}

Matcher _privateException() => isA<InitShutdownTasksException>().having(
  (e) => e.toString(),
  'sanitized reason',
  isNot(contains(f.istSecret)),
);

void main() {
  for (final receipt in [null, 73]) {
    test(
      'existing service-control ${receipt == null ? 'unknown' : 'owned pending job'} fences both new task workspaces',
      () async {
        final h = await f.istConnected(
          configure: (w) {
            w.methods.addAll({
              ...cron.reads,
              'cronjob.create',
              'cronjob.update',
              'cronjob.delete',
              'service.control',
            });
            w.values['service.control'] = receipt;
          },
        );
        expect(h.repo.cronTasksCapabilities.supported, isTrue);
        expect(h.repo.initShutdownTasksCapabilities.supported, isTrue);
        final sent = Completer<void>();
        h.wire
          ..hold = 'service.control'
          ..held = Completer<void>()
          ..beforeReply = (method, _) {
            if (method == 'service.control') sent.complete();
          };
        // This is only the in-memory synthetic transport, not a service call to
        // any machine. The reverse fence must work for pre-existing workflows.
        final pending = h.repo.execute(
          const ServiceControlCommand(
            service: 'nfs',
            action: ServiceControlAction.restart,
          ),
        );
        await sent.future;
        Future<void> peersBlocked() async {
          final count = h.wire.calls.length;
          await expectLater(
            h.repo.loadCronTasks(),
            throwsA(isA<CronTasksException>()),
          );
          await expectLater(
            h.repo.loadInitShutdownTasks(),
            throwsA(_privateException()),
          );
          expect(h.wire.calls.length, count);
        }

        await peersBlocked();
        h.wire.held!.complete();
        final result = await pending;
        expect(
          result,
          receipt == null
              ? isA<ManagementOutcomeUnknown>()
              : isA<ManagementJobSubmitted>(),
        );
        await peersBlocked();
        expect(_writes(h), isEmpty);
        expect(
          h.wire.calls.where((c) => c['method'] == 'service.control'),
          hasLength(1),
        );
        expect(
          h.wire.calls.where((c) => c['method'] == 'core.get_jobs'),
          isEmpty,
        );
        expect(
          h.wire.calls.where((c) => '${c['method']}'.startsWith('cronjob.')),
          isEmpty,
        );
      },
    );
  }

  test(
    'all-family inventory excludes command, script and free-form comments',
    () async {
      final h = await f.istConnected();
      final inventory = await h.repo.loadInitShutdownTasks();
      expect(inventory.tasks, hasLength(3));
      expect(
        inventory.tasks.singleWhere((t) => !t.isCommand).blockedReason,
        isNotNull,
      );
      expect(() => inventory.tasks.clear(), throwsUnsupportedError);
      final reads = h.wire.calls.where(
        (c) => c['method'] == 'initshutdownscript.query',
      );
      expect(reads, hasLength(1));
      expect(reads.single['params'], [
        [],
        {
          'limit': 129,
          'select': ['id', 'type', 'when', 'enabled', 'timeout'],
        },
      ]);
      expect(inventory.tasks.toString(), isNot(contains(f.istSecret)));
      expect(inventory.readiness.toString(), isNot(contains(f.istSecret)));
      expect(_writes(h), isEmpty);
      _noEffects(h);
    },
  );

  test(
    'selected private proof never requests SCRIPT or unrelated command rows',
    () async {
      final h = await f.istConnected();
      final review = await f.istReview(h, InitShutdownTasksAction.enable);
      final details = h.wire.calls.where((c) {
        if (c['method'] != 'initshutdownscript.query') return false;
        return ((c['params'] as List).first as List).isNotEmpty;
      }).toList();
      expect(details, isNotEmpty);
      for (final call in details) {
        expect((call['params'] as List).first, [
          ['id', '=', 1],
          ['type', '=', 'COMMAND'],
        ]);
        expect((call['params'] as List)[1]['limit'], 2);
      }
      expect(review.commandReference, matches(RegExp(r'^[0-9a-f]{64}$')));
      expect(review.warnings.join(), isNot(contains(f.istSecret)));
      expect(review.target, isNot(contains(f.istSecret)));
      _noEffects(h);
    },
  );

  test(
    'command reference is session keyed instead of a reusable plaintext hash',
    () async {
      final first = await f.istConnected(), second = await f.istConnected();
      final a = await f.istReview(first, InitShutdownTasksAction.enable);
      final b = await f.istReview(second, InitShutdownTasksAction.enable);
      expect(a.commandReference, isNot(b.commandReference));
      expect(a.commandReference, isNot(contains(f.istSecret)));
      expect(_writes(first), isEmpty);
      expect(_writes(second), isEmpty);
    },
  );

  for (final script in [null, '']) {
    test(
      'replacement preserves ${script == null ? 'null' : 'empty'} script and private comment exactly',
      () async {
        final h = await f.istConnected(
          configure: (w) => w.rows.first['script'] = script,
        );
        final before = Map<String, Object?>.from(h.wire.rows.first);
        final review = await f.istReview(h, InitShutdownTasksAction.replace);
        final result = await f.istExecute(h, review);
        expect(
          result.outcome,
          InitShutdownTasksOutcome.completed,
          reason: result.message,
        );
        expect(_writes(h).single['params'], [
          1,
          {
            'command': '${f.istBody} replaced',
            'when': 'POSTINIT',
            'timeout': 20,
          },
        ]);
        final after = h.wire.rows.singleWhere((r) => r['id'] == 1);
        for (final key in ['type', 'script', 'comment', 'enabled']) {
          expect(after[key], before[key], reason: key);
        }
        expect(review.request.command!.isDisposed, isTrue);
        expect(result.message, isNot(contains(f.istSecret)));
        _noEffects(h);
      },
    );
  }

  test(
    'enable submits only boolean and retains command/comment without replay',
    () async {
      final h = await f.istConnected();
      final before = Map<String, Object?>.from(h.wire.rows.first);
      final review = await f.istReview(h, InitShutdownTasksAction.enable);
      final result = await f.istExecute(h, review);
      expect(
        result.outcome,
        InitShutdownTasksOutcome.completed,
        reason: result.message,
      );
      expect(_writes(h).single['params'], [
        1,
        {'enabled': true},
      ]);
      expect(h.wire.rows.singleWhere((r) => r['id'] == 1), {
        ...before,
        'enabled': true,
      });
      expect(
        (await f.istExecute(h, review)).outcome,
        InitShutdownTasksOutcome.rejected,
      );
      expect(_writes(h), hasLength(1));
      expect(review.warnings.join(), contains('root privileges'));
      expect(review.warnings.join(), contains('does not reliably terminate'));
      expect(review.warnings.join(), contains('does not cancel'));
      expect(result.message, contains('remain unverified'));
      _noEffects(h);
    },
  );

  for (final action in [
    InitShutdownTasksAction.disable,
    InitShutdownTasksAction.delete,
  ]) {
    test(
      'legacy oversized wait and non-ASCII command may $action without being repaired',
      () async {
        final h = await f.istConnected(
          configure: (w) {
            w.rows.first
              ..['enabled'] = action == InitShutdownTasksAction.disable
              ..['timeout'] = -1
              ..['command'] = 'printf 한글';
          },
        );
        final i = await h.repo.loadInitShutdownTasks();
        final request = f.istRequest(i, action, task: i.tasks.first);
        final review = await h.repo.reviewInitShutdownTasks(request);
        final result = await f.istExecute(h, review);
        expect(
          result.outcome,
          InitShutdownTasksOutcome.completed,
          reason: result.message,
        );
        expect(
          _writes(h).single['params'],
          action == InitShutdownTasksAction.disable
              ? [
                  1,
                  {'enabled': false},
                ]
              : [1],
        );
        _noEffects(h);
      },
    );
  }

  for (final field in ['command', 'script', 'comment']) {
    test('private $field drift after review blocks before dispatch', () async {
      final h = await f.istConnected();
      final review = await f.istReview(h, InitShutdownTasksAction.enable);
      h.wire.rows.first[field] = 'CHANGED_${f.istSecret}';
      final result = await f.istExecute(h, review);
      expect(
        result.outcome,
        InitShutdownTasksOutcome.rejected,
        reason: result.message,
      );
      expect(result.message, isNot(contains(f.istSecret)));
      expect(_writes(h), isEmpty);
      _noEffects(h);
    });
  }

  for (final field in ['command', 'script', 'comment']) {
    test(
      'post-dispatch private $field drift becomes unknown, not rollback',
      () async {
        final h = await f.istConnected();
        final review = await f.istReview(h, InitShutdownTasksAction.disable);
        h.wire.afterWrite = () {
          h.wire.rows.singleWhere((r) => r['id'] == 2)[field] =
              'CHANGED_${f.istSecret}';
        };
        final result = await f.istExecute(h, review);
        expect(
          result.outcome,
          InitShutdownTasksOutcome.unknown,
          reason: result.message,
        );
        expect(result.message, isNot(contains(f.istSecret)));
        final count = h.wire.calls.length;
        await expectLater(
          h.repo.loadInitShutdownTasks(),
          throwsA(_privateException()),
        );
        expect(
          (await f.istExecute(h, review)).outcome,
          InitShutdownTasksOutcome.rejected,
        );
        expect(h.wire.calls.length, count);
        expect(_writes(h), hasLength(1));
        _noEffects(h);
      },
    );
  }

  test(
    'COMMAND-to-SCRIPT race never fetches or overwrites the new script',
    () async {
      final h = await f.istConnected();
      final i = await h.repo.loadInitShutdownTasks();
      h.wire.beforeReply = (method, _) {
        if (method == 'initshutdownscript.query' &&
            ((h.wire.calls.last['params'] as List).first as List).isNotEmpty) {
          h.wire.rows.first['type'] = 'SCRIPT';
          h.wire.rows.first['script'] = '/mnt/${f.istSecret}';
        }
      };
      await expectLater(
        h.repo.reviewInitShutdownTasks(
          f.istRequest(i, InitShutdownTasksAction.enable),
        ),
        throwsA(_privateException()),
      );
      expect(_writes(h), isEmpty);
      _noEffects(h);
    },
  );

  for (final method in ['auth.me', 'initshutdownscript.query']) {
    test(
      'disposing command during $method with current true expires preflight',
      () async {
        final h = await f.istConnected();
        final review = await f.istReview(h, InitShutdownTasksAction.replace);
        h.wire.beforeReply = (m, _) {
          if (m == method) review.request.command!.dispose();
        };
        final result = await h.repo.executeInitShutdownTasks(
          review,
          review.target,
          isCurrent: () => true,
        );
        expect(
          result.outcome,
          InitShutdownTasksOutcome.rejected,
          reason: result.message,
        );
        expect(review.request.command!.isDisposed, isTrue);
        expect(_writes(h), isEmpty);
        _noEffects(h);
      },
    );
  }

  test('pending then unknown init change fences cron and service controls with zero peer calls', () async {
    final h = await f.istConnected(
      configure: (w) {
        w.methods.addAll({
          ...cron.reads,
          'cronjob.create',
          'cronjob.update',
          'cronjob.delete',
          'service.control',
        });
      },
    );
    expect(h.repo.cronTasksCapabilities.supported, isTrue);
    final review = await f.istReview(h, InitShutdownTasksAction.disable);
    final sent = Completer<void>();
    h.wire
      ..hold = 'initshutdownscript.update'
      ..held = Completer<void>()
      ..overrideReceipt = true
      ..beforeReply = (method, _) {
        if (method == 'initshutdownscript.update') sent.complete();
      };
    final pending = f.istExecute(h, review);
    await sent.future;
    Future<void> peersBlocked() async {
      final count = h.wire.calls.length;
      await expectLater(
        h.repo.loadCronTasks(),
        throwsA(isA<CronTasksException>()),
      );
      await expectLater(
        h.repo.execute(
          const ServiceControlCommand(
            service: 'nfs',
            action: ServiceControlAction.start,
          ),
        ),
        throwsA(isA<ManagementException>()),
      );
      expect(h.wire.calls.length, count);
    }

    await peersBlocked();
    h.wire.held!.complete();
    final result = await pending;
    expect(
      result.outcome,
      InitShutdownTasksOutcome.unknown,
      reason: result.message,
    );
    await peersBlocked();
    expect(
      (await f.istExecute(h, review)).outcome,
      InitShutdownTasksOutcome.rejected,
    );
    expect(_writes(h), hasLength(1));
    _noEffects(h);
  });

  test(
    'schema surprises in selected row are not echoed into public failures',
    () async {
      final h = await f.istConnected();
      final i = await h.repo.loadInitShutdownTasks();
      h.wire.beforeReply = (method, _) {
        if (method == 'initshutdownscript.query' &&
            ((h.wire.calls.last['params'] as List).first as List).isNotEmpty) {
          h.wire.queryOverride = [
            {
              ...f.istRow(),
              'unexpected': {'token': f.istSecret},
            },
          ];
        }
      };
      await expectLater(
        h.repo.reviewInitShutdownTasks(
          f.istRequest(i, InitShutdownTasksAction.enable),
        ),
        throwsA(_privateException()),
      );
      expect(jsonEncode(_writes(h)), isNot(contains(f.istSecret)));
      expect(_writes(h), isEmpty);
      _noEffects(h);
    },
  );
}
