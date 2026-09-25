import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const methods = {
  'pool.snapshottask.query',
  'pool.snapshottask.create',
  'pool.snapshottask.update',
  'pool.snapshottask.delete',
  'pool.snapshottask.run',
  'pool.snapshottask.update_will_change_retention_for',
  'pool.snapshottask.delete_will_change_retention_for',
  'pool.dataset.query',
  'pool.filesystem_choices',
  'pool.snapshot.query',
  'replication.query',
  'vmware.query',
  'system.general.config',
};
Map<String, Object?> property(String value) => {
  'rawvalue': value,
  'value': value,
  'source': 'LOCAL',
};
Map<String, Object?> dataset(
  String id,
  String guid, {
  String kind = 'FILESYSTEM',
}) => {
  'id': id,
  'name': id,
  'type': kind,
  'guid': property(guid),
  'creation': property('1700000000'),
  'readonly': property('off'),
  'locked': false,
};
Map<String, Object?> task(int id, {String path = 'tank/data'}) => {
  'id': id,
  'dataset': path,
  'recursive': false,
  'exclude': <String>[],
  'lifetime_value': 2,
  'lifetime_unit': 'WEEK',
  'enabled': true,
  'naming_schema': 'auto-%Y-%m-%d_%H-%M',
  'allow_empty': true,
  'schedule': {
    'minute': '0',
    'hour': '*',
    'dom': '*',
    'month': '*',
    'dow': '*',
    'begin': '00:00',
    'end': '23:59',
  },
  'vmware_sync': false,
  'state': {'state': 'PENDING'},
};
SnapshotScheduleSettings settings({
  String dataset = 'tank/data',
  bool recursive = false,
  List<String> exclude = const [],
  int lifetime = 3,
  String unit = 'WEEK',
  bool enabled = true,
  String naming = 'auto-%Y-%m-%d_%H-%M',
  bool allowEmpty = true,
  SnapshotScheduleCron cron = const SnapshotScheduleCron(),
}) => SnapshotScheduleSettings(
  dataset: dataset,
  recursive: recursive,
  exclude: exclude,
  lifetimeValue: lifetime,
  lifetimeUnit: unit,
  enabled: enabled,
  namingSchema: naming,
  allowEmpty: allowEmpty,
  cron: cron,
);
Matcher failure(SnapshotSchedulesExceptionReason reason) =>
    isA<SnapshotSchedulesException>().having((e) => e.reason, 'reason', reason);
Future<Harness> connect({
  Set<String> available = methods,
  String version = '25.10.1',
}) async {
  final h = Harness(available, version);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    username: 'admin',
    apiKey: 'synthetic',
  );
  return h;
}

