import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const methods = {
  'sharing.nfs.query',
  'sharing.nfs.create',
  'sharing.nfs.update',
  'sharing.nfs.delete',
  'nfs.config',
  'service.query',
  'pool.dataset.query',
  'pool.dataset.attachments',
  'filesystem.stat',
  'filesystem.statfs',
  'filesystem.listdir',
  'failover.licensed',
  'user.get_user_obj',
  'group.get_group_obj',
  'pool.dataset.create',
};
Map<String, Object?> prop(String value) => {
  'rawvalue': value,
  'value': value,
  'source': 'LOCAL',
};
Map<String, Object?> dataset(String id, String guid) => {
  'id': id,
  'type': 'FILESYSTEM',
  'mountpoint': '/mnt/$id',
  'encrypted': false,
  'locked': false,
  'guid': prop(guid),
  'creation': prop('1700000000'),
  'readonly': prop('off'),
  'origin': prop('-'),
  'encryption': prop('off'),
  'encryptionroot': prop('-'),
  'keystatus': prop('-'),
  'acltype': prop('nfsv4'),
  'aclmode': prop('restricted'),
  'sharenfs': prop('off'),
  'managedby': null,
};
Map<String, Object?> share({int id = 1, String path = '/mnt/tank/data'}) => {
  'id': id,
  'path': path,
  'aliases': <String>[],
  'comment': 'Primary export',
  'networks': <String>['192.168.10.0/24'],
  'hosts': <String>[],
  'ro': false,
  'maproot_user': null,
  'maproot_group': null,
  'mapall_user': null,
  'mapall_group': null,
  'security': <String>['SYS'],
  'enabled': true,
  'locked': false,
  'expose_snapshots': false,
};
NfsShareSettings settings({
  String path = '/mnt/tank/data',
  String comment = 'Reviewed change',
  bool enabled = true,
  bool readOnly = false,
  List<String> hosts = const [],
  List<String> networks = const ['192.168.10.0/24'],
  String? user,
  String? group,
}) => NfsShareSettings(
  path: path,
  comment: comment,
  enabled: enabled,
  readOnly: readOnly,
  hosts: hosts,
  networks: networks,
  mapallUser: user,
  mapallGroup: group,
);
Matcher reason(NfsSharesExceptionReason r) =>
    isA<NfsSharesException>().having((e) => e.reason, 'reason', r);
Future<Harness> connect({
  String version = '25.10.1',
  Set<String> available = methods,
  String? badMetadata,
}) async {
  final h = Harness(version, available, badMetadata);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    username: 'admin',
    apiKey: 'synthetic-only',
    isConnectionCurrent: () => h.current,
  );
  return h;
}

Future<NfsShareReview> review(
  Harness h, {
  NfsShareAction action = NfsShareAction.update,
  NfsShareSettings? desired,
}) async {
  final inventory = await h.repo.loadNfsShares();
  return h.repo.reviewNfsShare(
    NfsShareRequest(
      inventory: inventory,
      action: action,
      share: action == NfsShareAction.create ? null : inventory.shares.first,
      settings: action == NfsShareAction.delete
          ? null
          : desired ??
                settings(
                  path: action == NfsShareAction.create
                      ? '/mnt/tank/new'
                      : '/mnt/tank/data',
                ),
    ),
  );
}

