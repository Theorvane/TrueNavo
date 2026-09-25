import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _methods = {
  'sharing.smb.query',
  'sharing.smb.presets',
  'sharing.smb.share_precheck',
  'sharing.smb.create',
  'sharing.smb.update',
  'sharing.smb.delete',
  'smb.config',
  'service.query',
  'pool.dataset.query',
  'pool.dataset.attachments',
  'filesystem.stat',
  'filesystem.statfs',
  'filesystem.getacl',
  'failover.licensed',
  'sharing.nfs.query',
  'sharing.nfs.update',
  'nfs.config',
  'filesystem.listdir',
  'user.get_user_obj',
  'group.get_group_obj',
  'group.create',
  'service.control',
  'core.get_jobs',
};
const _secret = 'private-error-and-auxiliary-settings';
Map<String, Object?> _prop(Object value) => {
  'rawvalue': '$value',
  'value': '$value',
  'source': 'LOCAL',
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
  'origin': _prop(''),
  'encryption': _prop('off'),
  'encryptionroot': _prop('-'),
  'keystatus': _prop('-'),
  'acltype': _prop('nfsv4'),
  'xattr': _prop('sa'),
  'filesystem_count': _prop(id == 'tank' ? 1 : 0),
  'managedby': null,
};
Map<String, Object?> _share({
  int id = 1,
  String name = 'Documents',
  String path = '/mnt/tank/data',
}) => {
  'id': id,
  'name': name,
  'path': path,
  'purpose': 'DEFAULT_SHARE',
  'readonly': false,
  'enabled': true,
  'comment': 'Existing documents',
  'browsable': true,
  'access_based_share_enumeration': false,
  'locked': false,
  'audit': {'enable': false, 'watch_list': [], 'ignore_list': []},
  'options': {'aapl_name_mangling': false, 'hostsallow': [], 'hostsdeny': []},
};
Matcher _reason(SmbSharesExceptionReason reason) =>
    isA<SmbSharesException>().having((e) => e.reason, 'reason', reason);

