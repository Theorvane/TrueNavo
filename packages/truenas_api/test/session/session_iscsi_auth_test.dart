import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _secret = 'fixture-chap-secret-never-exposed';

String _importedKey(String format, {int seed = 17}) =>
    'DHHC-1:$format:${base64Encode(List.generate(switch (format) {
      '01' => 36,
      '02' => 52,
      _ => 68,
    }, (i) => (i + seed) % 256))}:';

NvmeHostAuthentication _clearTarget() =>
    NvmeHostAuthenticationInventory.project([
      {
        'id': 3,
        'hostnqn': 'nqn.2026-09.example:old',
        'dhchap_key': _secret,
        'dhchap_ctrl_key': _secret,
        'dhchap_dhgroup': '4096-BIT',
        'dhchap_hash': 'SHA-256',
      },
    ]).hosts.single;

_Wire _replacementWire() => _Wire(
  advertiseNvme: true,
  advertiseNvmeHostUpdate: true,
  advertiseNvmeHashes: true,
  advertiseNvmeGroups: true,
)..keyReplace = true;

class _ReplaceHarness {
  _ReplaceHarness({_Wire? wire}) : wire = wire ?? _replacementWire() {
    repo = TrueNasSessionRepository(
      connector: _Connector(this.wire),
      nvmeHostKeyNow: () => clock,
    );
  }
  final _Wire wire;
  late final TrueNasSessionRepository repo;
  DateTime clock = DateTime.utc(2026, 9, 28);
  Future<void> connect() async {
    addTearDown(repo.close);
    await repo.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
  }

  Future<NvmeHostAuthentication> replace(
    NvmeHostKeyReplacementReview review,
    NvmeHostKeyDraft keys, {
    String hash = 'SHA-384',
    String? group,
  }) => repo.replaceNvmeHostImportedKeys(
    review: review,
    hash: hash,
    group: group,
    keys: keys,
  );
  int get writes =>
      wire.requests.where((r) => r['method'] == 'nvmet.host.update').length;
}

