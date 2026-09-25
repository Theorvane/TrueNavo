import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _methods = {
  'cloudsync.query',
  'cloudsync.credentials.query',
  'pool.dataset.query',
  'filesystem.stat',
  'filesystem.statfs',
  'system.general.config',
  'core.get_jobs',
  'cloudsync.create',
  'cloudsync.update',
  'cloudsync.delete',
  'cloudsync.sync',
  'pool.dataset.create',
};
const _endpoint = 'wss://nas.example/api/current';
const _secret = 'synthetic-secret-never-display';
Map<String, Object?> _credential({String provider = 'S3'}) => {
  'id': 1,
  'name': 'Archive',
  'provider': {'type': provider},
};
Map<String, Object?> _task() => {
  'id': 1,
  'description': 'Archive',
  'path': '/mnt/tank/data',
  'credentials': _credential(),
  'attributes': {
    'folder': 'data',
    'bucket': 'sample-bucket',
    'region': '',
    'storage_class': '',
    'encryption': null,
    'fast_list': false,
  },
  'direction': 'PUSH',
  'transfer_mode': 'COPY',
  'enabled': false,
  'schedule': {
    'minute': '0',
    'hour': '2',
    'dom': '*',
    'month': '*',
    'dow': '*',
  },
  'exclude': <String>[],
  'pre_script': '',
  'post_script': '',
  'args': '',
  'snapshot': false,
  'include': <String>[],
  'encryption': false,
  'filename_encryption': false,
  'follow_symlinks': false,
  'create_empty_src_dirs': false,
  'bwlimit': <Object?>[],
  'transfers': null,
  'locked': false,
  'job': null,
};
Map<String, Object?> _dataset(String id) => {
  'id': id,
  'type': 'FILESYSTEM',
  'guid': {'value': id == 'tank' ? '100' : '101'},
  'mountpoint': '/mnt/$id',
  'mounted': {'value': 'yes'},
  'readonly': {'value': 'off'},
  'locked': false,
  'key_loaded': null,
};
CloudSyncSettings _settings({
  String description = 'Changed',
  bool enabled = false,
  String path = '/mnt/tank/data',
  String mode = 'COPY',
}) => CloudSyncSettings(
  path: path,
  credentialId: 1,
  description: description,
  bucket: 'sample-bucket',
  folder: 'data',
  enabled: enabled,
  transferMode: mode,
);
Matcher _reason(CloudSyncExceptionReason reason) =>
    isA<CloudSyncException>().having((e) => e.reason, 'reason', reason);
Future<_Harness> _connected({
  String version = '25.10.1',
  Set<String> methods = _methods,
  String? malformedMetadata,
}) async {
  final h = _Harness(version, methods, malformedMetadata);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    username: 'admin',
    apiKey: 'synthetic',
    isConnectionCurrent: () => h.current,
  );
  return h;
}

Future<CloudSyncReview> _review(
  _Harness h, {
  CloudSyncAction action = CloudSyncAction.update,
  CloudSyncSettings? settings,
}) async {
  final inventory = await h.repo.loadCloudSync();
  return h.repo.reviewCloudSync(
    CloudSyncRequest(
      inventory: inventory,
      action: action,
      task: action == CloudSyncAction.create ? null : inventory.tasks.single,
      settings:
          action == CloudSyncAction.create || action == CloudSyncAction.update
          ? settings ?? _settings()
          : null,
    ),
  );
}