void main() {
  test(
    'legacy Admin unknown mutation keeps both native share gateways fenced',
    () async {
      final h = await _connect();
      final method = h.repo.adminCatalog.method('group.create')!;
      expect(method.supported, true);
      final result = await h.repo.invokeAdmin(
        AdminRequest(
          method: method,
          arguments: [
            {'name': 'synthetic-group'},
          ],
        ),
      );
      expect(result, isA<AdminOutcomeUnknown>());
      await _expectShareGatewaysBusy(h);
      expect(
        h.wire.requests.where((r) => r['method'] == 'group.create'),
        hasLength(1),
      );
      expect(h.wire.writes, isEmpty);
    },
  );
  test(
    'legacy Quick pending owned job fences shares until terminal verification',
    () async {
      final h = await _connect();
      expect(
        h.repo.managementCapabilities.supports(ManagementAction.serviceStart),
        true,
      );
      final result = await h.repo.execute(
        const ServiceControlCommand(
          service: 'cifs',
          action: ServiceControlAction.start,
        ),
      );
      expect(result, isA<ManagementJobSubmitted>());
      final job = result as ManagementJobSubmitted;
      expect(job.jobId, 42);
      await _expectShareGatewaysBusy(h);
      expect(await h.repo.pollJob(job), isA<ManagementJobSubmitted>());
      await _expectShareGatewaysBusy(h);
      h.wire.legacyJobState = 'SUCCESS';
      expect(await h.repo.pollJob(job), isA<ManagementCompleted>());
      // A verified terminal job releases the fence without replaying its write.
      expect((await h.repo.loadSmbShares()).shares, hasLength(1));
      expect(
        h.wire.requests.where((r) => r['method'] == 'service.control'),
        hasLength(1),
      );
      expect(h.wire.writes, isEmpty);
    },
  );
  test('unknown SMB operation blocks NFS reads and mutation with no subsequent dispatch', () async {
    final h = await _connect();
    expect(h.repo.nfsSharesCapabilities.supported, true);
    expect(h.repo.nfsSharesCapabilities.canUpdate, true);
    final review = await _review(h);
    h.wire.fault = 'error';
    expect(
      (await h.repo.executeSmbShare(review, review.confirmation)).outcome,
      SmbShareOutcome.unknown,
    );
    // SMB's legitimate preflight already reads NFS exports. Only calls after
    // the unknown outcome are at issue; none may pass the shared writer fence.
    final boundary = h.wire.requests.length;
    final busy = isA<NfsSharesException>().having(
      (e) => e.reason,
      'reason',
      NfsSharesExceptionReason.busy,
    );
    await expectLater(h.repo.loadNfsShares(), throwsA(busy));
    final nfs = NfsShareReview(
      action: NfsShareAction.update,
      target: 'NFS #1: /mnt/tank/data',
      identity: 'synthetic-only',
      changes: [],
      warnings: [],
    );
    await expectLater(h.repo.executeNfsShare(nfs, nfs.target), throwsA(busy));
    expect(h.wire.requests.skip(boundary), isEmpty);
    expect(h.wire.writes, hasLength(1));
  });
  test(
    'valid external path stays inventory-only; null contradicts pinned model',
    () async {
      final h = await _connect();
      h.wire.shares.add({
        ..._share(id: 2, name: 'Remote', path: 'EXTERNAL'),
        'purpose': 'EXTERNAL_SHARE',
        'options': {
          'remote_path': ['server/share'],
        },
      });
      final i = await h.repo.loadSmbShares();
      expect(i.shares.last.path, 'EXTERNAL');
      expect(i.shares.last.editable, false);
      h.wire.shares.last['path'] = null;
      await expectLater(
        h.repo.loadSmbShares(),
        throwsA(_reason(SmbSharesExceptionReason.invalid)),
      );
      expect(h.wire.writes, isEmpty);
    },
  );
  test(
    'redundant lossy GUID parsed number cannot replace exact raw string',
    () async {
      final h = await _connect();
      h.wire.rows.last['guid'] = {
        ..._prop('18446744073709551615'),
        'parsed': 18446744073709552000.0,
      };
      final r = await _review(h);
      expect(r.identity, contains('18446744073709551615'));
      expect(
        (await h.repo.executeSmbShare(r, r.confirmation)).outcome,
        SmbShareOutcome.verified,
      );
      expect(jsonEncode(h.wire.writes), isNot(contains('1844674407370955')));
    },
  );
  test('unsafe names and comments are validated without transport', () {
    for (final name in [
      'homes',
      'GLOBAL',
      'bad/name',
      'name\u202e',
      ' spaced ',
      'x\n',
    ]) {
      expect(SmbShareSettings(name: name).validationError, isNotNull);
    }
    expect(const SmbShareSettings(name: 'Shared 자료').validationError, isNull);
    expect(
      const SmbShareSettings(
        name: 'Docs',
        comment: 'private\nline',
      ).validationError,
      isNotNull,
    );
  });
  test('disconnected never reads a server', () async {
    final h = _Harness();
    addTearDown(h.repo.close);
    expect(h.repo.smbSharesCapabilities.supported, false);
    await expectLater(
      h.repo.loadSmbShares(),
      throwsA(_reason(SmbSharesExceptionReason.notAuthenticated)),
    );
    expect(h.wire.requests, isEmpty);
  });
  for (final version in ['25.04.2', '25.10-BETA.1', '26.0', '25.10.1\n']) {
    test('version $version blocked before inventory', () async {
      final h = await _connect(version: version);
      await expectLater(
        h.repo.loadSmbShares(),
        throwsA(_reason(SmbSharesExceptionReason.unsupportedVersion)),
      );
      expect(h.wire.requests.length, 4);
    });
  }
  test(
    'bounded inventory and honest enabled counts, no private reads',
    () async {
      final h = await _connect();
      h.wire.shares.add({
        ..._share(id: 2, name: 'Archive', path: '/mnt/tank/archive'),
        'enabled': false,
        'purpose': 'LEGACY_SHARE',
      });
      final i = await h.repo.loadSmbShares();
      expect(i.enabledCount, 1);
      expect(i.disabledCount, 1);
      expect(i.serviceState, 'RUNNING');
      expect(i.shares.first.editable, false);
      expect(i.datasets.first.editable, false);
      expect(i.datasets.last.editable, true);
      expect(() => i.shares.clear(), throwsUnsupportedError);
      final query =
          h.wire.requests.firstWhere(
                (r) => r['method'] == 'pool.dataset.query',
              )['params']
              as List;
      expect(query.first, [
        ['type', '=', 'FILESYSTEM'],
      ]);
      expect(
        (query.last as Map)['select'],
        contains(equals(['user_properties.managedby', 'managedby'])),
      );
      expect((query.last as Map)['limit'], 257);
      expect(h.wire.writes, isEmpty);
      expect(
        h.wire.requests.any((r) => r['method'] == 'sharing.smb.getacl'),
        false,
      );
    },
  );
  for (final action in SmbShareAction.values) {
    test(
      '${action.name} exact synchronous payload and independent readback',
      () async {
        final h = await _connect();
        if (action == SmbShareAction.create) h.wire.shares.clear();
        final review = await _review(h, action: action);
        expect(review.warnings.join(' '), contains('filesystem ACL'));
        final result = await h.repo.executeSmbShare(
          review,
          review.confirmation,
        );
        expect(result.outcome, SmbShareOutcome.verified);
        expect(h.wire.writes.length, 1);
        final params = h.wire.writes.single['params'] as List;
        if (action == SmbShareAction.create) {
          final data = params.single as Map;
          expect(data['purpose'], 'DEFAULT_SHARE');
          expect(data['path'], '/mnt/tank/data');
          expect(data['options'], {
            'aapl_name_mangling': false,
            'hostsallow': [],
            'hostsdeny': [],
          });
          expect(data.containsKey('acl'), false);
          expect(data.containsKey('id'), false);
        } else if (action == SmbShareAction.update) {
          expect(params, [
            1,
            {'comment': 'Reviewed change'},
          ]);
          expect(h.wire.shares.single['browsable'], true);
        } else {
          expect(params, [1]);
        }
        expect(
          h.wire.requests.where((r) => r['method'] == 'sharing.smb.getacl'),
          isEmpty,
        );
        expect(
          h.wire.requests.where((r) => r['method'] == 'core.get_jobs'),
          isEmpty,
        );
        await expectLater(
          h.repo.executeSmbShare(review, review.confirmation),
          throwsA(_reason(SmbSharesExceptionReason.stale)),
        );
      },
    );
  }
  for (final fault in [
    'job',
    'no_auth_required',
    'private',
    'uploadable',
    'downloadable',
    'missing',
  ]) {
    test('mutation metadata $fault blocks before review', () async {
      final h = await _connect(metadataFault: fault);
      expect(h.repo.smbSharesCapabilities.canUpdate, false);
      await expectLater(
        _review(h),
        throwsA(_reason(SmbSharesExceptionReason.unavailableMethod)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('side-effecting or private safety metadata blocks mutations', () async {
    final h = await _connect(badRead: 'filesystem.getacl');
    expect(h.repo.smbSharesCapabilities.canUpdate, false);
    await expectLater(
      _review(h),
      throwsA(_reason(SmbSharesExceptionReason.unavailableMethod)),
    );
  });
  test('no share-ACL read required or admitted', () async {
    final h = await _connect();
    final r = await _review(h);
    expect(
      h.wire.requests.any((r) => r['method'] == 'sharing.smb.getacl'),
      false,
    );
    expect(
      (await h.repo.executeSmbShare(r, r.confirmation)).outcome,
      SmbShareOutcome.verified,
    );
  });
  test(
    'name cannot change on update because rename flushes private ACLs',
    () async {
      final h = await _connect();
      final i = await h.repo.loadSmbShares();
      final request = SmbShareRequest(
        inventory: i,
        action: SmbShareAction.update,
        share: i.shares.single,
        settings: const SmbShareSettings(name: 'New name'),
      );
      expect(request.validationError, contains('share-level ACL'));
      await expectLater(
        h.repo.reviewSmbShare(request),
        throwsA(_reason(SmbSharesExceptionReason.invalid)),
      );
      expect(h.wire.writes, isEmpty);
    },
  );
  for (final change in [
    {'purpose': 'TIMEMACHINE_SHARE'},
    {'purpose': 'LEGACY_SHARE'},
    {'locked': true},
    {'locked': null},
    {
      'options': {
        'aapl_name_mangling': true,
        'hostsallow': [],
        'hostsdeny': [],
      },
    },
    {
      'options': {
        'aapl_name_mangling': false,
        'hostsallow': ['ALL'],
        'hostsdeny': [],
      },
    },
    {
      'audit': {
        'enable': true,
        'watch_list': ['staff'],
        'ignore_list': [],
      },
    },
    {'unknown': _secret},
  ]) {
    test(
      'protected share ${change.keys.first} remains inventory-only',
      () async {
        final h = await _connect();
        h.wire.shares.single.addAll(change);
        final i = await h.repo.loadSmbShares();
        expect(i.shares.single.editable, false);
        expect('${i.shares.single}', isNot(contains(_secret)));
        await expectLater(
          _review(h),
          throwsA(_reason(SmbSharesExceptionReason.invalid)),
        );
      },
    );
  }
  for (final field in [
    'guid',
    'creation',
    'managedby',
    'readonly',
    'origin',
    'encryption',
    'encryptionroot',
    'keystatus',
    'filesystem_count',
  ]) {
    test('dataset malformed $field cannot be selected', () async {
      final h = await _connect();
      h.wire.rows.last[field] = {'unexpected': true};
      try {
        final i = await h.repo.loadSmbShares();
        expect(i.datasets.last.editable, false);
      } on SmbSharesException catch (e) {
        expect(e.reason, SmbSharesExceptionReason.invalid);
      }
      expect(h.wire.writes, isEmpty);
    });
  }
  test('managed pool ancestor protects otherwise ordinary child', () async {
    final h = await _connect();
    h.wire.rows.first['managedby'] = _prop('apps');
    final i = await h.repo.loadSmbShares();
    expect(i.datasets.last.editable, false);
  });
  test(
    'hidden child count protects dataset despite no visible children',
    () async {
      final h = await _connect();
      h.wire.rows.last['filesystem_count'] = _prop(1);
      expect((await h.repo.loadSmbShares()).datasets.last.editable, false);
    },
  );
  for (final path in ['/', '/mnt', '/mnt/tank', '/mnt/tank/data']) {
    test('symbolic ancestor $path blocks before dispatch', () async {
      final h = await _connect();
      h.wire.statChanges[path] = {'type': 'SYMLINK'};
      await expectLater(
        _review(h),
        throwsA(_reason(SmbSharesExceptionReason.invalid)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('HA source propagation is blocked', () async {
    final h = await _connect();
    h.wire.ha = true;
    await expectLater(
      _review(h),
      throwsA(_reason(SmbSharesExceptionReason.dependency)),
    );
  });
  test('malformed ACE and conflicting ACL owner cannot be reviewed', () async {
    final h = await _connect();
    h.wire.acl['acl'] = [
      {
        'tag': 'owner@',
        'type': 'ALLOW',
        'id': -1,
        'perms': {'unknown': true},
        'flags': {},
      },
    ];
    await expectLater(
      _review(h),
      throwsA(_reason(SmbSharesExceptionReason.invalid)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test('NFS aliases and oversized export inventory fail closed', () async {
    final h = await _connect();
    h.wire.nfs = [
      {
        'id': 1,
        'path': '/mnt/other',
        'enabled': false,
        'aliases': ['/mnt/tank/data'],
      },
    ];
    await expectLater(
      _review(h),
      throwsA(_reason(SmbSharesExceptionReason.dependency)),
    );
    h.wire.nfs = [
      for (var i = 0; i < 129; i++)
        {'id': i, 'path': '/mnt/other$i', 'enabled': false, 'aliases': []},
    ];
    await expectLater(
      _review(h),
      throwsA(_reason(SmbSharesExceptionReason.invalid)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test(
    'dataset replacement during path proof is caught by closing inventory',
    () async {
      final h = await _connect();
      h.wire.onRequest = (r) {
        if (r['method'] == 'filesystem.getacl') h.wire.drift('dataset');
      };
      await expectLater(
        _review(h),
        throwsA(_reason(SmbSharesExceptionReason.stale)),
      );
      expect(h.wire.writes, isEmpty);
    },
  );
  test(
    'stopped service is never implicitly started by native client',
    () async {
      final h = await _connect();
      h.wire.service['state'] = 'STOPPED';
      final r = await _review(h);
      expect(
        (await h.repo.executeSmbShare(r, r.confirmation)).outcome,
        SmbShareOutcome.verified,
      );
      expect(h.wire.service['state'], 'STOPPED');
      expect(
        h.wire.requests.any(
          (r) =>
              (r['method'] as String).startsWith('service.') &&
              r['method'] != 'service.query',
        ),
        false,
      );
    },
  );
  test(
    'existing browsing and enumeration settings are retained exactly',
    () async {
      final h = await _connect();
      h.wire.shares.single['browsable'] = false;
      h.wire.shares.single['access_based_share_enumeration'] = true;
      final r = await _review(h);
      expect(
        (await h.repo.executeSmbShare(r, r.confirmation)).outcome,
        SmbShareOutcome.verified,
      );
      expect(h.wire.writes.single['params'], [
        1,
        {'comment': 'Reviewed change'},
      ]);
      expect(h.wire.shares.single['browsable'], false);
      expect(h.wire.shares.single['access_based_share_enumeration'], true);
    },
  );
  test('large exact GUID remains string identity', () async {
    final h = await _connect();
    h.wire.rows.last['guid'] = _prop('18446744073709551615');
    final r = await _review(h);
    expect(r.identity, contains('18446744073709551615'));
    expect(
      (await h.repo.executeSmbShare(r, r.confirmation)).outcome,
      SmbShareOutcome.verified,
    );
  });
  for (final path in ['/mnt/tank', '/mnt/tank/data', '/mnt/tank/data/child']) {
    test('disabled or ancestor NFS $path is a dependency', () async {
      final h = await _connect();
      h.wire.nfs = [
        {'id': 1, 'path': path, 'enabled': false, 'aliases': []},
      ];
      await expectLater(
        _review(h),
        throwsA(_reason(SmbSharesExceptionReason.dependency)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('unrelated canonical NFS export remains usable', () async {
    final h = await _connect();
    h.wire.nfs = [
      {'id': 1, 'path': '/mnt/other/data', 'enabled': true, 'aliases': []},
    ];
    final r = await _review(h);
    expect(
      (await h.repo.executeSmbShare(r, r.confirmation)).outcome,
      SmbShareOutcome.verified,
    );
  });
  test('unrelated NFS ancestor symlink cannot hide overlap', () async {
    final h = await _connect();
    h.wire.nfs = [
      {'id': 1, 'path': '/mnt/alias/data', 'enabled': false, 'aliases': []},
    ];
    h.wire.statChanges['/mnt/alias'] = {'type': 'SYMLINK'};
    await expectLater(
      _review(h),
      throwsA(_reason(SmbSharesExceptionReason.dependency)),
    );
  });
  test('other enabled consumer blocks and no remote details leak', () async {
    final h = await _connect();
    h.wire.extraAttachments = [
      {
        'type': 'App',
        'service': null,
        'attachments': [_secret],
      },
    ];
    await expectLater(
      _review(h),
      throwsA(_reason(SmbSharesExceptionReason.dependency)),
    );
    expect(h.wire.writes, isEmpty);
  });
  for (final drift in [
    'share',
    'dataset',
    'service',
    'config',
    'preset',
    'acl',
    'ancestor',
    'nfs',
    'ha',
  ]) {
    test('$drift changes invalidate final review without writes', () async {
      final h = await _connect();
      final r = await _review(h);
      h.wire.drift(drift);
      await expectLater(
        h.repo.executeSmbShare(r, r.confirmation),
        throwsA(isA<SmbSharesException>()),
      );
      expect(h.wire.writes, isEmpty);
      await expectLater(
        h.repo.executeSmbShare(r, r.confirmation),
        throwsA(_reason(SmbSharesExceptionReason.stale)),
      );
    });
  }
  for (final fault in [
    'timeout',
    'error',
    'wrong-receipt',
    'post-share',
    'post-dataset',
    'post-acl',
    'post-ancestor',
    'post-other',
  ]) {
    test('$fault after dispatch is unknown and never replayed', () async {
      final h = await _connect();
      final r = await _review(h);
      h.wire.fault = fault;
      final result = await h.repo.executeSmbShare(r, r.confirmation);
      expect(result.outcome, SmbShareOutcome.unknown);
      expect(result.message, isNot(contains(_secret)));
      await expectLater(
        h.repo.executeSmbShare(r, r.confirmation),
        throwsA(_reason(SmbSharesExceptionReason.busy)),
      );
      expect(h.wire.writes.length, 1);
    });
  }
  test('review is single-use and only latest review remains issued', () async {
    final h = await _connect();
    final i = await h.repo.loadSmbShares();
    final request = _request(i);
    final a = await h.repo.reviewSmbShare(request);
    final b = await h.repo.reviewSmbShare(request);
    await expectLater(
      h.repo.executeSmbShare(a, a.confirmation),
      throwsA(_reason(SmbSharesExceptionReason.stale)),
    );
    await expectLater(
      h.repo.executeSmbShare(b, 'wrong'),
      throwsA(_reason(SmbSharesExceptionReason.stale)),
    );
    await expectLater(
      h.repo.executeSmbShare(b, b.confirmation),
      throwsA(_reason(SmbSharesExceptionReason.stale)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test('forged review and inventory cannot authorize any operation', () async {
    final h = await _connect();
    final r = await _review(h);
    final fake = SmbShareReview(
      action: r.action,
      target: r.target,
      identity: r.identity,
      changes: r.changes,
      warnings: r.warnings,
    );
    await expectLater(
      h.repo.executeSmbShare(fake, fake.confirmation),
      throwsA(_reason(SmbSharesExceptionReason.stale)),
    );
    final i = await h.repo.loadSmbShares();
    final fakeI = SmbShareInventory(
      shares: i.shares,
      datasets: i.datasets,
      serviceState: i.serviceState,
      serviceEnabled: i.serviceEnabled,
    );
    await expectLater(
      h.repo.reviewSmbShare(_request(fakeI)),
      throwsA(_reason(SmbSharesExceptionReason.stale)),
    );
  });
  test('session change on final preflight fences write', () async {
    final h = await _connect();
    final r = await _review(h);
    h.wire.onRequest = (q) {
      if (q['method'] == 'filesystem.getacl') h.current = false;
    };
    await expectLater(
      h.repo.executeSmbShare(r, r.confirmation),
      throwsA(_reason(SmbSharesExceptionReason.notAuthenticated)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test('shared synchronous operation cannot overlap itself', () async {
    final h = await _connect();
    final r = await _review(h);
    h.wire.fault = 'timeout';
    final pending = h.repo.executeSmbShare(r, r.confirmation);
    await expectLater(
      h.repo.loadSmbShares(),
      throwsA(_reason(SmbSharesExceptionReason.busy)),
    );
    expect((await pending).outcome, SmbShareOutcome.unknown);
  });
  test('safe numbers reject min-int and rounded IDs', () async {
    for (final id in [-9223372036854775808, 9007199254740992]) {
      final h = await _connect();
      h.wire.shares.single['id'] = id;
      await expectLater(
        h.repo.loadSmbShares(),
        throwsA(_reason(SmbSharesExceptionReason.invalid)),
      );
    }
  });
  test('bounded duplicate inventory fails closed', () async {
    final h = await _connect();
    h.wire.shares.add(_share(id: 2, name: 'documents'));
    await expectLater(
      h.repo.loadSmbShares(),
      throwsA(_reason(SmbSharesExceptionReason.invalid)),
    );
    h.wire.shares.clear();
    h.wire.rows.addAll([
      for (var i = 0; i < 256; i++) _dataset('tank/d$i', '${i + 3}'),
    ]);
    await expectLater(
      h.repo.loadSmbShares(),
      throwsA(_reason(SmbSharesExceptionReason.invalid)),
    );
  });
  test('share read-only and disabling are real explicit patches', () async {
    final h = await _connect();
    final i = await h.repo.loadSmbShares();
    final r = await h.repo.reviewSmbShare(
      SmbShareRequest(
        inventory: i,
        action: SmbShareAction.update,
        share: i.shares.single,
        settings: const SmbShareSettings(
          name: 'Documents',
          comment: 'Existing documents',
          readonly: true,
          enabled: false,
        ),
      ),
    );
    expect(r.warnings.join(' '), contains('disconnect'));
    expect(
      (await h.repo.executeSmbShare(r, r.confirmation)).outcome,
      SmbShareOutcome.verified,
    );
    expect(h.wire.writes.single['params'], [
      1,
      {'readonly': true, 'enabled': false},
    ]);
  });
}

Future<void> _expectShareGatewaysBusy(_Harness h) async {
  expect(h.repo.smbSharesCapabilities.supported, true);
  expect(h.repo.smbSharesCapabilities.canUpdate, true);
  expect(h.repo.nfsSharesCapabilities.supported, true);
  expect(h.repo.nfsSharesCapabilities.canUpdate, true);
  final boundary = h.wire.requests.length;
  await expectLater(
    h.repo.loadSmbShares(),
    throwsA(_reason(SmbSharesExceptionReason.busy)),
  );
  final smb = SmbShareReview(
    action: SmbShareAction.update,
    target: 'Documents',
    identity: 'synthetic-only',
    changes: [],
    warnings: [],
  );
  await expectLater(
    h.repo.executeSmbShare(smb, smb.confirmation),
    throwsA(_reason(SmbSharesExceptionReason.busy)),
  );
  final nfsBusy = isA<NfsSharesException>().having(
    (e) => e.reason,
    'reason',
    NfsSharesExceptionReason.busy,
  );
  await expectLater(h.repo.loadNfsShares(), throwsA(nfsBusy));
  final nfs = NfsShareReview(
    action: NfsShareAction.update,
    target: 'NFS #1: /mnt/tank/data',
    identity: 'synthetic-only',
    changes: [],
    warnings: [],
  );
  await expectLater(h.repo.executeNfsShare(nfs, nfs.target), throwsA(nfsBusy));
  expect(h.wire.requests.skip(boundary), isEmpty);
}

SmbShareRequest _request(
  SmbShareInventory i, {
  SmbShareAction action = SmbShareAction.update,
}) => SmbShareRequest(
  inventory: i,
  action: action,
  share: action == SmbShareAction.create ? null : i.shares.single,
  dataset: action == SmbShareAction.create ? i.datasets.last : null,
  settings: action == SmbShareAction.delete
      ? null
      : SmbShareSettings(
          name: action == SmbShareAction.create ? 'New share' : 'Documents',
          comment: 'Reviewed change',
        ),
);
Future<SmbShareReview> _review(
  _Harness h, {
  SmbShareAction action = SmbShareAction.update,
}) async => h.repo.reviewSmbShare(
  _request(await h.repo.loadSmbShares(), action: action),
);
Future<_Harness> _connect({
  String version = '25.10.1',
  String? metadataFault,
  String? badRead,
}) async {
  final h = _Harness(
    version: version,
    metadataFault: metadataFault,
    badRead: badRead,
  );
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://fixture.invalid',
    apiKey: 'synthetic-key',
    username: 'admin',
    isConnectionCurrent: () => h.current,
  );
  return h;
}

class _Harness {
  _Harness({
    String version = '25.10.1',
    String? metadataFault,
    String? badRead,
  }) {
    wire = _Wire(version, metadataFault, badRead);
    repo = TrueNasSessionRepository(
      connector: _Connector(wire),
      managementRequestTimeout: const Duration(milliseconds: 80),
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
  _Wire(this.version, this.metadataFault, this.badRead);
  final String version;
  final String? metadataFault, badRead;
  final inbound = StreamController<String>();
  final requests = <Map<String, Object?>>[];
  final rows = [_dataset('tank', '1'), _dataset('tank/data', '2')];
  final shares = [_share()];
  final config = <String, Object?>{
    'id': 1,
    'smb_options': '',
    'enable_smb1': false,
    'ntlmv1_auth': false,
    'aapl_extensions': false,
  };
  final service = <String, Object?>{
    'id': 1,
    'service': 'cifs',
    'state': 'RUNNING',
    'enable': true,
  };
  final presets = <String, Object?>{
    'DEFAULT_SHARE': {'verbose_name': 'Default share'},
  };
  final acl = <String, Object?>{
    'path': '/mnt/tank/data',
    'uid': 1000,
    'gid': 1000,
    'acltype': 'NFS4',
    'trivial': true,
    'acl': [
      for (final tag in ['owner@', 'group@', 'everyone@'])
        {
          'tag': tag,
          'id': -1,
          'type': 'ALLOW',
          'perms': {
            for (final permission in PermissionAce.nfs4PermissionNames)
              permission: true,
          },
          'flags': {
            for (final flag in PermissionAce.nfs4FlagNames) flag: false,
          },
        },
    ],
    'aclflags': {'autoinherit': false, 'protected': false, 'defaulted': false},
  };
  final statChanges = <String, Map<String, Object?>>{};
  List<Map<String, Object?>> nfs = [], extraAttachments = [];
  bool ha = false;
  String legacyJobState = 'RUNNING';
  String? fault;
  void Function(Map<String, Object?>)? onRequest;
  List<Map<String, Object?>> get writes => requests
      .where(
        (r) => {
          'sharing.smb.create',
          'sharing.smb.update',
          'sharing.smb.delete',
        }.contains(r['method']),
      )
      .toList();
  void drift(String kind) {
    switch (kind) {
      case 'share':
        shares.single['comment'] = 'External';
      case 'dataset':
        rows.last['guid'] = _prop('999');
      case 'service':
        service['enable'] = false;
      case 'config':
        config['aapl_extensions'] = true;
      case 'preset':
        presets['DEFAULT_SHARE'] = {'verbose_name': 'Changed'};
      case 'acl':
        acl['uid'] = 2000;
      case 'ancestor':
        statChanges['/mnt/tank'] = {'inode': 999};
      case 'nfs':
        nfs = [
          {'id': 1, 'path': '/mnt/tank', 'enabled': true, 'aliases': []},
        ];
      case 'ha':
        ha = true;
    }
  }

  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String message) async {
    final r = (jsonDecode(message) as Map).cast<String, Object?>();
    requests.add(r);
    onRequest?.call(r);
    final method = r['method'] as String;
    final args = r['params'] as List? ?? [];
    Object? result;
    if (writes.isNotEmpty && identical(r, writes.last) && fault == 'error') {
      inbound.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': r['id'],
          'error': {'code': -32001, 'message': _secret},
        }),
      );
      return;
    }
    switch (method) {
      case 'auth.login_ex':
        result = {'response_type': 'SUCCESS'};
      case 'auth.me':
        result = {'username': 'admin'};
      case 'system.info':
        result = {'version': version};
      case 'core.get_methods':
        result = {
          for (final m in _methods)
            m: {
              'accepts': m == 'group.create'
                  ? [
                      {
                        '_name_': 'data',
                        '_required_': true,
                        'type': 'object',
                        'required': ['name'],
                        'properties': {
                          'name': {'type': 'string', 'minLength': 1},
                        },
                      },
                    ]
                  : [],
              'returns': m == 'group.create'
                  ? [
                      {'type': 'object', 'properties': {}},
                    ]
                  : [],
              'job': m == badRead || m == 'service.control',
              'filterable': false,
              'check_pipes': [],
              'roles': ['FULL_ADMIN'],
              'no_auth_required': false,
              'uploadable': false,
              'downloadable': false,
              if (m == 'sharing.smb.update' &&
                  metadataFault != null &&
                  metadataFault != 'missing')
                metadataFault!: true,
              if (m == 'sharing.smb.update' && metadataFault == 'missing')
                'job': null,
            },
        };
      case 'sharing.smb.query':
        result = shares;
      case 'group.create':
        inbound.add(
          jsonEncode({
            'jsonrpc': '2.0',
            'id': r['id'],
            'error': {'code': -32001, 'message': _secret},
          }),
        );
        return;
      case 'service.control':
        result = 42;
      case 'core.get_jobs':
        result = [
          {
            'id': 42,
            'method': 'service.control',
            'state': legacyJobState,
            'result': true,
          },
        ];
      case 'pool.dataset.query':
        result = rows;
      case 'service.query':
        result = [service];
      case 'smb.config':
        result = config;
      case 'sharing.smb.presets':
        result = presets;
      case 'sharing.smb.share_precheck':
        result = null;
      case 'sharing.nfs.query':
        result = nfs;
      case 'failover.licensed':
        result = ha;
      case 'pool.dataset.attachments':
        result = [
          if (shares.any(
            (s) => s['enabled'] == true && s['path'] == '/mnt/tank/data',
          ))
            {
              'type': 'SMB Share',
              'service': 'cifs',
              'attachments': [
                for (final s in shares.where(
                  (s) => s['enabled'] == true && s['path'] == '/mnt/tank/data',
                ))
                  s['name'],
              ],
            },
          ...extraAttachments,
        ];
      case 'filesystem.stat':
        final path = args.single as String;
        result = {
          'type': 'DIRECTORY',
          'realpath': path,
          'is_ctldir': false,
          'is_mountpoint': path == '/mnt/tank/data',
          'acl': true,
          'uid': 1000,
          'gid': 1000,
          'mode': 16877,
          'dev': 1,
          'inode': path.length,
          'mount_id': 2,
          'attributes': [],
          ...?(statChanges[path]),
        };
      case 'filesystem.statfs':
        result = {
          'fstype': 'zfs',
          'source': 'tank/data',
          'dest': '/mnt/tank/data',
          'fsid': '1',
          'flags': [],
        };
      case 'filesystem.getacl':
        result = acl;
      case 'sharing.smb.create':
        if (fault == 'timeout') return;
        final row = <String, Object?>{
          ...(args.single as Map).cast<String, Object?>(),
          'id': 2,
          'locked': false,
        };
        shares.add(row);
        result = row;
      case 'sharing.smb.update':
        if (fault == 'timeout') return;
        final row = shares.singleWhere((s) => s['id'] == args.first);
        row.addAll((args.last as Map).cast<String, Object?>());
        result = row;
      case 'sharing.smb.delete':
        if (fault == 'timeout') return;
        shares.removeWhere((s) => s['id'] == args.first);
        result = true;
      default:
        throw StateError('Unexpected synthetic method $method');
    }
    if ({
      'sharing.smb.create',
      'sharing.smb.update',
      'sharing.smb.delete',
    }.contains(method)) {
      if (fault == 'wrong-receipt') result = 42;
      if (fault == 'post-share') shares.single['comment'] = 'not submitted';
      if (fault == 'post-dataset') drift('dataset');
      if (fault == 'post-acl') drift('acl');
      if (fault == 'post-ancestor') drift('ancestor');
      if (fault == 'post-other') {
        shares.add(_share(id: 9, name: 'Unexpected', path: '/mnt/tank/other'));
      }
    }
    inbound.add(
      jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() => inbound.close();
}
