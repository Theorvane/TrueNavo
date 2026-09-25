import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _methods = {
  'pool.dataset.query',
  'pool.dataset.get_quota',
  'pool.dataset.set_quota',
  'pool.dataset.attachments',
  'user.get_user_obj',
  'group.get_group_obj',
  'pool.dataset.create',
};
const _secret = 'private-wire-error-must-not-leak';
Map<String, Object?> _prop(
  Object value, {
  String source = 'LOCAL',
  String? info,
}) => {
  'rawvalue': '$value',
  'value': '$value',
  'parsed': value,
  'source': source,
  'source_info': info,
};
Map<String, Object?> _dataset(String id, String guid) => {
  'id': id,
  'type': 'FILESYSTEM',
  'guid': _prop(guid),
  'creation': _prop(1700000000),
  'mountpoint': '/mnt/$id',
  'encrypted': false,
  'locked': false,
  'readonly': _prop('off'),
  'quota': _prop(0),
  'refquota': _prop(0),
  'reservation': _prop(0),
  'refreservation': _prop(0),
  'origin': _prop('', source: 'NONE'),
  'user_properties': {'managedby': _prop('-')},
};
Map<String, Object?> _quota(
  QuotaKind kind,
  int id, {
  int? quota = 1000,
  int? objects = 20,
  int? used = 200,
  int? usedObjects = 4,
}) => {
  'quota_type': kind.wire,
  'id': id,
  'name': id == 1000 ? 'alice' : 'staff',
  'quota': ?quota,
  'obj_quota': ?objects,
  'used_bytes': ?used,
  'obj_used': ?usedObjects,
};
Map<String, Object?> _identity(QuotaKind kind, int id) => {
  if (kind == QuotaKind.user) ...{
    'pw_uid': id,
    'pw_gid': 2000,
    'pw_name': 'alice',
    'pw_dir': '/private/home',
    'pw_gecos': _secret,
    'pw_shell': '/bin/sh',
    'grouplist': null,
  } else ...{
    'gr_gid': id,
    'gr_name': 'staff',
    'gr_mem': ['private-member'],
  },
  'local': true,
  'source': 'LOCAL',
  'sid': null,
};
Matcher _reason(QuotaExceptionReason reason) =>
    isA<QuotaException>().having((e) => e.reason, 'reason', reason);

