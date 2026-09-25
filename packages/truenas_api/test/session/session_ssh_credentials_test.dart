import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _reads = {
  'keychaincredential.query',
  'keychaincredential.used_by',
  'core.get_jobs',
};
const _writes = {
  'keychaincredential.create',
  'keychaincredential.update',
  'keychaincredential.delete',
  'keychaincredential.generate_ssh_key_pair',
};
const _methods = {..._reads, ..._writes, 'pool.dataset.create'};
const _crossMethods = {
  ..._methods,
  'alert.list',
  'alert.dismiss',
  'alert.restore',
  'failover.licensed',
  'auth.me',
  'auth.sessions',
  'user.query',
  'api_key.query',
  'system.security.config',
  'api_key.create',
  'cloudsync.credentials.query',
  'cloudsync.credentials.delete',
  'cloudsync.query',
  'cloud_backup.query',
  'system.version_short',
  'boot.get_state',
  'boot.environment.query',
  'update.status',
  'update.available_versions',
  'replication.query',
  'replication.delete',
  'pool.dataset.query',
  'pool.filesystem_choices',
  'pool.snapshot.query',
  'cloudsync.delete',
  'filesystem.stat',
  'filesystem.statfs',
  'system.general.config',
};
const _remoteError = 'synthetic-sensitive-remote-error';
Matcher _reason(SshCredentialsExceptionReason reason) =>
    isA<SshCredentialsException>().having((e) => e.reason, 'reason', reason);
final _edBlob = [
  ..._field(utf8.encode('ssh-ed25519')),
  ..._field(List.filled(32, 17)),
];
final _rsaBlob = [
  ..._field(utf8.encode('ssh-rsa')),
  ..._field([1, 0, 1]),
  ..._field([0, 128, ...List.filled(254, 17), 1]),
];
String _public(List<int> blob) =>
    '${utf8.decode(_readField(blob))} ${base64Encode(blob)}';
final _ed = _public(_edBlob), _rsa = _public(_rsaBlob);
String _private(List<int> public, {String cipher = 'none', int count = 1}) =>
    '-----BEGIN OPENSSH PRIVATE KEY-----\n${base64Encode([...utf8.encode('openssh-key-v1\x00'), ..._field(utf8.encode(cipher)), ..._field(utf8.encode('none')), ..._field([]), ..._number(count), ..._field(public), ..._field(List.filled(64, 23))])}\n-----END OPENSSH PRIVATE KEY-----\n';
List<int> _number(int n) => [
  n >> 24 & 255,
  n >> 16 & 255,
  n >> 8 & 255,
  n & 255,
];
List<int> _field(List<int> bytes) => [..._number(bytes.length), ...bytes];
List<int> _readField(List<int> bytes) => bytes.sublist(4, 4 + bytes[3]);

