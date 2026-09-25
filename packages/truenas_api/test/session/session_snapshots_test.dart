import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _methods = {
  'pool.snapshot.query',
  'pool.dataset.query',
  'pool.snapshot.create',
  'pool.snapshot.delete',
  'pool.snapshot.clone',
  'pool.snapshot.rollback',
  'pool.snapshot.hold',
  'pool.snapshot.release',
};
const _query = SnapshotQuery(dataset: 'tank/data');
Map<String, Object?> _prop(String raw) => {
  'rawvalue': raw,
  'value': raw,
  'parsed': int.tryParse(raw) ?? raw,
  'source': 'LOCAL',
};
Map<String, Object?> _dataset({
  String id = 'tank/data',
  String guid = '9007199254740999',
}) => {
  'id': id,
  'name': id,
  'type': 'FILESYSTEM',
  'locked': false,
  'encrypted': false,
  'guid': _prop(guid),
  'creation': _prop('1700000000'),
  'mountpoint': '/mnt/$id',
  'readonly': _prop('off'),
  'origin': _prop(''),
  'written': _prop('8192'),
  'referenced': _prop('536870912'),
};
Map<String, Object?> _snapshot({
  String id = 'tank/data@manual-1',
  String guid = '18446744073709551615',
}) => {
  'id': id,
  'name': id,
  'type': 'SNAPSHOT',
  'dataset': id.split('@').first,
  'snapshot_name': id.split('@').last,
  'pool': 'tank',
  'createtxg': '12345678',
  'holds': <String, Object?>{},
  'properties': <String, Object?>{
    'guid': _prop(guid),
    'creation': _prop('1720000000'),
    'createtxg': _prop('12345678'),
    'used': _prop('1024'),
    'referenced': _prop('536870912'),
    'userrefs': _prop('0'),
    'clones': _prop('-'),
    'defer_destroy': _prop('off'),
  },
};
Matcher _reason(SnapshotsExceptionReason value) =>
    isA<SnapshotsException>().having((e) => e.reason, 'reason', value);