void main() {
  group('protected NVMe key generation', () {
    test('secret-bearing RPC error is suppressed without retry', () async {
      final wire = _Wire(advertiseNvmeGenerate: true, advertiseNvmeHashes: true)
        ..generationFailure = true;
      final h = _ReplaceHarness(wire: wire);
      await h.connect();
      await expectLater(
        h.repo.generateNvmeHostKey(hash: 'SHA-256'),
        throwsA(
          isA<NvmeHostKeyGenerationException>().having(
            (e) => e.toString(),
            'safe error',
            isNot(contains(_secret)),
          ),
        ),
      );
      expect(
        wire.requests.where((r) => r['method'] == 'nvmet.host.generate_key'),
        hasLength(1),
      );
    });
    test('reconnection invalidates an old envelope', () async {
      final wires = List.generate(
        2,
        (_) => _Wire(advertiseNvmeGenerate: true, advertiseNvmeHashes: true),
      );
      final repo = TrueNasSessionRepository(
        connector: _RotatingConnector(wires),
      );
      addTearDown(repo.close);
      Future<void> connect() async {
        await repo.connect(
          serverInput: 'https://fixture.example',
          username: 'fixture-user',
          apiKey: 'fixture-key',
        );
      }

      await connect();
      final old = await repo.generateNvmeHostKey(hash: 'SHA-256');
      addTearDown(old.dispose);
      await connect();
      expect(
        () => old.takeForTransfer(acknowledgeSecretExposure: true),
        throwsA(isA<NvmeHostKeyGenerationException>()),
      );
      expect(old.isDisposed, true);
      final fresh = await repo.generateNvmeHostKey(hash: 'SHA-256');
      addTearDown(fresh.dispose);
      expect(
        fresh.takeForTransfer(acknowledgeSecretExposure: true),
        _importedKey('01'),
      );
    });
    for (final stage in ['hashes', 'generation']) {
      test(
        'disconnect during $stage discards late results without retry',
        () async {
          final gate = Completer<void>();
          final wire = _Wire(
            advertiseNvmeGenerate: true,
            advertiseNvmeHashes: true,
          );
          if (stage == 'hashes') {
            wire.pauseHashes = gate;
          } else {
            wire.pauseGeneration = gate;
          }
          final h = _ReplaceHarness(wire: wire);
          await h.connect();
          final future = h.repo.generateNvmeHostKey(hash: 'SHA-256');
          final rejected = expectLater(
            future,
            throwsA(isA<NvmeHostKeyGenerationException>()),
          );
          await (stage == 'hashes'
              ? wire.hashesStarted.future
              : wire.generationStarted.future);
          await h.repo.close();
          gate.complete();
          await rejected;
          expect(
            wire.requests.where(
              (r) => r['method'] == 'nvmet.host.generate_key',
            ),
            hasLength(stage == 'hashes' ? 0 : 1),
          );
        },
      );
    }
    for (final entry in {
      'SHA-256': '01',
      'SHA-384': '02',
      'SHA-512': '03',
    }.entries) {
      for (final nqn in [null, 'nqn.2026-09.example:initiator']) {
        test(
          '${entry.key} exact positional payload with optional NQN',
          () async {
            final wire = _Wire(
              advertiseNvmeGenerate: true,
              advertiseNvmeHashes: true,
            )..generatedKey = _importedKey(entry.value);
            final h = _ReplaceHarness(wire: wire);
            await h.connect();
            final key = await h.repo.generateNvmeHostKey(
              hash: entry.key,
              nqn: nqn,
            );
            addTearDown(key.dispose);
            expect(key.hash, entry.key);
            expect(key.nqn, nqn);
            expect(key.toString(), 'NvmeGeneratedHostKey(redacted)');
            expect(() => jsonEncode(key), throwsA(anything));
            expect(
              wire.requests
                  .where((r) => (r['method'] as String).startsWith('nvmet.'))
                  .map((r) => r['method']),
              ['nvmet.host.dhchap_hash_choices', 'nvmet.host.generate_key'],
            );
            expect(wire.requests.last['params'], [entry.key, nqn]);
            expect(
              () => key.takeForTransfer(acknowledgeSecretExposure: false),
              throwsA(isA<NvmeHostKeyGenerationException>()),
            );
            expect(key.isDisposed, false);
            expect(
              key.takeForTransfer(acknowledgeSecretExposure: true),
              wire.generatedKey,
            );
            expect(key.isDisposed, true);
            expect(
              () => key.takeForTransfer(acknowledgeSecretExposure: true),
              throwsA(isA<NvmeHostKeyGenerationException>()),
            );
            expect(
              h.repo.adminCatalog.method('nvmet.host.generate_key')?.supported,
              false,
            );
          },
        );
      }
    }
    for (final issue in [
      'method',
      'choices method',
      'version',
      'invalid hash',
      'invalid nqn',
      'subset',
      'malformed choices',
    ]) {
      test('$issue fails without generating', () async {
        final wire = _Wire(
          advertiseNvmeGenerate: issue != 'method',
          advertiseNvmeHashes: issue != 'choices method',
        );
        if (issue == 'version') wire.serverVersion = '25.04.2';
        if (issue == 'subset') wire.hashes = ['SHA-512'];
        if (issue == 'malformed choices') wire.hashes = [_secret];
        final h = _ReplaceHarness(wire: wire);
        await h.connect();
        await expectLater(
          h.repo.generateNvmeHostKey(
            hash: issue == 'invalid hash' ? _secret : 'SHA-256',
            nqn: issue == 'invalid nqn' ? _secret : null,
          ),
          throwsA(isA<NvmeHostKeyGenerationException>()),
        );
        expect(
          wire.requests.where((r) => r['method'] == 'nvmet.host.generate_key'),
          isEmpty,
        );
      });
    }
    for (final raw in [
      null,
      4,
      {'key': _secret},
      _secret,
      _importedKey('02'),
      'DHHC-1:00:AAAA:',
      'DHHC-1:01:AAAA:',
      '${_importedKey('01')}\n',
      '${_importedKey('01')}$_secret',
    ]) {
      test(
        'malformed or mismatched key ${raw.runtimeType} is suppressed',
        () async {
          final wire = _Wire(
            advertiseNvmeGenerate: true,
            advertiseNvmeHashes: true,
          )..generatedKey = raw;
          final h = _ReplaceHarness(wire: wire);
          await h.connect();
          try {
            await h.repo.generateNvmeHostKey(hash: 'SHA-256');
            fail('Expected safe rejection');
          } on NvmeHostKeyGenerationException catch (error) {
            expect(error.toString(), isNot(contains(_secret)));
            expect(error.toString(), isNot(contains('DHHC-1:')));
          }
          expect(
            wire.requests.where(
              (r) => r['method'] == 'nvmet.host.generate_key',
            ),
            hasLength(1),
          );
        },
      );
    }
    for (final action in ['dispose', 'close', 'expire', 'backwards']) {
      test('$action blocks secret transfer', () async {
        final h = _ReplaceHarness(
          wire: _Wire(advertiseNvmeGenerate: true, advertiseNvmeHashes: true),
        );
        await h.connect();
        final key = await h.repo.generateNvmeHostKey(hash: 'SHA-256');
        addTearDown(key.dispose);
        switch (action) {
          case 'dispose':
            key.dispose();
          case 'close':
            await h.repo.close();
          case 'expire':
            h.clock = h.clock.add(const Duration(minutes: 5));
          case 'backwards':
            h.clock = h.clock.subtract(const Duration(seconds: 1));
        }
        expect(
          () => key.takeForTransfer(acknowledgeSecretExposure: true),
          throwsA(isA<NvmeHostKeyGenerationException>()),
        );
        expect(key.isDisposed, true);
      });
    }
    test('disconnected repository cannot generate', () async {
      final wire = _Wire(
        advertiseNvmeGenerate: true,
        advertiseNvmeHashes: true,
      );
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await expectLater(
        repo.generateNvmeHostKey(hash: 'SHA-256'),
        throwsA(isA<NvmeHostKeyGenerationException>()),
      );
      expect(wire.requests, isEmpty);
    });
  });
  for (final oldAuthentication in [false, true]) {
    for (final controller in [false, true]) {
      test(
        'protected replacement preserves identity and verifies exact keys old=$oldAuthentication controller=$controller',
        () async {
          final h = _ReplaceHarness();
          if (oldAuthentication) {
            h.wire.hostRow.addAll({
              'dhchap_key': _secret,
              'dhchap_ctrl_key': _secret,
              'dhchap_dhgroup': '2048-BIT',
            });
          }
          await h.connect();
          final review = await h.repo.reviewNvmeHostKeyReplacement(3);
          addTearDown(review.dispose);
          expect(review.target.hostKeyReturned, oldAuthentication);
          expect(review.toString(), 'NvmeHostKeyReplacementReview(redacted)');
          expect(() => jsonEncode(review), throwsA(isA<Object>()));
          expect(h.writes, 0);
          final hostKey = _importedKey('01'),
              controllerKey = controller ? _importedKey('02') : null;
          final keys = NvmeHostKeyDraft.import(
            hostKey: hostKey,
            controllerKey: controllerKey,
          );
          final result = await h.replace(
            review,
            keys,
            group: controller ? '4096-BIT' : null,
          );
          expect(result.id, 3);
          expect(result.nqn, 'nqn.2026-09.example:old');
          expect(result.hash, 'SHA-384');
          expect(result.controllerKeyReturned, controller);
          expect(result.toString(), isNot(contains(hostKey)));
          expect(review.isDisposed, true);
          expect(keys.isDisposed, true);
          expect(h.writes, 1);
          final write = h.wire.requests.singleWhere(
            (r) => r['method'] == 'nvmet.host.update',
          );
          expect(write['params'], [
            3,
            {
              'dhchap_key': hostKey,
              'dhchap_ctrl_key': controllerKey,
              'dhchap_hash': 'SHA-384',
              'dhchap_dhgroup': controller ? '4096-BIT' : null,
            },
          ]);
          final reads = h.wire.requests
              .where(
                (r) =>
                    r['method'] == 'nvmet.host.query' &&
                    ((r['params'] as List).first as List).isNotEmpty,
              )
              .toList();
          expect(reads.length, 3);
          for (final r in reads) {
            expect((r['params'] as List).first, [
              ['id', '=', 3],
            ]);
            expect(((r['params'] as List).last as Map)['limit'], 2);
          }
          final next = NvmeHostKeyDraft.import(hostKey: hostKey);
          await expectLater(
            h.replace(review, next),
            throwsA(isA<NvmeHostException>()),
          );
          expect(next.isDisposed, true);
          expect(h.writes, 1);
        },
      );
    }
  }
  for (final change in [
    'host key',
    'controller key',
    'hash',
    'group',
    'NQN',
    'association',
    'other host',
    'expired',
    'clock backwards',
    'cancel',
    'unsupported hash',
    'unsupported group',
  ]) {
    test(
      'replacement preflight rejects $change and wipes owned objects',
      () async {
        final h = _ReplaceHarness();
        h.wire.hostRow.addAll({
          'dhchap_key': _secret,
          'dhchap_ctrl_key': _secret,
          'dhchap_dhgroup': '2048-BIT',
        });
        await h.connect();
        final review = await h.repo.reviewNvmeHostKeyReplacement(3);
        addTearDown(review.dispose);
        switch (change) {
          case 'host key':
            h.wire.hostRow['dhchap_key'] = _importedKey('01');
          case 'controller key':
            h.wire.hostRow['dhchap_ctrl_key'] = _importedKey('02');
          case 'hash':
            h.wire.hostRow['dhchap_hash'] = 'SHA-512';
          case 'group':
            h.wire.hostRow['dhchap_dhgroup'] = '8192-BIT';
          case 'NQN':
            h.wire.hostRow['hostnqn'] = 'nqn.2026-09.example:changed';
          case 'association':
            h.wire.replacementMappings.add({
              'id': 2,
              'host': {'id': 3},
              'subsys': {'id': 2},
            });
          case 'other host':
            h.wire.replacementOther['hostnqn'] = 'nqn.2026-09.example:changed';
          case 'expired':
            h.clock = h.clock.add(const Duration(minutes: 5));
          case 'clock backwards':
            h.clock = h.clock.subtract(const Duration(seconds: 1));
          case 'cancel':
            review.dispose();
          case 'unsupported hash':
            h.wire.hashes = ['SHA-256'];
          case 'unsupported group':
            h.wire.groups = [];
        }
        final keys = NvmeHostKeyDraft.import(hostKey: _importedKey('01'));
        await expectLater(
          h.replace(review, keys, group: '4096-BIT'),
          throwsA(
            isA<NvmeHostException>().having(
              (e) => e.toString(),
              'safe error',
              isNot(contains(_secret)),
            ),
          ),
        );
        expect(h.writes, 0);
        expect(keys.isDisposed, true);
        expect(review.isDisposed, true);
      },
    );
  }
  for (final failure in [
    'wrong ID',
    'wrong NQN',
    'wrong hash',
    'wrong group',
    'wrong host key',
    'wrong controller key',
    'redacted result',
    'missing field',
    'missing readback',
    'duplicate readback',
    'rotated readback',
    'redacted readback',
    'readback ID',
    'public drift',
    'new mapping',
  ]) {
    test(
      'replacement postwrite $failure rejects without retries or secret leaks',
      () async {
        final h = _ReplaceHarness();
        await h.connect();
        final review = await h.repo.reviewNvmeHostKeyReplacement(3);
        h.wire.keyReplaceFailure = failure;
        final keys = NvmeHostKeyDraft.import(
          hostKey: _importedKey('01'),
          controllerKey: _importedKey('02'),
        );
        await expectLater(
          h.replace(review, keys, group: '4096-BIT'),
          throwsA(
            isA<NvmeHostException>().having(
              (e) => e.toString(),
              'safe error',
              isNot(contains(_importedKey('01'))),
            ),
          ),
        );
        expect(h.writes, 1);
        expect(review.isDisposed, true);
        expect(keys.isDisposed, true);
        expect(
          h.wire.requests.where((r) => r['method'] == 'nvmet.host.create'),
          isEmpty,
        );
      },
    );
  }
  for (final issue in [
    'mapping',
    'duplicate NQN',
    'missing target',
    'inconsistent credentials',
    'invalid ID',
  ]) {
    test('replacement review rejects $issue without writes', () async {
      final h = _ReplaceHarness();
      switch (issue) {
        case 'mapping':
          h.wire.replacementMappings.add({
            'id': 2,
            'host': {'id': 3},
            'subsys': {'id': 2},
          });
        case 'duplicate NQN':
          h.wire.replacementOther['hostnqn'] = h.wire.hostRow['hostnqn'];
        case 'missing target':
          h.wire.hostRow['id'] = 99;
        case 'inconsistent credentials':
          h.wire.hostRow['dhchap_ctrl_key'] = _secret;
      }
      await h.connect();
      await expectLater(
        h.repo.reviewNvmeHostKeyReplacement(issue == 'invalid ID' ? 0 : 3),
        throwsA(isA<NvmeHostException>()),
      );
      expect(h.writes, 0);
    });
  }
  test('foreign repository cannot consume review or original draft', () async {
    final h = _ReplaceHarness(), other = _ReplaceHarness();
    await h.connect();
    await other.connect();
    final review = await h.repo.reviewNvmeHostKeyReplacement(3);
    final foreignKeys = NvmeHostKeyDraft.import(hostKey: _importedKey('01'));
    await expectLater(
      other.replace(review, foreignKeys),
      throwsA(isA<NvmeHostException>()),
    );
    expect(foreignKeys.isDisposed, true);
    expect(review.isDisposed, false);
    final keys = NvmeHostKeyDraft.import(hostKey: _importedKey('01'));
    await h.replace(review, keys);
    expect(h.writes, 1);
    expect(other.writes, 0);
  });
  test(
    'concurrent reuse cannot wipe in-flight replacement proof or draft',
    () async {
      final h = _ReplaceHarness();
      await h.connect();
      final review = await h.repo.reviewNvmeHostKeyReplacement(3);
      final keys = NvmeHostKeyDraft.import(hostKey: _importedKey('01'));
      h.wire.pauseHashes = Completer<void>();
      final pending = h.replace(review, keys);
      await h.wire.hashesStarted.future;
      await expectLater(
        h.replace(review, keys),
        throwsA(isA<NvmeHostException>()),
      );
      final otherKeys = NvmeHostKeyDraft.import(hostKey: _importedKey('01'));
      await expectLater(
        h.replace(review, otherKeys),
        throwsA(isA<NvmeHostException>()),
      );
      expect(keys.isDisposed, false);
      expect(review.isDisposed, false);
      expect(otherKeys.isDisposed, true);
      h.wire.pauseHashes!.complete();
      await pending;
      expect(keys.isDisposed, true);
      expect(review.isDisposed, true);
      expect(h.writes, 1);
    },
  );
  test('review expiry during algorithm discovery prevents dispatch', () async {
    final h = _ReplaceHarness();
    await h.connect();
    final review = await h.repo.reviewNvmeHostKeyReplacement(3);
    final keys = NvmeHostKeyDraft.import(hostKey: _importedKey('01'));
    h.wire.pauseHashes = Completer<void>();
    final pending = h.replace(review, keys);
    await h.wire.hashesStarted.future;
    h.clock = h.clock.add(const Duration(minutes: 5));
    h.wire.pauseHashes!.complete();
    await expectLater(pending, throwsA(isA<NvmeHostException>()));
    expect(h.writes, 0);
    expect(keys.isDisposed, true);
    expect(review.isDisposed, true);
  });
  for (final issue in [
    'no update',
    'no query',
    'no mappings',
    'no hashes',
    'no groups',
    'version',
  ]) {
    test('replacement requires advertised capability: $issue', () async {
      final wire = _Wire(
        advertiseNvme: issue != 'no query',
        advertiseNvmeMapping: issue != 'no mappings',
        advertiseNvmeHostUpdate: issue != 'no update',
        advertiseNvmeHashes: issue != 'no hashes',
        advertiseNvmeGroups: issue != 'no groups',
      )..keyReplace = true;
      if (issue == 'version') wire.serverVersion = '24.10.2';
      final h = _ReplaceHarness(wire: wire);
      await h.connect();
      await expectLater(
        h.repo.reviewNvmeHostKeyReplacement(3),
        throwsA(isA<NvmeHostException>()),
      );
      expect(
        wire.requests.where(
          (r) => (r['method'] as String).startsWith('nvmet.'),
        ),
        isEmpty,
      );
    });
  }
  for (final issue in ['review cancelled', 'keys cancelled']) {
    test('replacement $issue during preflight sends nothing', () async {
      final h = _ReplaceHarness();
      await h.connect();
      final review = await h.repo.reviewNvmeHostKeyReplacement(3);
      final keys = NvmeHostKeyDraft.import(hostKey: _importedKey('01'));
      h.wire.pauseHashes = Completer<void>();
      final pending = h.replace(review, keys);
      await h.wire.hashesStarted.future;
      if (issue == 'review cancelled') {
        review.dispose();
      } else {
        keys.dispose();
      }
      h.wire.pauseHashes!.complete();
      await expectLater(pending, throwsA(isA<NvmeHostException>()));
      expect(h.writes, 0);
      expect(keys.isDisposed, true);
      expect(review.isDisposed, true);
    });
  }
  test(
    'reconnection rejects previous connection review without consuming it',
    () async {
      final old = _replacementWire(), fresh = _replacementWire();
      final connector = _RotatingConnector([old, fresh]);
      final repo = TrueNasSessionRepository(connector: connector);
      addTearDown(repo.close);
      Future<void> connect() => repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      await connect();
      final review = await repo.reviewNvmeHostKeyReplacement(3);
      addTearDown(review.dispose);
      await connect();
      final keys = NvmeHostKeyDraft.import(hostKey: _importedKey('01'));
      await expectLater(
        repo.replaceNvmeHostImportedKeys(
          review: review,
          hash: 'SHA-256',
          group: null,
          keys: keys,
        ),
        throwsA(isA<NvmeHostException>()),
      );
      expect(keys.isDisposed, true);
      expect(review.isDisposed, false);
      expect(
        fresh.requests.where(
          (r) => (r['method'] as String).startsWith('nvmet.'),
        ),
        isEmpty,
      );
    },
  );
  for (final issue in [
    'missing field',
    'bad key shape',
    'duplicate IDs',
    'inventory boundary',
  ]) {
    test('replacement review rejects malformed $issue', () async {
      final h = _ReplaceHarness();
      await h.connect();
      if (issue == 'missing field') h.wire.hostRow.remove('dhchap_key');
      if (issue == 'bad key shape') {
        h.wire.hostRow['dhchap_key'] = {'secret': _secret};
      }
      if (issue == 'duplicate IDs') h.wire.replacementOther['id'] = 3;
      if (issue == 'inventory boundary') {
        h.wire.overrideHostQuery = true;
        h.wire.hostQueryResult = [
          for (var id = 1; id <= 101; id++)
            {'id': id, 'hostnqn': 'nqn.2026-09.example:$id'},
        ];
      }
      await expectLater(
        h.repo.reviewNvmeHostKeyReplacement(3),
        throwsA(isA<NvmeHostException>()),
      );
      expect(h.writes, 0);
    });
  }
  for (final issue in ['bad hash', 'bad group', 'disposed keys']) {
    test(
      'replacement invalid input $issue is consumed without dispatch',
      () async {
        final h = _ReplaceHarness();
        await h.connect();
        final review = await h.repo.reviewNvmeHostKeyReplacement(3);
        addTearDown(review.dispose);
        final keys = NvmeHostKeyDraft.import(hostKey: _importedKey('01'));
        if (issue == 'disposed keys') keys.dispose();
        await expectLater(
          h.replace(
            review,
            keys,
            hash: issue == 'bad hash' ? 'MD5' : 'SHA-256',
            group: issue == 'bad group' ? 'bad' : null,
          ),
          throwsA(isA<NvmeHostException>()),
        );
        expect(h.writes, 0);
        expect(keys.isDisposed, true);
        // Failure to claim an already consumed draft must not consume a review.
        expect(review.isDisposed, issue != 'disposed keys');
      },
    );
  }
  for (final format in ['01', '02', '03']) {
    test(
      'opaque imported-key draft supports format $format and idempotent disposal',
      () {
        final input = _importedKey(format);
        final draft = NvmeHostKeyDraft.import(
          hostKey: input,
          controllerKey: input,
        );
        expect(draft.hasControllerKey, true);
        expect(draft.isDisposed, false);
        expect(draft.toString(), isNot(contains(input)));
        expect(() => jsonEncode(draft), throwsA(isA<Object>()));
        draft.dispose();
        draft.dispose();
        expect(draft.isDisposed, true);
        expect(draft.toString(), 'NvmeHostKeyDraft(redacted)');
      },
    );
  }
  for (final input in [
    '',
    _secret,
    'DHHC-1:00:AAAA:',
    'DHHC-1:04:AAAA:',
    'DHHC-1:01:AAAA:',
    ' ${_importedKey('01')}',
    '${_importedKey('01')}\n',
    '${_importedKey('01')}:',
    _importedKey('01').replaceAll(':', '%3A'),
    'DHHC-1:01:${base64Encode(List.filled(36, 0)).replaceAll('A', '_')}:',
  ]) {
    test(
      'invalid imported-key structure length ${input.length} is safely rejected',
      () {
        expect(
          () => NvmeHostKeyDraft.import(hostKey: input),
          throwsA(
            isA<FormatException>().having(
              (e) => e.toString(),
              'safe',
              isNot(contains(input.isEmpty ? _secret : input)),
            ),
          ),
        );
        expect(
          () => NvmeHostKeyDraft.import(
            hostKey: _importedKey('01'),
            controllerKey: input,
          ),
          throwsFormatException,
        );
      },
    );
  }
  for (final controller in [false, true]) {
    test(
      'imported-key registration privately verifies exact saved keys controller=$controller',
      () async {
        final wire = _Wire(
          advertiseNvme: true,
          advertiseNvmeHostCreate: true,
          advertiseNvmeHashes: true,
          advertiseNvmeGroups: true,
        )..keyCreate = true;
        final repo = TrueNasSessionRepository(connector: _Connector(wire));
        addTearDown(repo.close);
        await repo.connect(
          serverInput: 'https://fixture.example',
          username: 'fixture-user',
          apiKey: 'fixture-key',
        );
        final hostKey = _importedKey('01');
        final controllerKey = controller ? _importedKey('02') : null;
        final draft = NvmeHostKeyDraft.import(
          hostKey: hostKey,
          controllerKey: controllerKey,
        );
        final result = await repo.createNvmeHostWithImportedKeys(
          hostNqn: 'nqn.2026-09.example:new',
          hash: 'SHA-384',
          group: controller ? '4096-BIT' : null,
          keys: draft,
        );
        expect(
          [
            result.id,
            result.nqn,
            result.hash,
            result.group,
            result.hostKeyReturned,
            result.controllerKeyReturned,
          ],
          [
            11,
            'nqn.2026-09.example:new',
            'SHA-384',
            controller ? '4096-BIT' : null,
            true,
            controller,
          ],
        );
        expect(result.toString(), isNot(contains(hostKey)));
        expect(draft.isDisposed, true);
        final create = wire.requests.singleWhere(
          (r) => r['method'] == 'nvmet.host.create',
        );
        expect(create['params'], [
          {
            'hostnqn': 'nqn.2026-09.example:new',
            'dhchap_key': hostKey,
            'dhchap_ctrl_key': controllerKey,
            'dhchap_hash': 'SHA-384',
            'dhchap_dhgroup': controller ? '4096-BIT' : null,
          },
        ]);
        expect(
          wire.requests.where(
            (r) =>
                (r['method'] as String).startsWith('nvmet.') &&
                r['method'] != 'nvmet.host.create' &&
                !(r['method'] as String).endsWith('.query') &&
                !(r['method'] as String).endsWith('_choices'),
          ),
          isEmpty,
        );
        final readsBeforeRetry = wire.requests.length;
        await expectLater(
          repo.createNvmeHostWithImportedKeys(
            hostNqn: 'nqn.2026-09.example:retry',
            hash: 'SHA-384',
            group: null,
            keys: draft,
          ),
          throwsA(isA<NvmeHostException>()),
        );
        expect(wire.requests.length, readsBeforeRetry);
      },
    );
  }
  for (final failure in [
    'existing ID',
    'wrong NQN',
    'wrong hash',
    'wrong group',
    'wrong host key',
    'wrong controller key',
    'redacted result',
    'missing result field',
    'missing readback',
    'duplicate readback',
    'rotated readback',
    'readback ID',
    'redacted readback',
    'identity drift',
    'missing public host',
    'new mapping',
  ]) {
    test(
      'imported-key registration $failure rejects after one create and disposes secrets',
      () async {
        final wire =
            _Wire(
                advertiseNvme: true,
                advertiseNvmeHostCreate: true,
                advertiseNvmeHashes: true,
                advertiseNvmeGroups: true,
              )
              ..keyCreate = true
              ..keyCreateFailure = failure;
        final repo = TrueNasSessionRepository(connector: _Connector(wire));
        addTearDown(repo.close);
        await repo.connect(
          serverInput: 'https://fixture.example',
          username: 'fixture-user',
          apiKey: 'fixture-key',
        );
        final draft = NvmeHostKeyDraft.import(
          hostKey: _importedKey('01'),
          controllerKey: _importedKey('02'),
        );
        await expectLater(
          repo.createNvmeHostWithImportedKeys(
            hostNqn: 'nqn.2026-09.example:new',
            hash: 'SHA-384',
            group: '4096-BIT',
            keys: draft,
          ),
          throwsA(isA<NvmeHostException>()),
        );
        expect(
          wire.requests.where((r) => r['method'] == 'nvmet.host.create'),
          hasLength(1),
        );
        expect(draft.isDisposed, true);
      },
    );
  }
  for (final failure in [
    'duplicate inventory',
    'duplicate NQN',
    'missing create',
    'missing choices',
    'missing mapping',
    'hash choice',
    'group choice',
    'bad NQN',
  ]) {
    test(
      'imported-key registration $failure rejects without writes and disposes draft',
      () async {
        final wire =
            _Wire(
                advertiseNvme: true,
                advertiseNvmeHostCreate: failure != 'missing create',
                advertiseNvmeHashes: failure != 'missing choices',
                advertiseNvmeGroups: true,
                advertiseNvmeMapping: failure != 'missing mapping',
              )
              ..keyCreate = true
              ..keyCreateFailure = failure;
        if (failure == 'duplicate NQN') {
          wire.hostRow['hostnqn'] = 'NQN.2026-09.EXAMPLE:NEW';
        }
        if (failure == 'hash choice') wire.hashes = ['SHA-256'];
        if (failure == 'group choice') wire.groups = ['2048-BIT'];
        final repo = TrueNasSessionRepository(connector: _Connector(wire));
        addTearDown(repo.close);
        await repo.connect(
          serverInput: 'https://fixture.example',
          username: 'fixture-user',
          apiKey: 'fixture-key',
        );
        final draft = NvmeHostKeyDraft.import(hostKey: _importedKey('01'));
        await expectLater(
          repo.createNvmeHostWithImportedKeys(
            hostNqn: failure == 'bad NQN' ? _secret : 'nqn.2026-09.example:new',
            hash: 'SHA-384',
            group: '4096-BIT',
            keys: draft,
          ),
          throwsA(isA<NvmeHostException>()),
        );
        expect(
          wire.requests.where((r) => r['method'] == 'nvmet.host.create'),
          isEmpty,
        );
        expect(draft.isDisposed, true);
      },
    );
  }
  test(
    'concurrent draft reuse cannot dispose the first in-flight import',
    () async {
      final wire =
          _Wire(
              advertiseNvme: true,
              advertiseNvmeHostCreate: true,
              advertiseNvmeHashes: true,
              advertiseNvmeGroups: true,
            )
            ..keyCreate = true
            ..pauseHashes = Completer<void>();
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      final draft = NvmeHostKeyDraft.import(hostKey: _importedKey('01'));
      final first = repo.createNvmeHostWithImportedKeys(
        hostNqn: 'nqn.2026-09.example:new',
        hash: 'SHA-384',
        group: null,
        keys: draft,
      );
      await wire.hashesStarted.future;
      await expectLater(
        repo.createNvmeHostWithImportedKeys(
          hostNqn: 'nqn.2026-09.example:second',
          hash: 'SHA-384',
          group: null,
          keys: draft,
        ),
        throwsA(isA<NvmeHostException>()),
      );
      expect(draft.isDisposed, false);
      wire.pauseHashes!.complete();
      expect((await first).id, 11);
      expect(draft.isDisposed, true);
      expect(
        wire.requests.where((r) => r['method'] == 'nvmet.host.create'),
        hasLength(1),
      );
    },
  );
  for (final raw in <Object?>[
    null,
    _secret,
    <Object?>[],
    [_secret, _secret],
  ]) {
    test(
      'exact authentication target rejects incomplete shape ${raw.runtimeType} ${raw is List ? raw.length : 0}',
      () async {
        final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true)
          ..overrideHostQuery = true
          ..hostQueryResult = raw;
        final repo = TrueNasSessionRepository(connector: _Connector(wire));
        addTearDown(repo.close);
        await repo.connect(
          serverInput: 'https://fixture.example',
          username: 'fixture-user',
          apiKey: 'fixture-key',
        );
        await expectLater(
          repo.loadNvmeHostAuthenticationTarget(3),
          throwsA(
            isA<NvmeHostException>().having(
              (e) => e.toString(),
              'safe error',
              isNot(contains(_secret)),
            ),
          ),
        );
        expect(
          wire.requests.where((r) => r['method'] == 'nvmet.host.update'),
          isEmpty,
        );
      },
    );
  }
  for (final id in [0, -1]) {
    test('invalid authentication target ID $id sends no read', () async {
      final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true);
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      await expectLater(
        repo.loadNvmeHostAuthenticationTarget(id),
        throwsA(isA<NvmeHostException>()),
      );
      expect(
        wire.requests.where(
          (r) => (r['method'] as String).startsWith('nvmet.'),
        ),
        isEmpty,
      );
    });
  }
  test(
    'disconnected authentication clearing never sends NVMe requests',
    () async {
      final wire = _Wire();
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await expectLater(
        repo.clearNvmeHostAuthentication(expected: _clearTarget()),
        throwsA(isA<NvmeHostException>()),
      );
      await expectLater(
        repo.loadNvmeHostAuthenticationTarget(3),
        throwsA(isA<NvmeHostException>()),
      );
      expect(wire.requests, isEmpty);
    },
  );
  test('protected authentication clearing sends only three nulls and strips all key values', () async {
    final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true);
    wire.hostRow.addAll({
      'dhchap_key': _secret,
      'dhchap_ctrl_key': _secret,
      'dhchap_dhgroup': '4096-BIT',
    });
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    await repo.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    final before = await repo.loadNvmeHostAuthenticationTarget(3);
    expect(before.sameReturnedSettings(_clearTarget()), true);
    expect(before.toString(), isNot(contains(_secret)));
    final cleared = await repo.clearNvmeHostAuthentication(expected: before);
    expect(
      [
        cleared.id,
        cleared.nqn,
        cleared.hash,
        cleared.hasReturnedAuthentication,
      ],
      [3, 'nqn.2026-09.example:old', 'SHA-256', false],
    );
    expect(cleared.toString(), isNot(contains(_secret)));
    final write = wire.requests.singleWhere(
      (r) => r['method'] == 'nvmet.host.update',
    );
    expect(write['params'], [
      3,
      {'dhchap_key': null, 'dhchap_ctrl_key': null, 'dhchap_dhgroup': null},
    ]);
    for (final read in wire.requests.where(
      (r) => r['method'] == 'nvmet.host.query',
    )) {
      expect(read['params'], [
        [
          ['id', '=', 3],
        ],
        {
          'select': [
            'id',
            'hostnqn',
            'dhchap_key',
            'dhchap_ctrl_key',
            'dhchap_dhgroup',
            'dhchap_hash',
          ],
          'limit': 2,
        },
      ]);
    }
    expect(
      wire.requests
          .where((r) => (r['method'] as String).startsWith('nvmet.'))
          .map((r) => r['method']),
      ['nvmet.host.query', 'nvmet.host.query', 'nvmet.host.update'],
    );
  });
  for (final changed in [
    'id',
    'hostnqn',
    'dhchap_hash',
    'dhchap_key',
    'dhchap_ctrl_key',
    'dhchap_dhgroup',
    'missing key',
    'invalid key',
    'missing update',
    'missing query',
  ]) {
    test('clearing SDK rejects $changed before writing', () async {
      final wire = _Wire(
        advertiseNvme: changed != 'missing query',
        advertiseNvmeHostUpdate: changed != 'missing update',
      );
      wire.hostRow.addAll({
        'dhchap_key': _secret,
        'dhchap_ctrl_key': _secret,
        'dhchap_dhgroup': '4096-BIT',
      });
      switch (changed) {
        case 'id':
          wire.hostRow['id'] = 999;
        case 'hostnqn':
          wire.hostRow['hostnqn'] = 'nqn.2026-09.example:other';
        case 'dhchap_hash':
          wire.hostRow['dhchap_hash'] = 'SHA-512';
        case 'dhchap_key':
          wire.hostRow['dhchap_key'] = null;
        case 'dhchap_ctrl_key':
          wire.hostRow['dhchap_ctrl_key'] = null;
        case 'dhchap_dhgroup':
          wire.hostRow['dhchap_dhgroup'] = '8192-BIT';
        case 'missing key':
          wire.hostRow.remove('dhchap_key');
        case 'invalid key':
          wire.hostRow['dhchap_key'] = {'unexpected_private': _secret};
      }
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      await expectLater(
        repo.clearNvmeHostAuthentication(expected: _clearTarget()),
        throwsA(
          isA<NvmeHostException>().having(
            (e) => e.toString(),
            'safe error',
            isNot(contains(_secret)),
          ),
        ),
      );
      expect(
        wire.requests.where((r) => r['method'] == 'nvmet.host.update'),
        isEmpty,
      );
    });
  }
  for (final failure in [
    'auth after update',
    'controller after update',
    'group after update',
    'hash after update',
    'ID after update',
    'NQN after update',
  ]) {
    test('clearing SDK rejects $failure after one update', () async {
      final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true)
        ..renameFailure = failure;
      wire.hostRow.addAll({
        'dhchap_key': _secret,
        'dhchap_ctrl_key': _secret,
        'dhchap_dhgroup': '4096-BIT',
      });
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      await expectLater(
        repo.clearNvmeHostAuthentication(expected: _clearTarget()),
        throwsA(isA<NvmeHostException>()),
      );
      expect(
        wire.requests.where((r) => r['method'] == 'nvmet.host.update'),
        hasLength(1),
      );
    });
  }
  test(
    'unset expected metadata rejects clearing without a host read',
    () async {
      final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true);
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      const unset = NvmeHostAuthentication(
        id: 3,
        nqn: 'nqn.2026-09.example:old',
        hash: 'SHA-256',
        group: null,
        hostKeyReturned: false,
        controllerKeyReturned: false,
      );
      await expectLater(
        repo.clearNvmeHostAuthentication(expected: unset),
        throwsA(isA<NvmeHostException>()),
      );
      expect(
        wire.requests.where(
          (r) => (r['method'] as String).startsWith('nvmet.'),
        ),
        isEmpty,
      );
    },
  );
  for (final input in [
    (0, 'SHA-256', 'SHA-384'),
    (-1, 'SHA-256', 'SHA-384'),
    (3, 'SHA-1', 'SHA-384'),
    (3, 'SHA-256', 'sha-384'),
    (3, 'SHA-256', 'SHA-256'),
  ]) {
    test('invalid hash SDK input $input sends no NVMe request', () async {
      final wire = _Wire(
        advertiseNvme: true,
        advertiseNvmeHostUpdate: true,
        advertiseNvmeHashes: true,
        advertiseNvmeGroups: true,
      );
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      await expectLater(
        repo.changeUncredentialedNvmeHostHash(
          id: input.$1,
          expectedNqn: 'nqn.2026-09.example:old',
          expectedHash: input.$2,
          newHash: input.$3,
        ),
        throwsA(isA<NvmeHostException>()),
      );
      expect(
        wire.requests.where(
          (r) => (r['method'] as String).startsWith('nvmet.'),
        ),
        isEmpty,
      );
    });
  }
  test(
    'hash-only SDK update privately preflights keys and preserves NQN',
    () async {
      final wire = _Wire(
        advertiseNvme: true,
        advertiseNvmeHostUpdate: true,
        advertiseNvmeHashes: true,
        advertiseNvmeGroups: true,
      );
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      final host = await repo.changeUncredentialedNvmeHostHash(
        id: 3,
        expectedNqn: 'nqn.2026-09.example:old',
        expectedHash: 'SHA-256',
        newHash: 'SHA-384',
      );
      expect(
        [host.id, host.nqn, host.hash],
        [3, 'nqn.2026-09.example:old', 'SHA-384'],
      );
      final write = wire.requests.singleWhere(
        (r) => r['method'] == 'nvmet.host.update',
      );
      expect(write['params'], [
        3,
        {'dhchap_hash': 'SHA-384'},
      ]);
      expect(host.toString(), isNot(contains(_secret)));
      expect(
        wire.requests
            .where((r) => (r['method'] as String).startsWith('nvmet.'))
            .map((r) => r['method']),
        [
          'nvmet.host.dhchap_hash_choices',
          'nvmet.host.dhchap_dhgroup_choices',
          'nvmet.host.query',
          'nvmet.host.update',
        ],
      );
    },
  );
  for (final change in [
    'dhchap_key',
    'dhchap_ctrl_key',
    'dhchap_dhgroup',
    'id',
    'hostnqn',
    'dhchap_hash',
    'choices',
    'malformed choices',
    'missing choices',
    'missing update',
  ]) {
    test('hash SDK rejects $change before writing', () async {
      final wire = _Wire(
        advertiseNvme: true,
        advertiseNvmeHostUpdate: change != 'missing update',
        advertiseNvmeHashes: change != 'missing choices',
        advertiseNvmeGroups: true,
      );
      if (wire.hostRow.containsKey(change)) {
        wire.hostRow[change] = switch (change) {
          'id' => 999,
          'dhchap_dhgroup' => '4096-BIT',
          'dhchap_hash' => 'SHA-512',
          _ => _secret,
        };
      }
      if (change == 'choices') wire.hashes = ['SHA-256'];
      if (change == 'malformed choices') wire.hashes = [_secret];
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      await expectLater(
        repo.changeUncredentialedNvmeHostHash(
          id: 3,
          expectedNqn: 'nqn.2026-09.example:old',
          expectedHash: 'SHA-256',
          newHash: 'SHA-384',
        ),
        throwsA(
          isA<NvmeHostException>().having(
            (e) => e.toString(),
            'safe',
            isNot(contains(_secret)),
          ),
        ),
      );
      expect(
        wire.requests.where((r) => r['method'] == 'nvmet.host.update'),
        isEmpty,
      );
    });
  }
  for (final failure in [
    'auth after update',
    'hash after update',
    'ID after update',
    'NQN after update',
  ]) {
    test(
      'hash SDK rejects unsafe returned fields $failure after exactly one write',
      () async {
        final wire = _Wire(
          advertiseNvme: true,
          advertiseNvmeHostUpdate: true,
          advertiseNvmeHashes: true,
          advertiseNvmeGroups: true,
        )..renameFailure = failure;
        final repo = TrueNasSessionRepository(connector: _Connector(wire));
        addTearDown(repo.close);
        await repo.connect(
          serverInput: 'https://fixture.example',
          username: 'fixture-user',
          apiKey: 'fixture-key',
        );
        await expectLater(
          repo.changeUncredentialedNvmeHostHash(
            id: 3,
            expectedNqn: 'nqn.2026-09.example:old',
            expectedHash: 'SHA-256',
            newHash: 'SHA-384',
          ),
          throwsA(isA<NvmeHostException>()),
        );
        expect(
          wire.requests.where((r) => r['method'] == 'nvmet.host.update'),
          hasLength(1),
        );
      },
    );
  }
  test(
    'algorithm discovery calls only two public parameterless reads',
    () async {
      final wire = _Wire(advertiseNvmeHashes: true, advertiseNvmeGroups: true)
        ..hashes = ['SHA-512', 'SHA-256']
        ..groups = ['8192-BIT'];
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      final value = await repo.loadNvmeHostAuthenticationChoices();
      expect(value.hashes, ['SHA-512', 'SHA-256']);
      expect(value.groups, ['8192-BIT']);
      expect(() => value.hashes.clear(), throwsUnsupportedError);
      expect(() => value.groups.clear(), throwsUnsupportedError);
      final calls = wire.requests
          .where((r) => (r['method'] as String).startsWith('nvmet.'))
          .toList();
      expect(calls.map((r) => r['method']), [
        'nvmet.host.dhchap_hash_choices',
        'nvmet.host.dhchap_dhgroup_choices',
      ]);
      for (final call in calls) {
        expect(call['params'], isEmpty);
      }
      for (final method in [
        'nvmet.host.dhchap_hash_choices',
        'nvmet.host.dhchap_dhgroup_choices',
      ]) {
        expect(repo.adminCatalog.method(method)?.supported, true);
      }
    },
  );
  for (final support in [(false, false), (true, false), (false, true)]) {
    test(
      'incomplete advertised algorithm support $support sends no reads',
      () async {
        final wire = _Wire(
          advertiseNvmeHashes: support.$1,
          advertiseNvmeGroups: support.$2,
        );
        final repo = TrueNasSessionRepository(connector: _Connector(wire));
        addTearDown(repo.close);
        await repo.connect(
          serverInput: 'https://fixture.example',
          username: 'fixture-user',
          apiKey: 'fixture-key',
        );
        await expectLater(
          repo.loadNvmeHostAuthenticationChoices(),
          throwsA(isA<NvmeHostChoicesException>()),
        );
        expect(
          wire.requests.where(
            (r) => (r['method'] as String).startsWith('nvmet.'),
          ),
          isEmpty,
        );
      },
    );
  }
  test('algorithm projection rejects duplicates unknown values and malformed shapes', () {
    for (final malformed in <Object?>[
      null,
      {},
      'SHA-256',
      [null],
      [256],
      [_secret],
      ['SHA-256', 'SHA-256'],
      ['SHA-256', 'SHA-384', 'SHA-512', 'SHA-256'],
    ]) {
      expect(
        () => NvmeHostAuthenticationChoices.project(malformed, []),
        throwsFormatException,
      );
    }
    for (final malformed in <Object?>[
      null,
      {},
      '2048-BIT',
      [null],
      [2048],
      [_secret],
      ['2048-BIT', '2048-BIT'],
      List.filled(6, '8192-BIT'),
    ]) {
      expect(
        () => NvmeHostAuthenticationChoices.project([], malformed),
        throwsFormatException,
      );
    }
    final empty = NvmeHostAuthenticationChoices.project([], []);
    expect(empty.hashes, isEmpty);
    expect(empty.groups, isEmpty);
  });
  test(
    'malformed algorithm wire result returns a fixed sanitized error',
    () async {
      final wire = _Wire(advertiseNvmeHashes: true, advertiseNvmeGroups: true)
        ..groups = [_secret];
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      await expectLater(
        repo.loadNvmeHostAuthenticationChoices(),
        throwsA(
          isA<NvmeHostChoicesException>().having(
            (e) => e.toString(),
            'safe error',
            isNot(contains(_secret)),
          ),
        ),
      );
    },
  );
  test('authentication inventory wire selects bounded fields and strips key values', () async {
    final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true);
    wire.hostRow['dhchap_key'] = _secret;
    wire.hostRow['dhchap_ctrl_key'] = _secret;
    wire.hostRow['dhchap_dhgroup'] = '4096-BIT';
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    await repo.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    final inventory = await repo.loadNvmeHostAuthentication();
    final host = inventory.hosts.single;
    expect(
      [
        host.id,
        host.nqn,
        host.hostKeyReturned,
        host.controllerKeyReturned,
        host.group,
        host.hash,
      ],
      [3, 'nqn.2026-09.example:old', true, true, '4096-BIT', 'SHA-256'],
    );
    expect(host.inconsistent, false);
    expect(host.toString(), isNot(contains(_secret)));
    expect(() => inventory.hosts.clear(), throwsUnsupportedError);
    final read = wire.requests.singleWhere(
      (r) => r['method'] == 'nvmet.host.query',
    );
    expect(read['params'], [
      [],
      {
        'select': [
          'id',
          'hostnqn',
          'dhchap_key',
          'dhchap_ctrl_key',
          'dhchap_dhgroup',
          'dhchap_hash',
        ],
        'limit': 101,
      },
    ]);
    expect(
      wire.requests.where(
        (r) =>
            (r['method'] as String).startsWith('nvmet.host') &&
            r['method'] != 'nvmet.host.query',
      ),
      isEmpty,
    );
  });
  test('unadvertised authentication inventory sends no host query', () async {
    final wire = _Wire();
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    await repo.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    await expectLater(
      repo.loadNvmeHostAuthentication(),
      throwsA(isA<NvmeHostException>()),
    );
    expect(
      wire.requests.where((r) => r['method'] == 'nvmet.host.query'),
      isEmpty,
    );
  });
  test('authentication projection distinguishes returned null nonempty and inconsistent fields', () {
    Map<String, Object?> row(int id) => {
      'id': id,
      'hostnqn': 'nqn.fixture:host$id',
      'dhchap_key': null,
      'dhchap_ctrl_key': null,
      'dhchap_dhgroup': null,
      'dhchap_hash': 'SHA-256',
    };
    final rows = NvmeHostAuthenticationInventory.project([
      row(1),
      {...row(2), 'dhchap_key': _secret},
      {...row(3), 'dhchap_key': _secret, 'dhchap_ctrl_key': _secret},
      {...row(4), 'dhchap_ctrl_key': _secret},
      {...row(5), 'dhchap_dhgroup': '2048-BIT'},
    ]).hosts;
    expect(rows.map((h) => h.inconsistent), [false, false, false, true, true]);
    expect(rows.map((h) => h.hostKeyReturned), [
      false,
      true,
      true,
      false,
      false,
    ]);
    expect(rows.toString(), isNot(contains(_secret)));
  });
  test('authentication projection rejects truncated missing malformed and duplicate metadata', () {
    final row = <String, Object?>{
      'id': 1,
      'hostnqn': 'nqn.fixture:host',
      'dhchap_key': null,
      'dhchap_ctrl_key': null,
      'dhchap_dhgroup': null,
      'dhchap_hash': 'SHA-256',
    };
    for (final key in row.keys) {
      expect(
        () =>
            NvmeHostAuthenticationInventory.project([Map.of(row)..remove(key)]),
        throwsFormatException,
      );
    }
    for (final key in ['dhchap_key', 'dhchap_ctrl_key']) {
      for (final value in ['', 1, false, 'bad\n', 'x' * 513]) {
        expect(
          () => NvmeHostAuthenticationInventory.project([
            {...row, key: value},
          ]),
          throwsFormatException,
        );
      }
    }
    for (final key in ['dhchap_hash', 'dhchap_dhgroup']) {
      expect(
        () => NvmeHostAuthenticationInventory.project([
          {...row, key: _secret},
        ]),
        throwsFormatException,
      );
    }
    for (final raw in [
      null,
      {},
      [row, row],
      List.filled(101, row),
    ]) {
      expect(
        () => NvmeHostAuthenticationInventory.project(raw),
        throwsFormatException,
      );
    }
    expect(NvmeHostAuthenticationInventory.project([]).hosts, isEmpty);
  });
  test(
    'protected host NQN edit selects one ID and sends only hostnqn',
    () async {
      final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true);
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      final before = await repo.loadUncredentialedNvmeHost(3);
      expect(
        [before.id, before.nqn, before.hash],
        [3, 'nqn.2026-09.example:old', 'SHA-256'],
      );
      final after = await repo.renameUncredentialedNvmeHost(
        id: 3,
        expectedNqn: before.nqn,
        expectedHash: before.hash,
        newNqn: 'nqn.2026-09.example:new',
      );
      expect(
        [after.id, after.nqn, after.hash],
        [3, 'nqn.2026-09.example:new', 'SHA-256'],
      );
      expect(after.toString(), isNot(contains(_secret)));
      final read = wire.requests.firstWhere(
        (r) => r['method'] == 'nvmet.host.query',
      );
      expect(read['params'], [
        [
          ['id', '=', 3],
        ],
        {
          'select': [
            'id',
            'hostnqn',
            'dhchap_key',
            'dhchap_ctrl_key',
            'dhchap_dhgroup',
            'dhchap_hash',
          ],
          'limit': 2,
        },
      ]);
      final write = wire.requests.singleWhere(
        (r) => r['method'] == 'nvmet.host.update',
      );
      expect(write['params'], [
        3,
        {'hostnqn': 'nqn.2026-09.example:new'},
      ]);
      expect(repo.adminCatalog.method('nvmet.host.update')?.supported, false);
    },
  );
  for (final changed in [
    'dhchap_key',
    'dhchap_ctrl_key',
    'dhchap_dhgroup',
    'dhchap_hash',
    'hostnqn',
    'id',
    'missing key',
  ]) {
    test(
      'protected rename rejects $changed before update without secret error',
      () async {
        final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true);
        if (changed == 'missing key') {
          wire.hostRow.remove('dhchap_key');
        } else {
          wire.hostRow[changed] = changed == 'id' ? 999 : _secret;
        }
        final repo = TrueNasSessionRepository(connector: _Connector(wire));
        addTearDown(repo.close);
        await repo.connect(
          serverInput: 'https://fixture.example',
          username: 'fixture-user',
          apiKey: 'fixture-key',
        );
        await expectLater(
          repo.renameUncredentialedNvmeHost(
            id: 3,
            expectedNqn: 'nqn.2026-09.example:old',
            expectedHash: 'SHA-256',
            newNqn: 'nqn.2026-09.example:new',
          ),
          throwsA(
            isA<NvmeHostException>().having(
              (e) => e.userMessage,
              'safe error',
              isNot(contains(_secret)),
            ),
          ),
        );
        expect(
          wire.requests.where((r) => r['method'] == 'nvmet.host.update'),
          isEmpty,
        );
      },
    );
  }
  for (final failure in [
    'auth after update',
    'hash after update',
    'ID after update',
    'NQN after update',
  ]) {
    test(
      '$failure rejects protected response after exactly one write',
      () async {
        final wire = _Wire(advertiseNvme: true, advertiseNvmeHostUpdate: true)
          ..renameFailure = failure;
        final repo = TrueNasSessionRepository(connector: _Connector(wire));
        addTearDown(repo.close);
        await repo.connect(
          serverInput: 'https://fixture.example',
          username: 'fixture-user',
          apiKey: 'fixture-key',
        );
        await expectLater(
          repo.renameUncredentialedNvmeHost(
            id: 3,
            expectedNqn: 'nqn.2026-09.example:old',
            expectedHash: 'SHA-256',
            newNqn: 'nqn.2026-09.example:new',
          ),
          throwsA(isA<NvmeHostException>()),
        );
        expect(
          wire.requests.where((r) => r['method'] == 'nvmet.host.update').length,
          1,
        );
      },
    );
  }
  test(
    'unadvertised rename and invalid arguments send no host update',
    () async {
      final wire = _Wire(advertiseNvme: true);
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      await expectLater(
        repo.renameUncredentialedNvmeHost(
          id: 3,
          expectedNqn: 'nqn.2026-09.example:old',
          expectedHash: 'SHA-256',
          newNqn: 'nqn.2026-09.example:new',
        ),
        throwsA(isA<NvmeHostException>()),
      );
      await expectLater(
        repo.loadUncredentialedNvmeHost(0),
        throwsA(isA<NvmeHostException>()),
      );
      expect(
        wire.requests.where(
          (r) => (r['method'] as String).startsWith('nvmet.host'),
        ),
        isEmpty,
      );
    },
  );
  test(
    'NVMe host registration projects only identity and rejects unexpected auth',
    () async {
      final wire = _Wire(advertiseNvmeHostCreate: true);
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      final created = await repo.createUnassociatedNvmeHost(
        hostNqn: 'nqn.2026-09.example:new',
      );
      expect([created.id, created.nqn], [11, 'nqn.2026-09.example:new']);
      expect(created.toString(), isNot(contains(_secret)));
      final call = wire.requests.singleWhere(
        (r) => r['method'] == 'nvmet.host.create',
      );
      expect(call['params'], [
        {
          'hostnqn': 'nqn.2026-09.example:new',
          'dhchap_key': null,
          'dhchap_ctrl_key': null,
          'dhchap_dhgroup': null,
        },
      ]);
      wire.malformed = true;
      await expectLater(
        repo.createUnassociatedNvmeHost(hostNqn: 'nqn.2026-09.example:new'),
        throwsA(
          isA<NvmeHostException>().having(
            (e) => e.userMessage,
            'safe error',
            isNot(contains(_secret)),
          ),
        ),
      );
      expect(repo.adminCatalog.method('nvmet.host.create')?.supported, false);
    },
  );
  test(
    'unadvertised host registration and invalid NQNs send no writes',
    () async {
      for (final advertised in [true, false]) {
        final wire = _Wire(advertiseNvmeHostCreate: advertised);
        final repo = TrueNasSessionRepository(connector: _Connector(wire));
        addTearDown(repo.close);
        await repo.connect(
          serverInput: 'https://fixture.example',
          username: 'fixture-user',
          apiKey: 'fixture-key',
        );
        for (final value
            in advertised
                ? [
                    'nqn.short',
                    ' nqn.2026-09.example:new',
                    'nqn.2026-09.example:new\n',
                    'nqn.2026-09.example:비밀',
                    'nqn.${'a' * 220}',
                  ]
                : ['nqn.2026-09.example:new']) {
          await expectLater(
            repo.createUnassociatedNvmeHost(hostNqn: value),
            throwsA(isA<NvmeHostException>()),
          );
        }
        expect(
          wire.requests.where((r) => r['method'] == 'nvmet.host.create'),
          isEmpty,
        );
      }
    },
  );
  test(
    'host create projection fails closed on unknown credentials and IDs',
    () {
      final base = <String, Object?>{
        'id': 11,
        'hostnqn': 'nqn.2026-09.example:new',
        'dhchap_key': null,
        'dhchap_ctrl_key': null,
        'dhchap_dhgroup': null,
      };
      for (final key in [
        'id',
        'hostnqn',
        'dhchap_key',
        'dhchap_ctrl_key',
        'dhchap_dhgroup',
      ]) {
        expect(
          () => NvmeHostCreated.project(Map.of(base)..remove(key)),
          throwsFormatException,
        );
      }
      expect(
        () => NvmeHostCreated.project({...base, 'id': 0}),
        throwsFormatException,
      );
      for (final key in ['dhchap_key', 'dhchap_ctrl_key', 'dhchap_dhgroup']) {
        expect(
          () => NvmeHostCreated.project({...base, key: _secret}),
          throwsFormatException,
        );
      }
    },
  );
  test('parser retains only references and rejects incomplete responses', () {
    final inventory = IscsiAuthInventory.parse([
      {
        'id': 3,
        'tag': 9,
        'user': 'client-user',
        'peeruser': 'target-user',
        'discovery_auth': 'CHAP_MUTUAL',
        'secret': _secret,
        'peersecret': _secret,
      },
    ], DateTime.parse('2026-01-01T09:00:00+09:00'));
    expect(inventory.references.single.tag, 9);
    expect(inventory.references.single.peerUser, 'target-user');
    expect(inventory.observedAt.isUtc, isTrue);
    expect(inventory.references.single.toString(), isNot(contains(_secret)));
    expect(() => inventory.references.clear(), throwsUnsupportedError);
    expect(
      () => IscsiAuthInventory.parse([
        {'id': 1},
      ], DateTime.utc(2026)),
      throwsFormatException,
    );
    expect(
      () => IscsiAuthInventory.parse(
        List.filled(101, {'id': 1}),
        DateTime.utc(2026),
      ),
      throwsFormatException,
    );
  });

  test(
    'dedicated wire request selects references and discards extra secrets',
    () async {
      final wire = _Wire();
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      final references = await repo.loadIscsiAuthReferences();
      expect(references.references.single.user, 'client-user');
      expect(references.toString(), isNot(contains(_secret)));
      final query = wire.requests.singleWhere(
        (r) => r['method'] == 'iscsi.auth.query',
      );
      final options = (query['params'] as List)[1] as Map;
      expect(options['select'], [
        'id',
        'tag',
        'user',
        'peeruser',
        'discovery_auth',
      ]);
      expect(options['select'], isNot(contains('secret')));
      expect(options['limit'], 101);
      expect(
        () => repo.query('iscsi.auth.query'),
        throwsA(isA<SessionQueryException>()),
      );
      expect(repo.adminCatalog.method('iscsi.auth.query')?.supported, isFalse);
    },
  );

  test('unadvertised method sends no authentication query', () async {
    final wire = _Wire(advertiseAuth: false);
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    await repo.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    await expectLater(
      repo.loadIscsiAuthReferences(),
      throwsA(isA<IscsiAuthException>()),
    );
    expect(
      wire.requests.where((r) => r['method'] == 'iscsi.auth.query'),
      isEmpty,
    );
  });

  test(
    'malformed secret-bearing result fails without returning raw data',
    () async {
      final wire = _Wire()..malformed = true;
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      await expectLater(
        repo.loadIscsiAuthReferences(),
        throwsA(
          isA<IscsiAuthException>().having(
            (e) => e.userMessage,
            'userMessage',
            isNot(contains(_secret)),
          ),
        ),
      );
    },
  );

  test(
    'NVMe host query selects public identities and strips DH-CHAP keys',
    () async {
      final wire = _Wire(advertiseNvme: true);
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      final rows = await repo.loadNvmeHostReferences();
      expect(rows.hosts.single['hostnqn'], 'nqn.fixture:client');
      expect(rows.hosts.single.containsKey('dhchap_key'), false);
      expect(rows.mappings.single['host'], {'id': 3});
      expect(rows.toString(), isNot(contains(_secret)));
      final hostQuery = wire.requests.singleWhere(
        (r) => r['method'] == 'nvmet.host.query',
      );
      final mappingQuery = wire.requests.singleWhere(
        (r) => r['method'] == 'nvmet.host_subsys.query',
      );
      expect((hostQuery['params'] as List)[1], {
        'select': ['id', 'hostnqn'],
        'limit': 101,
      });
      expect((mappingQuery['params'] as List)[1], {
        'select': ['id', 'host.id', 'subsys.id'],
        'limit': 101,
      });
      expect(repo.adminCatalog.method('nvmet.host.query')?.supported, false);
    },
  );

  test('unadvertised NVMe association method sends no host read', () async {
    final wire = _Wire(advertiseNvme: true, advertiseNvmeMapping: false);
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    await repo.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    await expectLater(
      repo.loadNvmeHostReferences(),
      throwsA(isA<NvmeHostException>()),
    );
    expect(
      wire.requests.where(
        (r) => (r['method'] as String).startsWith('nvmet.host'),
      ),
      isEmpty,
    );
  });

  test(
    'NVMe association create projects only IDs from a secret-bearing response',
    () async {
      final wire = _Wire(advertiseNvme: true, advertiseNvmeCreate: true);
      final repo = TrueNasSessionRepository(connector: _Connector(wire));
      addTearDown(repo.close);
      await repo.connect(
        serverInput: 'https://fixture.example',
        username: 'fixture-user',
        apiKey: 'fixture-key',
      );
      final created = await repo.createNvmeHostAssociation(
        hostId: 3,
        subsystemId: 2,
      );
      expect([created.id, created.hostId, created.subsystemId], [9, 3, 2]);
      expect(created.toString(), isNot(contains(_secret)));
      final call = wire.requests.singleWhere(
        (r) => r['method'] == 'nvmet.host_subsys.create',
      );
      expect(call['params'], [
        {'host_id': 3, 'subsys_id': 2},
      ]);
      expect(call.toString(), isNot(contains(_secret)));
    },
  );

  test('unadvertised NVMe association create sends no write', () async {
    final wire = _Wire(advertiseNvme: true);
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    await repo.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    await expectLater(
      repo.createNvmeHostAssociation(hostId: 3, subsystemId: 2),
      throwsA(isA<NvmeHostException>()),
    );
    expect(
      wire.requests.where((r) => r['method'] == 'nvmet.host_subsys.create'),
      isEmpty,
    );
  });

  test('NVMe port association create returns only public IDs', () async {
    final wire = _Wire(advertiseNvmePortCreate: true);
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    await repo.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    final created = await repo.createNvmePortAssociation(
      portId: 7,
      subsystemId: 2,
    );
    expect([created.id, created.portId, created.subsystemId], [10, 7, 2]);
    expect(created.toString(), isNot(contains(_secret)));
    final call = wire.requests.singleWhere(
      (r) => r['method'] == 'nvmet.port_subsys.create',
    );
    expect(call['params'], [
      {'port_id': 7, 'subsys_id': 2},
    ]);
  });

  test('unadvertised NVMe port association create sends no write', () async {
    final wire = _Wire();
    final repo = TrueNasSessionRepository(connector: _Connector(wire));
    addTearDown(repo.close);
    await repo.connect(
      serverInput: 'https://fixture.example',
      username: 'fixture-user',
      apiKey: 'fixture-key',
    );
    await expectLater(
      repo.createNvmePortAssociation(portId: 7, subsystemId: 2),
      throwsA(isA<NvmeHostException>()),
    );
    expect(
      wire.requests.where((r) => r['method'] == 'nvmet.port_subsys.create'),
      isEmpty,
    );
  });
}