void main() {
  test('disconnected inventory has no wire effects', () async {
    final h = _Harness();
    addTearDown(h.repo.close);
    expect(h.repo.quotaCapabilities.supported, isFalse);
    await expectLater(
      h.repo.loadQuotaDatasets(),
      throwsA(_reason(QuotaExceptionReason.notAuthenticated)),
    );
    expect(h.wire.requests, isEmpty);
  });
  for (final version in ['25.04.2', '25.10-BETA.1', '26.0.0', '25.10.1\n']) {
    test('unsupported $version rejects before quota reads', () async {
      final h = await _connect(version: version);
      await expectLater(
        h.repo.loadQuotaDatasets(),
        throwsA(_reason(QuotaExceptionReason.unsupportedVersion)),
      );
      expect(h.wire.requests, hasLength(4));
    });
  }
  test(
    'inventory exact bounded public query and raw immutable values',
    () async {
      final h = await _connect();
      final datasets = await h.repo.loadQuotaDatasets();
      expect(datasets.map((d) => d.id), ['tank', 'tank/data']);
      expect(() => datasets.clear(), throwsUnsupportedError);
      final args = h.wire.requests.last['params'] as List;
      expect(args.first, [
        ['type', '=', 'FILESYSTEM'],
      ]);
      expect((args.last as Map)['limit'], 257);
      expect(
        (args.last as Map)['select'],
        contains(equals(['user_properties.managedby', 'managedby'])),
      );
      expect(((args.last as Map)['extra'] as Map)['retrieve_children'], false);
      final inventory = await h.repo.loadQuotas(datasets.last);
      expect(inventory.entry(QuotaKind.user, 1000)!.usedBytes, 200);
      expect(inventory.entry(QuotaKind.group, 2000)!.objectLimit, 20);
      expect(() => inventory.entries.clear(), throwsUnsupportedError);
      expect(h.wire.quotaRequests.map((r) => r['params']), [
        [
          'tank/data',
          'USER',
          [],
          {'limit': 513},
        ],
        [
          'tank/data',
          'GROUP',
          [],
          {'limit': 513},
        ],
      ]);
      expect(h.wire.writes, isEmpty);
    },
  );
  test(
    'sparse quota fields preserve unknown usage and unlimited limits',
    () async {
      final h = await _connect();
      h.wire.users = [
        _quota(
          QuotaKind.user,
          1000,
          quota: null,
          objects: null,
          used: null,
          usedObjects: null,
        ),
      ];
      final inventory = await _inventory(h);
      final entry = inventory.entries.first;
      expect(entry.byteLimit, 0);
      expect(entry.objectLimit, 0);
      expect(entry.usedBytes, isNull);
      expect(entry.usedObjects, isNull);
      h.wire.users = [
        _quota(
          QuotaKind.user,
          1000,
          quota: 0,
          objects: 0,
          used: 0,
          usedObjects: 0,
        ),
      ];
      final zero = (await _inventory(h)).entries.first;
      expect(zero.usedBytes, 0);
      expect(zero.usedObjects, 0);
    },
  );
  for (final field in ['quota', 'obj_quota', 'used_bytes', 'obj_used']) {
    for (final value in <Object?>[
      -1,
      1.5,
      '200',
      true,
      null,
      9007199254740992,
    ]) {
      test('malformed $field $value fails closed', () async {
        final h = await _connect();
        h.wire.users.first[field] = value;
        await expectLater(
          _inventory(h),
          throwsA(_reason(QuotaExceptionReason.invalid)),
        );
        expect(h.wire.writes, isEmpty);
      });
    }
  }
  test(
    'unresolved rows remain readable but root or unknown identity cannot write',
    () async {
      final h = await _connect();
      h.wire.users.first['name'] = null;
      final inventory = await _inventory(h);
      expect(inventory.entries.first.name, isNull);
      for (final id in [0, -1, 4294967295]) {
        await expectLater(
          h.repo.resolveQuotaIdentity(inventory, QuotaKind.user, id),
          throwsA(_reason(QuotaExceptionReason.invalid)),
        );
      }
      h.wire.failMethod = 'user.get_user_obj';
      await expectLater(
        h.repo.resolveQuotaIdentity(inventory, QuotaKind.user, 1000),
        throwsA(_reason(QuotaExceptionReason.unavailable)),
      );
      expect(h.wire.writes, isEmpty);
    },
  );
  for (final kind in QuotaKind.values) {
    test(
      '$kind numeric resolution uses exact nonsecret wrapper and no group expansion',
      () async {
        final h = await _connect();
        final inventory = await _inventory(h);
        final id = kind == QuotaKind.user ? 1000 : 2000;
        final identity = await h.repo.resolveQuotaIdentity(inventory, kind, id);
        expect(identity.id, id);
        expect(identity.local, true);
        expect(identity.displayLabel, isNot(contains(_secret)));
        expect(h.wire.requests.last['params'], [
          {
            kind == QuotaKind.user ? 'uid' : 'gid': id,
            'sid_info': true,
            if (kind == QuotaKind.user) 'get_groups': false,
          },
        ]);
      },
    );
    for (final dimension in ['bytes', 'objects', 'both', 'remove']) {
      test(
        '$kind $dimension sends one exact numeric quota list and independently verifies',
        () async {
          final h = await _connect();
          final review = await _review(
            h,
            kind: kind,
            bytes: dimension == 'objects'
                ? null
                : dimension == 'remove'
                ? 0
                : 2000,
            objects: dimension == 'bytes'
                ? null
                : dimension == 'remove'
                ? 0
                : 40,
          );
          final result = await h.repo.executeQuotaReview(
            review,
            review.confirmation,
          );
          expect(result.outcome, QuotaOutcome.verified);
          final id = kind == QuotaKind.user ? '1000' : '2000';
          expect(h.wire.writes.single['params'], [
            'tank/data',
            [
              if (dimension != 'objects')
                {
                  'quota_type': kind.wire,
                  'id': id,
                  'quota_value': dimension == 'remove' ? 0 : 2000,
                },
              if (dimension != 'bytes')
                {
                  'quota_type': '${kind.wire}OBJ',
                  'id': id,
                  'quota_value': dimension == 'remove' ? 0 : 40,
                },
            ],
          ]);
          expect(
            h.wire.requests.where((r) => r['method'] == 'core.get_jobs'),
            isEmpty,
          );
          await expectLater(
            h.repo.executeQuotaReview(review, review.confirmation),
            throwsA(_reason(QuotaExceptionReason.stale)),
          );
          expect(h.wire.writes, hasLength(1));
        },
      );
    }
  }
  test(
    'new resolved ID with no usage can receive both limits with honest warning',
    () async {
      final h = await _connect();
      h.wire.users = [];
      final review = await _review(h);
      expect(review.warnings.join(' '), contains('usage is not reported'));
      expect(
        (await h.repo.executeQuotaReview(review, review.confirmation)).outcome,
        QuotaOutcome.verified,
      );
    },
  );
  test(
    'below-usage review explicitly warns instead of fabricating safe headroom',
    () async {
      final h = await _connect();
      final review = await _review(h, bytes: 1, objects: 1);
      expect(
        review.warnings.join(' '),
        contains('below the currently reported usage'),
      );
      expect(
        (await h.repo.executeQuotaReview(review, review.confirmation)).outcome,
        QuotaOutcome.verified,
      );
    },
  );
  test('single dimension removal preserves the other and row disappearance is unlimited', () async {
    final h = await _connect();
    final review = await _review(h, bytes: 0, objects: null);
    expect(
      (await h.repo.executeQuotaReview(review, review.confirmation)).outcome,
      QuotaOutcome.verified,
    );
    expect(h.wire.users.first['obj_quota'], 20);
    final remove = await _review(h, bytes: null, objects: 0);
    h.wire.dropEmptyRow = true;
    expect(
      (await h.repo.executeQuotaReview(remove, remove.confirmation)).outcome,
      QuotaOutcome.verified,
    );
  });
  for (final missing in [
    'pool.dataset.get_quota',
    'pool.dataset.query',
    'pool.dataset.set_quota',
    'pool.dataset.attachments',
    'user.get_user_obj',
    'group.get_group_obj',
  ]) {
    test(
      'missing $missing has separate read/write capability with no fallback',
      () async {
        final h = await _connect(methods: _methods.difference({missing}));
        if (missing == 'pool.dataset.get_quota' ||
            missing == 'pool.dataset.query') {
          expect(h.repo.quotaCapabilities.supported, false);
          await expectLater(
            h.repo.loadQuotaDatasets(),
            throwsA(_reason(QuotaExceptionReason.unavailableMethod)),
          );
        } else {
          final kind = missing == 'group.get_group_obj'
              ? QuotaKind.group
              : QuotaKind.user;
          expect(h.repo.quotaCapabilities.canSet(kind), false);
          expect((await _inventory(h)).entries, hasLength(2));
        }
        expect(h.wire.writes, isEmpty);
      },
    );
  }
  for (final flag in [
    'job',
    'no_auth_required',
    'uploadable',
    'downloadable',
    'private',
    '_private',
    'missing',
  ]) {
    test(
      'unsafe or incomplete set_quota metadata $flag cannot enable writes',
      () async {
        final h = await _connect(metadataFault: flag);
        expect(h.repo.quotaCapabilities.canSet(QuotaKind.user), false);
        expect(h.repo.quotaCapabilities.canSet(QuotaKind.group), false);
        expect((await _inventory(h)).entries, hasLength(2));
        expect(h.wire.writes, isEmpty);
      },
    );
  }
  test('known attachment configuration is reviewed without silently stopping service', () async {
    final h = await _connect();
    h.wire.attachments = [
      {
        'type': 'SMB Share',
        'service': 'cifs',
        'attachments': ['share'],
      },
    ];
    final review = await _review(h);
    expect(
      review.warnings.join(' '),
      contains('1 enabled service attachments'),
    );
    expect(
      (await h.repo.executeQuotaReview(review, review.confirmation)).outcome,
      QuotaOutcome.verified,
    );
    expect(h.wire.writes, hasLength(1));
  });
  for (final reason in [
    'encrypted',
    'locked',
    'managed',
    'mountpoint',
    'readonly',
    'clone',
    'ancestor',
  ]) {
    test('$reason dataset is not an admitted quota target', () async {
      final h = await _connect();
      switch (reason) {
        case 'encrypted':
          h.wire.rows.last['encrypted'] = true;
        case 'locked':
          h.wire.rows.last['locked'] = true;
        case 'managed':
          h.wire.rows.last['user_properties'] = {
            'managedby': _prop('application'),
          };
        case 'mountpoint':
          h.wire.rows.last['mountpoint'] = '/outside';
        case 'readonly':
          h.wire.rows.last['readonly'] = _prop('on');
        case 'clone':
          h.wire.rows.last['origin'] = _prop('tank/base@snap', source: 'NONE');
        case 'ancestor':
          h.wire.rows.removeAt(0);
      }
      final datasets = await h.repo.loadQuotaDatasets();
      expect(datasets.last.editable, false);
      await expectLater(
        h.repo.loadQuotas(datasets.last),
        throwsA(_reason(QuotaExceptionReason.stale)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('inherited config source must be an actual ancestor', () async {
    final h = await _connect();
    h.wire.rows.last['readonly'] = _prop(
      'off',
      source: 'INHERITED',
      info: 'tank',
    );
    expect((await h.repo.loadQuotaDatasets()).last.editable, true);
    h.wire.rows.last['readonly'] = _prop(
      'off',
      source: 'INHERITED',
      info: 'other',
    );
    await expectLater(
      h.repo.loadQuotaDatasets(),
      throwsA(_reason(QuotaExceptionReason.invalid)),
    );
  });
  test(
    'forged handles identity and review cannot authorize mutation',
    () async {
      final h = await _connect();
      await expectLater(
        h.repo.loadQuotas(const QuotaDataset(id: 'tank/data', guid: '2')),
        throwsA(_reason(QuotaExceptionReason.stale)),
      );
      final inventory = await _inventory(h);
      const identity = QuotaIdentity(
        kind: QuotaKind.user,
        id: 1000,
        name: 'alice',
        source: 'LOCAL',
        local: true,
      );
      await expectLater(
        h.repo.reviewQuotaChange(
          QuotaChange(
            inventory: inventory,
            identity: identity,
            byteLimit: 2000,
          ),
        ),
        throwsA(_reason(QuotaExceptionReason.stale)),
      );
      final real = await _review(h);
      final forged = QuotaReview(
        dataset: real.dataset,
        identity: real.identity,
        confirmation: real.confirmation,
        changes: real.changes,
        warnings: real.warnings,
      );
      await expectLater(
        h.repo.executeQuotaReview(forged, forged.confirmation),
        throwsA(_reason(QuotaExceptionReason.stale)),
      );
      expect(h.wire.writes, isEmpty);
    },
  );
  test(
    'refresh invalidates every old dataset and quota identity lease',
    () async {
      final h = await _connect();
      final inventory = await _inventory(h);
      final identity = await h.repo.resolveQuotaIdentity(
        inventory,
        QuotaKind.user,
        1000,
      );
      await h.repo.loadQuotaDatasets();
      await expectLater(
        h.repo.loadQuotas(inventory.dataset),
        throwsA(_reason(QuotaExceptionReason.stale)),
      );
      await expectLater(
        h.repo.reviewQuotaChange(
          QuotaChange(
            inventory: inventory,
            identity: identity,
            byteLimit: 2000,
          ),
        ),
        throwsA(_reason(QuotaExceptionReason.stale)),
      );
    },
  );
  test('wrong exact confirmation consumes review before dispatch', () async {
    final h = await _connect();
    final review = await _review(h);
    await expectLater(
      h.repo.executeQuotaReview(review, review.target),
      throwsA(_reason(QuotaExceptionReason.stale)),
    );
    await expectLater(
      h.repo.executeQuotaReview(review, review.confirmation),
      throwsA(_reason(QuotaExceptionReason.stale)),
    );
    expect(h.wire.writes, isEmpty);
  });
  for (final drift in [
    'guid',
    'creation',
    'parent-guid',
    'parent-quota',
    'quota',
    'other-quota',
    'identity',
    'source',
    'primary-group',
    'sid',
    'dependency',
  ]) {
    test('$drift after review rejects without any write', () async {
      final h = await _connect();
      final review = await _review(h);
      switch (drift) {
        case 'guid':
          h.wire.rows.last['guid'] = _prop('9');
        case 'creation':
          h.wire.rows.last['creation'] = _prop(1700000001);
        case 'parent-guid':
          h.wire.rows.first['guid'] = _prop('9');
        case 'parent-quota':
          h.wire.rows.first['quota'] = _prop(99999);
        case 'quota':
          h.wire.users.first['quota'] = 1100;
        case 'other-quota':
          h.wire.groups.first['quota'] = 1100;
        case 'identity':
          h.wire.user['pw_name'] = 'replacement';
        case 'source':
          h.wire.user['source'] = 'LDAP';
          h.wire.user['local'] = false;
        case 'primary-group':
          h.wire.user['pw_gid'] = 3000;
        case 'sid':
          h.wire.user['sid'] = 'S-1-5-21-9999';
        case 'dependency':
          h.wire.attachments = [
            {
              'type': 'SMB',
              'service': 'cifs',
              'attachments': ['new share'],
            },
          ];
      }
      expect(
        (await h.repo.executeQuotaReview(review, review.confirmation)).outcome,
        QuotaOutcome.rejected,
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test(
    'volatile usage changes and zero-only rows do not invalidate limits',
    () async {
      final h = await _connect();
      final review = await _review(h);
      h.wire.users.first['used_bytes'] = 250;
      h.wire.groups.first['obj_used'] = 8;
      h.wire.users.add(
        _quota(QuotaKind.user, 4444, quota: null, objects: null, used: 5),
      );
      expect(
        (await h.repo.executeQuotaReview(review, review.confirmation)).outcome,
        QuotaOutcome.verified,
      );
    },
  );
  test('final preflight catches quota drift during dependency reads', () async {
    final h = await _connect();
    final review = await _review(h);
    h.wire.onRequest = (r) {
      if (r['method'] == 'pool.dataset.attachments') {
        h.wire.groups.first['obj_quota'] = 99;
      }
    };
    expect(
      (await h.repo.executeQuotaReview(review, review.confirmation)).outcome,
      QuotaOutcome.rejected,
    );
    expect(h.wire.writes, isEmpty);
  });
  for (final fault in [
    'timeout',
    'error',
    'job',
    'true',
    'post-guid',
    'post-quota',
    'post-other-quota',
    'post-identity',
    'post-dependency',
    'post-read',
  ]) {
    test('$fault after sending stays unknown and cannot replay', () async {
      final h = await _connect();
      final review = await _review(h);
      h.wire.fault = fault;
      final result = await h.repo.executeQuotaReview(
        review,
        review.confirmation,
      );
      expect(result.outcome, QuotaOutcome.unknown);
      expect(result.message, isNot(contains(_secret)));
      await expectLater(
        h.repo.executeQuotaReview(review, review.confirmation),
        throwsA(_reason(QuotaExceptionReason.busy)),
      );
      expect(h.wire.writes, hasLength(1));
      expect(
        h.wire.requests
            .where((r) => '${r['method']}'.startsWith('core.'))
            .map((r) => r['method']),
        ['core.get_methods'],
      );
    });
  }
  test('unknown quota holds the shared SDK mutation guard', () async {
    final h = await _connect();
    final review = await _review(h);
    h.wire.fault = 'job';
    await h.repo.executeQuotaReview(review, review.confirmation);
    await expectLater(
      h.repo.execute(
        const CreateDatasetCommand(parent: 'tank', name: 'never-created'),
      ),
      throwsA(
        isA<ManagementException>().having(
          (e) => e.reason,
          'reason',
          ManagementExceptionReason.busy,
        ),
      ),
    );
    expect(h.wire.writes, hasLength(1));
  });
  test('session expiration before dispatch prevents writes, after dispatch preserves unknown', () async {
    final h = await _connect();
    final review = await _review(h);
    h.current = false;
    await expectLater(
      h.repo.executeQuotaReview(review, review.confirmation),
      throwsA(_reason(QuotaExceptionReason.notAuthenticated)),
    );
    expect(h.wire.writes, isEmpty);
    h.current = true;
    h.wire.onRequest = (r) {
      if (r['method'] == 'pool.dataset.set_quota') h.current = false;
    };
    expect(
      (await h.repo.executeQuotaReview(review, review.confirmation)).outcome,
      QuotaOutcome.unknown,
    );
    expect(h.wire.writes, hasLength(1));
  });
  test('bounded inventory rejects duplicates and truncation', () async {
    final h = await _connect();
    h.wire.rows.add(h.wire.rows.last);
    await expectLater(
      h.repo.loadQuotaDatasets(),
      throwsA(_reason(QuotaExceptionReason.invalid)),
    );
    h.wire.rows.removeLast();
    h.wire.users.add(h.wire.users.first);
    await expectLater(
      _inventory(h),
      throwsA(_reason(QuotaExceptionReason.invalid)),
    );
    h.wire.users = [for (var i = 0; i < 513; i++) _quota(QuotaKind.user, i)];
    await expectLater(
      _inventory(h),
      throwsA(_reason(QuotaExceptionReason.invalid)),
    );
    h.wire.rows.addAll([
      for (var i = 0; i < 256; i++) _dataset('tank/d$i', '${i + 5}'),
    ]);
    await expectLater(
      h.repo.loadQuotaDatasets(),
      throwsA(_reason(QuotaExceptionReason.invalid)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test(
    'no-op negative fractional overflow or root quota is never admitted',
    () async {
      final h = await _connect();
      final i = await _inventory(h);
      final id = await h.repo.resolveQuotaIdentity(i, QuotaKind.user, 1000);
      for (final value in [-1, 9007199254740992, 1000]) {
        await expectLater(
          h.repo.reviewQuotaChange(
            QuotaChange(inventory: i, identity: id, byteLimit: value),
          ),
          throwsA(_reason(QuotaExceptionReason.invalid)),
        );
      }
      await expectLater(
        h.repo.reviewQuotaChange(QuotaChange(inventory: i, identity: id)),
        throwsA(_reason(QuotaExceptionReason.invalid)),
      );
      expect(h.wire.writes, isEmpty);
    },
  );
  test(
    'identity malformed id cannot bind the selected numeric account',
    () async {
      final h = await _connect();
      final i = await _inventory(h);
      h.wire.user['pw_uid'] = 1001;
      await expectLater(
        h.repo.resolveQuotaIdentity(i, QuotaKind.user, 1000),
        throwsA(_reason(QuotaExceptionReason.invalid)),
      );
      expect(h.wire.writes, isEmpty);
    },
  );
  test('safe exceptions never expose raw remote messages', () async {
    final h = await _connect();
    final i = await _inventory(h);
    h.wire.failMethod = 'user.get_user_obj';
    try {
      await h.repo.resolveQuotaIdentity(i, QuotaKind.user, 1000);
      fail('expected exception');
    } on QuotaException catch (e) {
      expect('$e', isNot(contains(_secret)));
    }
  });
  for (final guid in ['0', '00000', '18446744073709551616']) {
    test('GUID $guid is not an admitted uint64 identity', () async {
      final h = await _connect();
      h.wire.rows.last['guid'] = _prop(guid);
      await expectLater(
        h.repo.loadQuotaDatasets(),
        throwsA(_reason(QuotaExceptionReason.invalid)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('maximum uint64 GUID remains an exact string', () async {
    final h = await _connect();
    h.wire.rows.last['guid'] = _prop('18446744073709551615');
    expect(
      (await h.repo.loadQuotaDatasets()).last.guid,
      '18446744073709551615',
    );
  });
  test(
    'literal none is a real managedby value, not an absence marker',
    () async {
      final h = await _connect();
      h.wire.rows.last['user_properties'] = {'managedby': _prop('none')};
      expect((await h.repo.loadQuotaDatasets()).last.editable, false);
      expect(h.wire.writes, isEmpty);
    },
  );
  test(
    'floating numeric identity cannot impersonate an exact integer ID',
    () async {
      final h = await _connect();
      final inventory = await _inventory(h);
      h.wire.user['pw_uid'] = 1000.0;
      await expectLater(
        h.repo.resolveQuotaIdentity(inventory, QuotaKind.user, 1000),
        throwsA(_reason(QuotaExceptionReason.invalid)),
      );
    },
  );
  for (final stage in [
    'quota-read',
    'last-identity',
    'post-identity',
    'post-attachments',
  ]) {
    test(
      'dataset replacement during $stage is enclosed by identity proof',
      () async {
        final h = await _connect();
        final review = await _review(h);
        var identities = 0;
        h.wire.onRequest = (request) {
          final method = request['method'];
          if (method == 'user.get_user_obj') identities++;
          final replace = switch (stage) {
            'quota-read' => method == 'pool.dataset.get_quota',
            'last-identity' => method == 'user.get_user_obj' && identities == 2,
            'post-identity' =>
              method == 'user.get_user_obj' && h.wire.writes.isNotEmpty,
            _ =>
              method == 'pool.dataset.attachments' && h.wire.writes.isNotEmpty,
          };
          if (replace) h.wire.rows.last['guid'] = _prop('999');
        };
        final result = await h.repo.executeQuotaReview(
          review,
          review.confirmation,
        );
        final post = stage.startsWith('post-');
        expect(
          result.outcome,
          post ? QuotaOutcome.unknown : QuotaOutcome.rejected,
        );
        expect(h.wire.writes.length, post ? 1 : 0);
      },
    );
  }
  test('read refresh cannot clear an unknown mutation lock', () async {
    final h = await _connect();
    final review = await _review(h);
    h.wire.fault = 'job';
    await h.repo.executeQuotaReview(review, review.confirmation);
    h.wire.fault = null;
    await _inventory(h);
    await expectLater(
      h.repo.executeQuotaReview(review, review.confirmation),
      throwsA(_reason(QuotaExceptionReason.busy)),
    );
    expect(h.wire.writes, hasLength(1));
  });
}

Future<QuotaInventory> _inventory(_Harness h) async =>
    h.repo.loadQuotas((await h.repo.loadQuotaDatasets()).last);
Future<QuotaReview> _review(
  _Harness h, {
  QuotaKind kind = QuotaKind.user,
  int? bytes = 2000,
  int? objects = 40,
}) async {
  final inventory = await _inventory(h);
  final identity = await h.repo.resolveQuotaIdentity(
    inventory,
    kind,
    kind == QuotaKind.user ? 1000 : 2000,
  );
  return h.repo.reviewQuotaChange(
    QuotaChange(
      inventory: inventory,
      identity: identity,
      byteLimit: bytes,
      objectLimit: objects,
    ),
  );
}

Future<_Harness> _connect({
  String version = '25.10.1',
  Set<String> methods = _methods,
  String? metadataFault,
}) async {
  final h = _Harness(
    version: version,
    methods: methods,
    metadataFault: metadataFault,
  );
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
  _Harness({
    String version = '25.10.1',
    Set<String> methods = _methods,
    String? metadataFault,
  }) {
    wire = _Wire(version, methods, metadataFault);
    repo = TrueNasSessionRepository(
      connector: _Connector(wire),
      managementRequestTimeout: const Duration(milliseconds: 60),
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
  _Wire(this.version, this.methods, this.metadataFault);
  final String version;
  final Set<String> methods;
  final String? metadataFault;
  final inbound = StreamController<String>();
  final requests = <Map<String, Object?>>[];
  final rows = [_dataset('tank', '1'), _dataset('tank/data', '2')];
  List<Map<String, Object?>> users = [_quota(QuotaKind.user, 1000)],
      groups = [_quota(QuotaKind.group, 2000)],
      attachments = [];
  final user = _identity(QuotaKind.user, 1000),
      group = _identity(QuotaKind.group, 2000);
  String? fault, failMethod;
  bool dropEmptyRow = false;
  void Function(Map<String, Object?>)? onRequest;
  List<Map<String, Object?>> get writes => requests
      .where(
        (r) =>
            r['method'] == 'pool.dataset.set_quota' ||
            r['method'] == 'pool.dataset.create',
      )
      .toList();
  List<Map<String, Object?>> get quotaRequests =>
      requests.where((r) => r['method'] == 'pool.dataset.get_quota').toList();
  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String message) async {
    final r = (jsonDecode(message) as Map).cast<String, Object?>();
    requests.add(r);
    onRequest?.call(r);
    final args = r['params'] as List? ?? const [];
    Object? result;
    if (r['method'] == failMethod ||
        r['method'] == 'pool.dataset.set_quota' && fault == 'error') {
      inbound.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': r['id'],
          'error': {'code': -32001, 'message': _secret},
        }),
      );
      return;
    }
    switch (r['method']) {
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
              'uploadable': false,
              'downloadable': false,
              if (m == 'pool.dataset.set_quota' &&
                  metadataFault != null &&
                  metadataFault != 'missing')
                metadataFault!: true,
              if (m == 'pool.dataset.set_quota' && metadataFault == 'missing')
                'no_auth_required': null,
            },
        };
      case 'pool.dataset.query':
        result = fault == 'post-read' && writes.isNotEmpty
            ? _secret
            : [
                for (final row in rows)
                  {
                    ...row,
                    'managedby': (row['user_properties'] as Map)['managedby'],
                  },
              ];
      case 'pool.dataset.get_quota':
        result = args[1] == 'USER' ? users : groups;
      case 'user.get_user_obj':
        result = user;
      case 'group.get_group_obj':
        result = group;
      case 'pool.dataset.attachments':
        result = attachments;
      case 'pool.dataset.set_quota':
        if (fault == 'timeout') return;
        for (final q in args[1] as List) {
          final kind = (q['quota_type'] as String).startsWith('USER')
              ? QuotaKind.user
              : QuotaKind.group;
          final list = kind == QuotaKind.user ? users : groups;
          final id = int.parse(q['id'] as String);
          var row = list.where((row) => row['id'] == id).firstOrNull;
          if (row == null) {
            row = _quota(
              kind,
              id,
              quota: null,
              objects: null,
              used: null,
              usedObjects: null,
            );
            list.add(row);
          }
          final key = (q['quota_type'] as String).endsWith('OBJ')
              ? 'obj_quota'
              : 'quota';
          if (q['quota_value'] == 0) {
            row.remove(key);
          } else {
            row[key] = q['quota_value'];
          }
          if (dropEmptyRow &&
              !row.containsKey('quota') &&
              !row.containsKey('obj_quota')) {
            list.remove(row);
          }
        }
        if (fault == 'job') result = 123;
        if (fault == 'true') result = true;
        if (fault == 'post-guid') rows.last['guid'] = _prop('999');
        if (fault == 'post-quota') users.first['quota'] = 99999;
        if (fault == 'post-other-quota') groups.first['quota'] = 99999;
        if (fault == 'post-identity') user['pw_name'] = 'replacement';
        if (fault == 'post-dependency') {
          attachments = [
            {
              'type': 'SMB',
              'service': 'cifs',
              'attachments': ['new'],
            },
          ];
        }
    }
    inbound.add(
      jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() => inbound.close();
}