void main() {
  test(
    'managed marker is selected from real nested dataset user properties',
    () async {
      final h = await _connect();
      h.transport.datasets.last['user_properties'] = {
        'managedby': _prop('external-manager'),
      };
      final values = await h.repo.loadSnapshotDatasets();
      expect(values.last.blockedReason, isNotNull);
      final options = (h.transport.requests.last['params'] as List).last as Map;
      expect(
        options['select'],
        contains(equals(['user_properties.managedby', 'managedby'])),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  group('native recovery', () {
    for (final kind in [
      SnapshotRecoveryKind.clone,
      SnapshotRecoveryKind.rollback,
      SnapshotRecoveryKind.hold,
      SnapshotRecoveryKind.release,
      SnapshotRecoveryKind.recursiveCreate,
      SnapshotRecoveryKind.bulkDelete,
    ]) {
      test('${kind.name} review reads only and exact write verifies', () async {
        final h = await _connect();
        if (kind == SnapshotRecoveryKind.release) {
          _setHold(h.transport.snapshots.single);
        }
        if (kind == SnapshotRecoveryKind.recursiveCreate) {
          h.transport.datasets.add(
            _dataset(id: 'tank/data/child', guid: '234'),
          );
        }
        final plan = await _recoveryPlan(h, kind);
        final review = await h.repo.reviewSnapshotRecovery(plan);
        expect(review.canApply, isTrue, reason: review.blockedReason);
        expect(h.transport.writes, isEmpty);
        expect(review.bookmarksInspectable, isFalse);
        expect(() => review.snapshots.clear(), throwsUnsupportedError);
        expect(() => review.datasets.clear(), throwsUnsupportedError);
        expect(() => review.newerSnapshots.clear(), throwsUnsupportedError);
        expect(() => review.warnings.clear(), throwsUnsupportedError);
        final result = await h.repo.applySnapshotRecovery(
          SnapshotRecoveryRequest(
            review: review,
            confirmation: plan.target,
            acknowledgeDataLoss: true,
          ),
        );
        expect(result.outcome, SnapshotOperationOutcome.verified);
        final write = h.transport.writes.first;
        switch (kind) {
          case SnapshotRecoveryKind.clone:
            expect(write['params'], [
              {
                'snapshot': 'tank/data@manual-1',
                'dataset_dst': 'tank/data/recovered',
                'dataset_properties': {'readonly': 'on'},
              },
            ]);
          case SnapshotRecoveryKind.rollback:
            expect(write['params'], [
              'tank/data@manual-1',
              {
                'recursive': false,
                'recursive_clones': false,
                'force': false,
                'recursive_rollback': false,
              },
            ]);
          case SnapshotRecoveryKind.hold:
          case SnapshotRecoveryKind.release:
            expect(write['params'], [
              'tank/data@manual-1',
              {'recursive': false},
            ]);
          case SnapshotRecoveryKind.recursiveCreate:
            expect(h.transport.writes, hasLength(2));
            for (final w in h.transport.writes) {
              expect(
                ((w['params'] as List).single as Map)['recursive'],
                isFalse,
              );
            }
          case SnapshotRecoveryKind.bulkDelete:
            expect(write['params'], [
              'tank/data@manual-1',
              {'recursive': false, 'defer': false},
            ]);
        }
      });
      test(
        '${kind.name} unknown outcome holds lock and never retries',
        () async {
          final h = await _connect();
          if (kind == SnapshotRecoveryKind.release) {
            _setHold(h.transport.snapshots.single);
          }
          final plan = await _recoveryPlan(h, kind);
          final review = await h.repo.reviewSnapshotRecovery(plan);
          h.transport.failure = 'timeout';
          final request = SnapshotRecoveryRequest(
            review: review,
            confirmation: plan.target,
            acknowledgeDataLoss: true,
          );
          expect(
            (await h.repo.applySnapshotRecovery(request)).outcome,
            SnapshotOperationOutcome.unknown,
          );
          await expectLater(
            h.repo.applySnapshotRecovery(request),
            throwsA(_reason(SnapshotsExceptionReason.busy)),
          );
          expect(h.transport.writes, hasLength(1));
        },
      );
    }
    test('rollback impact lists newer exact snapshots and clones without deleting them', () async {
      final h = await _connect();
      final plan = await _recoveryPlan(h, SnapshotRecoveryKind.rollback);
      final newer = _snapshot(id: 'tank/data@newer', guid: '42');
      newer['createtxg'] = '18446744073709551615';
      (newer['properties'] as Map)['createtxg'] = _prop('18446744073709551615');
      (newer['properties'] as Map)['clones'] = _prop('tank/clone');
      h.transport.snapshots.add(newer);
      final review = await h.repo.reviewSnapshotRecovery(plan);
      expect(review.canApply, isFalse);
      expect(review.newerSnapshots.single.clones, ['tank/clone']);
      expect(review.newerSnapshots.single.creationTxg, '18446744073709551615');
      expect(h.transport.writes, isEmpty);
    });
    for (final invalid in [
      'hidden-tag',
      'deferred',
      'guid',
      'forged',
      'wrong-confirmation',
      'no-consent',
      'connection',
    ]) {
      test('$invalid cannot bypass recovery preflight', () async {
        final h = await _connect();
        _setHold(h.transport.snapshots.single);
        final plan = await _recoveryPlan(h, SnapshotRecoveryKind.release);
        var review = await h.repo.reviewSnapshotRecovery(plan);
        var confirmation = plan.target;
        var consent = true;
        switch (invalid) {
          case 'hidden-tag':
            (h.transport.snapshots.single['properties'] as Map)['userrefs'] =
                _prop('2');
          case 'deferred':
            (h.transport.snapshots.single['properties']
                as Map)['defer_destroy'] = _prop(
              'on',
            );
          case 'guid':
            (h.transport.snapshots.single['properties'] as Map)['guid'] = _prop(
              '123',
            );
          case 'forged':
            review = SnapshotRecoveryReview(
              plan: plan,
              snapshots: review.snapshots,
              datasets: review.datasets,
              newerSnapshots: [],
              warnings: [],
            );
          case 'wrong-confirmation':
            confirmation = 'wrong';
          case 'no-consent':
            consent = false;
          case 'connection':
            h.current = false;
        }
        try {
          expect(
            (await h.repo.applySnapshotRecovery(
              SnapshotRecoveryRequest(
                review: review,
                confirmation: confirmation,
                acknowledgeDataLoss: consent,
              ),
            )).outcome,
            SnapshotOperationOutcome.rejected,
          );
        } on SnapshotsException {
          /* rejection before dispatch */
        }
        expect(h.transport.writes, isEmpty);
      });
    }
    test(
      'readonly account cannot obtain mutation authority from recovery plan',
      () async {
        final h = await _connect(
          methods: {'pool.dataset.query', 'pool.snapshot.query'},
        );
        final plan = await _recoveryPlan(h, SnapshotRecoveryKind.hold);
        await expectLater(
          h.repo.reviewSnapshotRecovery(plan),
          throwsA(_reason(SnapshotsExceptionReason.unavailableMethod)),
        );
        expect(h.transport.writes, isEmpty);
      },
    );
    test(
      'bulk deletion stops after uncertain second dispatch without retry',
      () async {
        final h = await _connect();
        h.transport.snapshots.add(
          _snapshot(id: 'tank/data@manual-2', guid: '42'),
        );
        final selected = (await h.repo.loadSnapshots(_query)).entries;
        final review = await h.repo.reviewSnapshotRecovery(
          SnapshotRecoveryPlan.bulkDelete(selected),
        );
        h.transport.failAtWrite = 2;
        expect(
          (await h.repo.applySnapshotRecovery(
            SnapshotRecoveryRequest(
              review: review,
              confirmation: review.plan.target,
              acknowledgeDataLoss: true,
            ),
          )).outcome,
          SnapshotOperationOutcome.unknown,
        );
        expect(h.transport.writes, hasLength(2));
        expect(h.transport.snapshots, hasLength(1));
      },
    );
    test('legacy create invalidates prior recovery authority', () async {
      final h = await _connect();
      final parent = (await h.repo.loadSnapshotDatasets()).single;
      final snapshot = (await h.repo.loadSnapshots(_query)).entries.single;
      final review = await h.repo.reviewSnapshotRecovery(
        SnapshotRecoveryPlan.hold(snapshot),
      );
      expect(
        (await h.repo.createSnapshot(
          SnapshotCreateRequest(dataset: parent, name: 'new-point'),
        )).outcome,
        SnapshotOperationOutcome.verified,
      );
      await expectLater(
        h.repo.applySnapshotRecovery(
          SnapshotRecoveryRequest(
            review: review,
            confirmation: review.plan.target,
          ),
        ),
        throwsA(_reason(SnapshotsExceptionReason.staleSnapshot)),
      );
      expect(h.transport.writes, hasLength(1));
    });
    test(
      'descendant set stops and locks after a partial second-write failure',
      () async {
        final h = await _connect();
        h.transport.datasets.add(_dataset(id: 'tank/data/child', guid: '42'));
        final plan = await _recoveryPlan(
          h,
          SnapshotRecoveryKind.recursiveCreate,
        );
        final review = await h.repo.reviewSnapshotRecovery(plan);
        h.transport.failAtWrite = 2;
        final request = SnapshotRecoveryRequest(
          review: review,
          confirmation: plan.target,
        );
        expect(
          (await h.repo.applySnapshotRecovery(request)).outcome,
          SnapshotOperationOutcome.unknown,
        );
        expect(
          h.transport.snapshots.where(
            (s) => (s['id'] as String).endsWith('@set-1'),
          ),
          hasLength(1),
        );
        await expectLater(
          h.repo.applySnapshotRecovery(request),
          throwsA(_reason(SnapshotsExceptionReason.busy)),
        );
        expect(h.transport.writes, hasLength(2));
      },
    );
    test(
      'descendant set membership drift rejects without creating anything',
      () async {
        final h = await _connect();
        final plan = await _recoveryPlan(
          h,
          SnapshotRecoveryKind.recursiveCreate,
        );
        final review = await h.repo.reviewSnapshotRecovery(plan);
        h.transport.datasets.add(
          _dataset(id: 'tank/data/new-child', guid: '42'),
        );
        expect(
          (await h.repo.applySnapshotRecovery(
            SnapshotRecoveryRequest(review: review, confirmation: plan.target),
          )).outcome,
          SnapshotOperationOutcome.rejected,
        );
        expect(h.transport.writes, isEmpty);
      },
    );
  });
  test('disconnected reads and writes cannot call a transport', () async {
    final h = _Harness();
    addTearDown(h.repo.close);
    expect(h.repo.snapshotsCapabilities.supported, isFalse);
    await expectLater(
      h.repo.loadSnapshotDatasets(),
      throwsA(_reason(SnapshotsExceptionReason.notAuthenticated)),
    );
    expect(h.transport.requests, isEmpty);
  });
  for (final version in ['25.04.2', '25.10-BETA.1', '26.0.1']) {
    test('unsupported $version never queries snapshots', () async {
      final h = await _connect(version: version);
      expect(h.repo.snapshotsCapabilities.supported, isFalse);
      await expectLater(
        h.repo.loadSnapshots(_query),
        throwsA(_reason(SnapshotsExceptionReason.unsupportedVersion)),
      );
      expect(h.transport.snapshotQueries, isEmpty);
    });
  }
  test(
    'read-only role can load snapshots without write capability or writes',
    () async {
      final h = await _connect(
        methods: {'pool.snapshot.query', 'pool.dataset.query'},
      );
      expect(h.repo.snapshotsCapabilities.supported, isTrue);
      expect(h.repo.snapshotsCapabilities.canCreate, isFalse);
      expect(h.repo.snapshotsCapabilities.canDelete, isFalse);
      final dataset = (await h.repo.loadSnapshotDatasets()).single;
      final snapshot = (await h.repo.loadSnapshots(_query)).entries.single;
      expect(snapshot.usedBytes, 1024);
      await expectLater(
        h.repo.createSnapshot(
          SnapshotCreateRequest(dataset: dataset, name: 'new'),
        ),
        throwsA(_reason(SnapshotsExceptionReason.unavailableMethod)),
      );
      await expectLater(
        h.repo.deleteSnapshot(
          SnapshotDeleteRequest(snapshot: snapshot, confirmation: snapshot.id),
        ),
        throwsA(_reason(SnapshotsExceptionReason.unavailableMethod)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test('inventory is bounded name discovery then exact details with holds and properties', () async {
    final h = await _connect();
    final page = await h.repo.loadSnapshots(
      const SnapshotQuery(dataset: 'tank/data', namePrefix: 'manual-'),
    );
    final entry = page.entries.single;
    expect(entry.guid, '18446744073709551615');
    expect(
      entry.createdAt,
      DateTime.fromMillisecondsSinceEpoch(1720000000000, isUtc: true),
    );
    expect(entry.canDelete, isTrue);
    expect(() => page.entries.clear(), throwsUnsupportedError);
    expect(() => entry.holds.clear(), throwsUnsupportedError);
    final reads = h.transport.snapshotQueries.toList();
    expect(reads.first['params'], [
      [
        ['dataset', '=', 'tank/data'],
        ['name', '^', 'tank/data@manual-'],
      ],
      {
        'select': ['name'],
        'order_by': ['name'],
        'offset': 0,
        'limit': 26,
      },
    ]);
    final exact = reads.last['params'] as List;
    expect(exact.first, [
      ['id', '=', entry.id],
    ]);
    expect((exact.last as Map)['limit'], 2);
    final extra = (exact.last as Map)['extra'] as Map;
    expect(extra['holds'], isTrue);
    expect(
      extra['properties'],
      containsAll([
        'guid',
        'creation',
        'used',
        'referenced',
        'userrefs',
        'clones',
        'defer_destroy',
      ]),
    );
    expect(h.transport.writes, isEmpty);
  });
  test('page never fetches more than 25 details and respects offset', () async {
    final h = await _connect();
    h.transport.snapshots = [
      for (var n = 0; n < 52; n++)
        _snapshot(id: 'tank/data@snapshot-${n.toString().padLeft(2, '0')}'),
    ];
    final result = await h.repo.loadSnapshots(
      const SnapshotQuery(dataset: 'tank/data', page: 1),
    );
    expect(result.entries.length, 25);
    expect(result.hasMore, isTrue);
    expect(result.entries.first.name, 'snapshot-25');
    expect(h.transport.snapshotQueries.length, 26);
    expect(h.transport.writes, isEmpty);
  });
  for (final query in [
    const SnapshotQuery(dataset: 'tank/data', page: 40),
    const SnapshotQuery(dataset: 'tank/data', page: -1),
    const SnapshotQuery(dataset: 'tank/../data'),
    const SnapshotQuery(dataset: 'tank/data', namePrefix: '*'),
  ]) {
    test(
      'invalid query ${query.dataset}/${query.page}/${query.namePrefix} never sends',
      () async {
        final h = await _connect();
        await expectLater(
          h.repo.loadSnapshots(query),
          throwsA(_reason(SnapshotsExceptionReason.invalidRequest)),
        );
        expect(h.transport.snapshotQueries, isEmpty);
      },
    );
  }
  test(
    'native create is one nonrecursive write and independent identity readback',
    () async {
      final h = await _connect();
      final dataset = (await h.repo.loadSnapshotDatasets()).single;
      final result = await h.repo.createSnapshot(
        SnapshotCreateRequest(dataset: dataset, name: 'manual-new'),
      );
      expect(result.outcome, SnapshotOperationOutcome.verified);
      expect(h.transport.writes.single['params'], [
        {
          'dataset': 'tank/data',
          'name': 'manual-new',
          'recursive': false,
          'vmware_sync': false,
        },
      ]);
      expect(h.transport.snapshots.length, 2);
    },
  );
  test('create rejects an existing name without writes', () async {
    final h = await _connect();
    final dataset = (await h.repo.loadSnapshotDatasets()).single;
    final result = await h.repo.createSnapshot(
      SnapshotCreateRequest(dataset: dataset, name: 'manual-1'),
    );
    expect(result.outcome, SnapshotOperationOutcome.rejected);
    expect(h.transport.writes, isEmpty);
  });
  for (final change in ['guid', 'creation', 'locked']) {
    test('filesystem $change drift prevents creation', () async {
      final h = await _connect();
      final dataset = (await h.repo.loadSnapshotDatasets()).single;
      h.transport.datasets.single[change] = change == 'locked'
          ? true
          : _prop('999');
      final result = await h.repo.createSnapshot(
        SnapshotCreateRequest(dataset: dataset, name: 'new'),
      );
      expect(result.outcome, SnapshotOperationOutcome.rejected);
      expect(h.transport.writes, isEmpty);
    });
  }
  for (final name in ['../x', 'a@b', '', '*', 'a/b', 'a b']) {
    test('invalid creation name $name is never dispatched', () async {
      final h = await _connect();
      final dataset = (await h.repo.loadSnapshotDatasets()).single;
      await expectLater(
        h.repo.createSnapshot(
          SnapshotCreateRequest(dataset: dataset, name: name),
        ),
        throwsA(_reason(SnapshotsExceptionReason.invalidRequest)),
      );
      expect(h.transport.writes, isEmpty);
    });
  }
  test(
    'created receipt must match fresh GUID or outcome remains unknown',
    () async {
      final h = await _connect();
      final dataset = (await h.repo.loadSnapshotDatasets()).single;
      h.transport.failure = 'receipt';
      final result = await h.repo.createSnapshot(
        SnapshotCreateRequest(dataset: dataset, name: 'new'),
      );
      expect(result.outcome, SnapshotOperationOutcome.unknown);
      expect(h.transport.writes.length, 1);
    },
  );
  test('delete uses issued identity and exact typed confirmation, then verifies absence', () async {
    final h = await _connect();
    final snapshot = (await h.repo.loadSnapshots(_query)).entries.single;
    final result = await h.repo.deleteSnapshot(
      SnapshotDeleteRequest(snapshot: snapshot, confirmation: snapshot.id),
    );
    expect(result.outcome, SnapshotOperationOutcome.verified);
    expect(h.transport.writes.single['params'], [
      snapshot.id,
      {'recursive': false, 'defer': false},
    ]);
    expect(h.transport.snapshots, isEmpty);
    expect(h.transport.snapshotQueries.last['params'], [
      [
        ['id', '=', snapshot.id],
      ],
      {
        'limit': 2,
        'extra': {
          'holds': true,
          'properties': [
            'guid',
            'creation',
            'createtxg',
            'used',
            'referenced',
            'userrefs',
            'clones',
            'defer_destroy',
          ],
        },
      },
    ]);
  });
  for (final confirmation in [
    'manual-1',
    ' tank/data@manual-1',
    'tank/data@manual-1 ',
  ]) {
    test('confirmation is exact without trimming: $confirmation', () async {
      final h = await _connect();
      final snapshot = (await h.repo.loadSnapshots(_query)).entries.single;
      await expectLater(
        h.repo.deleteSnapshot(
          SnapshotDeleteRequest(snapshot: snapshot, confirmation: confirmation),
        ),
        throwsA(_reason(SnapshotsExceptionReason.invalidRequest)),
      );
      expect(h.transport.writes, isEmpty);
    });
  }
  for (final safety in [
    'hold',
    'hiddenHold',
    'clone',
    'defer',
    'missingHolds',
    'missingClones',
    'missingUserrefs',
    'missingDefer',
  ]) {
    test(
      '$safety disables deletion and is rechecked before every write',
      () async {
        final h = await _connect();
        final snapshot = (await h.repo.loadSnapshots(_query)).entries.single;
        final raw = h.transport.snapshots.single;
        final props = raw['properties'] as Map;
        switch (safety) {
          case 'hold':
            raw['holds'] = {'truenas': 1720000001};
            props['userrefs'] = _prop('1');
          case 'hiddenHold':
            props['userrefs'] = _prop('1');
          case 'clone':
            props['clones'] = _prop('tank/clone');
          case 'defer':
            props['defer_destroy'] = _prop('on');
          case 'missingHolds':
            raw.remove('holds');
          case 'missingClones':
            props.remove('clones');
          case 'missingUserrefs':
            props.remove('userrefs');
          case 'missingDefer':
            props.remove('defer_destroy');
        }
        final result = await h.repo.deleteSnapshot(
          SnapshotDeleteRequest(snapshot: snapshot, confirmation: snapshot.id),
        );
        expect(result.outcome, SnapshotOperationOutcome.rejected);
        expect(h.transport.writes, isEmpty);
        final reload = (await h.repo.loadSnapshots(_query)).entries.single;
        expect(reload.canDelete, isFalse);
      },
    );
  }
  for (final identity in ['guid', 'creation', 'createtxg', 'gone']) {
    test('$identity change rejects fresh deletion preflight', () async {
      final h = await _connect();
      final snapshot = (await h.repo.loadSnapshots(_query)).entries.single;
      if (identity == 'gone') {
        h.transport.snapshots.clear();
      } else {
        (h.transport.snapshots.single['properties'] as Map)[identity] = _prop(
          '999',
        );
        if (identity == 'createtxg') {
          h.transport.snapshots.single['createtxg'] = '999';
        }
      }
      final result = await h.repo.deleteSnapshot(
        SnapshotDeleteRequest(snapshot: snapshot, confirmation: snapshot.id),
      );
      expect(result.outcome, SnapshotOperationOutcome.rejected);
      expect(h.transport.writes, isEmpty);
    });
  }
  test(
    'reload invalidates previous issued snapshots and filesystem objects',
    () async {
      final h = await _connect();
      final snapshot = (await h.repo.loadSnapshots(_query)).entries.single;
      await h.repo.loadSnapshots(_query);
      await expectLater(
        h.repo.deleteSnapshot(
          SnapshotDeleteRequest(snapshot: snapshot, confirmation: snapshot.id),
        ),
        throwsA(_reason(SnapshotsExceptionReason.staleSnapshot)),
      );
      final dataset = (await h.repo.loadSnapshotDatasets()).single;
      await h.repo.loadSnapshotDatasets();
      await expectLater(
        h.repo.createSnapshot(
          SnapshotCreateRequest(dataset: dataset, name: 'new'),
        ),
        throwsA(_reason(SnapshotsExceptionReason.staleSnapshot)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test('a caller-constructed identity cannot authorize a deletion', () async {
    final h = await _connect();
    final actual = (await h.repo.loadSnapshots(_query)).entries.single;
    final forged = SnapshotEntry(
      id: actual.id,
      dataset: actual.dataset,
      name: actual.name,
      guid: actual.guid,
      creationSeconds: actual.creationSeconds,
      creationTxg: actual.creationTxg,
      usedBytes: actual.usedBytes,
      referencedBytes: actual.referencedBytes,
      holds: {},
      userReferences: 0,
      clones: [],
      deferredDestroy: false,
    );
    await expectLater(
      h.repo.deleteSnapshot(
        SnapshotDeleteRequest(snapshot: forged, confirmation: forged.id),
      ),
      throwsA(_reason(SnapshotsExceptionReason.staleSnapshot)),
    );
    expect(h.transport.writes, isEmpty);
  });
  test(
    'connection change during preflight prevents the following write',
    () async {
      final h = await _connect();
      final snapshot = (await h.repo.loadSnapshots(_query)).entries.single;
      h.transport.onSnapshotRead = () => h.current = false;
      final result = await h.repo.deleteSnapshot(
        SnapshotDeleteRequest(snapshot: snapshot, confirmation: snapshot.id),
      );
      expect(result.outcome, SnapshotOperationOutcome.rejected);
      expect(h.transport.writes, isEmpty);
    },
  );
  for (final failure in ['timeout', 'error', 'mismatch', 'false']) {
    test(
      '$failure after dispatch is unknown, never retried and blocks further changes',
      () async {
        final h = await _connect();
        final snapshot = (await h.repo.loadSnapshots(_query)).entries.single;
        h.transport.failure = failure;
        final result = await h.repo.deleteSnapshot(
          SnapshotDeleteRequest(snapshot: snapshot, confirmation: snapshot.id),
        );
        expect(result.outcome, SnapshotOperationOutcome.unknown);
        expect(result.message, isNot(contains('private-secret')));
        final dataset = (await h.repo.loadSnapshotDatasets()).single;
        await expectLater(
          h.repo.createSnapshot(
            SnapshotCreateRequest(dataset: dataset, name: 'new'),
          ),
          throwsA(_reason(SnapshotsExceptionReason.busy)),
        );
        expect(h.transport.writes.length, 1);
      },
    );
  }
  test('duplicate submission cannot send a second mutation', () async {
    final h = await _connect();
    final snapshot = (await h.repo.loadSnapshots(_query)).entries.single;
    h.transport.failure = 'timeout';
    final request = SnapshotDeleteRequest(
      snapshot: snapshot,
      confirmation: snapshot.id,
    );
    final first = h.repo.deleteSnapshot(request);
    await expectLater(
      h.repo.deleteSnapshot(request),
      throwsA(_reason(SnapshotsExceptionReason.busy)),
    );
    await first;
    expect(h.transport.writes.length, 1);
  });
  test('malformed exact result cannot be used as deletion identity', () async {
    final h = await _connect();
    (h.transport.snapshots.single['properties'] as Map)['used'] = _prop(
      '9007199254740992',
    );
    await expectLater(
      h.repo.loadSnapshots(_query),
      throwsA(_reason(SnapshotsExceptionReason.invalidResponse)),
    );
    expect(h.transport.writes, isEmpty);
  });
}

Future<_Harness> _connect({
  String version = '25.10.1',
  Set<String> methods = _methods,
}) async {
  final h = _Harness(version: version, methods: methods);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'fixture-key',
    username: 'admin',
    isConnectionCurrent: () => h.current,
  );
  return h;
}

void _setHold(Map<String, Object?> snapshot) {
  snapshot['holds'] = {'truenas': 1720000100};
  (snapshot['properties'] as Map)['userrefs'] = _prop('1');
}

Future<SnapshotRecoveryPlan> _recoveryPlan(
  _Harness h,
  SnapshotRecoveryKind kind,
) async {
  final dataset = (await h.repo.loadSnapshotDatasets()).first;
  final snapshot = (await h.repo.loadSnapshots(_query)).entries.first;
  return switch (kind) {
    SnapshotRecoveryKind.clone => SnapshotRecoveryPlan.clone(
      snapshot: snapshot,
      parent: dataset,
      newName: 'recovered',
    ),
    SnapshotRecoveryKind.rollback => SnapshotRecoveryPlan.rollback(snapshot),
    SnapshotRecoveryKind.hold => SnapshotRecoveryPlan.hold(snapshot),
    SnapshotRecoveryKind.release => SnapshotRecoveryPlan.release(snapshot),
    SnapshotRecoveryKind.recursiveCreate =>
      SnapshotRecoveryPlan.recursiveCreate(dataset: dataset, name: 'set-1'),
    SnapshotRecoveryKind.bulkDelete => SnapshotRecoveryPlan.bulkDelete([
      snapshot,
    ]),
  };
}

class _Harness {
  _Harness({String version = '25.10.1', Set<String> methods = _methods}) {
    transport = _Transport(version, methods);
    repo = TrueNasSessionRepository(
      connector: _Connector(transport),
      managementRequestTimeout: const Duration(milliseconds: 50),
    );
  }
  var current = true;
  late final _Transport transport;
  late final TrueNasSessionRepository repo;
}

class _Connector implements RpcConnector {
  _Connector(this.transport);
  final RpcTransport transport;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => transport;
}

class _Transport implements RpcTransport {
  _Transport(this.version, this.methods);
  final String version;
  final Set<String> methods;
  final inbound = StreamController<String>();
  final requests = <Map<String, Object?>>[];
  List<Map<String, Object?>> datasets = [_dataset()];
  List<Map<String, Object?>> snapshots = [_snapshot()];
  String? failure;
  int? failAtWrite;
  void Function()? onSnapshotRead;
  Iterable<Map<String, Object?>> get writes => requests.where(
    (r) => {
      'pool.snapshot.create',
      'pool.snapshot.delete',
      'pool.snapshot.clone',
      'pool.snapshot.rollback',
      'pool.snapshot.hold',
      'pool.snapshot.release',
    }.contains(r['method']),
  );
  Iterable<Map<String, Object?>> get snapshotQueries =>
      requests.where((r) => r['method'] == 'pool.snapshot.query');
  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String frame) async {
    final request = Map<String, Object?>.from(jsonDecode(frame) as Map);
    requests.add(request);
    final method = request['method'];
    final params = request['params'] as List? ?? [];
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
          for (final m in methods)
            m: {
              'accepts': [],
              'returns': [],
              'job': false,
              'no_auth_required': false,
            },
        };
      case 'pool.dataset.query':
        final filter = (params.first as List).single as List;
        result = filter.first == 'id'
            ? datasets.where((row) => row['id'] == filter.last).toList()
            : datasets;
        result = [
          for (final row in result as List)
            {
              ...row as Map,
              if (row['user_properties'] is Map)
                'managedby': (row['user_properties'] as Map)['managedby'],
            },
        ];
      case 'pool.snapshot.query':
        onSnapshotRead?.call();
        final filters = params.first as List;
        final options = params.last as Map;
        var rows = snapshots.toList();
        for (final value in filters) {
          final filter = value as List;
          rows = rows
              .where(
                (row) => filter[1] == '='
                    ? row[filter.first] == filter.last
                    : (row[filter.first] as String).startsWith(
                        filter.last as String,
                      ),
              )
              .toList();
        }
        if (options['select'] != null) {
          rows.sort(
            (a, b) => (a['name'] as String).compareTo(b['name'] as String),
          );
          result = rows
              .skip(options['offset'] as int? ?? 0)
              .take(options['limit'] as int)
              .map((r) => {'name': r['name']})
              .toList();
        } else {
          result = rows;
        }
      case 'pool.snapshot.create':
      case 'pool.snapshot.delete':
      case 'pool.snapshot.clone':
      case 'pool.snapshot.rollback':
      case 'pool.snapshot.hold':
      case 'pool.snapshot.release':
        if (writes.length == failAtWrite) return;
        if (failure == 'timeout') return;
        if (failure == 'error') {
          inbound.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': request['id'],
              'error': {'code': -32001, 'message': 'private-secret'},
            }),
          );
          return;
        }
        if (method == 'pool.snapshot.create') {
          final payload = params.single as Map;
          final created = _snapshot(
            id: '${payload['dataset']}@${payload['name']}',
            guid: '456',
          );
          if (failure != 'mismatch') snapshots.add(created);
          result = failure == 'receipt'
              ? _snapshot(id: created['id'] as String, guid: '999')
              : (Map<String, Object?>.from(created)..remove('holds'));
        } else if (method == 'pool.snapshot.delete') {
          if (failure != 'mismatch' && failure != 'false') {
            snapshots.removeWhere((s) => s['id'] == params.first);
          }
          result = failure != 'false';
        } else if (method == 'pool.snapshot.clone') {
          final payload = params.single as Map;
          final destination = _dataset(
            id: payload['dataset_dst'] as String,
            guid: '777',
          );
          destination['origin'] = _prop(payload['snapshot'] as String);
          destination['readonly'] = _prop('on');
          if (failure != 'mismatch') {
            datasets.add(destination);
            (snapshots.singleWhere(
                  (s) => s['id'] == payload['snapshot'],
                )['properties']
                as Map)['clones'] = _prop(
              payload['dataset_dst'] as String,
            );
          }
          result = true;
        } else if (method == 'pool.snapshot.rollback') {
          if (failure != 'mismatch') {
            datasets.singleWhere(
              (d) => d['id'] == (params.first as String).split('@').first,
            )['written'] = _prop(
              '0',
            );
          }
        } else if (method == 'pool.snapshot.hold') {
          if (failure != 'mismatch') {
            _setHold(snapshots.singleWhere((s) => s['id'] == params.first));
          }
        } else if (method == 'pool.snapshot.release') {
          if (failure != 'mismatch') {
            final snapshot = snapshots.singleWhere(
              (s) => s['id'] == params.first,
            );
            snapshot['holds'] = <String, Object?>{};
            (snapshot['properties'] as Map)['userrefs'] = _prop('0');
          }
        }
    }
    inbound.add(
      jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() => inbound.close();
}