final class _Connector implements RpcConnector {
  _Connector(this.wire);
  final _Wire wire;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wire;
}

final class _RotatingConnector implements RpcConnector {
  _RotatingConnector(this.wires);
  final List<_Wire> wires;
  int _index = 0;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wires[_index++];
}

final class _Wire implements RpcTransport {
  _Wire({
    this.advertiseAuth = true,
    this.advertiseNvme = false,
    this.advertiseNvmeMapping = true,
    this.advertiseNvmeCreate = false,
    this.advertiseNvmePortCreate = false,
    this.advertiseNvmeHostCreate = false,
    this.advertiseNvmeHostUpdate = false,
    this.advertiseNvmeHashes = false,
    this.advertiseNvmeGroups = false,
    this.advertiseNvmeGenerate = false,
  });
  final bool advertiseAuth;
  final bool advertiseNvme, advertiseNvmeMapping;
  final bool advertiseNvmeCreate;
  final bool advertiseNvmePortCreate;
  final bool advertiseNvmeHostCreate;
  final bool advertiseNvmeHostUpdate;
  final bool advertiseNvmeHashes, advertiseNvmeGroups;
  final bool advertiseNvmeGenerate;
  Object? generatedKey = _importedKey('01');
  bool generationFailure = false;
  Completer<void>? pauseGeneration;
  final generationStarted = Completer<void>();
  Object? hashes = ['SHA-256', 'SHA-384', 'SHA-512'];
  Object? groups = ['2048-BIT', '3072-BIT', '4096-BIT', '6144-BIT', '8192-BIT'];
  String? renameFailure;
  bool overrideHostQuery = false;
  bool keyCreate = false;
  bool keyReplace = false;
  String? keyReplaceFailure;
  final replacementMappings = <Map<String, Object?>>[];
  final replacementOther = <String, Object?>{
    'id': 8,
    'hostnqn': 'nqn.2026-09.example:other',
  };
  bool replacementWritten = false;
  String serverVersion = '25.10.1';
  String? keyCreateFailure;
  Map<String, Object?>? createdHost;
  Completer<void>? pauseHashes;
  final hashesStarted = Completer<void>();
  Object? hostQueryResult;
  final hostRow = <String, Object?>{
    'id': 3,
    'hostnqn': 'nqn.2026-09.example:old',
    'dhchap_key': null,
    'dhchap_ctrl_key': null,
    'dhchap_dhgroup': null,
    'dhchap_hash': 'SHA-256',
    'unexpected_private_data': _secret,
  };
  bool malformed = false;
  final _incoming = StreamController<String>();
  final requests = <Map<String, dynamic>>[];

