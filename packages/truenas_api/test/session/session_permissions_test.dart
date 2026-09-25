import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const permissionMethods = {
  'pool.dataset.query',
  'filesystem.stat',
  'filesystem.statfs',
  'filesystem.getacl',
  'filesystem.setacl',
  'filesystem.setperm',
  'core.get_jobs',
  'user.query',
  'group.query',
};
Map<String, Object?> prop(String value) => {
  'rawvalue': value,
  'value': value,
  'parsed': value,
  'source': 'LOCAL',
};
Map<String, Object?> posix(
  String tag,
  int bits, {
  int id = -1,
  bool defaults = false,
}) => {
  'tag': tag,
  'id': id,
  'who': null,
  'default': defaults,
  'perms': {
    'READ': bits & 4 != 0,
    'WRITE': bits & 2 != 0,
    'EXECUTE': bits & 1 != 0,
  },
};
Map<String, Object?> nfs(
  String tag, {
  int id = -1,
  String type = 'ALLOW',
  bool write = false,
}) => {
  'tag': tag,
  'id': id,
  'who': null,
  'type': type,
  'perms': {
    for (final p in PermissionAce.nfs4PermissionNames)
      p:
          p == 'READ_DATA' ||
          p == 'EXECUTE' ||
          p == 'SYNCHRONIZE' ||
          write && p == 'WRITE_DATA',
  },
  'flags': {for (final f in PermissionAce.nfs4FlagNames) f: false},
};
PermissionAce edited(
  PermissionAce ace, {
  String? permission,
  String? flag,
  String? tag,
  int? id,
  String? type,
  bool? defaults,
}) => PermissionAce(
  tag: tag ?? ace.tag,
  id: id ?? ace.id,
  type: type ?? ace.type,
  permissions: {
    ...ace.permissions,
    ?permission: !(ace.permissions[permission] ?? false),
  },
  flags: {...ace.flags, ?flag: !(ace.flags[flag] ?? false)},
  isDefault: defaults ?? ace.isDefault,
);
List<PermissionAce> changed(PermissionReview review) => [
  edited(
    review.acl.first,
    permission: review.aclType == PermissionAclType.nfs4
        ? 'WRITE_DATA'
        : 'WRITE',
  ),
  ...review.acl.skip(1),
];
Matcher error(PermissionsExceptionReason reason) =>
    isA<PermissionsException>().having((e) => e.reason, 'reason', reason);
Future<PermissionsHarness> connect({
  String kind = 'POSIX1E',
  String version = '25.10.1',
  Set<String> methods = permissionMethods,
}) async {
  final h = PermissionsHarness(kind, version, methods);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    username: 'admin',
    apiKey: 'synthetic-only',
  );
  return h;
}