void main() {
  test('bounded source projection retrieves nested managed marker, dataset ancestors and timezone safely', () async {
    final h = await connect();
    final inventory = await h.repo.loadSnapshotSchedules();
    expect(inventory.tasks.single.settings.dataset, 'tank/data');
    expect(inventory.timezone, 'America/New_York');
    expect(
      inventory.datasets.firstWhere((d) => d.id == 'tank').available,
      false,
    );
    expect(
      inventory.datasets.firstWhere((d) => d.id == 'tank/data').available,
      true,
    );
    final q =
        h.wire.calls.firstWhere(
              (r) => r['method'] == 'pool.dataset.query',
            )['params']
            as List;
    expect(q.first, isNotEmpty);
    final options = q[1] as Map;
    expect((options['select'] as List).last, [
      'user_properties.managedby',
      'managedby',
    ]);
    expect((options['extra'] as Map)['retrieve_user_props'], true);
    expect(h.wire.writes, isEmpty);
    expect(inventory.tasks.single.state, 'PENDING');
    expect(() => inventory.tasks.clear(), throwsUnsupportedError);
  });
  for (final version in ['25.04.2', '25.10-BETA.1', '26.0.0']) {
    test('$version performs no schedule reads', () async {
      final h = await connect(version: version);
      await expectLater(
        h.repo.loadSnapshotSchedules(),
        throwsA(failure(SnapshotSchedulesExceptionReason.unsupportedVersion)),
      );
      expect(
        h.wire.calls.where((r) => r['method'] == 'pool.snapshottask.query'),
        isEmpty,
      );
    });
  }
  test('create dispatches one full typed policy and verifies exact independently read settings', () async {
    final h = await connect();
    final inv = await h.repo.loadSnapshotSchedules();
    final review = await h.repo.reviewSnapshotSchedule(
      SnapshotScheduleRequest(
        inventory: inv,
        action: SnapshotScheduleAction.create,
        settings: settings(
          naming: 'daily-%Y-%m-%d_%H-%M',
          cron: const SnapshotScheduleCron(hour: '2'),
        ),
      ),
    );
    expect(review.affectedSnapshots, ['tank/data@auto-2026-09-01_00-00']);
    expect(review.warnings.join(' '), contains('adopted'));
    expect(h.wire.writes, isEmpty);
    final result = await h.repo.executeSnapshotSchedule(review, review.target);
    expect(result.outcome, SnapshotScheduleOutcome.verified);
    final payload = (h.wire.writes.single['params'] as List).single as Map;
    expect(payload.keys.toSet(), {
      'dataset',
      'recursive',
      'exclude',
      'lifetime_value',
      'lifetime_unit',
      'enabled',
      'naming_schema',
      'allow_empty',
      'schedule',
    });
    expect(payload['schedule'], {
      'minute': '0',
      'hour': '2',
      'dom': '*',
      'month': '*',
      'dow': '*',
      'begin': '00:00',
      'end': '23:59',
    });
    expect(h.wire.calls.last['method'], 'pool.snapshottask.query');
    await expectLater(
      h.repo.executeSnapshotSchedule(review, review.target),
      throwsA(failure(SnapshotSchedulesExceptionReason.stale)),
    );
    expect(h.wire.writes.length, 1);
  });
  test('partial update preserves unselected metadata and explicitly disables unowned fixation job', () async {
    final h = await connect();
    final inv = await h.repo.loadSnapshotSchedules();
    final review = await h.review(inv, proposed: settings());
    final result = await h.repo.executeSnapshotSchedule(review, review.target);
    expect(result.outcome, SnapshotScheduleOutcome.verified);
    expect(h.wire.writes.single['params'], [
      1,
      {'lifetime_value': 3, 'fixate_removal_date': false},
    ]);
    expect(h.wire.tasks.single['allow_empty'], true);
    expect(h.wire.tasks.single['schedule'], task(1)['schedule']);
  });
  test('shorter retention reviews bounded existing points and makes destructive expiry explicit', () async {
    final h = await connect();
    final inv = await h.repo.loadSnapshotSchedules();
    final review = await h.review(
      inv,
      proposed: settings(lifetime: 1, unit: 'DAY'),
    );
    expect(
      review.warnings.join(' '),
      contains('DANGER: retention is shortened'),
    );
    expect(
      review.warnings.join(' '),
      contains('next automatic retention pass'),
    );
    expect(review.affectedSnapshots, ['tank/data@auto-2026-09-01_00-00']);
    expect(
      h.wire.calls
          .where(
            (r) =>
                r['method'] ==
                'pool.snapshottask.delete_will_change_retention_for',
          )
          .length,
      1,
    );
    expect(
      h.wire.calls
          .where(
            (r) =>
                r['method'] ==
                'pool.snapshottask.update_will_change_retention_for',
          )
          .length,
      1,
    );
    expect(
      (await h.repo.executeSnapshotSchedule(review, review.target)).outcome,
      SnapshotScheduleOutcome.verified,
    );
  });
  test('delete is policy-only with exact options and qualified existing retention warning', () async {
    final h = await connect();
    final inv = await h.repo.loadSnapshotSchedules();
    final review = await h.review(inv, action: SnapshotScheduleAction.delete);
    expect(
      review.warnings.join(' '),
      contains('does not directly destroy snapshots'),
    );
    expect(review.warnings.join(' '), contains('NOT fixated'));
    final result = await h.repo.executeSnapshotSchedule(review, review.target);
    expect(result.outcome, SnapshotScheduleOutcome.verified);
    expect(h.wire.writes.single['params'], [
      1,
      {'fixate_removal_date': false},
    ]);
    expect(h.wire.tasks, isEmpty);
    expect(h.wire.snapshots.length, 2);
    expect(
      h.wire.calls.any((r) => r['method'] == 'pool.snapshot.delete'),
      false,
    );
  });
  test('run null acknowledges queue only, never invents owned job or snapshot success', () async {
    final h = await connect();
    final inv = await h.repo.loadSnapshotSchedules();
    final review = await h.review(inv, action: SnapshotScheduleAction.run);
    final result = await h.repo.executeSnapshotSchedule(review, review.target);
    expect(result.outcome, SnapshotScheduleOutcome.accepted);
    expect(result.message, contains('completion was not verified'));
    expect(h.wire.writes.single['params'], [1]);
    expect(h.wire.calls.any((r) => r['method'] == 'core.get_jobs'), false);
    expect(h.wire.snapshots.length, 2);
  });
  test(
    'disabled task cannot run but can be enabled in a separate reviewed edit',
    () async {
      final h = await connect();
      h.wire.tasks.single['enabled'] = false;
      final inv = await h.repo.loadSnapshotSchedules();
      await expectLater(
        h.review(inv, action: SnapshotScheduleAction.run),
        throwsA(failure(SnapshotSchedulesExceptionReason.invalid)),
      );
      expect(h.wire.writes, isEmpty);
      final review = await h.review(inv, proposed: settings(lifetime: 2));
      expect(
        (await h.repo.executeSnapshotSchedule(review, review.target)).outcome,
        SnapshotScheduleOutcome.verified,
      );
    },
  );
  test('unrelated VMware task is preserved while selected ordinary task edits verify', () async {
    final h = await connect();
    h.wire.tasks.add(task(2, path: 'tank/other')..['vmware_sync'] = true);
    h.wire.vmware.add({'id': 4, 'filesystem': 'tank/other'});
    final inv = await h.repo.loadSnapshotSchedules();
    final review = await h.review(inv, proposed: settings());
    expect(
      (await h.repo.executeSnapshotSchedule(review, review.target)).outcome,
      SnapshotScheduleOutcome.verified,
    );
    expect(h.wire.tasks.last['vmware_sync'], true);
  });
  for (final cause in ['vmware', 'replication', 'running']) {
    test('$cause bound task is blocked before write', () async {
      final h = await connect();
      if (cause == 'vmware') h.wire.tasks.single['vmware_sync'] = true;
      if (cause == 'running') {
        h.wire.tasks.single['state'] = {'state': 'RUNNING', 'error': 'private'};
      }
      if (cause == 'replication') {
        h.wire.replications.add({
          'id': 2,
          'periodic_snapshot_tasks': [
            {'id': 1},
          ],
        });
      }
      final inv = await h.repo.loadSnapshotSchedules();
      await expectLater(
        h.review(inv, proposed: settings()),
        throwsA(isA<SnapshotSchedulesException>()),
      );
      expect(h.wire.writes, isEmpty);
      expect(inv.tasks.single.state, isNot(contains('private')));
    });
  }
  test(
    'recursive current descendants and exact subtree exclusions are reviewed',
    () async {
      final h = await connect();
      final inv = await h.repo.loadSnapshotSchedules();
      final review = await h.review(
        inv,
        proposed: settings(recursive: true, exclude: ['tank/data/cache']),
      );
      expect(review.changes.join(' '), contains('Dataset scope: tank/data'));
      expect(review.warnings.join(' '), contains('future descendants'));
      expect(review.affectedSnapshots, ['tank/data@auto-2026-09-01_00-00']);
      expect(
        (await h.repo.executeSnapshotSchedule(review, review.target)).outcome,
        SnapshotScheduleOutcome.verified,
      );
      expect(h.wire.tasks.single['exclude'], ['tank/data/cache']);
    },
  );
  test('VMware descendant cannot be hidden by a recursive exclusion', () async {
    final h = await connect();
    h.wire.vmware.add({'id': 8, 'filesystem': 'tank/data/cache'});
    final inv = await h.repo.loadSnapshotSchedules();
    await expectLater(
      h.review(
        inv,
        proposed: settings(recursive: true, exclude: ['tank/data/cache']),
      ),
      throwsA(failure(SnapshotSchedulesExceptionReason.dependency)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test(
    'caller exclusion mutation after review cannot change issued payload',
    () async {
      final h = await connect();
      final excluded = ['tank/data/cache'];
      final inv = await h.repo.loadSnapshotSchedules();
      final review = await h.review(
        inv,
        proposed: settings(recursive: true, exclude: excluded),
      );
      excluded.clear();
      expect(
        (await h.repo.executeSnapshotSchedule(review, review.target)).outcome,
        SnapshotScheduleOutcome.verified,
      );
      expect(h.wire.tasks.single['exclude'], ['tank/data/cache']);
    },
  );
  for (final cause in ['managed', 'locked', 'readonly', 'missing']) {
    test(
      '$cause ancestor blocks descendant schedules without blocking normal root provenance',
      () async {
        final h = await connect();
        if (cause == 'managed') {
          h.wire.datasets.first['managedby'] = property('external');
        }
        if (cause == 'locked') h.wire.datasets.first['locked'] = true;
        if (cause == 'readonly') {
          h.wire.datasets.first['readonly'] = property('on');
        }
        if (cause == 'missing') h.wire.datasets.removeAt(0);
        final inv = await h.repo.loadSnapshotSchedules();
        expect(
          inv.datasets.firstWhere((d) => d.id == 'tank/data').available,
          false,
        );
        await expectLater(
          h.review(inv, proposed: settings()),
          throwsA(isA<SnapshotSchedulesException>()),
        );
        expect(h.wire.writes, isEmpty);
      },
    );
  }
  test('excluded managed descendant is safe; newly included managed descendant is blocked', () async {
    final h = await connect();
    h.wire.datasets.firstWhere(
      (d) => d['id'] == 'tank/data/cache',
    )['managedby'] = property(
      'external',
    );
    final inv = await h.repo.loadSnapshotSchedules();
    await expectLater(
      h.review(inv, proposed: settings(recursive: true)),
      throwsA(failure(SnapshotSchedulesExceptionReason.dependency)),
    );
    final review = await h.review(
      inv,
      proposed: settings(recursive: true, exclude: ['tank/data/cache']),
    );
    expect(review.affectedSnapshots.length, 1);
    expect(h.wire.writes, isEmpty);
  });
  for (final changed in [
    'task',
    'guid',
    'timezone',
    'snapshot',
    'new_child',
    'replication',
    'vmware',
  ]) {
    test('fresh $changed drift consumes review and blocks dispatch', () async {
      final h = await connect();
      final inv = await h.repo.loadSnapshotSchedules();
      final review = await h.review(inv, proposed: settings());
      switch (changed) {
        case 'task':
          h.wire.tasks.single['allow_empty'] = false;
        case 'guid':
          h.wire.datasets[1]['guid'] = property('200');
        case 'timezone':
          h.wire.timezone = 'UTC';
        case 'snapshot':
          h.wire.snapshots.add({
            'id': 'tank/data@auto-2026-09-02_00-00',
            'dataset': 'tank/data',
          });
        case 'new_child':
          h.wire.datasets.add(dataset('tank/data/new', '88'));
        case 'replication':
          h.wire.replications.add({
            'id': 5,
            'periodic_snapshot_tasks': [
              {'id': 1},
            ],
          });
        case 'vmware':
          h.wire.vmware.add({'id': 5, 'filesystem': 'tank/data'});
      }
      await expectLater(
        h.repo.executeSnapshotSchedule(review, review.target),
        throwsA(isA<SnapshotSchedulesException>()),
      );
      await expectLater(
        h.repo.executeSnapshotSchedule(review, review.target),
        throwsA(failure(SnapshotSchedulesExceptionReason.stale)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('retention response names absent from displayed manifest are stale, not silently omitted', () async {
    final h = await connect();
    h.wire.retention = {
      'tank/data': ['missing'],
    };
    final inv = await h.repo.loadSnapshotSchedules();
    await expectLater(
      h.review(inv, action: SnapshotScheduleAction.delete),
      throwsA(failure(SnapshotSchedulesExceptionReason.stale)),
    );
    expect(h.wire.writes, isEmpty);
  });
  for (final kind in ['replication', 'vmware']) {
    test('duplicate $kind identities are rejected', () async {
      final h = await connect();
      if (kind == 'replication') {
        h.wire.replications.addAll([
          {'id': 4, 'periodic_snapshot_tasks': []},
          {'id': 4, 'periodic_snapshot_tasks': []},
        ]);
      } else {
        h.wire.vmware.addAll([
          {'id': 4, 'filesystem': 'tank/other'},
          {'id': 4, 'filesystem': 'tank/other'},
        ]);
      }
      final inv = await h.repo.loadSnapshotSchedules();
      await expectLater(
        h.review(inv, proposed: settings()),
        throwsA(failure(SnapshotSchedulesExceptionReason.invalid)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final id in ['0', '18446744073709551616']) {
    test('invalid dataset GUID $id fails closed', () async {
      final h = await connect();
      h.wire.datasets[1]['guid'] = property(id);
      await expectLater(
        h.repo.loadSnapshotSchedules(),
        throwsA(failure(SnapshotSchedulesExceptionReason.invalid)),
      );
    });
  }
  test(
    '256 snapshot review bound is enforced without truncated affected list',
    () async {
      final h = await connect();
      h.wire.snapshots = [
        for (var i = 0; i < 257; i++)
          {'id': 'tank/data@auto-$i', 'dataset': 'tank/data'},
      ];
      final inv = await h.repo.loadSnapshotSchedules();
      await expectLater(
        h.review(inv, proposed: settings()),
        throwsA(failure(SnapshotSchedulesExceptionReason.invalid)),
      );
      expect(h.wire.writes, isEmpty);
    },
  );
  for (final mode in [
    'timeout',
    'wrong_receipt',
    'wrong_id',
    'readback',
    'other_task',
  ]) {
    test('$mode after dispatch becomes unknown and never retries', () async {
      final h = await connect();
      final inv = await h.repo.loadSnapshotSchedules();
      final review = await h.review(inv, proposed: settings());
      h.wire.tamper = mode;
      expect(
        (await h.repo.executeSnapshotSchedule(review, review.target)).outcome,
        SnapshotScheduleOutcome.unknown,
      );
      await expectLater(
        h.repo.executeSnapshotSchedule(review, review.target),
        throwsA(failure(SnapshotSchedulesExceptionReason.busy)),
      );
      expect(h.wire.writes.length, 1);
    });
  }
  test('unexpected job ID from non-job run remains unknown', () async {
    final h = await connect();
    final inv = await h.repo.loadSnapshotSchedules();
    final review = await h.review(inv, action: SnapshotScheduleAction.run);
    h.wire.tamper = 'wrong_receipt';
    expect(
      (await h.repo.executeSnapshotSchedule(review, review.target)).outcome,
      SnapshotScheduleOutcome.unknown,
    );
    expect(h.wire.writes.length, 1);
  });
  test('issuing a newer review invalidates the previous lease', () async {
    final h = await connect();
    final inv = await h.repo.loadSnapshotSchedules();
    final first = await h.review(inv, proposed: settings());
    final second = await h.review(inv, proposed: settings(lifetime: 4));
    await expectLater(
      h.repo.executeSnapshotSchedule(first, first.target),
      throwsA(failure(SnapshotSchedulesExceptionReason.stale)),
    );
    expect(
      (await h.repo.executeSnapshotSchedule(second, second.target)).outcome,
      SnapshotScheduleOutcome.verified,
    );
    expect(h.wire.writes.length, 1);
  });
  test('oversized retention list is rejected without truncation', () async {
    final h = await connect();
    h.wire.retention = {
      'tank/data': [for (var i = 0; i < 257; i++) 'snapshot-$i'],
    };
    final inv = await h.repo.loadSnapshotSchedules();
    await expectLater(
      h.review(inv, action: SnapshotScheduleAction.delete),
      throwsA(failure(SnapshotSchedulesExceptionReason.invalid)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test('forged and cross-session reviews cannot dispatch; incorrect confirmation consumes issued lease', () async {
    final h = await connect(), other = await connect();
    final inv = await h.repo.loadSnapshotSchedules();
    final review = await h.review(inv, proposed: settings());
    await expectLater(
      other.repo.executeSnapshotSchedule(review, review.target),
      throwsA(failure(SnapshotSchedulesExceptionReason.stale)),
    );
    final forged = SnapshotScheduleReview(
      action: review.action,
      target: review.target,
      identity: review.identity,
      changes: review.changes,
      warnings: review.warnings,
    );
    await expectLater(
      h.repo.executeSnapshotSchedule(forged, forged.target),
      throwsA(failure(SnapshotSchedulesExceptionReason.stale)),
    );
    await expectLater(
      h.repo.executeSnapshotSchedule(review, '${review.target} '),
      throwsA(failure(SnapshotSchedulesExceptionReason.stale)),
    );
    await expectLater(
      h.repo.executeSnapshotSchedule(review, review.target),
      throwsA(failure(SnapshotSchedulesExceptionReason.stale)),
    );
    expect(h.wire.writes, isEmpty);
    expect(other.wire.writes, isEmpty);
  });
  test('missing retention method disables update but preserves read-only inventory', () async {
    final h = await connect(
      available: methods.difference({
        'pool.snapshottask.update_will_change_retention_for',
      }),
    );
    final inv = await h.repo.loadSnapshotSchedules();
    expect(h.repo.snapshotSchedulesCapabilities.canUpdate, false);
    await expectLater(
      h.review(inv, proposed: settings()),
      throwsA(failure(SnapshotSchedulesExceptionReason.unavailableMethod)),
    );
    expect(h.wire.writes, isEmpty);
  });
  for (final cron in [
    const SnapshotScheduleCron(minute: '*/0'),
    const SnapshotScheduleCron(minute: '60'),
    const SnapshotScheduleCron(hour: '24'),
    const SnapshotScheduleCron(dom: '31', month: '2'),
    const SnapshotScheduleCron(month: '13'),
    const SnapshotScheduleCron(dow: '8'),
    const SnapshotScheduleCron(minute: '1/2'),
    const SnapshotScheduleCron(minute: '*/2,3'),
    const SnapshotScheduleCron(begin: '09:00', end: '09:00'),
    const SnapshotScheduleCron(begin: '22:00', end: '04:00'),
    const SnapshotScheduleCron(hour: '2', begin: '09:00', end: '18:00'),
  ]) {
    test(
      'unsafe cron ${[cron.minute, cron.hour, cron.dom, cron.month, cron.dow, cron.begin, cron.end]} rejects before mutation',
      () {
        expect(cron.validationError, isNotNull);
      },
    );
  }
  for (final cron in [
    const SnapshotScheduleCron(
      minute: '*/15',
      hour: '9-17',
      dow: '1-5',
      begin: '09:00',
      end: '18:00',
    ),
    const SnapshotScheduleCron(dom: '29', month: '2'),
    const SnapshotScheduleCron(dom: '31', month: '2', dow: '1'),
    const SnapshotScheduleCron(dow: '0'),
    const SnapshotScheduleCron(dow: '7'),
    const SnapshotScheduleCron(minute: '00'),
  ]) {
    test(
      'supported cron preserves real calendar/OR semantics ${[cron.minute, cron.hour, cron.dom, cron.month, cron.dow]}',
      () {
        expect(cron.validationError, null);
      },
    );
  }
  test(
    'naming retention exclusions and exact unit semantics validate locally',
    () {
      expect(settings(lifetime: 0).validationError, isNotNull);
      expect(settings(lifetime: -1).validationError, isNotNull);
      expect(settings(unit: 'FOREVER').validationError, isNotNull);
      expect(settings(naming: 'auto-%Y-%m-%d').validationError, isNotNull);
      expect(
        settings(naming: 'auto-%Y-%m-%d_%H-%M-%S').validationError,
        isNotNull,
      );
      expect(settings(naming: '../%Y-%m-%d_%H-%M').validationError, isNotNull);
      expect(settings(exclude: ['tank/data/cache']).validationError, isNotNull);
      expect(
        settings(recursive: true, exclude: ['tank/other']).validationError,
        isNotNull,
      );
      expect(settings(lifetime: 1, unit: 'MONTH').lifetimeSeconds, 30 * 86400);
      expect(settings(lifetime: 1, unit: 'YEAR').lifetimeSeconds, 365 * 86400);
    },
  );
}

class Harness {
  Harness(Set<String> available, String version) {
    wire = FakeWire(available, version);
    repo = TrueNasSessionRepository(
      connector: Connector(wire),
      managementRequestTimeout: const Duration(milliseconds: 40),
    );
  }
  late final FakeWire wire;
  late final TrueNasSessionRepository repo;
  Future<SnapshotScheduleReview> review(
    SnapshotScheduleInventory inv, {
    SnapshotScheduleAction action = SnapshotScheduleAction.update,
    SnapshotScheduleSettings? proposed,
  }) => repo.reviewSnapshotSchedule(
    SnapshotScheduleRequest(
      inventory: inv,
      action: action,
      task: inv.tasks.first,
      settings: proposed,
    ),
  );
}

class Connector implements RpcConnector {
  const Connector(this.wire);
  final RpcTransport wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class FakeWire implements RpcTransport {
  FakeWire(this.available, this.version);
  final Set<String> available;
  final String version;
  final input = StreamController<String>();
  final calls = <Map<String, Object?>>[];
  final datasets = <Map<String, Object?>>[
    dataset('tank', '1'),
    dataset('tank/data', '2'),
    dataset('tank/data/cache', '3', kind: 'VOLUME'),
    dataset('tank/other', '4'),
  ];
  final tasks = <Map<String, Object?>>[task(1)];
  final replications = <Map<String, Object?>>[],
      vmware = <Map<String, Object?>>[];
  List<Map<String, Object?>> snapshots = [
    {'id': 'tank/data@auto-2026-09-01_00-00', 'dataset': 'tank/data'},
    {
      'id': 'tank/data/cache@auto-2026-09-01_00-00',
      'dataset': 'tank/data/cache',
    },
  ];
  Map<String, List<String>> retention = {
    'tank/data': ['auto-2026-09-01_00-00'],
  };
  String timezone = 'America/New_York';
  String? tamper;
  Iterable<Map<String, Object?>> get writes => calls.where(
    (r) => {
      'pool.snapshottask.create',
      'pool.snapshottask.update',
      'pool.snapshottask.delete',
      'pool.snapshottask.run',
    }.contains(r['method']),
  );
  @override
  Stream<String> get inboundFrames => input.stream;
  @override
  Future<void> send(String frame) async {
    final request = Map<String, Object?>.from(jsonDecode(frame) as Map);
    calls.add(request);
    final method = request['method'] as String,
        args = request['params'] as List? ?? [];
    Object? result;
    switch (method) {
      case 'auth.login_ex':
        result = {'response_type': 'SUCCESS'};
      case 'auth.me':
        result = {'username': 'admin'};
      case 'system.info':
        result = {'version': version};
      case 'core.get_methods':
        result = {
          for (final m in available)
            m: {
              'accepts': [],
              'returns': [],
              'job': false,
              'no_auth_required': false,
            },
        };
      case 'pool.dataset.query':
        result = datasets;
      case 'pool.filesystem_choices':
        result = datasets.map((d) => d['id']).toList();
      case 'system.general.config':
        result = {
          'timezone': timezone,
          'ui_certificate': {'private': 'never retained'},
        };
      case 'pool.snapshottask.query':
        result = tasks;
      case 'replication.query':
        result = replications;
      case 'vmware.query':
        result = vmware;
      case 'pool.snapshot.query':
        final scope = ((args.first as List).single as List)[2] as List;
        result = snapshots.where((s) => scope.contains(s['dataset'])).toList();
      case 'pool.snapshottask.delete_will_change_retention_for':
        result = retention;
      case 'pool.snapshottask.update_will_change_retention_for':
        result = <String, Object?>{};
      case 'pool.snapshottask.create':
        final created = {
          ...Map<String, Object?>.from(args.single as Map),
          'id': 2,
          'vmware_sync': false,
          'state': {'state': 'PENDING'},
        };
        tasks.add(created);
        result = created;
      case 'pool.snapshottask.update':
        final current = tasks.firstWhere((t) => t['id'] == args[0]);
        final patch = Map<String, Object?>.from(args[1] as Map)
          ..remove('fixate_removal_date');
        current.addAll(patch);
        result = {...current};
      case 'pool.snapshottask.delete':
        tasks.removeWhere((t) => t['id'] == args[0]);
        result = true;
      case 'pool.snapshottask.run':
        result = null;
      default:
        throw StateError('Unexpected fake method $method');
    }
    if ({
      'pool.snapshottask.create',
      'pool.snapshottask.update',
      'pool.snapshottask.delete',
      'pool.snapshottask.run',
    }.contains(method)) {
      if (tamper == 'timeout') return;
      if (tamper == 'wrong_receipt') result = 42;
      if (tamper == 'wrong_id' && result is Map) result = {...result, 'id': 99};
      if (tamper == 'readback') tasks.first['allow_empty'] = false;
      if (tamper == 'other_task') tasks.add(task(77, path: 'tank/other'));
    }
    input.add(
      jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() async {
    await input.close();
  }
}