  @override
  Stream<String> get inboundFrames => _incoming.stream;

  @override
  Future<void> send(String frame) async {
    final request = jsonDecode(frame) as Map<String, dynamic>;
    requests.add(request);
    if (request['method'] == 'nvmet.host.generate_key' && generationFailure) {
      _incoming.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': request['id'],
          'error': {'code': -32603, 'message': _secret, 'data': _secret},
        }),
      );
      return;
    }
    if (request['method'] == 'nvmet.host.dhchap_hash_choices' &&
        pauseHashes != null) {
      if (!hashesStarted.isCompleted) hashesStarted.complete();
      await pauseHashes!.future;
      if (_incoming.isClosed) return;
    }
    if (request['method'] == 'nvmet.host.generate_key' &&
        pauseGeneration != null) {
      if (!generationStarted.isCompleted) generationStarted.complete();
      await pauseGeneration!.future;
      if (_incoming.isClosed) return;
    }
    final result = switch (request['method']) {
      'auth.login_ex' => {'response_type': 'SUCCESS'},
      'auth.me' => {'pw_name': 'fixture-user'},
      'system.info' => {'version': serverVersion},
      'core.get_methods' => {
        if (advertiseAuth)
          'iscsi.auth.query': {
            'accepts': <Object?>[],
            'returns': [
              <String, Object?>{'type': 'array'},
            ],
            'job': false,
            'filterable': true,
            'no_auth_required': false,
            'uploadable': false,
            'downloadable': false,
            'roles': ['SHARING_ISCSI_AUTH_READ'],
          },
        if (advertiseNvme) 'nvmet.host.query': _nvmeMetadata,
        if (advertiseNvme && advertiseNvmeMapping)
          'nvmet.host_subsys.query': _nvmeMetadata,
        if (advertiseNvmeCreate) 'nvmet.host_subsys.create': _nvmeMetadata,
        if (advertiseNvmePortCreate) 'nvmet.port_subsys.create': _nvmeMetadata,
        if (advertiseNvmeHostCreate) 'nvmet.host.create': _nvmeMetadata,
        if (advertiseNvmeHostUpdate) 'nvmet.host.update': _nvmeMetadata,
        if (advertiseNvmeHashes)
          'nvmet.host.dhchap_hash_choices': _nvmeMetadata,
        if (advertiseNvmeGenerate) 'nvmet.host.generate_key': _nvmeMetadata,
        if (advertiseNvmeGroups)
          'nvmet.host.dhchap_dhgroup_choices': _nvmeMetadata,
      },
      'iscsi.auth.query' =>
        malformed
            ? [
                {'id': 1, 'secret': _secret},
              ]
            : [
                {
                  'id': 3,
                  'tag': 9,
                  'user': 'client-user',
                  'peeruser': '',
                  'discovery_auth': 'CHAP',
                  // Deliberately violate select to prove SDK projection.
                  'secret': _secret,
                  'peersecret': _secret,
                },
              ],
      'nvmet.host.query' when overrideHostQuery => hostQueryResult,
      'nvmet.host.query' when keyCreate => _keyQuery(request),
      'nvmet.host.query' when keyReplace => _replacementQuery(request),
      'nvmet.host.query' when advertiseNvmeHostUpdate => [Map.of(hostRow)],
      'nvmet.host.dhchap_hash_choices' => hashes,
      'nvmet.host.generate_key' => generatedKey,
      'nvmet.host.dhchap_dhgroup_choices' => groups,
      'nvmet.host.update' when keyReplace => _replaceKeys(request),
      'nvmet.host.update' => _rename(request),
      'nvmet.host.query' => [
        {'id': 3, 'hostnqn': 'nqn.fixture:client', 'dhchap_key': _secret},
      ],
      'nvmet.host.create' when keyCreate => _keyCreate(request),
      'nvmet.host.create' => {
        'id': 11,
        'hostnqn': 'nqn.2026-09.example:new',
        'dhchap_key': malformed ? _secret : null,
        'dhchap_ctrl_key': null,
        'dhchap_dhgroup': null,
        'unexpected_private_data': _secret,
      },
      'nvmet.host_subsys.query'
          when keyCreate &&
              createdHost != null &&
              keyCreateFailure == 'new mapping' =>
        [
          {
            'id': 4,
            'host': {'id': 3},
            'subsys': {'id': 2},
          },
          {
            'id': 5,
            'host': {'id': 11},
            'subsys': {'id': 2},
          },
        ],
      'nvmet.host_subsys.query' when keyReplace => replacementMappings,
      'nvmet.host_subsys.query' => [
        {
          'id': 4,
          'host': {'id': 3, 'dhchap_ctrl_key': _secret},
          'subsys': {'id': 2},
        },
      ],
      'nvmet.host_subsys.create' => {
        'id': 9,
        'host': {'id': 3, 'dhchap_key': _secret},
        'subsys': {'id': 2, 'serial': _secret},
      },
      'nvmet.port_subsys.create' => {
        'id': 10,
        'port': {'id': 7, 'addr_traddr': _secret},
        'subsys': {'id': 2, 'serial': _secret},
      },
      _ => throw StateError('Unexpected fixture method'),
    };
    _incoming.add(
      jsonEncode({'jsonrpc': '2.0', 'id': request['id'], 'result': result}),
    );
  }

  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }

  Object _rename(Map<String, dynamic> request) {
    final payload = (request['params'] as List)[1] as Map;
    if (payload.containsKey('hostnqn')) hostRow['hostnqn'] = payload['hostnqn'];
    if (payload.containsKey('dhchap_hash')) {
      hostRow['dhchap_hash'] = payload['dhchap_hash'];
    }
    for (final key in ['dhchap_key', 'dhchap_ctrl_key', 'dhchap_dhgroup']) {
      if (payload.containsKey(key)) hostRow[key] = payload[key];
    }
    switch (renameFailure) {
      case 'auth after update':
        hostRow['dhchap_key'] = _secret;
      case 'controller after update':
        hostRow['dhchap_ctrl_key'] = _secret;
      case 'group after update':
        hostRow['dhchap_dhgroup'] = '2048-BIT';
      case 'hash after update':
        hostRow['dhchap_hash'] = 'SHA-512';
      case 'ID after update':
        hostRow['id'] = 999;
      case 'NQN after update':
        hostRow['hostnqn'] = 'nqn.2026-09.example:wrong';
    }
    return Map.of(hostRow);
  }

  Object? _keyQuery(Map<String, dynamic> request) {
    final filter = (request['params'] as List).first as List;
    if (filter.isNotEmpty) {
      if (keyCreateFailure == 'missing readback') return [];
      if (keyCreateFailure == 'duplicate readback') {
        return [createdHost, createdHost];
      }
      final row = Map<String, Object?>.of(createdHost!);
      switch (keyCreateFailure) {
        case 'rotated readback':
          row['dhchap_key'] = _importedKey('01', seed: 99);
        case 'readback ID':
          row['id'] = 98;
        case 'redacted readback':
          row['dhchap_key'] = '********';
      }
      return [row];
    }
    final old = Map.of(hostRow);
    if (createdHost != null && keyCreateFailure == 'identity drift') {
      old['hostnqn'] = 'nqn.2026-09.example:changed';
    }
    return [
      old,
      if (keyCreateFailure == 'duplicate inventory') old,
      if (createdHost != null && keyCreateFailure != 'missing public host')
        Map.of(createdHost!),
    ];
  }

  Object _keyCreate(Map<String, dynamic> request) {
    createdHost = {
      'id': 11,
      ...Map<String, Object?>.from((request['params'] as List).single as Map),
      'unexpected_private_data': _secret,
    };
    switch (keyCreateFailure) {
      case 'existing ID':
        createdHost!['id'] = 3;
      case 'wrong NQN':
        createdHost!['hostnqn'] = 'nqn.2026-09.example:wrong';
      case 'wrong hash':
        createdHost!['dhchap_hash'] = 'SHA-512';
      case 'wrong group':
        createdHost!['dhchap_dhgroup'] = '8192-BIT';
      case 'wrong host key':
        createdHost!['dhchap_key'] = _importedKey('01', seed: 99);
      case 'wrong controller key':
        createdHost!['dhchap_ctrl_key'] = _importedKey('01', seed: 99);
      case 'redacted result':
        createdHost!['dhchap_key'] = '********';
      case 'missing result field':
        createdHost!.remove('dhchap_ctrl_key');
    }
    return Map.of(createdHost!);
  }

  Object? _replacementQuery(Map<String, dynamic> request) {
    final filter = (request['params'] as List).first as List;
    if (filter.isEmpty) return [Map.of(hostRow), Map.of(replacementOther)];
    if (replacementWritten && keyReplaceFailure == 'missing readback') {
      return [];
    }
    final row = Map.of(hostRow);
    if (replacementWritten && keyReplaceFailure == 'duplicate readback') {
      return [row, row];
    }
    if (replacementWritten && keyReplaceFailure == 'rotated readback') {
      row['dhchap_key'] = _importedKey('01', seed: 99);
    }
    if (replacementWritten && keyReplaceFailure == 'redacted readback') {
      row['dhchap_key'] = '********';
    }
    if (replacementWritten && keyReplaceFailure == 'readback ID') {
      row['id'] = 99;
    }
    return [row];
  }

  Object _replaceKeys(Map<String, dynamic> request) {
    final params = request['params'] as List;
    expect(params.first, 3);
    hostRow.addAll(Map<String, Object?>.from(params.last as Map));
    replacementWritten = true;
    if (keyReplaceFailure == 'public drift') {
      replacementOther['hostnqn'] = 'nqn.2026-09.example:changed';
    }
    if (keyReplaceFailure == 'new mapping') {
      replacementMappings.add({
        'id': 9,
        'host': {'id': 3},
        'subsys': {'id': 2},
      });
    }
    final row = Map.of(hostRow);
    switch (keyReplaceFailure) {
      case 'wrong ID':
        row['id'] = 99;
      case 'wrong NQN':
        row['hostnqn'] = 'nqn.2026-09.example:wrong';
      case 'wrong hash':
        row['dhchap_hash'] = 'SHA-512';
      case 'wrong group':
        row['dhchap_dhgroup'] = '8192-BIT';
      case 'wrong host key':
        row['dhchap_key'] = _importedKey('01', seed: 99);
      case 'wrong controller key':
        row['dhchap_ctrl_key'] = _importedKey('01', seed: 99);
      case 'redacted result':
        row['dhchap_key'] = '********';
      case 'missing field':
        row.remove('dhchap_ctrl_key');
    }
    return row;
  }
}

const _nvmeMetadata = <String, Object?>{
  'accepts': <Object?>[],
  'returns': [
    <String, Object?>{'type': 'array'},
  ],
  'job': false,
  'filterable': true,
  'no_auth_required': false,
  'uploadable': false,
  'downloadable': false,
  'roles': ['SHARING_NVME_TARGET_READ'],
};