void main() {
  test(
    'advanced ACL read uses numeric IDs and bounded safe dataset projection',
    () async {
      final h = await connect();
      final review = await h.review();
      expect(review.mode, '750');
      expect(review.uid, 1000);
      expect(review.acl.length, 3);
      expect(review.canEditAcl, isTrue);
      expect(review.canEditMode, isTrue);
      expect(
        h.transport.calls.lastWhere(
          (r) => r['method'] == 'filesystem.getacl',
        )['params'],
        ['/mnt/tank/data', false, false],
      );
      final opts =
          (h.transport.calls.firstWhere(
                    (r) => r['method'] == 'pool.dataset.query',
                  )['params']
                  as List)[1]
              as Map;
      expect(opts['select'], isNot(contains('user_properties')));
      expect((opts['select'] as List).last, [
        'user_properties.managedby',
        'managedby',
      ]);
      expect((opts['extra'] as Map)['retrieve_user_props'], true);
      expect(h.transport.writes, isEmpty);
    },
  );
  for (final version in ['25.04.2', '25.10-BETA.1', '26.0.1']) {
    test('unsupported $version performs no permission reads', () async {
      final h = await connect(version: version);
      await expectLater(
        h.repo.loadPermissionDatasets(),
        throwsA(error(PermissionsExceptionReason.unsupportedVersion)),
      );
      expect(
        h.transport.calls.where((r) => r['method'] == 'pool.dataset.query'),
        isEmpty,
      );
    });
  }
  test(
    'missing explicitly retrieved managed alias is unset, not unknown',
    () async {
      final h = await connect();
      h.transport.dataset.remove('managedby');
      expect((await h.review()).editable, true);
      final calls = h.transport.calls.where(
        (r) => r['method'] == 'pool.dataset.query',
      );
      for (final call in calls) {
        final params = call['params'] as List;
        expect(params.first, isNotEmpty);
        final options = params[1] as Map;
        expect((options['select'] as List).last, [
          'user_properties.managedby',
          'managedby',
        ]);
        expect((options['extra'] as Map)['retrieve_user_props'], true);
        expect(
          (options['extra'] as Map)['properties'],
          isNot(contains('managedby')),
        );
      }
    },
  );
  for (final marker in [
    null,
    {'unknown': 'marker'},
    prop('external-system'),
  ]) {
    test(
      'present malformed or external managed marker $marker blocks writes',
      () async {
        final h = await connect();
        h.transport.dataset['managedby'] = marker;
        final review = await h.review();
        expect(review.editable, false);
        await expectLater(
          h.repo.applyPermissions(
            PermissionApplyRequest(review: review, acl: changed(review)),
          ),
          throwsA(error(PermissionsExceptionReason.invalidInput)),
        );
        expect(h.transport.writes, isEmpty);
      },
    );
  }
  test('identical job and arguments in another session do not share dispatch identity', () async {
    final a = await connect(), b = await connect();
    final ar = await a.review(), br = await b.review();
    final first = await a.repo.applyPermissions(
      PermissionApplyRequest(review: ar, acl: changed(ar)),
    );
    final second = await b.repo.applyPermissions(
      PermissionApplyRequest(review: br, acl: changed(br)),
    );
    expect(first.jobId, second.jobId);
    expect(a.transport.arguments, b.transport.arguments);
    expect(a.transport.jobMessageId, isNot(b.transport.jobMessageId));
    b.transport.jobMessageId = a.transport.jobMessageId;
    b.transport.jobState = 'SUCCESS';
    expect(
      (await b.repo.checkPermissionOperation(second)).outcome,
      PermissionOperationOutcome.unknown,
    );
    expect(b.transport.writes.length, 1);
  });
  test('no-propagate requires file or directory inheritance', () async {
    final h = await connect(kind: 'NFS4');
    final review = await h.review();
    final noPropagate = edited(review.acl.first, flag: 'NO_PROPAGATE_INHERIT');
    expect(
      PermissionApplyRequest(
        review: review,
        acl: [noPropagate, ...review.acl.skip(1)],
      ).validationError,
      isNotNull,
    );
    expect(
      PermissionApplyRequest(
        review: review,
        acl: [
          edited(noPropagate, flag: 'DIRECTORY_INHERIT'),
          ...review.acl.skip(1),
        ],
      ).validationError,
      null,
    );
    expect(h.transport.writes, isEmpty);
  });
  test(
    'NFSv4 readback with same entries but changed order is not verified',
    () async {
      final h = await connect(kind: 'NFS4');
      final review = await h.review();
      final pending = await h.repo.applyPermissions(
        PermissionApplyRequest(review: review, acl: changed(review)),
      );
      h.transport.applyJob();
      h.transport.acl = h.transport.acl.reversed.toList();
      h.transport.jobState = 'SUCCESS';
      expect(
        (await h.repo.checkPermissionOperation(pending)).outcome,
        PermissionOperationOutcome.unknown,
      );
    },
  );
  test(
    'POSIX semantic readback permits insignificant order normalization',
    () async {
      final h = await connect();
      final review = await h.review();
      final pending = await h.repo.applyPermissions(
        PermissionApplyRequest(review: review, acl: changed(review)),
      );
      h.transport.applyJob();
      h.transport.acl = h.transport.acl.reversed.toList();
      h.transport.jobState = 'SUCCESS';
      expect(
        (await h.repo.checkPermissionOperation(pending)).outcome,
        PermissionOperationOutcome.verified,
      );
    },
  );
  test('read-only mount is readable but cannot dispatch', () async {
    final h = await connect();
    h.transport.mountOverrides['flags'] = ['RO'];
    final review = await h.review();
    expect(review.editable, false);
    expect(h.transport.writes, isEmpty);
  });
  test('nonrecursive POSIX edit owns exact job args and verifies independent advanced readback', () async {
    final h = await connect();
    final review = await h.review();
    final acl = changed(review);
    final pending = await h.repo.applyPermissions(
      PermissionApplyRequest(review: review, acl: acl),
    );
    expect(pending.canCheck, isTrue);
    expect(pending.jobId, 41);
    final wire = (h.transport.writes.single['params'] as List).single as Map;
    expect(wire['uid'], -1);
    expect(wire['gid'], -1);
    expect(wire['user'], null);
    expect(wire['group'], null);
    expect(wire['options'], {
      'recursive': false,
      'traverse': false,
      'stripacl': false,
      'canonicalize': false,
      'validate_effective_acl': true,
    });
    expect(await h.repo.checkPermissionOperation(pending), same(pending));
    h.transport.jobState = 'SUCCESS';
    expect(
      (await h.repo.checkPermissionOperation(pending)).outcome,
      PermissionOperationOutcome.verified,
    );
    expect(h.transport.mode, int.parse('550', radix: 8));
    expect(h.transport.writes.length, 1);
  });
  test('NFSv4 preserves advanced ACE flags and order while allowing ACL-derived mode changes', () async {
    final h = await connect(kind: 'NFS4');
    h.transport.acl = [
      nfs('USER', id: 1001, type: 'DENY'),
      nfs('owner@'),
      nfs('group@'),
      nfs('everyone@'),
    ];
    final review = await h.review();
    final request = PermissionApplyRequest(
      review: review,
      acl: [
        edited(review.acl.first, flag: 'FILE_INHERIT'),
        ...review.acl.skip(1),
      ],
    );
    final pending = await h.repo.applyPermissions(request);
    h.transport.jobState = 'SUCCESS';
    h.transport.nfsMode = 511;
    expect(
      (await h.repo.checkPermissionOperation(pending)).outcome,
      PermissionOperationOutcome.verified,
    );
    expect((h.transport.acl.first as Map)['type'], 'DENY');
    expect(
      ((h.transport.acl.first as Map)['flags'] as Map)['FILE_INHERIT'],
      true,
    );
  });
  for (final kind in ['POSIX1E', 'DISABLED']) {
    test(
      'mode write on $kind preserves ownership and uses nonrecursive setperm without ACL stripping request',
      () async {
        final h = await connect(kind: kind);
        final review = await h.review();
        final pending = await h.repo.applyPermissions(
          PermissionApplyRequest(review: review, mode: '770'),
        );
        final wire =
            (h.transport.writes.single['params'] as List).single as Map;
        expect(wire, {
          'path': '/mnt/tank/data',
          'uid': null,
          'gid': null,
          'user': null,
          'group': null,
          'mode': '770',
          'options': {'recursive': false, 'traverse': false, 'stripacl': false},
        });
        h.transport.jobState = 'SUCCESS';
        expect(
          (await h.repo.checkPermissionOperation(pending)).outcome,
          PermissionOperationOutcome.verified,
        );
      },
    );
  }
  test(
    'extended POSIX and NFSv4 cannot be silently converted to mode',
    () async {
      for (final kind in ['POSIX1E', 'NFS4']) {
        final h = await connect(kind: kind);
        if (kind == 'POSIX1E') {
          h.transport.acl.addAll([
            posix('MASK', 5),
            posix('USER', 4, id: 1001),
          ]);
        }
        final review = await h.review();
        expect(review.canEditMode, false);
        expect(
          PermissionApplyRequest(review: review, mode: '777').validationError,
          isNotNull,
        );
        expect(h.transport.writes, isEmpty);
      }
    },
  );
  for (final flag in ['autoinherit', 'protected', 'defaulted']) {
    test(
      'nondefault NFSv4 ACL-wide $flag is visible but blocks reset-prone writes',
      () async {
        final h = await connect(kind: 'NFS4');
        h.transport.aclFlags[flag] = true;
        final review = await h.review();
        expect(review.aclFlags[flag], true);
        expect(review.editable, false);
        await expectLater(
          h.repo.applyPermissions(
            PermissionApplyRequest(review: review, acl: changed(review)),
          ),
          throwsA(error(PermissionsExceptionReason.invalidInput)),
        );
        expect(h.transport.writes, isEmpty);
      },
    );
  }
  test('special mode bits return an explicit readonly review instead of malformed response', () async {
    final h = await connect();
    h.transport.mode = 1512;
    final review = await h.review();
    expect(review.mode, '2750');
    expect(review.editable, false);
    expect(review.blockedReason, contains('Special mode'));
  });
  for (final field in ['guid', 'readonly', 'managedby', 'aclmode']) {
    test('fresh $field drift blocks before write', () async {
      final h = await connect();
      final review = await h.review();
      h.transport.dataset[field] = prop(field == 'readonly' ? 'on' : 'changed');
      await expectLater(
        h.repo.applyPermissions(
          PermissionApplyRequest(review: review, acl: changed(review)),
        ),
        throwsA(isA<PermissionsException>()),
      );
      expect(h.transport.writes, isEmpty);
    });
  }
  test('dataset metadata is refreshed again after identity lookup', () async {
    final h = await connect();
    final review = await h.review();
    h.transport.driftOnLookup = true;
    final acl = [
      ...review.acl,
      PermissionAce(tag: 'MASK', permissions: {'READ': true, 'EXECUTE': true}),
      PermissionAce(tag: 'USER', id: 1001, permissions: {'READ': true}),
    ];
    await expectLater(
      h.repo.applyPermissions(PermissionApplyRequest(review: review, acl: acl)),
      throwsA(error(PermissionsExceptionReason.staleSnapshot)),
    );
    expect(h.transport.writes, isEmpty);
  });
  test(
    'new named principal needs fresh identity proof using UID not account ID',
    () async {
      final h = await connect();
      final identity = await h.repo.lookupPermissionIdentity(
        PermissionIdentityKind.user,
        1001,
      );
      expect(identity!.name, 'fixture');
      expect(identity.id, 1001);
      final review = await h.review();
      h.transport.identityExists = false;
      final acl = [
        ...review.acl,
        PermissionAce(
          tag: 'MASK',
          permissions: {'READ': true, 'EXECUTE': true},
        ),
        PermissionAce(tag: 'USER', id: 1001, permissions: {'READ': true}),
      ];
      await expectLater(
        h.repo.applyPermissions(
          PermissionApplyRequest(review: review, acl: acl),
        ),
        throwsA(error(PermissionsExceptionReason.invalidInput)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test(
    'every path ancestor is checked, not only lexical final realpath',
    () async {
      final h = await connect();
      h.transport.pathOverrides['/mnt/tank'] = {
        'type': 'SYMLINK',
        'realpath': '/other',
      };
      await expectLater(
        h.review(),
        throwsA(error(PermissionsExceptionReason.invalidResponse)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  for (final field in ['source', 'dest', 'fstype']) {
    test('wrong statfs $field blocks dataset-root proof', () async {
      final h = await connect();
      h.transport.mountOverrides[field] = 'wrong';
      await expectLater(
        h.review(),
        throwsA(error(PermissionsExceptionReason.invalidResponse)),
      );
      expect(h.transport.writes, isEmpty);
    });
  }
  test('post-write ancestor replacement remains unknown', () async {
    final h = await connect();
    final review = await h.review();
    final pending = await h.repo.applyPermissions(
      PermissionApplyRequest(review: review, acl: changed(review)),
    );
    h.transport.jobState = 'SUCCESS';
    h.transport.pathOverrides['/mnt/tank'] = {'inode': 999};
    expect(
      (await h.repo.checkPermissionOperation(pending)).outcome,
      PermissionOperationOutcome.unknown,
    );
  });
  for (final tamper in [
    'id',
    'method',
    'arguments',
    'message_ids',
    'missing',
    'FAILED',
    'ABORTED',
    'acl',
    'owner',
    'flags',
    'modern',
    'timeout',
  ]) {
    test('$tamper cannot falsely verify or retry an ACL mutation', () async {
      final h = await connect(kind: tamper == 'flags' ? 'NFS4' : 'POSIX1E');
      final review = await h.review();
      h.transport.tamper = tamper;
      final pending = await h.repo.applyPermissions(
        PermissionApplyRequest(review: review, acl: changed(review)),
      );
      PermissionOperationResult result = pending;
      if (pending.canCheck) {
        h.transport.jobState = 'SUCCESS';
        result = await h.repo.checkPermissionOperation(pending);
      }
      expect(result.outcome, PermissionOperationOutcome.unknown);
      expect(h.transport.writes.length, 1);
      await expectLater(
        h.repo.applyPermissions(
          PermissionApplyRequest(review: review, acl: changed(review)),
        ),
        throwsA(error(PermissionsExceptionReason.busy)),
      );
      expect(h.transport.writes.length, 1);
    });
  }
  test('issued job and review objects cannot be fabricated or reused cross-session', () async {
    final h = await connect();
    final other = await connect();
    final review = await h.review();
    await expectLater(
      other.repo.applyPermissions(
        PermissionApplyRequest(review: review, acl: changed(review)),
      ),
      throwsA(error(PermissionsExceptionReason.staleSnapshot)),
    );
    final pending = await h.repo.applyPermissions(
      PermissionApplyRequest(review: review, acl: changed(review)),
    );
    await expectLater(
      h.repo.checkPermissionOperation(
        PermissionOperationResult(
          outcome: PermissionOperationOutcome.pending,
          jobId: pending.jobId,
        ),
      ),
      throwsA(error(PermissionsExceptionReason.staleSnapshot)),
    );
    expect(h.transport.writes.length, 1);
  });
  test(
    'method-level setacl permission is required independently of reads',
    () async {
      final h = await connect(
        methods: permissionMethods.difference({'filesystem.setacl'}),
      );
      final review = await h.review();
      await expectLater(
        h.repo.applyPermissions(
          PermissionApplyRequest(review: review, acl: changed(review)),
        ),
        throwsA(error(PermissionsExceptionReason.unavailableMethod)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  for (final raw in [
    <String, Object?>{'UNKNOWN': true},
    <String, Object?>{'READ_DATA': true},
  ]) {
    test(
      'incomplete or unknown advanced permission metadata fails closed $raw',
      () async {
        final h = await connect(kind: 'NFS4');
        (h.transport.acl.first as Map)['perms'] = raw;
        await expectLater(
          h.review(),
          throwsA(error(PermissionsExceptionReason.invalidResponse)),
        );
      },
    );
  }
  for (final id in [-9223372036854775808, 2147483648, 9007199254740992]) {
    test('unsafe numeric identity $id is rejected', () async {
      final h = await connect();
      await expectLater(
        h.repo.lookupPermissionIdentity(PermissionIdentityKind.user, id),
        throwsA(error(PermissionsExceptionReason.invalidInput)),
      );
      expect(h.transport.writes, isEmpty);
    });
  }
  test('POSIX masks defaults duplicates and unknown fields validate without dispatch', () async {
    final h = await connect();
    final review = await h.review();
    for (final acl in [
      <PermissionAce>[],
      [...review.acl, review.acl.first],
      [
        ...review.acl,
        PermissionAce(tag: 'USER', id: 1001, permissions: {'READ': true}),
      ],
      [
        ...review.acl,
        PermissionAce(
          tag: 'OTHER',
          permissions: {'READ': true},
          isDefault: true,
        ),
      ],
      [edited(review.acl.first, permission: 'UNKNOWN'), ...review.acl.skip(1)],
    ]) {
      expect(
        PermissionApplyRequest(review: review, acl: acl).validationError,
        isNotNull,
      );
    }
    final acl = [
      ...review.acl,
      PermissionAce(tag: 'MASK', permissions: {'READ': true, 'EXECUTE': true}),
      PermissionAce(tag: 'USER', id: 1001, permissions: {'READ': true}),
      for (final ace in review.acl) edited(ace, defaults: true),
    ];
    expect(
      PermissionApplyRequest(review: review, acl: acl).validationError,
      null,
    );
    expect(h.transport.writes, isEmpty);
  });
  test('NFSv4 special DENY and invalid inherit-only are rejected', () async {
    final h = await connect(kind: 'NFS4');
    final review = await h.review();
    expect(
      PermissionApplyRequest(
        review: review,
        acl: [
          edited(review.acl.first, type: 'DENY'),
          ...review.acl.skip(1),
        ],
      ).validationError,
      isNotNull,
    );
    expect(
      PermissionApplyRequest(
        review: review,
        acl: [
          edited(review.acl.first, flag: 'INHERIT_ONLY'),
          ...review.acl.skip(1),
        ],
      ).validationError,
      isNotNull,
    );
  });
  test('mutation parameters cannot request recursion ownership or ACL-wide changes', () async {
    final h = await connect(kind: 'NFS4');
    final review = await h.review();
    await h.repo.applyPermissions(
      PermissionApplyRequest(review: review, acl: changed(review)),
    );
    final payload = (h.transport.writes.single['params'] as List).single as Map;
    expect(payload['nfs41_flags'], {
      'autoinherit': false,
      'protected': false,
      'defaulted': false,
    });
    expect((payload['options'] as Map)['recursive'], false);
  });
}

class PermissionsHarness {
  PermissionsHarness(String kind, String version, Set<String> methods) {
    transport = PermissionsTransport(kind, version, methods);
    repo = TrueNasSessionRepository(
      connector: PermissionsConnector(transport),
      managementRequestTimeout: const Duration(milliseconds: 50),
    );
  }
  late final PermissionsTransport transport;
  late final TrueNasSessionRepository repo;
  Future<PermissionReview> review() async =>
      repo.loadPermissionReview((await repo.loadPermissionDatasets()).single);
}

class PermissionsConnector implements RpcConnector {
  const PermissionsConnector(this.transport);
  final RpcTransport transport;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => transport;
}

class PermissionsTransport implements RpcTransport {
  PermissionsTransport(this.kind, this.version, this.methods) {
    dataset = {
      'id': 'tank/data',
      'name': 'tank/data',
      'type': 'FILESYSTEM',
      'mountpoint': '/mnt/tank/data',
      'locked': false,
      'encrypted': false,
      'guid': prop('18446744073709551615'),
      'creation': prop('1700000000'),
      'readonly': prop('off'),
      'acltype': prop(
        kind == 'NFS4'
            ? 'nfsv4'
            : kind == 'POSIX1E'
            ? 'posix'
            : 'off',
      ),
      'aclmode': prop('passthrough'),
      'managedby': prop('-'),
    };
    acl = kind == 'NFS4'
        ? [nfs('owner@'), nfs('group@'), nfs('everyone@')]
        : kind == 'POSIX1E'
        ? [posix('USER_OBJ', 7), posix('GROUP_OBJ', 5), posix('OTHER', 0)]
        : [];
  }
  final String kind, version;
  final Set<String> methods;
  final inbound = StreamController<String>();
  final calls = <Map<String, Object?>>[];
  late Map<String, Object?> dataset;
  late List<Object?> acl;
  final aclFlags = {
    'autoinherit': false,
    'protected': false,
    'defaulted': false,
  };
  final pathOverrides = <String, Map<String, Object?>>{};
  final mountOverrides = <String, Object?>{};
  int mode = 488, uid = 1000, gid = 1000, nfsMode = 488;
  String jobState = 'RUNNING';
  String? tamper;
  bool applied = false, driftOnLookup = false, identityExists = true;
  List<Object?>? arguments;
  String? jobMethod;
  Object? jobMessageId;
  Iterable<Map<String, Object?>> get writes => calls.where(
    (r) =>
        r['method'] == 'filesystem.setacl' ||
        r['method'] == 'filesystem.setperm',
  );
  @override
  Stream<String> get inboundFrames => inbound.stream;
  Object? aclResult() => {
    'path': '/mnt/tank/data',
    'uid': uid,
    'gid': gid,
    'user': null,
    'group': null,
    'acltype': kind,
    'trivial': kind == 'DISABLED' || kind == 'POSIX1E' && acl.length == 3,
    'acl': kind == 'DISABLED' ? null : acl,
    if (kind == 'NFS4') 'aclflags': aclFlags,
  };
  void applyJob() {
    if (applied) return;
    applied = true;
    final payload = arguments!.single as Map;
    if (jobMethod == 'filesystem.setacl') {
      acl = (jsonDecode(jsonEncode(payload['dacl'])) as List).cast<Object?>();
      if (kind == 'NFS4') {
        mode = nfsMode;
      } else {
        int bits(String tag) {
          final p =
              (acl.cast<Map>().firstWhere(
                    (a) => a['default'] == false && a['tag'] == tag,
                  )['perms']
                  as Map);
          return (p['READ'] == true ? 4 : 0) +
              (p['WRITE'] == true ? 2 : 0) +
              (p['EXECUTE'] == true ? 1 : 0);
        }

        mode = int.parse(
          '${bits('USER_OBJ')}${bits(acl.cast<Map>().any((a) => a['tag'] == 'MASK' && a['default'] == false) ? 'MASK' : 'GROUP_OBJ')}${bits('OTHER')}',
          radix: 8,
        );
      }
    } else {
      mode = int.parse(payload['mode'] as String, radix: 8);
      if (kind == 'POSIX1E') {
        acl = [
          posix('USER_OBJ', (mode >> 6) & 7),
          posix('GROUP_OBJ', (mode >> 3) & 7),
          posix('OTHER', mode & 7),
        ];
      }
    }
    if (tamper == 'acl') {
      ((acl.first as Map)['perms'] as Map)['EXECUTE'] =
          !(((acl.first as Map)['perms'] as Map)['EXECUTE'] as bool);
    }
    if (tamper == 'owner') uid = 1234;
    if (tamper == 'flags') aclFlags['protected'] = true;
  }

  @override
  Future<void> send(String frame) async {
    final r = Map<String, Object?>.from(jsonDecode(frame) as Map);
    calls.add(r);
    final method = r['method'] as String;
    final args = r['params'] as List? ?? [];
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
              'job': m == 'filesystem.setacl' || m == 'filesystem.setperm',
              'no_auth_required': false,
            },
        };
      case 'pool.dataset.query':
        result = [dataset];
      case 'filesystem.stat':
        final path = args.single as String;
        final target = path == '/mnt/tank/data';
        result = {
          'type': 'DIRECTORY',
          'realpath': path,
          'uid': target ? uid : 0,
          'gid': target ? gid : 0,
          'mode': 16384 + (target ? mode : 493),
          'dev': 1,
          'inode': path.length,
          'mount_id': target ? 2 : 1,
          'is_ctldir': false,
          'is_mountpoint': target,
          'acl': target && kind != 'DISABLED',
          'attributes': <String>[],
          ...?pathOverrides[path],
        };
      case 'filesystem.statfs':
        result = {
          'fstype': 'zfs',
          'source': 'tank/data',
          'dest': '/mnt/tank/data',
          'fsid': '123',
          'flags': ['RW'],
          ...mountOverrides,
        };
      case 'filesystem.getacl':
        result = aclResult();
      case 'user.query':
      case 'group.query':
        final id = ((args.first as List).single as List)[2];
        if (driftOnLookup) dataset['managedby'] = prop('external');
        result = identityExists
            ? [
                {
                  method == 'user.query' ? 'uid' : 'gid': id,
                  method == 'user.query' ? 'username' : 'name': 'fixture',
                  'local': true,
                },
              ]
            : [];
      case 'filesystem.setacl':
      case 'filesystem.setperm':
        arguments = List<Object?>.from(args);
        jobMethod = method;
        jobMessageId = r['id'];
        if (tamper == 'timeout') return;
        result = tamper == 'modern' ? aclResult() : 41;
      case 'core.get_jobs':
        if (jobState == 'SUCCESS') applyJob();
        result = tamper == 'missing'
            ? []
            : [
                {
                  'id': tamper == 'id' ? 99 : 41,
                  'method': tamper == 'method' ? 'filesystem.other' : jobMethod,
                  'arguments': tamper == 'arguments' ? <Object?>[] : arguments,
                  'message_ids': tamper == 'message_ids'
                      ? ['other-session']
                      : [jobMessageId],
                  'state': tamper == 'FAILED' || tamper == 'ABORTED'
                      ? tamper
                      : jobState,
                  'result': {'private': 'ignored'},
                },
              ];
      default:
        throw StateError('Unexpected synthetic permission method $method');
    }
    inbound.add(
      jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() async {
    await inbound.close();
  }
}