void main() {
  for (final guid in ['9223372036854775807', '18446744073709551615']) {
    test(
      'authoritative GUID $guid survives large redundant parsed property value',
      () async {
        final h = await connect();
        h.wire.datasets[1]['guid'] = {
          ...prop(guid),
          'parsed': guid == '9223372036854775807'
              ? 9223372036854775807
              : 1.8446744073709552e19,
        };
        final r = await review(h);
        expect(r.identity, contains(guid));
        expect(
          (await h.repo.executeNfsShare(r, r.target)).outcome,
          NfsShareOutcome.verified,
        );
      },
    );
  }
  test('unknown NFS operation blocks SMB read and mutation before any SMB dispatch', () async {
    final h = await connect(
      available: {...methods, 'sharing.smb.query', 'sharing.smb.update'},
    );
    final r = await review(h);
    h.wire.postFault = 'error';
    expect(
      (await h.repo.executeNfsShare(r, r.target)).outcome,
      NfsShareOutcome.unknown,
    );
    final busy = isA<SmbSharesException>().having(
      (e) => e.reason,
      'reason',
      SmbSharesExceptionReason.busy,
    );
    await expectLater(h.repo.loadSmbShares(), throwsA(busy));
    final smb = SmbShareReview(
      action: SmbShareAction.update,
      target: 'Documents',
      identity: 'fake-only',
      changes: [],
      warnings: [],
    );
    await expectLater(h.repo.executeSmbShare(smb, smb.target), throwsA(busy));
    expect(
      h.wire.calls.where(
        (r) => (r['method'] as String).startsWith('sharing.smb.'),
      ),
      isEmpty,
    );
    expect(h.wire.writes, hasLength(1));
  });
  test(
    'nullable lock status keeps inventory visible but blocks every write',
    () async {
      final h = await connect();
      h.wire.shares.single['locked'] = null;
      final i = await h.repo.loadNfsShares();
      expect(i.shares, hasLength(1));
      expect(i.shares.single.editable, false);
      expect(i.blockedReason, isNotNull);
      expect(h.wire.writes, isEmpty);
    },
  );
  test('zero creation timestamp cannot establish dataset identity', () async {
    final h = await connect();
    h.wire.datasets[1]['creation'] = prop('0');
    final i = await h.repo.loadNfsShares();
    expect(i.datasets, isEmpty);
    expect(i.blockedReason, isNotNull);
    expect(h.wire.writes, isEmpty);
  });
  test(
    'local identity with a valid SMB SID remains supported and bound',
    () async {
      final h = await connect();
      h.wire.sid = 'S-1-5-21-100-200-300-1000';
      final r = await review(
        h,
        desired: settings(user: 'backup', group: 'backup'),
      );
      expect(
        (await h.repo.executeNfsShare(r, r.target)).outcome,
        NfsShareOutcome.verified,
      );
    },
  );
  test('mapping SID replacement after dispatch remains unknown', () async {
    final h = await connect();
    h.wire.sid = 'S-1-5-21-100-200-300-1000';
    final r = await review(h, desired: settings(user: 'backup'));
    h.wire.onWrite = () => h.wire.sid = 'S-1-5-21-100-200-300-1001';
    expect(
      (await h.repo.executeNfsShare(r, r.target)).outcome,
      NfsShareOutcome.unknown,
    );
  });
  test('malformed local SID cannot pass identity proof', () async {
    final h = await connect();
    h.wire.sid = 'S-1-5-4294967296';
    await expectLater(
      review(h, desired: settings(user: 'backup')),
      throwsA(reason(NfsSharesExceptionReason.invalid)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test('disconnect during optional proof propagates rather than issuing stale inventory', () async {
    final h = await connect();
    h.wire.onCall = (r) {
      if (r['method'] == 'filesystem.listdir') h.current = false;
    };
    await expectLater(
      h.repo.loadNfsShares(),
      throwsA(reason(NfsSharesExceptionReason.notAuthenticated)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test(
    'missing global config field fails rather than inferring a default',
    () async {
      final h = await connect();
      h.wire.config.remove('keytab_has_nfs_spn');
      await expectLater(
        h.repo.loadNfsShares(),
        throwsA(reason(NfsSharesExceptionReason.invalid)),
      );
      expect(h.wire.writes, isEmpty);
    },
  );
  test('unexpected enabled NFS attachment never passes preflight', () async {
    final h = await connect();
    h.wire.extraAttachments = [
      {
        'type': 'NFS Share',
        'service': 'nfs',
        'attachments': ['/mnt/tank/data/foreign'],
      },
    ];
    await expectLater(
      review(h),
      throwsA(reason(NfsSharesExceptionReason.invalid)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test(
    'unselected native NFS attachment drift after dispatch is unknown',
    () async {
      final h = await connect();
      final r = await review(h);
      h.wire.onWrite = () => h.wire.extraAttachments = [
        {
          'type': 'NFS Share',
          'service': 'nfs',
          'attachments': ['/mnt/tank/data/foreign'],
        },
      ];
      expect(
        (await h.repo.executeNfsShare(r, r.target)).outcome,
        NfsShareOutcome.unknown,
      );
    },
  );
  test('native model accepts plain paths, local names and exact CIDR without controls', () {
    expect(settings(user: 'backup', group: 'backup').validationError, isNull);
    expect(settings(comment: '한국어 export').validationError, isNull);
    for (final text in ['bad\nname', 'bad\u202ename']) {
      expect(settings(comment: text).validationError, isNotNull);
    }
  });
  for (final network in [
    '192.168.1.1/24',
    '192.168.1.0/0',
    '192.168.1.0/33',
    '0.0.0.0/0',
    '::/0',
    '192.168.1.0/024',
  ]) {
    test('reject ambiguous or unsupported network $network', () {
      expect(settings(networks: [network]).validationError, isNotNull);
    });
  }
  test('duplicates, overlapping networks, host-in-network, DNS and group-only rejected', () {
    expect(
      settings(hosts: ['nas.example'], networks: []).validationError,
      isNotNull,
    );
    expect(settings(hosts: ['192.168.10.1']).validationError, isNotNull);
    expect(
      settings(networks: ['192.168.10.0/24', '192.168.10.0/25'])
          .validationError,
      isNotNull,
    );
    expect(
      settings(
        hosts: ['192.168.5.1', '192.168.5.1'],
        networks: [],
      ).validationError,
      isNotNull,
    );
    expect(settings(group: 'backup').validationError, isNotNull);
  });
  test(
    'immutable settings and inventory cannot mutate issued target',
    () async {
      final hosts = ['192.168.2.1'];
      final s = settings(hosts: hosts, networks: []);
      hosts.clear();
      expect(s.hosts, hasLength(1));
      expect(() => s.hosts.clear(), throwsUnsupportedError);
      final h = await connect();
      final inventory = await h.repo.loadNfsShares();
      expect(inventory.blockedReason, isNull);
      expect(inventory.shares.single.editable, true);
      expect(() => inventory.shares.clear(), throwsUnsupportedError);
      expect(h.wire.writes, isEmpty);
    },
  );
  for (final version in ['25.04.2', '25.10-BETA.1', '26.0.0']) {
    test('version $version prevents inventory transport', () async {
      final h = await connect(version: version);
      await expectLater(
        h.repo.loadNfsShares(),
        throwsA(reason(NfsSharesExceptionReason.unsupportedVersion)),
      );
      expect(
        h.wire.calls.where((r) => r['method'] == 'sharing.nfs.query'),
        isEmpty,
      );
    });
  }
  for (final flag in [
    'job',
    'private',
    '_private',
    'uploadable',
    'downloadable',
    'no_auth_required',
    'missing',
  ]) {
    test('unsafe setter metadata $flag disables capability', () async {
      final h = await connect(badMetadata: flag);
      expect(h.repo.nfsSharesCapabilities.canUpdate, false);
      await expectLater(
        review(h),
        throwsA(reason(NfsSharesExceptionReason.unavailableMethod)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('missing write proofs and denied advertised proofs preserve read-only inventory', () async {
    final h = await connect(
      available: methods.difference({'filesystem.listdir'}),
    );
    final i = await h.repo.loadNfsShares();
    expect(i.shares, hasLength(1));
    expect(i.blockedReason, isNotNull);
    expect(h.repo.nfsSharesCapabilities.canCreate, false);
    final denied = await connect();
    denied.wire.failMethod = 'filesystem.listdir';
    final read = await denied.repo.loadNfsShares();
    expect(read.shares, hasLength(1));
    expect(read.datasets, isEmpty);
    expect(read.blockedReason, isNot(contains('private-wire-secret')));
  });
  for (final action in NfsShareAction.values) {
    test(
      '${action.name} dispatches once and independently verifies exact configuration',
      () async {
        final h = await connect();
        final r = await review(h, action: action);
        expect(r.warnings.join(), contains('globally'));
        expect(r.warnings.join(), contains('/etc/exports.d'));
        expect(h.wire.writes, isEmpty);
        final result = await h.repo.executeNfsShare(r, r.target);
        expect(result.outcome, NfsShareOutcome.verified);
        expect(h.wire.writes, hasLength(1));
        expect(h.wire.writes.single['method'], 'sharing.nfs.${action.name}');
        await expectLater(
          h.repo.executeNfsShare(r, r.target),
          throwsA(reason(NfsSharesExceptionReason.stale)),
        );
        expect(h.wire.writes, hasLength(1));
      },
    );
  }
  test('partial update preserves hidden security and exact null/empty mapping fields', () async {
    final h = await connect();
    h.wire.shares.single['security'] = <String>[];
    h.wire.shares.single['maproot_user'] = '';
    h.wire.shares.single['maproot_group'] = '';
    final i = await h.repo.loadNfsShares();
    final r = await h.repo.reviewNfsShare(
      NfsShareRequest(
        inventory: i,
        action: NfsShareAction.update,
        share: i.shares.single,
        settings: NfsShareSettings(
          path: '/mnt/tank/data',
          comment: 'Changed',
          networks: ['192.168.10.0/24'],
          maprootUser: '',
          maprootGroup: '',
        ),
      ),
    );
    expect(
      (await h.repo.executeNfsShare(r, r.target)).outcome,
      NfsShareOutcome.verified,
    );
    expect((h.wire.writes.single['params'] as List)[1], {'comment': 'Changed'});
    expect(h.wire.shares.single['security'], isEmpty);
  });
  test(
    'disable and readonly are explicitly reviewed and preserve dataset',
    () async {
      final h = await connect();
      final r = await review(
        h,
        desired: settings(enabled: false, readOnly: true),
      );
      expect(r.changes.join(), contains('enabled'));
      expect(
        (await h.repo.executeNfsShare(r, r.target)).outcome,
        NfsShareOutcome.verified,
      );
      expect(h.wire.datasets, hasLength(3));
    },
  );
  test('exact confirmation failure consumes review and never writes', () async {
    final h = await connect();
    final r = await review(h);
    await expectLater(
      h.repo.executeNfsShare(r, '${r.target} '),
      throwsA(reason(NfsSharesExceptionReason.stale)),
    );
    await expectLater(
      h.repo.executeNfsShare(r, r.target),
      throwsA(reason(NfsSharesExceptionReason.stale)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test(
    'new review invalidates previous and foreign issued handles are rejected',
    () async {
      final h = await connect();
      final r = await review(h);
      final second = await review(h);
      await expectLater(
        h.repo.executeNfsShare(r, r.target),
        throwsA(reason(NfsSharesExceptionReason.stale)),
      );
      final forged = NfsShareReview(
        action: second.action,
        target: second.target,
        identity: second.identity,
        changes: second.changes,
        warnings: second.warnings,
      );
      await expectLater(
        h.repo.executeNfsShare(forged, forged.target),
        throwsA(reason(NfsSharesExceptionReason.stale)),
      );
      expect(h.wire.writes, isEmpty);
    },
  );
  for (final fault in [
    'guid',
    'config',
    'service',
    'other-share',
    'dependency',
    'identity',
    'inode',
    'exports-inode',
    'manual-export',
  ]) {
    test('preflight $fault drift sends nothing', () async {
      final h = await connect();
      final r = await review(
        h,
        desired: settings(user: 'backup', group: 'backup'),
      );
      h.wire.drift(fault);
      expect(
        (await h.repo.executeNfsShare(r, r.target)).outcome,
        NfsShareOutcome.rejected,
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final fault in [
    'guid',
    'config',
    'service',
    'other-share',
    'dependency',
    'identity',
    'inode',
    'exports-inode',
    'manual-export',
    'receipt',
    'readback',
    'error',
    'timeout',
  ]) {
    test('post-dispatch $fault remains unknown and holds lock', () async {
      final h = await connect();
      final r = await review(
        h,
        desired: settings(user: 'backup', group: 'backup'),
      );
      h.wire.postFault = fault;
      final result = await h.repo.executeNfsShare(r, r.target);
      expect(result.outcome, NfsShareOutcome.unknown);
      expect(result.message, isNot(contains('private-wire-secret')));
      expect(h.wire.writes, hasLength(1));
      await expectLater(
        h.repo.loadNfsShares(),
        throwsA(reason(NfsSharesExceptionReason.busy)),
      );
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
  }
  test('removed old mapping identity is still verified after update', () async {
    final h = await connect();
    h.wire.shares.single['mapall_user'] = 'backup';
    h.wire.shares.single['mapall_group'] = 'backup';
    final r = await review(h);
    h.wire.postFault = 'identity';
    expect(
      (await h.repo.executeNfsShare(r, r.target)).outcome,
      NfsShareOutcome.unknown,
    );
  });
  for (final key in ['aliases', 'security', 'expose_snapshots', 'locked']) {
    test(
      'unsupported existing $key blocks global reload without hiding export',
      () async {
        final h = await connect();
        h.wire.shares.single[key] = switch (key) {
          'aliases' => ['legacy'],
          'security' => ['KRB5'],
          _ => true,
        };
        final i = await h.repo.loadNfsShares();
        expect(i.shares, hasLength(1));
        expect(i.blockedReason, isNotNull);
        expect(i.shares.single.editable, false);
        expect(h.wire.writes, isEmpty);
      },
    );
  }
  for (final fault in [
    'encrypted',
    'managed',
    'missing-ancestor',
    'symlink-etc',
    'mutable-exports',
  ]) {
    test('$fault blocks safely', () async {
      final h = await connect();
      switch (fault) {
        case 'encrypted':
          h.wire.datasets.last['encrypted'] = true;
          h.wire.datasets[1]['encrypted'] = true;
        case 'managed':
          h.wire.datasets[1]['managedby'] = prop('none');
        case 'missing-ancestor':
          h.wire.datasets.removeAt(0);
        case 'symlink-etc':
          h.wire.symlink = '/etc';
        case 'mutable-exports':
          h.wire.immutable = false;
      }
      final i = await h.repo.loadNfsShares();
      final request = NfsShareRequest(
        inventory: i,
        action: NfsShareAction.update,
        share: i.shares.single,
        settings: settings(),
      );
      expect(request.validationError, isNotNull);
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final id in [0, 4294967295, 9007199254740991]) {
    test('local mapping UID $id rejected', () async {
      final h = await connect();
      h.wire.uid = id;
      await expectLater(
        review(h, desired: settings(user: 'backup')),
        throwsA(reason(NfsSharesExceptionReason.invalid)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('nonlocal identities and path moves are not admitted', () async {
    final h = await connect();
    h.wire.local = false;
    await expectLater(
      review(h, desired: settings(user: 'backup')),
      throwsA(reason(NfsSharesExceptionReason.invalid)),
    );
    await expectLater(
      review(h, desired: settings(path: '/mnt/tank/new')),
      throwsA(reason(NfsSharesExceptionReason.invalid)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test(
    'stale connection before dispatch prevents write; after dispatch unknown',
    () async {
      final h = await connect();
      final r = await review(h);
      h.current = false;
      await expectLater(
        h.repo.executeNfsShare(r, r.target),
        throwsA(reason(NfsSharesExceptionReason.notAuthenticated)),
      );
      expect(h.wire.writes, isEmpty);
      h.current = true;
      h.wire.onWrite = () => h.current = false;
      expect(
        (await h.repo.executeNfsShare(r, r.target)).outcome,
        NfsShareOutcome.unknown,
      );
    },
  );
  test('bounded duplicate/oversized inventories fail closed', () async {
    final h = await connect();
    h.wire.shares.add(share());
    await expectLater(
      h.repo.loadNfsShares(),
      throwsA(reason(NfsSharesExceptionReason.invalid)),
    );
    h.wire.shares = [for (var i = 0; i < 257; i++) share(id: i + 1)];
    await expectLater(
      h.repo.loadNfsShares(),
      throwsA(reason(NfsSharesExceptionReason.invalid)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test(
    'public export proof lists without filters and stats every ancestor',
    () async {
      final h = await connect();
      await review(h);
      final request = h.wire.calls.firstWhere(
        (r) => r['method'] == 'filesystem.listdir',
      );
      expect(request['params'], [
        '/etc/exports.d',
        [],
        {
          'limit': 1,
          'select': ['name', 'path', 'type'],
        },
      ]);
      expect(
        h.wire.calls
            .where((r) => r['method'] == 'filesystem.stat')
            .map((r) => (r['params'] as List).single),
        containsAll([
          '/',
          '/etc',
          '/etc/exports.d',
          '/mnt',
          '/mnt/tank',
          '/mnt/tank/data',
        ]),
      );
      expect(h.wire.writes, isEmpty);
    },
  );
}

class Harness {
  Harness(String version, Set<String> methods, String? metadata) {
    wire = Wire(version, methods, metadata);
    repo = TrueNasSessionRepository(
      connector: Connector(wire),
      managementRequestTimeout: const Duration(milliseconds: 80),
    );
  }
  bool current = true;
  late final Wire wire;
  late final TrueNasSessionRepository repo;
}

class Connector implements RpcConnector {
  Connector(this.wire);
  final RpcTransport wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class Wire implements RpcTransport {
  Wire(this.version, this.methods, this.badMetadata);
  final String version;
  final Set<String> methods;
  final String? badMetadata;
  final inbound = StreamController<String>();
  final calls = <Map<String, Object?>>[];
  List<Map<String, Object?>> shares = [share()];
  final datasets = [
    dataset('tank', '1'),
    dataset('tank/data', '2'),
    dataset('tank/new', '3'),
  ];
  final config = <String, Object?>{
    'id': 1,
    'allow_nonroot': false,
    'protocols': ['NFSV3', 'NFSV4'],
    'v4_krb': false,
    'v4_krb_enabled': false,
    'rdma': false,
    'keytab_has_nfs_spn': false,
    'servers': 4,
    'managed_nfsd': true,
    'v4_domain': '',
    'bindip': <String>[],
    'mountd_port': null,
    'rpcstatd_port': null,
    'rpclockd_port': null,
    'mountd_log': false,
    'statd_lockd_log': false,
    'userd_manage_gids': false,
  };
  int uid = 1000, inode = 42, exportsInode = 10;
  bool local = true, immutable = true;
  String service = 'RUNNING';
  bool manual = false;
  String? symlink, postFault, failMethod;
  VoidCallback? onWrite;
  void Function(Map<String, Object?>)? onCall;
  String? sid;
  List<Map<String, Object?>> extraAttachments = [];
  List<Map<String, Object?>> get writes => calls
      .where(
        (r) => {
          'sharing.nfs.create',
          'sharing.nfs.update',
          'sharing.nfs.delete',
          'pool.dataset.create',
        }.contains(r['method']),
      )
      .toList();
  void drift(String fault) {
    switch (fault) {
      case 'guid':
        datasets[1]['guid'] = prop('999');
      case 'config':
        config['allow_nonroot'] = true;
      case 'service':
        service = 'STOPPED';
      case 'other-share':
        shares.add(share(id: 99, path: '/mnt/tank/new'));
      case 'dependency':
        extraAttachments = [
          {
            'type': 'SMB',
            'service': 'cifs',
            'attachments': ['new-consumer'],
          },
        ];
      case 'identity':
        uid++;
      case 'inode':
        inode++;
      case 'exports-inode':
        exportsInode++;
      case 'manual-export':
        manual = true;
    }
  }

  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String message) async {
    final r = (jsonDecode(message) as Map).cast<String, Object?>();
    calls.add(r);
    onCall?.call(r);
    final args = r['params'] as List? ?? [];
    final method = r['method'];
    Object? result;
    if (method == failMethod) {
      _error(r);
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
          for (final m in methods)
            m: {
              'accepts': [],
              'returns': [],
              'job': false,
              'no_auth_required': false,
              'uploadable': false,
              'downloadable': false,
              if (m == 'sharing.nfs.update' &&
                  badMetadata != null &&
                  badMetadata != 'missing')
                badMetadata!: true,
              if (m == 'sharing.nfs.update' && badMetadata == 'missing')
                'job': null,
            },
        };
      case 'sharing.nfs.query':
        result = postFault == 'readback' && writes.isNotEmpty
            ? 'private-wire-secret'
            : shares;
      case 'nfs.config':
        result = config;
      case 'service.query':
        result = [
          {'id': 1, 'service': 'nfs', 'state': service, 'enable': true},
        ];
      case 'pool.dataset.query':
        result = datasets;
      case 'failover.licensed':
        result = false;
      case 'filesystem.stat':
        final path = args.single as String;
        result = {
          'type': path == symlink ? 'SYMLINK' : 'DIRECTORY',
          'realpath': path,
          'uid': 0,
          'gid': 0,
          'mode': 16877,
          'dev': 1,
          'inode': path == '/etc/exports.d' ? exportsInode : inode,
          'mount_id': 1,
          'acl': false,
          'is_ctldir': false,
          'is_mountpoint': true,
          'attributes': path == '/etc/exports.d' && immutable
              ? ['IMMUTABLE']
              : <String>[],
        };
      case 'filesystem.listdir':
        result = manual
            ? [
                {
                  'name': 'manual.exports',
                  'path': '/etc/exports.d/manual.exports',
                  'type': 'FILE',
                },
              ]
            : [];
      case 'filesystem.statfs':
        result = {
          'fstype': 'zfs',
          'source': (args.single as String).substring(5),
          'dest': args.single,
          'fsid': 'exact-mount',
          'flags': ['RW', 'NFS4ACL'],
        };
      case 'pool.dataset.attachments':
        final root = '/mnt/${args.single}';
        final names = [
          for (final s in shares)
            if (s['enabled'] == true &&
                ((s['path'] as String) == root ||
                    (s['path'] as String).startsWith('$root/')))
              s['path'],
        ];
        result = [
          if (names.isNotEmpty)
            {'type': 'NFS Share', 'service': 'nfs', 'attachments': names},
          ...extraAttachments,
        ];
      case 'user.get_user_obj':
        result = {
          'pw_name': (args.single as Map)['username'],
          'pw_uid': uid,
          'pw_gid': 2000,
          'source': local ? 'LOCAL' : 'LDAP',
          'local': local,
          'sid': sid,
        };
      case 'group.get_group_obj':
        result = {
          'gr_name': (args.single as Map)['groupname'],
          'gr_gid': 2000,
          'source': local ? 'LOCAL' : 'LDAP',
          'local': local,
          'sid': sid,
        };
      case 'sharing.nfs.create':
        final row = {
          'id': 2,
          ...(args.single as Map).cast<String, Object?>(),
          'locked': false,
        };
        shares.add(row);
        result = Map<String, Object?>.from(row);
      case 'sharing.nfs.update':
        final row = shares.firstWhere((s) => s['id'] == args.first);
        row.addAll((args[1] as Map).cast<String, Object?>());
        result = Map<String, Object?>.from(row);
      case 'sharing.nfs.delete':
        shares.removeWhere((s) => s['id'] == args.first);
        result = true;
    }
    if ({
      'sharing.nfs.create',
      'sharing.nfs.update',
      'sharing.nfs.delete',
    }.contains(method)) {
      onWrite?.call();
      if (postFault == 'timeout') return;
      if (postFault == 'error') {
        _error(r);
        return;
      }
      if (postFault == 'receipt') result = {'id': 1};
      if (postFault != null) drift(postFault!);
    }
    inbound.add(
      jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': result}),
    );
  }

  void _error(Map r) => inbound.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': r['id'],
      'error': {'code': -32001, 'message': 'private-wire-secret'},
    }),
  );
  @override
  Future<void> close() => inbound.close();
}

typedef VoidCallback = void Function();
