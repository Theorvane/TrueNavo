import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

import 'init_shutdown_tasks_fixtures.dart' as ist;
import 'session_cron_tasks_test.dart' as f;

const _forbidden = {
  'cronjob.run',
  'cronjob.construct_cron_command',
  'cronjob.validate_data',
  'initshutdownscript.execute_init_tasks',
  'user.get_user_obj',
  'directoryservices.status',
  'directoryservices.health.check',
  'filesystem.stat',
  'core.job_abort',
  'core.job_download_logs',
  'core.subscribe',
  'mail.send',
  'service.control',
  'etc.generate',
};

void _noEffects(f.CronHarness h) => expect(
  h.wire.calls.map((c) => c['method']).toSet().intersection(_forbidden),
  isEmpty,
);

Matcher _privateException() => isA<CronTasksException>().having(
  (e) => e.toString(),
  'sanitized reason',
  isNot(contains(f.secret)),
);

Map<String, dynamic> _write(f.CronHarness h) => h.wire.calls.singleWhere(
  (c) => const {
    'cronjob.create',
    'cronjob.update',
    'cronjob.delete',
  }.contains(c['method']),
);

void main() {
  test(
    'account choices use top-level local filter and safe projection only',
    () async {
      final h = await f.connected(
        configure: (w) {
          ((w.values['user.query'] as List).first as Map).addAll(
            <String, Object?>{
              'unixhash': f.secret,
              'smbhash': f.secret,
              'home': '/mnt/${f.secret}',
              'email': '${f.secret}@invalid.example',
            },
          );
        },
      );
      final i = await h.repo.loadCronTasks();
      expect(i.users.map((u) => [u.id, u.uid, u.username]), [
        [1, 0, 'root'],
        [2, 1000, 'worker'],
      ]);
      expect(i.users.toString(), isNot(contains(f.secret)));
      for (final call in h.wire.calls.where(
        (c) => c['method'] == 'user.query',
      )) {
        expect(call['params'], [
          [
            ['local', '=', true],
          ],
          {
            'limit': 1025,
            'select': ['id', 'uid', 'username', 'local', 'locked'],
          },
        ]);
      }
      expect(f.writes(h), 0);
      _noEffects(h);
    },
  );

  test('container-style locked local account cannot authorize scheduled command execution', () async {
    final h = await f.connected(
      configure: (w) {
        ((w.values['user.query'] as List).first as Map)['locked'] = true;
      },
    );
    final i = await h.repo.loadCronTasks();
    expect(i.users.map((u) => u.username), ['worker']);
    final request = f.request(i, action: CronTasksAction.enable);
    expect(request.validationError, isNotNull);
    final count = h.wire.calls.length;
    await expectLater(
      h.repo.reviewCronTasks(request),
      throwsA(_privateException()),
    );
    expect(h.wire.calls.length, count);
    expect(f.writes(h), 0);
    _noEffects(h);
  });

  for (final field in ['credential', 'configuration', 'kerberos_realm']) {
    test(
      'disabled directory with private $field remains inadmissible',
      () async {
        final h = await f.connected(
          configure: (w) {
            (w.values['directoryservices.config'] as Map)[field] = {
              'secret': f.secret,
            };
          },
        );
        final i = await h.repo.loadCronTasks();
        expect(i.directoryConfigured, isTrue);
        expect(i.blockedReason, isNotNull);
        expect(i.blockedReason, isNot(contains(f.secret)));
        await expectLater(
          h.repo.reviewCronTasks(f.request(i)),
          throwsA(_privateException()),
        );
        expect(f.writes(h), 0);
        _noEffects(h);
      },
    );
  }

  test('selected-only preservation includes hidden extensions without resending them', () async {
    final h = await f.connected(
      configure: (w) {
        ((w.rows as List).first as Map)['extension'] = <String, Object?>{
          'token': f.secret,
          'exact': [null, '', false, 0],
        };
      },
    );
    final review = await f.review(h);
    expect(review.warnings.join(), isNot(contains(f.secret)));
    final result = await f.execute(h, review);
    expect(result.outcome, CronTasksOutcome.completed, reason: result.message);
    expect(_write(h)['params'], [
      1,
      {'description': 'Changed maintenance'},
    ]);
    expect(((h.wire.rows as List).first as Map)['extension'], {
      'token': f.secret,
      'exact': [null, '', false, 0],
    });
    for (final call in h.wire.calls.where(
      (c) => c['method'] == 'cronjob.query',
    )) {
      final params = call['params'] as List;
      if ((params[1] as Map)['get'] == true) {
        expect(params.first, [
          ['id', '=', 1],
        ]);
      } else {
        expect((params[1] as Map)['select'], isNot(contains('command')));
      }
    }
    expect(result.message, isNot(contains(f.secret)));
    _noEffects(h);
  });

  for (final command in ['printf first\nprintf second', 'x' * 4097]) {
    test(
      'legacy command of length ${command.length} is preserved disabled but cannot enable',
      () async {
        final h = await f.connected(
          configure: (w) {
            ((w.rows as List).first as Map)['command'] = command;
          },
        );
        final review = await f.review(h);
        final result = await f.execute(h, review);
        expect(
          result.outcome,
          CronTasksOutcome.completed,
          reason: result.message,
        );
        expect(_write(h)['params'], [
          1,
          {'description': 'Changed maintenance'},
        ]);
        expect(((h.wire.rows as List).first as Map)['command'], command);
        expect(((h.wire.rows as List).first as Map)['enabled'], isFalse);
        final i = await h.repo.loadCronTasks();
        await expectLater(
          h.repo.reviewCronTasks(f.request(i, action: CronTasksAction.enable)),
          throwsA(_privateException()),
        );
        expect(f.writes(h), 1);
        _noEffects(h);
      },
    );
  }

  for (final masked in [
    '********',
    '*****',
    '<redacted>',
    '[redacted]',
    '<hidden>',
    '[hidden]',
    ' REDACTED ',
  ]) {
    test(
      'canonical masked command $masked cannot become new or preserved authority',
      () async {
        expect(CronTaskCommand.validationErrorFor(masked), isNotNull);
        expect(
          () => CronTaskCommand.fromText(masked),
          throwsA(_privateException()),
        );
        final h = await f.connected(
          configure: (w) {
            ((w.rows as List).first as Map)['command'] = masked;
          },
        );
        final i = await h.repo.loadCronTasks();
        await expectLater(
          h.repo.reviewCronTasks(f.request(i, action: CronTasksAction.enable)),
          throwsA(_privateException()),
        );
        await expectLater(
          h.repo.reviewCronTasks(f.request(i, action: CronTasksAction.delete)),
          throwsA(_privateException()),
        );
        expect(f.writes(h), 0);
        _noEffects(h);
      },
    );
  }

  test('changing stderr means suppressing output, not requesting email or running a test', () async {
    final h = await f.connected(
      configure: (w) {
        ((w.rows as List).first as Map)['stderr'] = false;
      },
    );
    final i = await h.repo.loadCronTasks();
    final old = i.tasks.first.settings;
    final review = await h.repo.reviewCronTasks(
      f.request(
        i,
        after: CronTaskSettings(
          user: old.user,
          description: old.description,
          schedule: old.schedule,
          hideStdout: old.hideStdout,
          hideStderr: true,
        ),
      ),
    );
    final result = await f.execute(h, review);
    expect(result.outcome, CronTasksOutcome.completed, reason: result.message);
    expect(_write(h)['params'], [
      1,
      {'stderr': true},
    ]);
    expect(
      review.warnings.join(),
      contains('do not guarantee command secrecy'),
    );
    expect(
      review.warnings.join(),
      contains('not proof of an OS daemon restart'),
    );
    expect(result.message, contains('cancellation were not verified'));
    _noEffects(h);
  });

  for (final outcome in ['completed', 'rejected', 'unknown']) {
    test(
      'owned replacement capsule is disposed after $outcome execution',
      () async {
        final h = await f.connected();
        final command = CronTaskCommand.fromText(
          'printf FRESH_PRIVATE_COMMAND',
        );
        addTearDown(command.dispose);
        final review = await f.review(h, command: command);
        expect(command.isDisposed, isFalse);
        if (outcome == 'rejected') h.authorized = false;
        if (outcome == 'unknown') h.wire.fault = 'cronjob.update';
        final result = await f.execute(h, review);
        expect(result.outcome.name, outcome, reason: result.message);
        expect(command.isDisposed, isTrue);
        expect(command.byteLength, 0);
        expect(result.message, isNot(contains('FRESH_PRIVATE_COMMAND')));
        expect(f.writes(h), outcome == 'rejected' ? 0 : 1);
        _noEffects(h);
      },
    );
  }

  test(
    'reload and replacement review dispose superseded command ownership',
    () async {
      final h = await f.connected();
      final first = CronTaskCommand.fromText('printf FIRST_PRIVATE_COMMAND');
      final second = CronTaskCommand.fromText('printf SECOND_PRIVATE_COMMAND');
      addTearDown(first.dispose);
      addTearDown(second.dispose);
      final i = await h.repo.loadCronTasks();
      final old = await h.repo.reviewCronTasks(f.request(i, command: first));
      final current = await h.repo.reviewCronTasks(
        f.request(i, command: second),
      );
      expect(first.isDisposed, isTrue);
      expect(second.isDisposed, isFalse);
      expect((await f.execute(h, old)).outcome, CronTasksOutcome.rejected);
      expect(second.isDisposed, isFalse);
      await h.repo.loadCronTasks();
      expect(second.isDisposed, isTrue);
      expect((await f.execute(h, current)).outcome, CronTasksOutcome.rejected);
      expect(f.writes(h), 0);
      _noEffects(h);
    },
  );

  test('private extension drift after response is unknown and cannot be silently cleared', () async {
    final h = await f.connected(
      configure: (w) {
        ((w.rows as List).first as Map)['extension'] = {'private': f.secret};
      },
    );
    final review = await f.review(h);
    h.wire.afterWrite = () {
      ((h.wire.rows as List).first as Map)['extension'] = {'private': null};
    };
    final result = await f.execute(h, review);
    expect(result.outcome, CronTasksOutcome.unknown, reason: result.message);
    expect(result.message, isNot(contains(f.secret)));
    final count = h.wire.calls.length;
    await expectLater(h.repo.loadCronTasks(), throwsA(_privateException()));
    expect((await f.execute(h, review)).outcome, CronTasksOutcome.rejected);
    expect(h.wire.calls.length, count);
    expect(f.writes(h), 1);
    _noEffects(h);
  });

  test('pending and unknown cron writes fence init tasks and service control without peer reads', () async {
    final h = await f.connected(
      configure: (w) {
        w.methods.addAll({
          ...ist.istReads,
          ...ist.istWrites,
          'service.control',
        });
      },
    );
    expect(h.repo.initShutdownTasksCapabilities.supported, isTrue);
    final review = await f.review(h, action: CronTasksAction.disable);
    final sent = Completer<void>();
    h.wire
      ..hold = 'cronjob.update'
      ..held = Completer<void>()
      ..overrideReceipt = true
      ..beforeReply = (method, _) {
        if (method == 'cronjob.update') sent.complete();
      };
    final pending = f.execute(h, review);
    await sent.future;
    Future<void> peersBlocked() async {
      final count = h.wire.calls.length;
      await expectLater(
        h.repo.loadInitShutdownTasks(),
        throwsA(isA<InitShutdownTasksException>()),
      );
      await expectLater(
        h.repo.execute(
          const ServiceControlCommand(
            service: 'smb',
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
    expect(result.outcome, CronTasksOutcome.unknown, reason: result.message);
    await peersBlocked();
    expect((await f.execute(h, review)).outcome, CronTasksOutcome.rejected);
    expect(f.writes(h), 1);
    _noEffects(h);
  });

  test('local ID substitution with the same username and UID invalidates authority', () async {
    final h = await f.connected();
    final review = await f.review(h);
    ((h.wire.values['user.query'] as List).first as Map)['id'] = 91;
    final result = await f.execute(h, review);
    expect(result.outcome, CronTasksOutcome.rejected, reason: result.message);
    expect(f.writes(h), 0);
    expect(
      jsonEncode(
        h.wire.calls.where((c) => c['method'] == 'cronjob.update').toList(),
      ),
      '[]',
    );
    _noEffects(h);
  });
}