void main() {
  for (final pending in [false, true]) {
    test(
      'cloud ${pending ? 'owned job' : 'unknown write'} fences replication, updates and legacy management',
      () async {
        final h = await _connected(
          methods: {
            ..._methods,
            'replication.query',
            'pool.filesystem_choices',
            'pool.snapshot.query',
            'replication.delete',
            'system.version_short',
            'boot.get_state',
            'boot.environment.query',
            'failover.licensed',
            'update.status',
            'update.available_versions',
          },
        );
        final r = await _review(
          h,
          action: pending ? CloudSyncAction.run : CloudSyncAction.update,
        );
        if (!pending) h.wire.fault = 'remote';
        expect(
          (await h.repo.executeCloudSync(r, r.target)).outcome,
          pending ? CloudSyncOutcome.pending : CloudSyncOutcome.unknown,
        );
        final boundary = h.wire.calls.length;
        expect(h.repo.replicationCapabilities.canDelete, true);
        expect(h.repo.systemUpdatesCapabilities.canCheck, true);
        await expectLater(
          h.repo.reviewReplication(
            ReplicationRequest(
              inventory: ReplicationInventory(
                endpoint: _endpoint,
                tasks: const [],
                datasets: const [],
              ),
              action: ReplicationAction.delete,
            ),
          ),
          throwsA(
            isA<ReplicationException>().having(
              (e) => e.reason,
              'reason',
              ReplicationExceptionReason.busy,
            ),
          ),
        );
        await expectLater(
          h.repo.reviewSystemUpdate(
            SystemUpdateRequest(
              inventory: SystemUpdateInventory(
                endpoint: _endpoint,
                currentVersion: '25.10.1',
                bootPool: 'boot-pool',
                bootHealthy: true,
                failoverLicensed: false,
                conflictingJob: false,
                environments: const [],
              ),
              action: SystemUpdateAction.check,
            ),
          ),
          throwsA(
            isA<SystemUpdatesException>().having(
              (e) => e.reason,
              'reason',
              SystemUpdatesExceptionReason.busy,
            ),
          ),
        );
        await expectLater(
          h.repo.execute(
            const CreateDatasetCommand(parent: 'tank', name: 'documents'),
          ),
          throwsA(
            isA<ManagementException>().having(
              (e) => e.reason,
              'reason',
              ManagementExceptionReason.busy,
            ),
          ),
        );
        expect(h.wire.calls.length, boundary);
      },
    );
  }
  test('disconnected calls never dispatch', () async {
    final h = _Harness('25.10.1', _methods, null);
    addTearDown(h.repo.close);
    expect(h.repo.cloudSyncCapabilities.connected, false);
    await expectLater(
      h.repo.loadCloudSync(),
      throwsA(_reason(CloudSyncExceptionReason.notAuthenticated)),
    );
    expect(h.wire.calls, isEmpty);
  });
  for (final version in ['25.04.2', '26.0', '25.10-BETA', '25.10.1\n']) {
    test('unsupported $version blocks reads', () async {
      final h = await _connected(version: version);
      await expectLater(
        h.repo.loadCloudSync(),
        throwsA(_reason(CloudSyncExceptionReason.unsupportedVersion)),
      );
      expect(h.wire.calls.length, 4);
    });
  }
  for (final method in _methods.difference({
    'cloudsync.create',
    'cloudsync.update',
    'cloudsync.delete',
    'cloudsync.sync',
    'pool.dataset.create',
  })) {
    test('missing safety method $method fails closed', () async {
      final h = await _connected(methods: _methods.difference({method}));
      expect(h.repo.cloudSyncCapabilities.supported, false);
      await expectLater(
        h.repo.loadCloudSync(),
        throwsA(_reason(CloudSyncExceptionReason.unavailableMethod)),
      );
    });
  }
  for (final field in [
    'job',
    'uploadable',
    'downloadable',
    'private',
    '_private',
    'no_auth_required',
  ]) {
    test('unsafe metadata $field blocks update', () async {
      final h = await _connected(malformedMetadata: field);
      expect(h.repo.cloudSyncCapabilities.canUpdate, false);
    });
  }
  test(
    'inventory has only credential references and no remote activity',
    () async {
      final h = await _connected();
      final inventory = await h.repo.loadCloudSync();
      expect(inventory.credentials.single.name, 'Archive');
      expect(inventory.tasks.single.settings.path, '/mnt/tank/data');
      expect(inventory.datasets.last.blockedReason, isNull);
      expect(h.wire.writes, isEmpty);
      final select =
          h.wire.calls.firstWhere(
                (r) => r['method'] == 'cloudsync.credentials.query',
              )['params']
              as List;
      expect((select.last as Map)['select'], ['id', 'name', 'provider.type']);
      final queries = h.wire.calls.where(
        (r) => r['method'] == 'cloudsync.query',
      );
      expect(
        jsonEncode(queries.toList()),
        isNot(contains('encryption_password')),
      );
      expect(jsonEncode(queries.toList()), isNot(contains('encryption_salt')));
      expect(
        h.wire.calls.any(
          (r) => [
            'cloudsync.providers',
            'cloudsync.list_directory',
            'cloudsync.list_buckets',
            'cloudsync.credentials.verify',
            'cloudsync.sync_onetime',
          ].contains(r['method']),
        ),
        false,
      );
    },
  );
  for (final action in CloudSyncAction.values) {
    test('exact ${action.name} payload submitted once', () async {
      final h = await _connected();
      final review = await _review(h, action: action);
      final result = await h.repo.executeCloudSync(review, review.target);
      expect(
        result.outcome,
        action == CloudSyncAction.run
            ? CloudSyncOutcome.pending
            : CloudSyncOutcome.succeeded,
      );
      expect(h.wire.writes.length, 1);
      final request = h.wire.writes.single;
      if (action == CloudSyncAction.run) {
        expect(request['method'], 'cloudsync.sync');
        expect(request['params'], [
          1,
          {'dry_run': false},
        ]);
      }
      if (action == CloudSyncAction.delete) expect(request['params'], [1]);
      if (action == CloudSyncAction.update) {
        expect(request['params'], [
          1,
          {'description': 'Changed'},
        ]);
      }
      if (action == CloudSyncAction.create) {
        final payload = (request['params'] as List).single as Map;
        expect(payload['credentials'], 1);
        expect(payload['enabled'], false);
        expect(payload.containsKey('pre_script'), false);
        expect(payload.containsKey('encryption_password'), false);
      }
      await expectLater(
        h.repo.executeCloudSync(review, review.target),
        throwsA(isA<CloudSyncException>()),
      );
      expect(h.wire.writes.length, 1);
    });
  }
  test('enablement saved explicitly without implicit run', () async {
    final h = await _connected();
    final r = await _review(
      h,
      settings: _settings(description: 'Archive', enabled: true),
    );
    expect(r.warnings.join(' '), contains('automatically'));
    expect(
      (await h.repo.executeCloudSync(r, r.target)).outcome,
      CloudSyncOutcome.succeeded,
    );
    expect(h.wire.writes.single['params'], [
      1,
      {'enabled': true},
    ]);
  });
  test('wrong exact confirmation consumes review without write', () async {
    final h = await _connected();
    final r = await _review(h);
    await expectLater(
      h.repo.executeCloudSync(r, ' ${r.target}'),
      throwsA(_reason(CloudSyncExceptionReason.staleReview)),
    );
    await expectLater(
      h.repo.executeCloudSync(r, r.target),
      throwsA(_reason(CloudSyncExceptionReason.staleReview)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test('forged review rejected', () async {
    final h = await _connected();
    final r = await _review(h),
        forged = CloudSyncReview(
          request: r.request,
          endpoint: r.endpoint,
          warnings: r.warnings,
        );
    await expectLater(
      h.repo.executeCloudSync(forged, forged.target),
      throwsA(_reason(CloudSyncExceptionReason.staleReview)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test('reload invalidates issued review', () async {
    final h = await _connected();
    final r = await _review(h);
    await h.repo.loadCloudSync();
    await expectLater(
      h.repo.executeCloudSync(r, r.target),
      throwsA(_reason(CloudSyncExceptionReason.staleReview)),
    );
    expect(h.wire.writes, isEmpty);
  });
  for (final drift in [
    'task',
    'credential',
    'guid',
    'timezone',
    'stat',
    'mount',
    'job',
  ]) {
    test('$drift drift rejects before dispatch', () async {
      final h = await _connected();
      final r = await _review(h);
      h.wire.drift(drift);
      expect(
        (await h.repo.executeCloudSync(r, r.target)).outcome,
        CloudSyncOutcome.rejected,
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final unsafe in [
    'snapshot',
    'encryption',
    'filename_encryption',
    'follow_symlinks',
    'create_empty_src_dirs',
    'locked',
    'pre_script',
    'post_script',
    'args',
    'include',
    'bwlimit',
    'transfers',
    'provider',
    'fast_list',
    'root_folder',
    'active',
  ]) {
    test('$unsafe task remains visible but cannot mutate', () async {
      final h = await _connected();
      h.wire.unsafe(unsafe);
      final inventory = await h.repo.loadCloudSync();
      expect(inventory.tasks.length, 1);
      expect(inventory.tasks.single.blockedReason, isNotNull);
      for (final action in [
        CloudSyncAction.update,
        CloudSyncAction.delete,
        CloudSyncAction.run,
      ]) {
        final request = CloudSyncRequest(
          inventory: inventory,
          action: action,
          task: inventory.tasks.single,
        );
        expect(request.validationError, isNotNull);
      }
      expect(h.wire.writes, isEmpty);
      expect(inventory.tasks.single.blockedReason, isNot(contains(_secret)));
    });
  }
  for (final path in [
    '/mnt',
    '/mnt/tank',
    '/mnt/tank/data/',
    '/mnt/tank/../data',
    '/mnt/tank//data',
    '/etc',
    '/mnt/tank/.zfs',
  ]) {
    test('unsafe local path $path rejected locally', () {
      expect(_settings(path: path).validate('S3'), isNotNull);
    });
  }
  for (final folder in [
    '',
    '/',
    '../x',
    'a/../b',
    'a//b',
    'a/',
    '/a',
    'a\nb',
  ]) {
    test('unsafe remote folder $folder rejected locally', () {
      expect(
        CloudSyncSettings(
          path: '/mnt/tank/data',
          credentialId: 1,
          bucket: 'sample-bucket',
          folder: folder,
        ).validate('S3'),
        isNotNull,
      );
    });
  }
  for (final cron in ['60', '-1', '*/0', 'a', '1\n', '1-70']) {
    test('invalid cron $cron rejected locally', () {
      expect(
        CloudSyncSettings(
          path: '/mnt/tank/data',
          credentialId: 1,
          bucket: 'sample-bucket',
          folder: 'data',
          minute: cron,
        ).validate('S3'),
        isNotNull,
      );
    });
  }
  for (final exclusion in ['../x', 'a\nb', '- /x', '+ x', 'a\\b']) {
    test('unsafe exclusion $exclusion rejected locally', () {
      expect(
        CloudSyncSettings(
          path: '/mnt/tank/data',
          credentialId: 1,
          bucket: 'sample-bucket',
          folder: 'data',
          exclude: [exclusion],
        ).validate('S3'),
        isNotNull,
      );
    });
  }
  test(
    'PULL SYNC and MOVE explicitly describe destructive direction',
    () async {
      final h = await _connected();
      h.wire.task['direction'] = 'PULL';
      h.wire.task['transfer_mode'] = 'SYNC';
      final r = await _review(h, action: CloudSyncAction.run);
      expect(r.warnings.join(' '), contains('PULL writes NAS data'));
      expect(r.warnings.join(' '), contains('deletes destination'));
      expect(h.wire.writes, isEmpty);
    },
  );
  test('Dropbox payload excludes S3 attributes', () async {
    final h = await _connected();
    h.wire.credential = _credential(provider: 'DROPBOX');
    h.wire.task['credentials'] = h.wire.credential;
    h.wire.task['attributes'] = {'folder': 'data', 'chunk_size': 48};
    final r = await _review(
      h,
      settings: CloudSyncSettings(
        path: '/mnt/tank/data',
        credentialId: 1,
        folder: 'data',
        description: 'Dropbox',
        dropboxChunkSize: 64,
      ),
    );
    expect(
      (await h.repo.executeCloudSync(r, r.target)).outcome,
      CloudSyncOutcome.succeeded,
    );
    expect((h.wire.writes.single['params'] as List)[1], {
      'description': 'Dropbox',
      'attributes': {'folder': 'data', 'chunk_size': 64},
    });
  });
  for (final fault in ['timeout', 'remote', 'receipt', 'disconnect']) {
    test('$fault write outcome retains fence without retry', () async {
      final h = await _connected();
      final r = await _review(h);
      h.wire.fault = fault;
      expect(
        (await h.repo.executeCloudSync(r, r.target)).outcome,
        CloudSyncOutcome.unknown,
      );
      expect(h.wire.writes.length, 1);
      if (fault != 'disconnect') {
        final i = await h.repo.loadCloudSync();
        await expectLater(
          h.repo.reviewCloudSync(
            CloudSyncRequest(
              inventory: i,
              action: CloudSyncAction.run,
              task: i.tasks.single,
            ),
          ),
          throwsA(_reason(CloudSyncExceptionReason.busy)),
        );
      }
      expect(h.wire.writes.length, 1);
    });
  }
  for (final errno in [1, 13]) {
    test(
      'exact permission errno $errno is rejected without unknown fence',
      () async {
        final h = await _connected();
        final r = await _review(h);
        h.wire.errno = errno;
        h.wire.fault = 'remote';
        expect(
          (await h.repo.executeCloudSync(r, r.target)).outcome,
          CloudSyncOutcome.rejected,
        );
        expect(h.wire.writes.length, 1);
      },
    );
  }
  test('owned progress terminal polling releases job without replay', () async {
    final h = await _connected();
    final r = await _review(h, action: CloudSyncAction.run),
        result = await h.repo.executeCloudSync(r, r.target),
        job = result.job!;
    expect((await h.repo.pollCloudSync(job)).percent, 25);
    h.wire.jobState = 'SUCCESS';
    expect(
      (await h.repo.pollCloudSync(job)).outcome,
      CloudSyncOutcome.succeeded,
    );
    await expectLater(
      h.repo.pollCloudSync(job),
      throwsA(_reason(CloudSyncExceptionReason.staleReview)),
    );
    expect(h.wire.writes.length, 1);
  });
  for (final state in ['FAILED', 'ABORTED']) {
    test('$state warns partial effects', () async {
      final h = await _connected();
      final r = await _review(h, action: CloudSyncAction.run),
          result = await h.repo.executeCloudSync(r, r.target);
      h.wire.jobState = state;
      final completed = await h.repo.pollCloudSync(result.job!);
      expect(completed.outcome, CloudSyncOutcome.failed);
      expect(completed.message, contains('Partial'));
    });
  }
  for (final fault in [
    'id',
    'method',
    'arguments',
    'arguments_number',
    'result',
    'state',
    'progress',
    'progress_missing',
    'result_missing',
    'missing',
  ]) {
    test('owned job $fault mismatch stays unknown and can recover', () async {
      final h = await _connected();
      final r = await _review(h, action: CloudSyncAction.run),
          result = await h.repo.executeCloudSync(r, r.target);
      h.wire.jobFault = fault;
      expect(
        (await h.repo.pollCloudSync(result.job!)).outcome,
        CloudSyncOutcome.unknown,
      );
      h.wire.jobFault = null;
      h.wire.jobState = 'SUCCESS';
      expect(
        (await h.repo.pollCloudSync(result.job!)).outcome,
        CloudSyncOutcome.succeeded,
      );
      expect(h.wire.writes.length, 1);
    });
  }
  test('forged owned job cannot dispatch poll', () async {
    final h = await _connected();
    await expectLater(
      h.repo.pollCloudSync(
        const CloudSyncJob(id: 77, taskId: 1, endpoint: _endpoint),
      ),
      throwsA(_reason(CloudSyncExceptionReason.staleReview)),
    );
    expect(h.wire.calls.length, 4);
  });
  test('connection generation change prevents execution', () async {
    final h = await _connected();
    final r = await _review(h);
    h.current = false;
    await expectLater(
      h.repo.executeCloudSync(r, r.target),
      throwsA(_reason(CloudSyncExceptionReason.notAuthenticated)),
    );
    expect(h.wire.writes, isEmpty);
  });
  test('remote read errors are sanitized', () async {
    final h = await _connected();
    h.wire.readFault = true;
    await expectLater(
      h.repo.loadCloudSync(),
      throwsA(
        isA<CloudSyncException>().having(
          (e) => e.toString(),
          'safe',
          isNot(contains(_secret)),
        ),
      ),
    );
    expect(h.wire.writes, isEmpty);
  });
}

class _Harness {
  _Harness(String version, Set<String> methods, String? malformed)
    : wire = _Wire(version, methods, malformed) {
    repo = TrueNasSessionRepository(
      connector: _Connector(wire),
      managementRequestTimeout: const Duration(milliseconds: 35),
    );
  }
  final _Wire wire;
  late final TrueNasSessionRepository repo;
  bool current = true;
}

class _Connector implements RpcConnector {
  const _Connector(this.wire);
  final _Wire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

class _Wire implements RpcTransport {
  _Wire(this.version, this.methods, this.malformed);
  final String version;
  final Set<String> methods;
  final String? malformed;
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  Map<String, Object?> credential = _credential(), task = _task();
  final datasets = [_dataset('tank'), _dataset('tank/data')];
  String timezone = 'UTC', jobState = 'RUNNING';
  String? fault, jobFault;
  Object? errno;
  bool readFault = false, conflict = false;
  int inode = 1;
  String fsid = '1';
  List<Map<String, dynamic>> get writes => calls
      .where(
        (r) => {
          'cloudsync.create',
          'cloudsync.update',
          'cloudsync.delete',
          'cloudsync.sync',
        }.contains(r['method']),
      )
      .toList();
  @override
  Stream<String> get inboundFrames => inbound.stream;
  void drift(String what) {
    switch (what) {
      case 'task':
        task['description'] = 'External';
      case 'credential':
        credential['name'] = 'Different';
        task['credentials'] = credential;
      case 'guid':
        datasets.last['guid'] = {'value': '999'};
      case 'timezone':
        timezone = 'Asia/Seoul';
      case 'stat':
        inode = 9;
      case 'mount':
        fsid = '9';
      case 'job':
        conflict = true;
    }
  }

  void unsafe(String what) {
    switch (what) {
      case 'provider':
        credential = _credential(provider: 'B2');
        task['credentials'] = credential;
      case 'fast_list':
        (task['attributes'] as Map)['fast_list'] = true;
      case 'root_folder':
        (task['attributes'] as Map)['folder'] = '';
      case 'active':
        task['job'] = {'id': 9, 'state': 'RUNNING'};
      case 'pre_script' || 'post_script' || 'args':
        task[what] = _secret;
      case 'include' || 'bwlimit':
        task[what] = ['advanced'];
      case 'transfers':
        task[what] = 4;
      default:
        task[what] = true;
    }
  }

  @override
  Future<void> send(String frame) async {
    final r = jsonDecode(frame) as Map<String, dynamic>;
    calls.add(r);
    final method = r['method'] as String,
        params = r['params'] as List? ?? const [];
    Object? result;
    if (readFault && method == 'cloudsync.query') {
      _error(r);
      return;
    }
    switch (method) {
      case 'auth.login_ex':
        result = {'response_type': 'SUCCESS'};
      case 'auth.me':
        result = {'username': 'admin'};
      case 'system.info':
        result = {
          'version': version,
          'hostname': 'nas',
          'system_product': 'Test',
        };
      case 'core.get_methods':
        result = {
          for (final m in methods)
            m: {
              'job': m == 'cloudsync.sync',
              'uploadable': false,
              'downloadable': false,
              'no_auth_required': false,
              if (m == 'cloudsync.update' && malformed != null)
                malformed!: true,
            },
        };
      case 'cloudsync.credentials.query':
        result = [credential];
      case 'cloudsync.query':
        result = [task];
      case 'pool.dataset.query':
        result = datasets;
      case 'system.general.config':
        result = {'timezone': timezone};
      case 'filesystem.stat':
        result = {
          'type': 'DIRECTORY',
          'realpath': params.single,
          'is_ctldir': false,
          'is_mountpoint': true,
          'dev': 1,
          'inode': inode,
          'mount_id': 1,
          'mode': 16877,
          'uid': 0,
          'gid': 0,
        };
      case 'filesystem.statfs':
        result = {
          'fstype': 'zfs',
          'source': 'tank/data',
          'dest': '/mnt/tank/data',
          'fsid': fsid,
          'flags': <String>[],
        };
      case 'core.get_jobs':
        final filters = params.first as List;
        if ((filters.single as List).first == 'id') {
          final row = <String, Object?>{
            'id': 77,
            'method': 'cloudsync.sync',
            'arguments': [
              1,
              {'dry_run': false},
            ],
            'state': jobState,
            'progress': {'percent': 25},
            'result': null,
          };
          switch (jobFault) {
            case 'id':
              row['id'] = 78;
            case 'method':
              row['method'] = 'cloudsync.sync_onetime';
            case 'arguments':
              row['arguments'] = [
                1,
                {'dry_run': true},
              ];
            case 'arguments_number':
              row['arguments'] = [
                1.0,
                {'dry_run': false},
              ];
            case 'result':
              row['state'] = 'SUCCESS';
              row['result'] = true;
            case 'state':
              row['state'] = 'OTHER';
            case 'progress':
              row['progress'] = {'percent': 101};
            case 'progress_missing':
              row.remove('progress');
            case 'result_missing':
              row['state'] = 'SUCCESS';
              row.remove('result');
          }
          result = jobFault == 'missing' ? [] : [row];
        } else {
          result = conflict
              ? [
                  {'id': 9, 'method': 'cloudsync.sync', 'state': 'RUNNING'},
                ]
              : [];
        }
      case 'cloudsync.create':
        task = {
          ..._task(),
          ...(params.single as Map).cast<String, Object?>(),
          'id': 2,
          'credentials': credential,
        };
        result = task;
      case 'cloudsync.update':
        task.addAll((params[1] as Map).cast<String, Object?>());
        if (task['credentials'] is int) task['credentials'] = credential;
        result = task;
      case 'cloudsync.delete':
        result = true;
      case 'cloudsync.sync':
        result = 77;
      default:
        throw StateError('Unexpected $method');
    }
    if ({
      'cloudsync.create',
      'cloudsync.update',
      'cloudsync.delete',
      'cloudsync.sync',
    }.contains(method)) {
      if (fault == 'timeout') return;
      if (fault == 'disconnect') {
        await close();
        return;
      }
      if (fault == 'remote') {
        _error(r);
        return;
      }
      if (fault == 'receipt') result = {'id': 1};
    }
    inbound.add(
      jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': result}),
    );
  }

  void _error(Map r) => inbound.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': r['id'],
      'error': {
        'code': -32001,
        'message': _secret,
        'data': {'errno': errno, 'private': _secret},
      },
    }),
  );
  @override
  Future<void> close() async {
    if (!inbound.isClosed) await inbound.close();
  }
}
