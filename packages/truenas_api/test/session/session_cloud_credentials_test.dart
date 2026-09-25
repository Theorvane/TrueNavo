import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _secret = 'synthetic-secret-never-display';
const _methods = {
  'cloudsync.credentials.query',
  'cloudsync.query',
  'cloud_backup.query',
  'core.get_jobs',
  'cloudsync.credentials.create',
  'cloudsync.credentials.update',
  'cloudsync.credentials.delete',
};
CloudCredentialWriteOnlyInput _s3({
  String key = _secret,
  String secret = _secret,
  String endpoint = '',
  String region = '',
  int parts = 10000,
}) => CloudCredentialWriteOnlyInput.s3(
  accessKeyId: key,
  secretAccessKey: secret,
  endpoint: endpoint,
  region: region,
  skipRegion: false,
  signaturesV2: false,
  maxUploadParts: parts,
);
CloudCredentialWriteOnlyInput _dropbox({
  String token = '{"access_token":"synthetic","token_type":"bearer"}',
  String clientId = '',
  String clientSecret = '',
}) => CloudCredentialWriteOnlyInput.dropbox(
  token: token,
  clientId: clientId,
  clientSecret: clientSecret,
);
Matcher _reason(CloudCredentialsExceptionReason reason) =>
    isA<CloudCredentialsException>().having((e) => e.reason, 'reason', reason);
Future<_Harness> _connected({
  String version = '25.10.1',
  Set<String> methods = _methods,
  String? badFlag,
}) async {
  final h = _Harness(version, methods, badFlag);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'synthetic',
    username: 'admin',
    isConnectionCurrent: () => h.current,
  );
  return h;
}

Future<CloudCredentialReview> _review(
  _Harness h, {
  CloudCredentialAction action = CloudCredentialAction.rename,
  String? provider,
}) async {
  final inventory = await h.repo.loadCloudCredentials();
  return h.repo.reviewCloudCredential(
    CloudCredentialRequest(
      inventory: inventory,
      action: action,
      credential: action == CloudCredentialAction.create
          ? null
          : inventory.credentials.single,
      name: action == CloudCredentialAction.create
          ? 'New'
          : action == CloudCredentialAction.rename
          ? 'Renamed'
          : null,
      provider: action == CloudCredentialAction.create
          ? provider ?? 'S3'
          : null,
    ),
  );
}

