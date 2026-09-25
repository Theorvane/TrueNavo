import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _reads = {
  'auth.me',
  'auth.sessions',
  'user.query',
  'api_key.query',
  'system.security.config',
};
const _writes = {'api_key.create', 'api_key.update', 'api_key.delete'};
const _methods = {..._reads, ..._writes, 'pool.dataset.create'};
const _crossMethods = {
  ..._methods,
  'cloudsync.credentials.query',
  'cloudsync.credentials.delete',
  'cloudsync.query',
  'cloud_backup.query',
  'core.get_jobs',
  'cloudsync.delete',
  'pool.dataset.query',
  'filesystem.stat',
  'filesystem.statfs',
  'system.general.config',
  'replication.query',
  'replication.delete',
  'pool.filesystem_choices',
  'pool.snapshot.query',
  'system.version_short',
  'boot.get_state',
  'boot.environment.query',
  'failover.licensed',
  'update.status',
  'update.available_versions',
};
const _secret = 'synthetic-remote-details-never-display';
Matcher _reason(ApiKeysExceptionReason reason) =>
    isA<ApiKeysException>().having((e) => e.reason, 'reason', reason);

void main() {
  for (final method in {..._writes, 'api_key.query'}) {
    test(
      'generic $method cannot bypass native credential safeguards',
      () async {
        final h = await _connected();
        final spec = h.repo.adminCatalog.method(method)!;
        expect(spec.supported, isFalse);
        final count = h.wire.requests.length;
        await expectLater(
          h.repo.invokeAdmin(AdminRequest(method: spec, arguments: const [])),
          throwsA(
            isA<AdminException>().having(
              (e) => e.reason,
              'reason',
              AdminExceptionReason.unavailableMethod,
            ),
          ),
        );
        expect(h.wire.requests.length, count);
      },
    );
  }
  test(
    'disconnected adapter exposes no capability and dispatches nothing',
    () async {
      final wire = _Wire();
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      expect(repo.apiKeysCapabilities.supported, isFalse);
      await expectLater(
        repo.loadApiKeys(),
        throwsA(_reason(ApiKeysExceptionReason.notAuthenticated)),
      );
      expect(wire.requests, isEmpty);
    },
  );
  for (final version in ['25.04.2', '26.0.0', '25.10-BETA', '25.10.1\n']) {
    test('unsupported version $version cannot read keys', () async {
      final h = await _connected(version: version);
      final count = h.wire.requests.length;
      await expectLater(
        h.repo.loadApiKeys(),
        throwsA(_reason(ApiKeysExceptionReason.unsupportedVersion)),
      );
      expect(h.wire.requests.length, count);
    });
  }
  for (final missing in _reads) {
    test('missing $missing disables safe identity reads', () async {
      final h = await _connected(methods: _methods.difference({missing}));
      expect(h.repo.apiKeysCapabilities.available, isFalse);
      final count = h.wire.requests.length;
      await expectLater(
        h.repo.loadApiKeys(),
        throwsA(_reason(ApiKeysExceptionReason.unavailableMethod)),
      );
      expect(h.wire.requests.length, count);
    });
  }
  for (final metadata in [
    {'job': true},
    {'uploadable': true},
    {'downloadable': true},
    {'private': true},
    {'_private': true},
    {'no_auth_required': true},
  ]) {
    test(
      'unsafe writer metadata $metadata blocks all mutation capabilities',
      () async {
        final h = await _connected(
          overrides: {for (final method in _writes) method: metadata},
        );
        expect(h.repo.apiKeysCapabilities.supported, isTrue);
        expect(h.repo.apiKeysCapabilities.canCreate, isFalse);
        expect(h.repo.apiKeysCapabilities.canUpdate, isFalse);
        expect(h.repo.apiKeysCapabilities.canDelete, isFalse);
      },
    );
  }
  test(
    'key inventory projects only safe fields with bounded own-account scope',
    () async {
      final h = await _connected();
      final start = h.wire.requests.length;
      final inventory = await h.repo.loadApiKeys();
      expect(h.wire.requests.skip(start).map((r) => r['method']), _reads);
      expect(inventory.username, 'fixture-user');
      expect(inventory.currentKeyId, 1);
      expect(inventory.keys.length, 2);
      expect(inventory.keys.first.id, 1);
      expect(() => inventory.keys.clear(), throwsUnsupportedError);
      final query = h.wire.requests.last;
      expect(query['params'], [
        [
          ['username', '=', 'fixture-user'],
        ],
        {
          'limit': 129,
          'select': [
            'id',
            'name',
            'username',
            'user_identifier',
            'created_at',
            'expires_at',
            'local',
            'revoked',
          ],
        },
      ]);
      expect(query.toString(), isNot(contains('keyhash')));
      expect(h.wire.writes, isEmpty);
    },
  );
  for (final action in [
    ApiKeyAction.edit,
    ApiKeyAction.rotate,
    ApiKeyAction.delete,
  ]) {
    test('current API key $action protected before preflight', () async {
      final h = await _connected();
      final inventory = await h.repo.loadApiKeys();
      final request = _request(inventory, action, key: inventory.keys.first);
      expect(request.validationError, contains('authenticating'));
      final count = h.wire.requests.length;
      await expectLater(
        h.repo.reviewApiKey(request),
        throwsA(_reason(ApiKeysExceptionReason.invalidRequest)),
      );
      expect(h.wire.requests.length, count);
    });
  }
  for (final type in [
    'TOKEN',
    'UNIX_SOCKET',
    'LOGIN_ONETIME_PASSWORD',
    'TRUENAS_NODE',
    'NEW_TYPE',
  ]) {
    test('unsupported $type credential cannot change keys', () async {
      final h = await _connected();
      h.wire.session['credentials'] = type;
      final inventory = await h.repo.loadApiKeys();
      expect(inventory.blockedReason, isNotNull);
      await expectLater(
        h.repo.reviewApiKey(_request(inventory, ApiKeyAction.create)),
        throwsA(_reason(ApiKeysExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final type in ['LOGIN_PASSWORD', 'LOGIN_TWOFACTOR']) {
    test('$type safely identifies no current API key', () async {
      final h = await _connected();
      h.wire.session['credentials'] = type;
      h.wire.session['credentials_data'] = {'username': 'fixture-user'};
      final inventory = await h.repo.loadApiKeys();
      expect(inventory.currentKeyId, isNull);
      expect(inventory.targetBlockedReason(inventory.keys.first), isNull);
      final review = await h.repo.reviewApiKey(
        _request(inventory, ApiKeyAction.delete, key: inventory.keys.first),
      );
      expect(
        (await h.repo.executeApiKey(review, review.target)).outcome,
        ApiKeyOutcome.succeeded,
      );
    });
  }
  for (final field in ['builtin', 'locked', 'roles', 'stig']) {
    test('$field safety policy disables every key mutation', () async {
      final h = await _connected();
      if (field == 'stig') {
        h.wire.security['enable_gpos_stig'] = true;
      } else {
        h.wire.user[field] = field == 'roles' ? [] : true;
      }
      final inventory = await h.repo.loadApiKeys();
      expect(inventory.blockedReason, isNotNull);
      await expectLater(
        h.repo.reviewApiKey(_request(inventory, ApiKeyAction.create)),
        throwsA(_reason(ApiKeysExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final owner in ['LEGACY_API_KEY', 'S-1-5-21-123', 99]) {
    test('legacy or other-owner key $owner protected', () async {
      final h = await _connected();
      h.wire.keys.last['user_identifier'] = owner;
      final inventory = await h.repo.loadApiKeys();
      expect(inventory.targetBlockedReason(inventory.keys.last), isNotNull);
      await expectLater(
        h.repo.reviewApiKey(_request(inventory, ApiKeyAction.delete)),
        throwsA(_reason(ApiKeysExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final action in ApiKeyAction.values) {
    test(
      '$action exact payload, reviewed identity and single-use receipt',
      () async {
        final h = await _connected();
        final i = await h.repo.loadApiKeys();
        final req = _request(i, action);
        final review = await h.repo.reviewApiKey(req);
        expect(review.warnings.join(' '), isNot(contains(_secret)));
        expect(h.wire.writes, isEmpty);
        final result = await h.repo.executeApiKey(review, review.target);
        expect(result.outcome, ApiKeyOutcome.succeeded);
        expect(h.wire.writes, hasLength(1));
        final args = h.wire.writes.single['params'];
        expect(args, switch (action) {
          ApiKeyAction.create => [
            {
              'name': 'new-client',
              'expires_at': null,
              'username': 'fixture-user',
            },
          ],
          ApiKeyAction.edit => [
            2,
            {'name': 'renamed-client', 'expires_at': null, 'reset': false},
          ],
          ApiKeyAction.rotate => [
            2,
            {'name': 'renamed-client', 'expires_at': null, 'reset': true},
          ],
          ApiKeyAction.delete => [2],
        });
        if (action == ApiKeyAction.create || action == ApiKeyAction.rotate) {
          expect(result.secret, isNotNull);
          expect(result.toString(), isNot(contains('aaaa')));
          expect(result.withoutSecret.secret, isNull);
          expect(result.secret.toString(), 'ApiKeyOneTimeSecret(redacted)');
          expect(
            result.secret!.take(),
            '${action == ApiKeyAction.create ? 3 : 2}-${'a' * 64}',
          );
          expect(result.secret!.take(), isNull);
        } else {
          expect(result.secret, isNull);
        }
        final count = h.wire.requests.length;
        await expectLater(
          h.repo.executeApiKey(review, review.target),
          throwsA(_reason(ApiKeysExceptionReason.staleReview)),
        );
        expect(h.wire.requests.length, count);
      },
    );
  }
  test('explicit future UTC expiry exact payload and warnings', () async {
    final h = await _connected();
    final i = await h.repo.loadApiKeys();
    final date = DateTime.now().toUtc().add(const Duration(days: 30));
    final req = ApiKeyRequest(
      inventory: i,
      action: ApiKeyAction.create,
      name: 'new-client',
      expiresAt: date,
    );
    final r = await h.repo.reviewApiKey(req);
    expect(r.warnings.join(' '), isNot(contains('No expiry was explicitly')));
    expect(
      (await h.repo.executeApiKey(r, r.target)).outcome,
      ApiKeyOutcome.succeeded,
    );
    expect(
      (h.wire.writes.single['params'] as List).single['expires_at'],
      req.serverExpiry!.toIso8601String(),
    );
  });
  for (final name in ['', ' x', 'x ', 'x\n', 'x' * 201, 'current-client']) {
    test('invalid or duplicate name is blocked ${name.length}', () async {
      final h = await _connected();
      final i = await h.repo.loadApiKeys();
      final request = ApiKeyRequest(
        inventory: i,
        action: ApiKeyAction.create,
        name: name,
      );
      expect(request.validationError, isNotNull);
      await expectLater(
        h.repo.reviewApiKey(request),
        throwsA(_reason(ApiKeysExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final delta in [
    const Duration(seconds: 30),
    const Duration(days: -1),
    const Duration(days: 367),
  ]) {
    test('expiry outside review window $delta blocked', () async {
      final h = await _connected();
      final i = await h.repo.loadApiKeys();
      final request = ApiKeyRequest(
        inventory: i,
        action: ApiKeyAction.create,
        name: 'new-client',
        expiresAt: DateTime.now().toUtc().add(delta),
      );
      expect(request.validationError, isNotNull);
      await expectLater(
        h.repo.reviewApiKey(request),
        throwsA(_reason(ApiKeysExceptionReason.invalidRequest)),
      );
    });
  }
  test('forged review and inventory objects never dispatch', () async {
    final h = await _connected();
    final i = await h.repo.loadApiKeys();
    final request = _request(i, ApiKeyAction.create);
    final fake = ApiKeyReview(
      request: request,
      endpoint: i.endpoint,
      warnings: [],
    );
    final count = h.wire.requests.length;
    await expectLater(
      h.repo.executeApiKey(fake, fake.target),
      throwsA(_reason(ApiKeysExceptionReason.staleReview)),
    );
    expect(h.wire.requests.length, count);
  });
  test(
    'wrong confirmation consumes review without any extra request',
    () async {
      final h = await _connected();
      final r = await _review(h);
      final count = h.wire.requests.length;
      await expectLater(
        h.repo.executeApiKey(r, '${r.target} '),
        throwsA(_reason(ApiKeysExceptionReason.staleReview)),
      );
      await expectLater(
        h.repo.executeApiKey(r, r.target),
        throwsA(_reason(ApiKeysExceptionReason.staleReview)),
      );
      expect(h.wire.requests.length, count);
    },
  );
  test('reload expires previously issued review', () async {
    final h = await _connected();
    final r = await _review(h);
    await h.repo.loadApiKeys();
    final count = h.wire.requests.length;
    await expectLater(
      h.repo.executeApiKey(r, r.target),
      throwsA(_reason(ApiKeysExceptionReason.staleReview)),
    );
    expect(h.wire.requests.length, count);
  });
  for (final drift in [
    'session',
    'credential',
    'user',
    'roles',
    'stig',
    'key-name',
    'key-created',
    'key-owner',
    'key-revoked',
    'add-key',
  ]) {
    test('$drift changes before dispatch reject without write', () async {
      final h = await _connected();
      final r = await _review(h);
      switch (drift) {
        case 'session':
          h.wire.session['id'] = 'different-session';
        case 'credential':
          h.wire.session['credentials'] = 'LOGIN_PASSWORD';
        case 'user':
          h.wire.user['id'] = 77;
        case 'roles':
          h.wire.user['roles'] = ['FULL_ADMIN'];
        case 'stig':
          h.wire.security['enable_gpos_stig'] = true;
        case 'key-name':
          h.wire.keys.last['name'] = 'changed';
        case 'key-created':
          h.wire.keys.last['created_at'] = '2026-09-02T00:00:00Z';
        case 'key-owner':
          h.wire.keys.last['user_identifier'] = 77;
        case 'key-revoked':
          h.wire.keys.last['revoked'] = true;
        case 'add-key':
          h.wire.keys.add(_key(4, 'new-other-client'));
      }
      final result = await h.repo.executeApiKey(r, r.target);
      expect(result.outcome, ApiKeyOutcome.rejected);
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final failure in [
    'timeout',
    'permission',
    'error',
    'malformed',
    'wrong-key',
    'wrong-name',
    'wrong-owner',
    'unexpected-secret',
    'missing-expiry',
  ]) {
    test(
      'postdispatch $failure is unknown and never exposes secret or unlocks',
      () async {
        final h = await _connected(timeout: const Duration(milliseconds: 25));
        final action = failure == 'unexpected-secret'
            ? ApiKeyAction.edit
            : ApiKeyAction.create;
        final r = await _review(h, action: action);
        h.wire.failure = failure;
        final result = await h.repo.executeApiKey(r, r.target);
        expect(result.outcome, ApiKeyOutcome.unknown);
        expect(result.message, isNot(contains(_secret)));
        expect(result.secret, isNull);
        final count = h.wire.requests.length;
        await expectLater(
          h.repo.reviewApiKey(r.request),
          throwsA(_reason(ApiKeysExceptionReason.busy)),
        );
        await expectLater(
          h.repo.execute(
            const CreateDatasetCommand(parent: 'tank', name: 'docs'),
          ),
          throwsA(
            isA<ManagementException>().having(
              (e) => e.reason,
              'reason',
              ManagementExceptionReason.busy,
            ),
          ),
        );
        expect(h.wire.requests.length, count);
        h.wire.failure = null;
        final i = await h.repo.loadApiKeys();
        await expectLater(
          h.repo.reviewApiKey(_request(i, ApiKeyAction.create)),
          throwsA(_reason(ApiKeysExceptionReason.busy)),
        );
        expect(h.wire.writes.length, 1);
      },
    );
  }
  for (final method in _reads) {
    test('$method preflight error is redacted with zero writes', () async {
      final h = await _connected();
      final r = await _review(h);
      h.wire.rejectRead = method;
      final result = await h.repo.executeApiKey(r, r.target);
      expect(result.outcome, ApiKeyOutcome.rejected);
      expect(result.message, isNot(contains(_secret)));
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final malformed in [
    'me',
    'current-none',
    'current-multiple',
    'insecure',
    'internal',
    'data-user',
    'key-id',
    'user-none',
    'keys-duplicate',
    'keys-too-many',
    'other-username',
    'date',
    'bool-id',
    'no-expiry',
  ]) {
    test('malformed $malformed identity blocked on load', () async {
      final h = await _connected();
      h.wire.malformed = malformed;
      await expectLater(
        h.repo.loadApiKeys(),
        throwsA(_reason(ApiKeysExceptionReason.invalidResponse)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('closing repository makes an issued review unusable', () async {
    final h = await _connected();
    final r = await _review(h);
    await h.repo.close();
    final count = h.wire.requests.length;
    await expectLater(
      h.repo.executeApiKey(r, r.target),
      throwsA(_reason(ApiKeysExceptionReason.notAuthenticated)),
    );
    expect(h.wire.requests.length, count);
  });
  test('discard consumes newly generated value without revealing', () {
    final secret = ApiKeyOneTimeSecret(_secret);
    secret.discard();
    expect(secret.take(), isNull);
    expect(secret.toString(), isNot(contains(_secret)));
  });
  for (final date in <Object>[
    '2026-09-01T00:00:00',
    '2026-09-01T00:00:00.123456',
    {'\$date': 1788220800000},
  ]) {
    test('source UTC created timestamp accepts $date safely', () async {
      final h = await _connected();
      h.wire.keys.last['created_at'] = date;
      final inventory = await h.repo.loadApiKeys();
      expect(inventory.keys.last.createdAt.isUtc, isTrue);
      expect(inventory.keys.last.createdAt.year, 2026);
    });
  }
  for (final date in [
    '2026-02-30T00:00:00Z',
    '2026-09-01T25:00:00Z',
    '2026-09-01T00:00:00+24:00',
    '2026-09-01T00:00:00Z\n',
  ]) {
    test('calendar-overflow or malformed date $date rejected', () async {
      final h = await _connected();
      h.wire.keys.last['created_at'] = date;
      await expectLater(
        h.repo.loadApiKeys(),
        throwsA(_reason(ApiKeysExceptionReason.invalidResponse)),
      );
    });
  }
  test('naive expiry is not accepted as UTC by inference', () async {
    final h = await _connected();
    h.wire.keys.last['expires_at'] = '2026-09-01T00:00:00';
    await expectLater(
      h.repo.loadApiKeys(),
      throwsA(_reason(ApiKeysExceptionReason.invalidResponse)),
    );
  });
  for (final settled in [false, true]) {
    test(
      '${settled ? 'unknown' : 'pending'} API-key write fences every newer native family',
      () async {
        final h = await _connected(
          methods: _crossMethods,
          timeout: const Duration(milliseconds: 100),
        );
        final review = await _review(h);
        h.wire.holdMethod = 'api_key.create';
        final operation = h.repo.executeApiKey(review, review.target);
        await _until(() => h.wire.writes.isNotEmpty);
        if (settled) expect((await operation).outcome, ApiKeyOutcome.unknown);
        await _crossFence(h);
        if (!settled) expect((await operation).outcome, ApiKeyOutcome.unknown);
      },
    );
  }
  for (final settled in [false, true]) {
    test(
      '${settled ? 'unknown' : 'pending'} cloud-credential deletion protects API keys in reverse',
      () async {
        final h = await _connected(
          methods: _crossMethods,
          timeout: const Duration(milliseconds: 100),
        );
        final apiReview = await _review(h);
        final inventory = await h.repo.loadCloudCredentials();
        final review = await h.repo.reviewCloudCredential(
          CloudCredentialRequest(
            inventory: inventory,
            action: CloudCredentialAction.delete,
            credential: inventory.credentials.single,
          ),
        );
        h.wire.holdMethod = 'cloudsync.credentials.delete';
        final operation = h.repo.executeCloudCredential(review, review.target);
        await _until(
          () => h.wire.requests.any((r) => r['method'] == h.wire.holdMethod),
        );
        if (settled) {
          expect((await operation).outcome, CloudCredentialOutcome.unknown);
        }
        final count = h.wire.requests.length;
        await expectLater(
          h.repo.reviewApiKey(apiReview.request),
          throwsA(_reason(ApiKeysExceptionReason.busy)),
        );
        await expectLater(
          h.repo.executeApiKey(apiReview, apiReview.target),
          throwsA(_reason(ApiKeysExceptionReason.busy)),
        );
        expect(h.wire.requests.length, count);
        if (!settled) {
          expect((await operation).outcome, CloudCredentialOutcome.unknown);
        }
      },
    );
  }
}

Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 1000; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Synthetic dispatch did not occur.');
}

Future<void> _crossFence(_Harness h) async {
  final count = h.wire.requests.length;
  expect(h.repo.cloudCredentialsCapabilities.canDelete, isTrue);
  expect(h.repo.cloudSyncCapabilities.canDelete, isTrue);
  expect(h.repo.replicationCapabilities.canDelete, isTrue);
  expect(h.repo.systemUpdatesCapabilities.canCheck, isTrue);
  await expectLater(
    h.repo.reviewCloudCredential(
      CloudCredentialRequest(
        inventory: CloudCredentialInventory(
          endpoint: 'wss://synthetic.example/api/current',
          credentials: [],
          references: [],
        ),
        action: CloudCredentialAction.delete,
      ),
    ),
    throwsA(
      isA<CloudCredentialsException>().having(
        (e) => e.reason,
        'reason',
        CloudCredentialsExceptionReason.busy,
      ),
    ),
  );
  await expectLater(
    h.repo.reviewCloudSync(
      CloudSyncRequest(
        inventory: CloudSyncInventory(
          endpoint: 'wss://synthetic.example/api/current',
          timezone: 'UTC',
          tasks: [],
          credentials: [],
          datasets: [],
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
    h.repo.reviewReplication(
      ReplicationRequest(
        inventory: ReplicationInventory(
          endpoint: 'wss://synthetic.example/api/current',
          tasks: [],
          datasets: [],
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
          endpoint: 'wss://synthetic.example/api/current',
          currentVersion: '25.10.1',
          bootPool: 'boot-pool',
          bootHealthy: true,
          failoverLicensed: false,
          conflictingJob: false,
          environments: [],
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
  expect(h.wire.requests.length, count);
}

ApiKeyRequest _request(
  ApiKeyInventory i,
  ApiKeyAction action, {
  ApiKeySnapshot? key,
}) => ApiKeyRequest(
  inventory: i,
  action: action,
  key: action == ApiKeyAction.create ? null : key ?? i.keys.last,
  name: action == ApiKeyAction.delete
      ? ''
      : action == ApiKeyAction.create
      ? 'new-client'
      : 'renamed-client',
);
Future<ApiKeyReview> _review(
  _Harness h, {
  ApiKeyAction action = ApiKeyAction.create,
}) async => h.repo.reviewApiKey(_request(await h.repo.loadApiKeys(), action));

final class _Harness {
  _Harness(this.repo, this.wire);
  final TrueNasSessionRepository repo;
  final _Wire wire;
}

Future<_Harness> _connected({
  String version = '25.10.1',
  Set<String> methods = _methods,
  Map<String, Map<String, Object?>> overrides = const {},
  Duration timeout = const Duration(seconds: 2),
}) async {
  final wire = _Wire(version: version, methods: methods, overrides: overrides);
  final repo = TrueNasSessionRepository(
    connector: _Connector(wire),
    managementRequestTimeout: timeout,
  );
  addTearDown(repo.close);
  await repo.connect(
    serverInput: 'https://synthetic.example',
    username: 'fixture-user',
    apiKey: 'fixture-key',
  );
  return _Harness(repo, wire);
}

final class _Connector implements RpcConnector {
  _Connector(this.wire);
  final _Wire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

Map<String, Object?> _key(int id, String name) => {
  'id': id,
  'name': name,
  'username': 'fixture-user',
  'user_identifier': 42,
  'local': true,
  'revoked': false,
  'created_at': '2026-09-01T00:00:00Z',
  'expires_at': null,
  'keyhash': _secret,
};

final class _Wire implements RpcTransport {
  _Wire({
    this.version = '25.10.1',
    this.methods = _methods,
    this.overrides = const {},
  });
  final String version;
  final Set<String> methods;
  final Map<String, Map<String, Object?>> overrides;
  final _incoming = StreamController<String>();
  final requests = <Map<String, dynamic>>[];
  String? failure, rejectRead, malformed, holdMethod;
  final session = <String, Object?>{
    'id': 'session-one',
    'current': true,
    'internal': false,
    'secure_transport': true,
    'credentials': 'API_KEY',
    'credentials_data': {
      'username': 'fixture-user',
      'api_key': {'id': 1, 'name': 'current-client'},
    },
  };
  final user = <String, Object?>{
    'id': 42,
    'username': 'fixture-user',
    'local': true,
    'builtin': false,
    'locked': false,
    'roles': ['READONLY_ADMIN'],
  };
  final security = <String, Object?>{'enable_gpos_stig': false};
  final keys = <Map<String, Object?>>[
    _key(1, 'current-client'),
    _key(2, 'other-client'),
  ];
  List<Map<String, dynamic>> get writes =>
      requests.where((r) => _writes.contains(r['method'])).toList();
  @override
  Stream<String> get inboundFrames => _incoming.stream;
  @override
  Future<void> send(String frame) async {
    final request = jsonDecode(frame) as Map<String, dynamic>;
    requests.add(request);
    final method = request['method'] as String;
    if (method == holdMethod) return;
    if (method == rejectRead ||
        _writes.contains(method) && {'permission', 'error'}.contains(failure)) {
      _incoming.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': request['id'],
          'error': {
            'code': -32000,
            'message': _secret,
            'data': {
              'errno': failure == 'permission' ? 13 : 5,
              'trace': _secret,
            },
          },
        }),
      );
      return;
    }
    if (_writes.contains(method) && failure == 'timeout') return;
    Object? result;
    switch (method) {
      case 'auth.login_ex':
        result = {'response_type': 'SUCCESS'};
      case 'auth.me':
        result = malformed == 'me'
            ? {'pw_name': 'other-user'}
            : {'pw_name': 'fixture-user'};
      case 'system.info':
        result = {'version': version};
      case 'core.get_methods':
        result = {
          for (final name in methods)
            name: {
              'accepts': <Object?>[],
              'returns': <Object?>[],
              'roles': ['FULL_ADMIN'],
              'job': false,
              'filterable': false,
              'uploadable': false,
              'downloadable': false,
              'no_auth_required': false,
              ...?overrides[name],
            },
        };
      case 'auth.sessions':
        final value = Map<String, Object?>.of(session);
        if (malformed == 'insecure') value['secure_transport'] = false;
        if (malformed == 'internal') value['internal'] = true;
        if (malformed == 'data-user') {
          value['credentials_data'] = {'username': 'other-user'};
        }
        if (malformed == 'key-id') {
          value['credentials_data'] = {
            'username': 'fixture-user',
            'api_key': {'id': true},
          };
        }
        result = malformed == 'current-none'
            ? []
            : malformed == 'current-multiple'
            ? [value, value]
            : [value];
      case 'user.query':
        result = malformed == 'user-none' ? [] : [user];
      case 'system.security.config':
        result = security;
      case 'cloudsync.credentials.query':
        result = [
          {
            'id': 10,
            'name': 'unused-s3',
            'provider': {'type': 'S3'},
          },
        ];
      case 'cloudsync.query':
      case 'cloud_backup.query':
      case 'core.get_jobs':
        result = [];
      case 'api_key.query':
        final values = keys.map((k) => Map<String, Object?>.of(k)).toList();
        if (malformed == 'keys-duplicate') values.add(values.first);
        if (malformed == 'other-username') {
          values.last['username'] = 'other-user';
        }
        if (malformed == 'date') values.last['created_at'] = _secret;
        if (malformed == 'bool-id') values.last['id'] = true;
        if (malformed == 'no-expiry') values.last.remove('expires_at');
        result = malformed == 'keys-too-many'
            ? List.filled(129, values.first)
            : values;
      case 'api_key.create':
        final data = (request['params'] as List).first as Map;
        final key = _key(3, data['name'] as String)
          ..['expires_at'] = data['expires_at'];
        keys.add(key);
        // The create implementation returns its pre-extension numeric string.
        result = {...key, 'user_identifier': '42', 'key': '3-${'a' * 64}'};
      case 'api_key.update':
        final args = request['params'] as List;
        final data = args[1] as Map;
        final key = keys.singleWhere((k) => k['id'] == args.first);
        key['name'] = data['name'];
        key['expires_at'] = data['expires_at'];
        if (data['reset'] == true) key['revoked'] = false;
        result = {
          ...key,
          if (data['reset'] == true || failure == 'unexpected-secret')
            'key': '${key['id']}-${'a' * 64}',
        };
      case 'api_key.delete':
        keys.removeWhere((k) => k['id'] == (request['params'] as List).single);
        result = true;
      default:
        throw StateError('Unexpected synthetic method: $method');
    }
    if (_writes.contains(method)) {
      if (failure == 'missing-expiry') (result as Map).remove('expires_at');
      if (failure == 'malformed') result = {'key': _secret};
      if (failure == 'wrong-key') (result as Map)['key'] = '999-${'a' * 64}';
      if (failure == 'wrong-name') (result as Map)['name'] = 'different-client';
      if (failure == 'wrong-owner') (result as Map)['user_identifier'] = 999;
    }
    _incoming.add(
      jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}