void main() {
  for (final method in {
    ..._writes,
    'keychaincredential.query',
    'keychaincredential.remote_ssh_host_key_scan',
    'keychaincredential.remote_ssh_semiautomatic_setup',
    'keychaincredential.setup_ssh_connection',
  }) {
    test('generic $method cannot bypass native SSH review', () async {
      final h = await _connected(methods: {..._methods, method});
      final spec = h.repo.adminCatalog.method(method);
      if (spec == null) {
        expect(_writes.contains(method), isFalse);
        return;
      }
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
    });
  }
  test('disconnected capability never sends read', () async {
    final wire = _Wire();
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    expect(repo.sshCredentialsCapabilities.supported, isFalse);
    await expectLater(
      repo.loadSshCredentials(),
      throwsA(_reason(SshCredentialsExceptionReason.notAuthenticated)),
    );
    expect(wire.requests, isEmpty);
  });
  for (final version in ['25.04.2', '26.0.0', '25.10-BETA', '25.10.1\n']) {
    test('unsupported $version never queries credential metadata', () async {
      final h = await _connected(version: version);
      final count = h.wire.requests.length;
      await expectLater(
        h.repo.loadSshCredentials(),
        throwsA(_reason(SshCredentialsExceptionReason.unsupportedVersion)),
      );
      expect(h.wire.requests.length, count);
    });
  }
  for (final missing in _reads) {
    test('missing $missing disables safe inventory', () async {
      final h = await _connected(methods: _methods.difference({missing}));
      expect(h.repo.sshCredentialsCapabilities.available, isFalse);
      await expectLater(
        h.repo.loadSshCredentials(),
        throwsA(_reason(SshCredentialsExceptionReason.unavailableMethod)),
      );
    });
  }
  for (final overrides in [
    {'job': true},
    {'uploadable': true},
    {'downloadable': true},
    {'private': true},
    {'_private': true},
    {'no_auth_required': true},
  ]) {
    test('unsafe metadata $overrides disables writers', () async {
      final h = await _connected(
        overrides: {for (final method in _writes) method: overrides},
      );
      expect(h.repo.sshCredentialsCapabilities.supported, isTrue);
      for (final action in SshCredentialAction.values) {
        expect(h.repo.sshCredentialsCapabilities.allows(action), isFalse);
      }
    });
  }
  test(
    'type-filtered nested projections never request keypair private material',
    () async {
      final h = await _connected();
      final i = await h.repo.loadSshCredentials();
      expect(i.credentials.length, 3);
      expect(i.keyPairs.length, 2);
      expect(i.connections.length, 1);
      expect(i.credentials.first.usageCount, 1);
      expect(i.keyPairs.first.publicKey, _ed);
      expect(i.connections.single.connection!.keyPairId, 1);
      expect(() => i.credentials.clear(), throwsUnsupportedError);
      final queries = h.wire.requests
          .where((r) => r['method'] == 'keychaincredential.query')
          .toList();
      expect(queries.length, 2);
      expect(queries.first['params'], [
        [
          ['type', '=', 'SSH_KEY_PAIR'],
        ],
        {
          'limit': 33,
          'select': ['id', 'name', 'type', 'attributes.public_key'],
        },
      ]);
      expect(queries.last['params'], [
        [
          ['type', '=', 'SSH_CREDENTIALS'],
        ],
        {
          'limit': 33,
          'select': [
            'id',
            'name',
            'type',
            'attributes.host',
            'attributes.port',
            'attributes.username',
            'attributes.private_key',
            'attributes.remote_host_key',
            'attributes.connect_timeout',
          ],
        },
      ]);
      expect(h.wire.writes, isEmpty);
      expect(
        h.wire.requests.any(
          (r) => (r['method'] as String).contains('remote_ssh'),
        ),
        isFalse,
      );
    },
  );
  test('fingerprint hashes SSH wire bytes and strips padding not text', () {
    expect(
      sshPublicKeyFingerprint(_ed),
      'SHA256:${base64Encode(sha256.convert(_edBlob).bytes).replaceAll('=', '')}',
    );
    expect(
      sshPublicKeyFingerprint('$_ed harmless-comment\n'),
      sshPublicKeyFingerprint(_ed),
    );
    expect(sshPublicKeyFingerprint('$_ed\n$_rsa'), isNull);
    expect(sshPublicKeyFingerprint('ssh-dss AAAA'), isNull);
  });
  test(
    'host-key comments are discarded before public inventory and review',
    () async {
      final h = await _connected();
      (h.wire.connections.single['attributes'] as Map)['remote_host_key'] =
          '$_ed $_remoteError';
      final inventory = await h.repo.loadSshCredentials();
      final connection = inventory.connections.single.connection!;
      expect(connection.remoteHostKey, _ed);
      expect(connection.hostKeyFingerprints, [sshPublicKeyFingerprint(_ed)]);
      final review = await h.repo.reviewSshCredential(
        SshCredentialRequest(
          inventory: inventory,
          action: SshCredentialAction.rename,
          credential: inventory.connections.single,
          name: 'renamed-connection',
        ),
      );
      expect(
        review.request.credential!.connection!.remoteHostKey,
        isNot(contains(_remoteError)),
      );
      expect(review.warnings.join(' '), isNot(contains(_remoteError)));
      final result = await h.repo.executeSshCredential(review, review.target);
      expect(result.outcome, SshCredentialOutcome.succeeded);
      expect(result.message, isNot(contains(_remoteError)));
    },
  );
  for (final private in [
    '',
    _private(_edBlob, cipher: 'aes256-ctr'),
    _private(_edBlob, count: 2),
    '-----BEGIN RSA PRIVATE KEY-----\nAAAA\n-----END RSA PRIVATE KEY-----',
    'x' * 65537,
  ]) {
    test('unsafe import container blocked ${private.length}', () {
      final input = SshCredentialWriteOnlyInput.keyPair(privateKey: private);
      expect(input.validationError, isNotNull);
      expect(
        input.toString(),
        isNot(contains(private.isEmpty ? 'AAAA' : private)),
      );
      input.dispose();
      expect(input.disposed, isTrue);
    });
  }
  test('import public/private container identity mismatch rejected', () {
    final input = SshCredentialWriteOnlyInput.keyPair(
      privateKey: _private(_edBlob),
      publicKey: _rsa,
    );
    expect(input.validationError, contains('does not match'));
    input.dispose();
  });
  for (final action in SshCredentialAction.values) {
    test(
      '$action exact public wire contract with separate verification',
      () async {
        final h = await _connected();
        final i = await h.repo.loadSshCredentials();
        final request = _request(i, action);
        final review = await h.repo.reviewSshCredential(request);
        final input = action == SshCredentialAction.importKeyPair
            ? SshCredentialWriteOnlyInput.keyPair(privateKey: _private(_edBlob))
            : null;
        expect(h.wire.writes, isEmpty);
        final result = await h.repo.executeSshCredential(
          review,
          review.target,
          input: input,
        );
        expect(result.outcome, SshCredentialOutcome.succeeded);
        expect(input?.disposed ?? true, isTrue);
        final count = action == SshCredentialAction.generateKeyPair ? 2 : 1;
        expect(h.wire.writes.length, count);
        final last = h.wire.writes.last;
        switch (action) {
          case SshCredentialAction.importKeyPair:
            expect(last['method'], 'keychaincredential.create');
            expect((last['params'] as List).single, {
              'name': 'new-key',
              'type': 'SSH_KEY_PAIR',
              'attributes': {
                'private_key': _private(_edBlob),
                'public_key': null,
              },
            });
            expect(result.publicKey, _ed);
          case SshCredentialAction.generateKeyPair:
            expect(
              h.wire.writes.first['method'],
              'keychaincredential.generate_ssh_key_pair',
            );
            expect(h.wire.writes.first['params'], []);
            expect(result.publicKey, _rsa);
            expect(
              (last['params'] as List).single['attributes']['private_key'],
              _private(_rsaBlob),
            );
          case SshCredentialAction.createConnection:
            expect((last['params'] as List).single, {
              'name': 'new-connection',
              'type': 'SSH_CREDENTIALS',
              'attributes': {
                'host': 'backup.example',
                'port': 2222,
                'username': 'backup',
                'private_key': 1,
                'remote_host_key': _ed,
                'connect_timeout': 15,
              },
            });
            expect(result.message, contains('No SSH connection'));
            expect(result.publicKey, isNull);
          case SshCredentialAction.rename:
            expect(last['params'], [
              3,
              {'name': 'renamed-key'},
            ]);
            expect(result.publicKey, isNull);
          case SshCredentialAction.delete:
            expect(last['params'], [
              3,
              {'cascade': false},
            ]);
            expect(result.publicKey, isNull);
        }
        expect(result.message, isNot(contains(_remoteError)));
        final after = h.wire.requests
            .skipWhile((r) => !identical(r, last))
            .skip(1)
            .toList();
        expect(
          after.any((r) => r['method'] == 'keychaincredential.query'),
          isTrue,
        );
        final boundary = h.wire.requests.length;
        await expectLater(
          h.repo.executeSshCredential(review, review.target),
          throwsA(_reason(SshCredentialsExceptionReason.staleReview)),
        );
        expect(h.wire.requests.length, boundary);
      },
    );
  }
  test(
    'deleting unused connection accounts for removed keypair dependency',
    () async {
      final h = await _connected();
      final i = await h.repo.loadSshCredentials();
      final r = await h.repo.reviewSshCredential(
        SshCredentialRequest(
          inventory: i,
          action: SshCredentialAction.delete,
          credential: i.connections.single,
        ),
      );
      expect(
        (await h.repo.executeSshCredential(r, r.target)).outcome,
        SshCredentialOutcome.succeeded,
      );
      expect(h.wire.connections, isEmpty);
    },
  );
  for (final action in [
    SshCredentialAction.rename,
    SshCredentialAction.delete,
  ]) {
    test('referenced keypair $action never dispatched', () async {
      final h = await _connected();
      final i = await h.repo.loadSshCredentials();
      final req = SshCredentialRequest(
        inventory: i,
        action: action,
        credential: i.credentials.first,
        name: action == SshCredentialAction.rename ? 'changed' : '',
      );
      expect(req.validationError, contains('dependency'));
      await expectLater(
        h.repo.reviewSshCredential(req),
        throwsA(_reason(SshCredentialsExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final field in [
    'host',
    'port',
    'username',
    'key-id',
    'timeout',
    'hostkey',
    'too-long-hostkey',
    'unverified',
  ]) {
    test('unsafe manual $field rejected before any remote attempt', () async {
      final h = await _connected();
      final i = await h.repo.loadSshCredentials();
      final req = SshCredentialRequest(
        inventory: i,
        action: SshCredentialAction.createConnection,
        name: 'new-connection',
        hostKeyVerified: field != 'unverified',
        connection: SshConnectionSettings(
          host: field == 'host'
              ? 'https://user:password@backup.example'
              : 'backup.example',
          port: field == 'port' ? 0 : 22,
          username: field == 'username' ? '-oProxyCommand=touch' : 'backup',
          keyPairId: field == 'key-id' ? 999 : 1,
          remoteHostKey: field == 'hostkey'
              ? 'backup.example $_ed'
              : field == 'too-long-hostkey'
              ? '$_ed ${'x' * 1024}'
              : _ed,
          connectTimeout: field == 'timeout' ? 0 : 10,
        ),
      );
      expect(req.validationError, isNotNull);
      await expectLater(
        h.repo.reviewSshCredential(req),
        throwsA(_reason(SshCredentialsExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final name in ['', ' bad', 'bad ', 'bad\n', 'x' * 256, 'spare-key']) {
    test('invalid or duplicate name ${name.length} rejected', () async {
      final h = await _connected();
      final i = await h.repo.loadSshCredentials();
      final req = SshCredentialRequest(
        inventory: i,
        action: SshCredentialAction.generateKeyPair,
        name: name,
      );
      await expectLater(
        h.repo.reviewSshCredential(req),
        throwsA(_reason(SshCredentialsExceptionReason.invalidRequest)),
      );
    });
  }
  test(
    'forged and wrong confirmations consume no write and dispose input',
    () async {
      final h = await _connected();
      final i = await h.repo.loadSshCredentials();
      final req = _request(i, SshCredentialAction.importKeyPair);
      final forged = SshCredentialReview(
        request: req,
        endpoint: i.endpoint,
        warnings: [],
      );
      final input = SshCredentialWriteOnlyInput.keyPair(
        privateKey: _private(_edBlob),
      );
      await expectLater(
        h.repo.executeSshCredential(forged, forged.target, input: input),
        throwsA(_reason(SshCredentialsExceptionReason.staleReview)),
      );
      expect(input.disposed, isTrue);
      final r = await h.repo.reviewSshCredential(req);
      await expectLater(
        h.repo.executeSshCredential(r, '${r.target} '),
        throwsA(_reason(SshCredentialsExceptionReason.staleReview)),
      );
      await expectLater(
        h.repo.executeSshCredential(r, r.target),
        throwsA(_reason(SshCredentialsExceptionReason.staleReview)),
      );
      expect(h.wire.writes, isEmpty);
    },
  );
  test('refresh invalidates review', () async {
    final h = await _connected();
    final r = await _review(h);
    await h.repo.loadSshCredentials();
    await expectLater(
      h.repo.executeSshCredential(r, r.target),
      throwsA(_reason(SshCredentialsExceptionReason.staleReview)),
    );
  });
  for (final type in ['SSH_KEY_PAIR', 'SSH_CREDENTIALS']) {
    test('bounded $type capacity blocks creation before effects', () async {
      final h = await _connected();
      if (type == 'SSH_KEY_PAIR') {
        h.wire.pairs.clear();
        h.wire.pairs.addAll(List.generate(32, (i) => _pair(i + 1, 'key-$i')));
        h.wire.connections.clear();
      } else {
        h.wire.connections.clear();
        h.wire.connections.addAll(
          List.generate(
            32,
            (i) => {..._connection(), 'id': i + 100, 'name': 'connection-$i'},
          ),
        );
      }
      final inventory = await h.repo.loadSshCredentials();
      final action = type == 'SSH_KEY_PAIR'
          ? SshCredentialAction.generateKeyPair
          : SshCredentialAction.createConnection;
      final request = SshCredentialRequest(
        inventory: inventory,
        action: action,
        name: 'new-item',
        hostKeyVerified: type == 'SSH_CREDENTIALS',
        connection: type == 'SSH_CREDENTIALS'
            ? SshConnectionSettings(
                host: 'backup.example',
                port: 22,
                username: 'backup',
                keyPairId: 1,
                remoteHostKey: _ed,
                connectTimeout: 10,
              )
            : null,
      );
      expect(request.validationError, contains('at most 32'));
      await expectLater(
        h.repo.reviewSshCredential(request),
        throwsA(_reason(SshCredentialsExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final drift in [
    'name',
    'public-key',
    'host',
    'host-key',
    'dependency',
    'job',
    'new-entry',
    'key-type',
  ]) {
    test('fresh $drift drift rejects before mutation', () async {
      final h = await _connected();
      final r = await _review(h);
      switch (drift) {
        case 'name':
          h.wire.pairs.last['name'] = 'changed';
        case 'public-key':
          (h.wire.pairs.last['attributes'] as Map)['public_key'] = _rsa;
        case 'host':
          (h.wire.connections.single['attributes'] as Map)['host'] =
              'changed.example';
        case 'host-key':
          (h.wire.connections.single['attributes'] as Map)['remote_host_key'] =
              _rsa;
        case 'dependency':
          h.wire.extraUses[3] = [
            {'title': 'Rsync task', 'unbind_method': 'disable'},
          ];
        case 'job':
          h.wire.jobs.add({
            'id': 8,
            'method': 'replication.run',
            'state': 'RUNNING',
          });
        case 'new-entry':
          h.wire.pairs.add(_pair(5, 'new-other-key'));
        case 'key-type':
          h.wire.pairs.last['type'] = 'SSH_CREDENTIALS';
      }
      expect(
        (await h.repo.executeSshCredential(r, r.target)).outcome,
        SshCredentialOutcome.rejected,
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final method in _reads) {
    test('preflight $method errors redacted without writes', () async {
      final h = await _connected();
      final r = await _review(h);
      h.wire.errorMethod = method;
      final result = await h.repo.executeSshCredential(r, r.target);
      expect(result.outcome, SshCredentialOutcome.rejected);
      expect(result.message, isNot(contains(_remoteError)));
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final failure in [
    'timeout',
    'permission',
    'error',
    'receipt',
    'private-hostkey',
    'wrong-public',
    'post-read',
    'wrong-id',
    'delete-true',
    'generate-malformed',
    'generate-drift',
    'generate-create-error',
  ]) {
    test(
      'postdispatch $failure keeps unknown fence and withholds output',
      () async {
        final h = await _connected(timeout: const Duration(milliseconds: 50));
        final action = failure.startsWith('generate')
            ? SshCredentialAction.generateKeyPair
            : failure == 'delete-true'
            ? SshCredentialAction.delete
            : SshCredentialAction.importKeyPair;
        final r = await _review(h, action: action);
        h.wire.failure = failure;
        final input = action == SshCredentialAction.importKeyPair
            ? SshCredentialWriteOnlyInput.keyPair(privateKey: _private(_edBlob))
            : null;
        final result = await h.repo.executeSshCredential(
          r,
          r.target,
          input: input,
        );
        expect(result.outcome, SshCredentialOutcome.unknown);
        expect(result.publicKey, isNull);
        expect(result.message, isNot(contains(_remoteError)));
        expect(input?.disposed ?? true, isTrue);
        final count = h.wire.requests.length;
        await expectLater(
          h.repo.reviewSshCredential(r.request),
          throwsA(_reason(SshCredentialsExceptionReason.busy)),
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
        if (failure == 'generate-malformed' || failure == 'generate-drift') {
          expect(h.wire.writes.map((r) => r['method']), [
            'keychaincredential.generate_ssh_key_pair',
          ]);
        }
      },
    );
  }
  for (final malformed in [
    'wrong-type',
    'duplicate',
    'too-many',
    'missing-public',
    'private-in-public',
    'private-in-host',
    'missing-host',
    'host-user-info',
    'unsafe-username',
    'invalid-port',
    'invalid-timeout',
    'bool-ref',
    'uses-not-list',
    'uses-too-many',
    'uses-invalid-action',
    'jobs-invalid',
  ]) {
    test('malformed $malformed inventory never exposes raw data', () async {
      final h = await _connected();
      h.wire.malformed = malformed;
      await expectLater(
        h.repo.loadSshCredentials(),
        throwsA(_reason(SshCredentialsExceptionReason.invalidResponse)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  for (final settled in [false, true]) {
    test(
      '${settled ? 'unknown' : 'pending'} SSH generation fences other native writers',
      () async {
        final h = await _connected(
          methods: _crossMethods,
          timeout: const Duration(milliseconds: 100),
        );
        final r = await _review(h, action: SshCredentialAction.generateKeyPair);
        h.wire.holdMethod = 'keychaincredential.generate_ssh_key_pair';
        final operation = h.repo.executeSshCredential(r, r.target);
        await _until(() => h.wire.writes.isNotEmpty);
        if (settled) {
          expect((await operation).outcome, SshCredentialOutcome.unknown);
        }
        await _crossFence(h);
        if (!settled) {
          expect((await operation).outcome, SshCredentialOutcome.unknown);
        }
      },
    );
  }
  for (final settled in [false, true]) {
    test(
      '${settled ? 'unknown' : 'pending'} cloud credential deletion fences SSH in reverse',
      () async {
        final h = await _connected(
          methods: _crossMethods,
          timeout: const Duration(milliseconds: 100),
        );
        final ssh = await _review(h);
        final inventory = await h.repo.loadCloudCredentials();
        final r = await h.repo.reviewCloudCredential(
          CloudCredentialRequest(
            inventory: inventory,
            action: CloudCredentialAction.delete,
            credential: inventory.credentials.single,
          ),
        );
        h.wire.holdMethod = 'cloudsync.credentials.delete';
        final operation = h.repo.executeCloudCredential(r, r.target);
        await _until(
          () => h.wire.requests.any((r) => r['method'] == h.wire.holdMethod),
        );
        if (settled) {
          expect((await operation).outcome, CloudCredentialOutcome.unknown);
        }
        final count = h.wire.requests.length;
        await expectLater(
          h.repo.reviewSshCredential(ssh.request),
          throwsA(_reason(SshCredentialsExceptionReason.busy)),
        );
        await expectLater(
          h.repo.executeSshCredential(ssh, ssh.target),
          throwsA(_reason(SshCredentialsExceptionReason.busy)),
        );
        expect(h.wire.requests.length, count);
        if (!settled) {
          expect((await operation).outcome, CloudCredentialOutcome.unknown);
        }
      },
    );
  }
  test('disconnected issued import is rejected and input discarded', () async {
    final h = await _connected();
    final r = await _review(h, action: SshCredentialAction.importKeyPair);
    await h.repo.close();
    final input = SshCredentialWriteOnlyInput.keyPair(
      privateKey: _private(_edBlob),
    );
    await expectLater(
      h.repo.executeSshCredential(r, r.target, input: input),
      throwsA(_reason(SshCredentialsExceptionReason.notAuthenticated)),
    );
    expect(input.disposed, isTrue);
    expect(h.wire.writes, isEmpty);
  });
}

SshCredentialRequest _request(
  SshCredentialInventory i,
  SshCredentialAction action,
) => SshCredentialRequest(
  inventory: i,
  action: action,
  credential:
      action == SshCredentialAction.rename ||
          action == SshCredentialAction.delete
      ? i.credentials.singleWhere((e) => e.id == 3)
      : null,
  name: action == SshCredentialAction.delete
      ? ''
      : action == SshCredentialAction.rename
      ? 'renamed-key'
      : action == SshCredentialAction.createConnection
      ? 'new-connection'
      : 'new-key',
  hostKeyVerified: action == SshCredentialAction.createConnection,
  connection: action == SshCredentialAction.createConnection
      ? SshConnectionSettings(
          host: 'backup.example',
          port: 2222,
          username: 'backup',
          keyPairId: 1,
          remoteHostKey: _ed,
          connectTimeout: 15,
        )
      : null,
);
Future<SshCredentialReview> _review(
  _Harness h, {
  SshCredentialAction action = SshCredentialAction.rename,
}) async => h.repo.reviewSshCredential(
  _request(await h.repo.loadSshCredentials(), action),
);
Future<void> _until(bool Function() condition) async {
  for (var i = 0; i < 1000; i++) {
    if (condition()) return;
    await Future<void>.delayed(Duration.zero);
  }
  fail('Synthetic dispatch missing.');
}

Future<void> _crossFence(_Harness h) async {
  final count = h.wire.requests.length;
  final alert = AlertSnapshot(
    id: 'fixture',
    klass: 'PoolStatus',
    source: 'VolumeStatus',
    node: 'Controller A',
    level: 'WARNING',
    firstSeen: DateTime.utc(2026),
    lastSeen: DateTime.utc(2026),
    dismissed: false,
    oneShot: false,
  );
  await expectLater(
    h.repo.reviewAlert(
      AlertRequest(
        inventory: AlertInventory(
          endpoint: 'wss://synthetic.example/api/current',
          failoverLicensed: false,
          alerts: [alert],
        ),
        action: AlertAction.dismiss,
        alert: alert,
      ),
    ),
    throwsA(
      isA<AlertsException>().having(
        (e) => e.reason,
        'reason',
        AlertsExceptionReason.busy,
      ),
    ),
  );
  await expectLater(
    h.repo.reviewApiKey(
      ApiKeyRequest(
        inventory: ApiKeyInventory(
          endpoint: 'wss://synthetic.example/api/current',
          username: 'fixture-user',
          userId: 42,
          sessionId: 'fixture',
          credentialType: 'LOGIN_PASSWORD',
          currentKeyId: null,
          accountEligible: true,
          stig: false,
          keys: [],
        ),
        action: ApiKeyAction.create,
        name: 'new-client',
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
  expect(h.wire.requests.length, count);
}

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

Map<String, Object?> _pair(int id, String name, {String? public}) => {
  'id': id,
  'name': name,
  'type': 'SSH_KEY_PAIR',
  'attributes': {'public_key': public ?? _ed, 'private_key': _remoteError},
};
Map<String, Object?> _connection() => {
  'id': 2,
  'name': 'remote-backup',
  'type': 'SSH_CREDENTIALS',
  'attributes': {
    'host': 'existing.example',
    'port': 22,
    'username': 'backup',
    'private_key': 1,
    'remote_host_key': _ed,
    'connect_timeout': 10,
  },
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
  final pairs = <Map<String, Object?>>[
    _pair(1, 'replication-key'),
    _pair(3, 'spare-key'),
  ];
  final connections = <Map<String, Object?>>[_connection()];
  final extraUses = <int, List<Object?>>{};
  final jobs = <Map<String, Object?>>[];
  String? failure, malformed, errorMethod, holdMethod;
  bool mutated = false;
  List<Map<String, dynamic>> get writes =>
      requests.where((r) => _writes.contains(r['method'])).toList();
  @override
  Stream<String> get inboundFrames => _incoming.stream;
  void _error(Map<String, dynamic> r, {int errno = 5}) => _incoming.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': r['id'],
      'error': {
        'code': -32000,
        'message': _remoteError,
        'data': {'errno': errno, 'secret': _private(_edBlob)},
      },
    }),
  );
  @override
  Future<void> send(String frame) async {
    final r = jsonDecode(frame) as Map<String, dynamic>;
    requests.add(r);
    final method = r['method'] as String;
    if (method == holdMethod ||
        _writes.contains(method) && failure == 'timeout') {
      return;
    }
    if (method == errorMethod ||
        _writes.contains(method) && {'permission', 'error'}.contains(failure) ||
        failure == 'generate-create-error' &&
            method == 'keychaincredential.create' ||
        failure == 'post-read' && mutated && _reads.contains(method)) {
      _error(r, errno: failure == 'permission' ? 13 : 5);
      return;
    }
    Object? result;
    switch (method) {
      case 'auth.login_ex':
        result = {'response_type': 'SUCCESS'};
      case 'auth.me':
        result = {'pw_name': 'fixture-user'};
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
      case 'keychaincredential.query':
        final args = r['params'] as List;
        final type = (args.first as List).single[2];
        final values = (jsonDecode(
          jsonEncode(type == 'SSH_KEY_PAIR' ? pairs : connections),
        ) as List).cast<Map<String, dynamic>>();
        if (type == 'SSH_KEY_PAIR') {
          if (malformed == 'wrong-type') {
            values.first['type'] = 'SSH_CREDENTIALS';
          }
          if (malformed == 'duplicate') values.add(values.first);
          if (malformed == 'missing-public') {
            (values.first['attributes'] as Map).remove('public_key');
          }
          if (malformed == 'private-in-public') {
            (values.first['attributes'] as Map)['public_key'] = _private(
              _edBlob,
            );
          }
          result = malformed == 'too-many'
              ? List.filled(33, values.first)
              : values;
        } else {
          if (malformed == 'private-in-host' ||
              failure == 'private-hostkey' && mutated) {
            (values.first['attributes'] as Map)['remote_host_key'] = _private(
              _edBlob,
            );
          }
          if (malformed == 'missing-host') {
            (values.first['attributes'] as Map).remove('host');
          }
          if (malformed == 'host-user-info') {
            (values.first['attributes'] as Map)['host'] =
                'https://user:password@backup.example';
          }
          if (malformed == 'unsafe-username') {
            (values.first['attributes'] as Map)['username'] =
                '-oProxyCommand=unsafe';
          }
          if (malformed == 'invalid-port') {
            (values.first['attributes'] as Map)['port'] = 0;
          }
          if (malformed == 'invalid-timeout') {
            (values.first['attributes'] as Map)['connect_timeout'] = 0;
          }
          if (malformed == 'bool-ref') {
            (values.first['attributes'] as Map)['private_key'] = true;
          }
          result = values;
        }
      case 'keychaincredential.used_by':
        final id = (r['params'] as List).single as int;
        final refs = <Object?>[...?extraUses[id]];
        for (final connection in connections) {
          if ((connection['attributes'] as Map)['private_key'] == id) {
            refs.add({
              'title': 'SSH credentials ${connection['name']}',
              'unbind_method': 'delete',
            });
            refs.addAll(extraUses[connection['id']] ?? []);
          }
        }
        result = malformed == 'uses-not-list'
            ? true
            : malformed == 'uses-too-many'
            ? List.filled(257, {
                'title': 'dependency',
                'unbind_method': 'disable',
              })
            : malformed == 'uses-invalid-action'
            ? [
                {'title': 'dependency', 'unbind_method': 'execute'},
              ]
            : refs;
      case 'core.get_jobs':
        result = malformed == 'jobs-invalid'
            ? [
                {'id': true, 'method': 'replication.run', 'state': 'RUNNING'},
              ]
            : jobs;
      case 'keychaincredential.generate_ssh_key_pair':
        result = failure == 'generate-malformed'
            ? {'private_key': _remoteError, 'public_key': _remoteError}
            : {'private_key': _private(_rsaBlob), 'public_key': _rsa};
        if (failure == 'generate-drift') {
          pairs.last['name'] = 'changed-after-generation';
        }
      case 'keychaincredential.create':
        mutated = true;
        final payload = (r['params'] as List).single as Map<String, dynamic>;
        final attributes = Map<String, dynamic>.from(
          payload['attributes'] as Map,
        );
        if (payload['type'] == 'SSH_KEY_PAIR') {
          attributes['public_key'] = failure == 'wrong-public'
              ? _rsa
              : attributes['public_key'] ?? _ed;
          final row = <String, Object?>{
            'id': 4,
            ...payload,
            'attributes': attributes,
          };
          pairs.add(row);
          result = row;
        } else {
          final row = <String, Object?>{
            'id': 4,
            ...payload,
            'attributes': attributes,
          };
          connections.add(row);
          result = row;
        }
      case 'keychaincredential.update':
        mutated = true;
        final args = r['params'] as List;
        final row = [
          ...pairs,
          ...connections,
        ].singleWhere((e) => e['id'] == args[0]);
        row['name'] = (args[1] as Map)['name'];
        result = row;
      case 'keychaincredential.delete':
        mutated = true;
        final args = r['params'] as List;
        final id = args.first;
        expect(args[1], {'cascade': false});
        pairs.removeWhere((e) => e['id'] == id);
        connections.removeWhere((e) => e['id'] == id);
        result = failure == 'delete-true' ? true : null;
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
        result = [];
      default:
        throw StateError('Unexpected synthetic method $method');
    }
    if (_writes.contains(method) &&
        method != 'keychaincredential.generate_ssh_key_pair') {
      if (failure == 'receipt') {
        result = {
          'id': 999,
          'attributes': {'private_key': _remoteError},
        };
      }
      if (failure == 'wrong-id') result = {...(result as Map), 'id': 999};
    }
    _incoming.add(
      jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}