void main() {
  for (final pending in [false, true]) {
    test(
      'credential ${pending ? 'in-flight' : 'unknown'} fences every auxiliary family and legacy writes',
      () async {
        final h = await _connected(
          methods: {
            ..._methods,
            'auth.me',
            'auth.sessions',
            'user.query',
            'api_key.query',
            'system.security.config',
            'api_key.create',
            'replication.query',
            'pool.dataset.query',
            'pool.filesystem_choices',
            'pool.snapshot.query',
            'replication.delete',
            'filesystem.stat',
            'filesystem.statfs',
            'system.general.config',
            'cloudsync.delete',
            'system.version_short',
            'boot.get_state',
            'boot.environment.query',
            'failover.licensed',
            'update.status',
            'update.available_versions',
            'pool.dataset.create',
          },
        );
        final r = await _review(h);
        if (pending) {
          h.wire.holdWrite = Completer<void>();
        } else {
          h.wire.writeFault = 'remote';
        }
        final mutation = h.repo.executeCloudCredential(r, r.target);
        await Future<void>.delayed(const Duration(milliseconds: 1));
        if (!pending) {
          expect((await mutation).outcome, CloudCredentialOutcome.unknown);
        }
        expect(h.wire.writes.length, 1);
        final boundary = h.wire.calls.length;
        await expectLater(
          h.repo.reviewApiKey(
            ApiKeyRequest(
              inventory: ApiKeyInventory(
                endpoint: 'wss://nas.example/api/current',
                username: 'admin',
                userId: 1000,
                sessionId: 'sample',
                credentialType: 'LOGIN_PASSWORD',
                currentKeyId: null,
                accountEligible: true,
                stig: false,
                keys: const [],
              ),
              action: ApiKeyAction.create,
              name: 'New',
            ),
          ),
          throwsA(
            isA<ApiKeysException>().having(
              (e) => e.reason,
              'reason',
              ApiKeysExceptionReason.busy,
            ),
          ),
        );
        await expectLater(
          h.repo.reviewReplication(
            ReplicationRequest(
              inventory: ReplicationInventory(
                endpoint: 'wss://nas.example/api/current',
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
          h.repo.reviewCloudSync(
            CloudSyncRequest(
              inventory: CloudSyncInventory(
                endpoint: 'wss://nas.example/api/current',
                timezone: 'UTC',
                tasks: const [],
                credentials: const [],
                datasets: const [],
              ),
              action: CloudSyncAction.delete,
            ),
          ),
          throwsA(
            isA<CloudSyncException>().having(
              (e) => e.reason,
              'reason',
              CloudSyncExceptionReason.busy,
            ),
          ),
        );
        await expectLater(
          h.repo.reviewSystemUpdate(
            SystemUpdateRequest(
              inventory: SystemUpdateInventory(
                endpoint: 'wss://nas.example/api/current',
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
        if (pending) {
          h.wire.holdWrite!.complete();
          expect((await mutation).outcome, CloudCredentialOutcome.succeeded);
        }
      },
    );
  }
  test('disconnected fails without dispatch', () async {
    final h = _Harness('25.10.1', _methods, null);
    addTearDown(h.repo.close);
    expect(h.repo.cloudCredentialsCapabilities.connected, false);
    await expectLater(
      h.repo.loadCloudCredentials(),
      throwsA(_reason(CloudCredentialsExceptionReason.notAuthenticated)),
    );
    expect(h.wire.calls, isEmpty);
  });
  test(
    'direct disconnected execute discards write-only input before throwing',
    () async {
      final h = _Harness('25.10.1', _methods, null);
      addTearDown(h.repo.close);
      final inventory = CloudCredentialInventory(
        endpoint: 'wss://nas.example/api/current',
        credentials: const [],
        references: const [],
      );
      final review = CloudCredentialReview(
        request: CloudCredentialRequest(
          inventory: inventory,
          action: CloudCredentialAction.create,
          name: 'New',
          provider: 'S3',
        ),
        endpoint: inventory.endpoint,
        warnings: const [],
      );
      final input = _s3();
      await expectLater(
        h.repo.executeCloudCredential(review, review.target, input: input),
        throwsA(_reason(CloudCredentialsExceptionReason.notAuthenticated)),
      );
      expect(input.disposed, true);
      expect(h.wire.calls, isEmpty);
    },
  );
  for (final version in ['25.04.2', '26.0', '25.10-BETA', '25.10.1\n']) {
    test('version $version denied', () async {
      final h = await _connected(version: version);
      final boundary = h.wire.calls.length;
      await expectLater(
        h.repo.loadCloudCredentials(),
        throwsA(_reason(CloudCredentialsExceptionReason.unsupportedVersion)),
      );
      expect(h.wire.calls.length, boundary);
    });
  }
  for (final method in _methods) {
    test('missing $method capability fails closed', () async {
      final h = await _connected(methods: {..._methods}..remove(method));
      final c = h.repo.cloudCredentialsCapabilities;
      if (method.endsWith('.create')) {
        expect(c.canCreate, false);
      } else if (method.endsWith('.update')) {
        expect(c.canUpdate, false);
      } else if (method.endsWith('.delete')) {
        expect(c.canDelete, false);
      } else {
        expect(c.supported, false);
      }
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final flag in [
    'job',
    'uploadable',
    'downloadable',
    'private',
    '_private',
    'no_auth_required',
  ]) {
    test('unsafe metadata $flag disallows update', () async {
      final h = await _connected(badFlag: flag);
      expect(h.repo.cloudCredentialsCapabilities.canUpdate, false);
    });
  }
  test(
    'strict projection inventory omits all stored provider secrets and effects',
    () async {
      final h = await _connected();
      h.wire.entry['provider'] = {
        'type': 'S3',
        'access_key_id': _secret,
        'secret_access_key': _secret,
        'region': _secret,
      };
      final inventory = await h.repo.loadCloudCredentials();
      expect(inventory.credentials.single.name, 'Archive');
      expect(inventory.credentials.single.provider, 'S3');
      final reads = h.wire.calls.skip(4).toList();
      expect(reads.map((r) => r['method']), [
        'cloudsync.credentials.query',
        'cloudsync.query',
        'cloud_backup.query',
        'core.get_jobs',
      ]);
      expect(((reads.first['params'] as List)[1] as Map)['select'], [
        'id',
        'name',
        'provider.type',
      ]);
      for (final read in reads.skip(1).take(2)) {
        expect(((read['params'] as List)[1] as Map)['select'], [
          'id',
          'credentials.id',
          'enabled',
        ]);
      }
      expect(jsonEncode(reads), isNot(contains(_secret)));
      expect(inventory.toString(), isNot(contains(_secret)));
      expect(h.wire.writes, isEmpty);
    },
  );
  test(
    'rename sends only name preserving complete server provider object',
    () async {
      final h = await _connected();
      h.wire.entry['provider'] = {
        'type': 'S3',
        'secret_access_key': _secret,
        'custom': 'retained',
      };
      final r = await _review(h);
      final result = await h.repo.executeCloudCredential(r, r.target);
      expect(result.outcome, CloudCredentialOutcome.succeeded);
      expect(h.wire.writes.single['params'], [
        1,
        {'name': 'Renamed'},
      ]);
      expect((h.wire.entry['provider'] as Map)['custom'], 'retained');
      expect(result.message, isNot(contains(_secret)));
    },
  );
  for (final provider in ['S3', 'DROPBOX']) {
    for (final action in [
      CloudCredentialAction.create,
      CloudCredentialAction.replace,
    ]) {
      test(
        '$provider ${action.name} sends complete new provider and disposes input',
        () async {
          final h = await _connected();
          h.wire.entry['provider'] = {
            'type': provider,
            'legacy-secret': _secret,
          };
          final r = await _review(h, action: action, provider: provider);
          final input = provider == 'S3' ? _s3() : _dropbox();
          final result = await h.repo.executeCloudCredential(
            r,
            r.target,
            input: input,
          );
          expect(result.outcome, CloudCredentialOutcome.succeeded);
          expect(input.disposed, true);
          expect(result.message, isNot(contains(_secret)));
          expect(r.toString(), isNot(contains(_secret)));
          expect(r.warnings.join(), isNot(contains(_secret)));
          final payload = (h.wire.writes.single['params'] as List).last as Map,
              fields = payload['provider'] as Map;
          expect(
            fields.keys.toSet(),
            provider == 'S3'
                ? {
                    'type',
                    'access_key_id',
                    'secret_access_key',
                    'endpoint',
                    'region',
                    'skip_region',
                    'signatures_v2',
                    'max_upload_parts',
                  }
                : {'type', 'token', 'client_id', 'client_secret'},
          );
          expect(fields.containsKey('legacy-secret'), false);
          expect(
            payload.containsKey('name'),
            action == CloudCredentialAction.create,
          );
        },
      );
    }
  }
  test('delete unused exact id only', () async {
    final h = await _connected();
    final r = await _review(h, action: CloudCredentialAction.delete);
    expect(
      (await h.repo.executeCloudCredential(r, r.target)).outcome,
      CloudCredentialOutcome.succeeded,
    );
    expect(h.wire.writes.single['params'], [1]);
  });
  for (final kind in ['cloudsync', 'cloud_backup']) {
    test('$kind references block deletion', () async {
      final h = await _connected();
      h.wire.references[kind] = [
        {
          'id': 4,
          'credentials': {'id': 1},
          'enabled': false,
        },
      ];
      await expectLater(
        _review(h, action: CloudCredentialAction.delete),
        throwsA(_reason(CloudCredentialsExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    });
    test('$kind enabled schedules block replacement', () async {
      final h = await _connected();
      h.wire.references[kind] = [
        {
          'id': 4,
          'credentials': {'id': 1},
          'enabled': true,
        },
      ];
      await expectLater(
        _review(h, action: CloudCredentialAction.replace),
        throwsA(_reason(CloudCredentialsExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    });
    test('$kind disabled references reviewed before replacement', () async {
      final h = await _connected();
      h.wire.references[kind] = [
        {
          'id': 4,
          'credentials': {'id': 1},
          'enabled': false,
        },
      ];
      final r = await _review(h, action: CloudCredentialAction.replace);
      expect(r.warnings.join(), contains('1 referencing'));
      expect(
        (await h.repo.executeCloudCredential(
          r,
          r.target,
          input: _s3(),
        )).outcome,
        CloudCredentialOutcome.succeeded,
      );
    });
    test('$kind reference drift after review rejects dispatch', () async {
      final h = await _connected();
      final r = await _review(h, action: CloudCredentialAction.delete);
      h.wire.references[kind] = [
        {
          'id': 4,
          'credentials': {'id': 1},
          'enabled': false,
        },
      ];
      expect(
        (await h.repo.executeCloudCredential(r, r.target)).outcome,
        CloudCredentialOutcome.rejected,
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final field in ['id', 'name', 'provider', 'job']) {
    test('$field drift invalidates issued review', () async {
      final h = await _connected();
      final r = await _review(h);
      switch (field) {
        case 'id':
          h.wire.entry['id'] = 2;
        case 'name':
          h.wire.entry['name'] = 'Other';
        case 'provider':
          h.wire.entry['provider'] = {'type': 'DROPBOX'};
        case 'job':
          h.wire.jobs = [
            {'id': 2, 'method': 'cloudsync.sync', 'state': 'RUNNING'},
          ];
      }
      expect(
        (await h.repo.executeCloudCredential(r, r.target)).outcome,
        CloudCredentialOutcome.rejected,
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final method in [
    'cloudsync.sync',
    'cloud_backup.sync',
    'replication.run',
    'pool.create',
    'filesystem.setacl',
    'update.run',
    'system.reboot',
  ]) {
    test('active $method blocks changes', () async {
      final h = await _connected();
      h.wire.jobs = [
        {'id': 2, 'method': method, 'state': 'RUNNING'},
      ];
      await expectLater(
        _review(h),
        throwsA(_reason(CloudCredentialsExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('unsupported provider visible but immutable', () async {
    final h = await _connected();
    h.wire.entry['provider'] = {'type': 'ONEDRIVE'};
    final inv = await h.repo.loadCloudCredentials();
    expect(inv.credentials.single.supported, false);
    await expectLater(
      h.repo.reviewCloudCredential(
        CloudCredentialRequest(
          inventory: inv,
          action: CloudCredentialAction.delete,
          credential: inv.credentials.single,
        ),
      ),
      throwsA(_reason(CloudCredentialsExceptionReason.invalidRequest)),
    );
    expect(h.wire.writes, isEmpty);
  });
  for (final fault in [
    'credential-double-id',
    'credential-name',
    'credential-provider',
    'credential-overflow',
    'ref-double-id',
    'ref-missing',
    'ref-unknown',
    'ref-enabled',
    'ref-overflow',
    'job-double-id',
    'job-state',
    'job-overflow',
  ]) {
    test('malformed $fault fails secret-free inventory', () async {
      final h = await _connected();
      h.wire.readFault = fault;
      await expectLater(
        h.repo.loadCloudCredentials(),
        throwsA(_reason(CloudCredentialsExceptionReason.invalidResponse)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('read error withheld without retry', () async {
    final h = await _connected();
    h.wire.readFault = 'remote';
    await expectLater(
      h.repo.loadCloudCredentials(),
      throwsA(_reason(CloudCredentialsExceptionReason.unavailable)),
    );
    expect(
      h.wire.calls
          .where((r) => r['method'] == 'cloudsync.credentials.query')
          .length,
      1,
    );
    expect(h.wire.writes, isEmpty);
  });
  test('forged inventory and forged reviews never dispatch', () async {
    final h = await _connected();
    final inv = CloudCredentialInventory(
      endpoint: 'wss://nas.example/api/current',
      credentials: const [],
      references: const [],
    );
    final request = CloudCredentialRequest(
      inventory: inv,
      action: CloudCredentialAction.create,
      name: 'New',
      provider: 'S3',
    );
    await expectLater(
      h.repo.reviewCloudCredential(request),
      throwsA(_reason(CloudCredentialsExceptionReason.staleReview)),
    );
    final forged = CloudCredentialReview(
      request: request,
      endpoint: inv.endpoint,
      warnings: const [],
    );
    final input = _s3();
    expect(
      (await h.repo.executeCloudCredential(
        forged,
        forged.target,
        input: input,
      )).outcome,
      CloudCredentialOutcome.rejected,
    );
    expect(input.disposed, true);
    expect(h.wire.writes, isEmpty);
  });
  test('new inventory permanently expires old review', () async {
    final h = await _connected();
    final r = await _review(h);
    await h.repo.loadCloudCredentials();
    expect(
      (await h.repo.executeCloudCredential(r, r.target)).outcome,
      CloudCredentialOutcome.rejected,
    );
    expect(h.wire.writes, isEmpty);
  });
  test('wrong confirmation consumes one-shot review', () async {
    final h = await _connected();
    final r = await _review(h);
    expect(
      (await h.repo.executeCloudCredential(r, '${r.target} ')).outcome,
      CloudCredentialOutcome.rejected,
    );
    expect(
      (await h.repo.executeCloudCredential(r, r.target)).outcome,
      CloudCredentialOutcome.rejected,
    );
    expect(h.wire.writes, isEmpty);
  });
  test('success never replayed', () async {
    final h = await _connected();
    final r = await _review(h);
    await h.repo.executeCloudCredential(r, r.target);
    expect(
      (await h.repo.executeCloudCredential(r, r.target)).outcome,
      CloudCredentialOutcome.rejected,
    );
    expect(h.wire.writes.length, 1);
  });
  for (final fault in [
    'timeout',
    'remote',
    'wrong-id',
    'wrong-provider',
    'wrong-name',
    'malformed',
    'number-id',
  ]) {
    test('$fault after dispatch remains unknown and fences mutation', () async {
      final h = await _connected();
      final r = await _review(h);
      h.wire.writeFault = fault;
      final result = await h.repo.executeCloudCredential(r, r.target);
      expect(result.outcome, CloudCredentialOutcome.unknown);
      expect(result.message, isNot(contains(_secret)));
      h.wire.writeFault = null;
      final inv = await h.repo.loadCloudCredentials();
      await expectLater(
        h.repo.reviewCloudCredential(
          CloudCredentialRequest(
            inventory: inv,
            action: CloudCredentialAction.rename,
            credential: inv.credentials.single,
            name: 'Next',
          ),
        ),
        throwsA(_reason(CloudCredentialsExceptionReason.busy)),
      );
      expect(h.wire.writes.length, 1);
    });
  }
  for (final errno in [1, 13]) {
    test('post-dispatch permission errno $errno remains unknown', () async {
      final h = await _connected();
      final r = await _review(h);
      h.wire.writeFault = 'remote';
      h.wire.errno = errno;
      expect(
        (await h.repo.executeCloudCredential(r, r.target)).outcome,
        CloudCredentialOutcome.unknown,
      );
      h.wire.writeFault = null;
      await expectLater(
        _review(h),
        throwsA(_reason(CloudCredentialsExceptionReason.busy)),
      );
    });
  }
  for (final errno in ['13', 13.0, 22, null]) {
    test('non-exact permission errno $errno is unknown', () async {
      final h = await _connected();
      final r = await _review(h);
      h.wire.writeFault = 'remote';
      h.wire.errno = errno;
      expect(
        (await h.repo.executeCloudCredential(r, r.target)).outcome,
        CloudCredentialOutcome.unknown,
      );
    });
  }
  test(
    'session expiry after review cannot dispatch and discards input',
    () async {
      final h = await _connected();
      final r = await _review(h, action: CloudCredentialAction.replace);
      h.current = false;
      final input = _s3();
      expect(
        (await h.repo.executeCloudCredential(
          r,
          r.target,
          input: input,
        )).outcome,
        CloudCredentialOutcome.rejected,
      );
      expect(input.disposed, true);
      expect(h.wire.writes, isEmpty);
    },
  );
  test(
    'missing/wrong provider input fails before preflight and is disposed',
    () async {
      final h = await _connected();
      final r = await _review(h, action: CloudCredentialAction.replace),
          input = _dropbox();
      final boundary = h.wire.calls.length;
      expect(
        (await h.repo.executeCloudCredential(
          r,
          r.target,
          input: input,
        )).outcome,
        CloudCredentialOutcome.rejected,
      );
      expect(h.wire.calls.length, boundary);
      expect(input.disposed, true);
    },
  );
  test('secret input on rename forbidden and discarded', () async {
    final h = await _connected();
    final r = await _review(h), input = _s3();
    expect(
      (await h.repo.executeCloudCredential(r, r.target, input: input)).outcome,
      CloudCredentialOutcome.rejected,
    );
    expect(input.disposed, true);
    expect(h.wire.writes, isEmpty);
  });
  for (final input in [
    _s3(key: ''),
    _s3(secret: ' '),
    _s3(key: 'a\nb'),
    _s3(secret: 'a\rb'),
    _s3(key: 'a\u0000b'),
    _s3(endpoint: 'http://s3.example'),
    _s3(endpoint: 'https://user:pass@s3.example'),
    _s3(endpoint: 'https://s3.example/path'),
    _s3(endpoint: 'https://s3.example?q=x'),
    _s3(endpoint: 'https://s3.example#x'),
    _s3(region: 'bad region'),
    _s3(parts: 0),
    _s3(parts: 10001),
    _dropbox(token: 'not-json'),
    _dropbox(token: '{}'),
    _dropbox(token: '{"access_token":"a","token_type":"bad"}'),
    _dropbox(token: '{\n"access_token":"a","token_type":"bearer"}'),
    _dropbox(clientId: 'id'),
    _dropbox(clientSecret: 'secret'),
    _dropbox(clientId: 'a\nb', clientSecret: 'secret'),
  ]) {
    test(
      'invalid write-only input ${input.hashCode} rejected and redacted',
      () {
        expect(input.validationError, isNotNull);
        expect(input.toString(), isNot(contains(_secret)));
        input.dispose();
        expect(input.disposed, true);
        expect(input.validationError, isNotNull);
      },
    );
  }
  test(
    'bounded HTTPS custom endpoint and complete Dropbox inputs accepted',
    () {
      final s3 = _s3(
            endpoint: 'https://s3.example:9443/',
            region: 'ap-northeast-2',
            parts: 1000,
          ),
          dropbox = _dropbox(clientId: 'id', clientSecret: 'secret');
      expect(s3.validationError, isNull);
      expect(dropbox.validationError, isNull);
      s3.dispose();
      dropbox.dispose();
    },
  );
  test('busy second request cannot clear first mutation lock', () async {
    final h = await _connected();
    final r = await _review(h);
    h.wire.holdWrite = Completer<void>();
    final first = h.repo.executeCloudCredential(r, r.target);
    await Future<void>.delayed(const Duration(milliseconds: 1));
    expect(h.wire.writes.length, 1);
    expect(
      (await h.repo.executeCloudCredential(r, r.target)).outcome,
      CloudCredentialOutcome.rejected,
    );
    await expectLater(
      h.repo.loadCloudCredentials(),
      throwsA(_reason(CloudCredentialsExceptionReason.busy)),
    );
    h.wire.holdWrite!.complete();
    expect((await first).outcome, CloudCredentialOutcome.succeeded);
  });
}

class _Harness {
  _Harness(String version, Set<String> methods, String? flag)
    : wire = _Wire(version, methods, flag) {
    repo = TrueNasSessionRepository(
      connector: _Connector(wire),
      managementRequestTimeout: const Duration(milliseconds: 100),
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
  _Wire(this.version, this.methods, this.badFlag);
  final String version;
  final Set<String> methods;
  final String? badFlag;
  final inbound = StreamController<String>();
  final calls = <Map<String, dynamic>>[];
  final entry = <String, Object?>{
    'id': 1,
    'name': 'Archive',
    'provider': {'type': 'S3'},
  };
  final references = <String, List<Object?>>{
    'cloudsync': [],
    'cloud_backup': [],
  };
  List<Object?> jobs = [];
  String? readFault, writeFault;
  Object? errno;
  Completer<void>? holdWrite;
  List<Map<String, dynamic>> get writes => calls
      .where(
        (r) => {
          'cloudsync.credentials.create',
          'cloudsync.credentials.update',
          'cloudsync.credentials.delete',
        }.contains(r['method']),
      )
      .toList();
  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String frame) async {
    final r = jsonDecode(frame) as Map<String, dynamic>;
    calls.add(r);
    final method = r['method'] as String, params = r['params'] as List? ?? [];
    Object? result;
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
              'job': false,
              'uploadable': false,
              'downloadable': false,
              'no_auth_required': false,
              if (m == 'cloudsync.credentials.update' && badFlag != null)
                badFlag!: true,
            },
        };
      case 'cloudsync.credentials.query':
        if (readFault == 'remote') {
          _error(r);
          return;
        }
        result = [entry];
        switch (readFault) {
          case 'credential-double-id':
            result = [entry, entry];
          case 'credential-name':
            result = [
              {...entry, 'name': ''},
            ];
          case 'credential-provider':
            result = [
              {
                ...entry,
                'provider': {'type': null},
              },
            ];
          case 'credential-overflow':
            result = List.filled(129, entry);
        }
      case 'cloudsync.query' || 'cloud_backup.query':
        result = references[method.split('.').first];
        if (method == 'cloudsync.query') {
          switch (readFault) {
            case 'ref-double-id':
              result = [
                {
                  'id': 2,
                  'credentials': {'id': 1},
                  'enabled': false,
                },
                {
                  'id': 2,
                  'credentials': {'id': 1},
                  'enabled': false,
                },
              ];
            case 'ref-missing':
              result = [
                {'id': 2, 'enabled': false},
              ];
            case 'ref-unknown':
              result = [
                {
                  'id': 2,
                  'credentials': {'id': 99},
                  'enabled': false,
                },
              ];
            case 'ref-enabled':
              result = [
                {
                  'id': 2,
                  'credentials': {'id': 1},
                  'enabled': null,
                },
              ];
            case 'ref-overflow':
              result = List.filled(257, {});
          }
        }
      case 'core.get_jobs':
        result = jobs;
        switch (readFault) {
          case 'job-double-id':
            result = [
              {'id': 2, 'method': 'core.test', 'state': 'RUNNING'},
              {'id': 2, 'method': 'core.test', 'state': 'RUNNING'},
            ];
          case 'job-state':
            result = [
              {'id': 2, 'method': 'core.test', 'state': 'OTHER'},
            ];
          case 'job-overflow':
            result = List.filled(129, {});
        }
      case 'cloudsync.credentials.create':
        result = {'id': 2, ...(params.single as Map)};
      case 'cloudsync.credentials.update':
        entry.addAll((params.last as Map).cast<String, Object?>());
        result = {...entry};
      case 'cloudsync.credentials.delete':
        result = true;
      default:
        throw StateError('Unexpected method $method');
    }
    if ({
      'cloudsync.credentials.create',
      'cloudsync.credentials.update',
      'cloudsync.credentials.delete',
    }.contains(method)) {
      if (holdWrite != null) await holdWrite!.future;
      switch (writeFault) {
        case 'timeout':
          return;
        case 'remote':
          _error(r);
          return;
        case 'wrong-id':
          result = {...entry, 'id': 9};
        case 'number-id':
          result = {...entry, 'id': 1.0};
        case 'wrong-provider':
          result = {
            ...entry,
            'provider': {'type': 'DROPBOX'},
          };
        case 'wrong-name':
          result = {...entry, 'name': 'Wrong'};
        case 'malformed':
          result = {'secret': _secret};
      }
    }
    if (!inbound.isClosed) {
      inbound.add(
        jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': result}),
      );
    }
  }

  void _error(Map r) {
    if (!inbound.isClosed) {
      inbound.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': r['id'],
          'error': {
            'code': -32000,
            'message': _secret,
            'data': {'errno': errno, 'trace': _secret},
          },
        }),
      );
    }
  }

  @override
  Future<void> close() async {
    await inbound.close();
  }
}
