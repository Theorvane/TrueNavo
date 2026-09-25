import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _train = 'TrueNAS-SCALE-Goldeye';
const _current = '25.10.1';
const _next = '25.10.2';
const _secret = 'synthetic-remote-details-never-display';
const _create = CreateDatasetCommand(parent: 'tank', name: 'documents');
const _localMethods = {
  'system.version_short',
  'boot.get_state',
  'boot.environment.query',
  'failover.licensed',
  'core.get_jobs',
};
const _methods = {
  ..._localMethods,
  'update.status',
  'update.config',
  'update.available_versions',
  'update.download',
  'update.run',
  'pool.dataset.create',
  'sharing.smb.query',
  'sharing.nfs.query',
  'nfs.config',
  'pool.dataset.query',
  'service.query',
  'replication.query',
  'replication.delete',
  'pool.filesystem_choices',
  'pool.snapshot.query',
  'cloudsync.query',
  'cloudsync.credentials.query',
  'cloudsync.delete',
  'filesystem.stat',
  'filesystem.statfs',
  'system.general.config',
};

Matcher _reason(SystemUpdatesExceptionReason reason) =>
    isA<SystemUpdatesException>().having((e) => e.reason, 'reason', reason);

void main() {
  for (final method in [
    'update.config',
    'update.status',
    'update.available_versions',
    'update.download',
    'update.run',
  ]) {
    test(
      'generic $method cannot bypass explicit native update review',
      () async {
        final h = await _connected();
        final spec = h.repo.adminCatalog.method(method)!;
        expect(spec.supported, isFalse);
        expect(
          spec.unsupportedReason,
          adminOperationDefinitions
              .singleWhere((p) => p.method == method)
              .blockedReason,
        );
        expect(spec.unsupportedReason, isNotNull);
        final boundary = h.wire.requests.length;
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
        expect(h.wire.requests.length, boundary);
      },
    );
  }
  test('disconnected capability and reads never dispatch', () async {
    final wire = _Wire();
    final repo = TrueNasSessionRepository(connector: _Connector([wire]));
    addTearDown(repo.close);
    expect(repo.systemUpdatesCapabilities.connected, isFalse);
    await expectLater(
      repo.loadSystemUpdates(),
      throwsA(_reason(SystemUpdatesExceptionReason.notAuthenticated)),
    );
    expect(wire.requests, isEmpty);
  });

  for (final version in ['25.04.2', '26.0.0', '25.10-BETA', '25.10.1\n']) {
    test('unsupported session release $version refuses local reads', () async {
      final h = await _connected(version: version);
      expect(h.repo.systemUpdatesCapabilities.supported, isFalse);
      final count = h.wire.requests.length;
      await expectLater(
        h.repo.loadSystemUpdates(),
        throwsA(_reason(SystemUpdatesExceptionReason.unsupportedVersion)),
      );
      expect(h.wire.requests.length, count);
    });
  }

  for (final missing in _localMethods) {
    test('missing $missing disables native update capability', () async {
      final h = await _connected(methods: _methods.difference({missing}));
      expect(h.repo.systemUpdatesCapabilities.available, isFalse);
      await expectLater(
        h.repo.loadSystemUpdates(),
        throwsA(_reason(SystemUpdatesExceptionReason.unavailableMethod)),
      );
      expect(h.wire.updateRequests, isEmpty);
    });
  }

  for (final fault in <Map<String, Object?>>[
    {'job': false},
    {'job': null},
    {'uploadable': true},
    {'downloadable': true},
    {'private': true},
    {'_private': true},
    {'no_auth_required': true},
  ]) {
    test(
      'unsafe mutation metadata $fault disables both update writers',
      () async {
        final h = await _connected(
          overrides: {'update.download': fault, 'update.run': fault},
        );
        expect(h.repo.systemUpdatesCapabilities.supported, isTrue);
        expect(h.repo.systemUpdatesCapabilities.canCheck, isTrue);
        expect(h.repo.systemUpdatesCapabilities.canDownload, isFalse);
        expect(h.repo.systemUpdatesCapabilities.canInstall, isFalse);
      },
    );
  }

  test('local inventory works without any update source permissions', () async {
    final h = await _connected(methods: _localMethods);
    final inventory = await h.repo.loadSystemUpdates();
    expect(inventory.checked, isFalse);
    expect(h.repo.systemUpdatesCapabilities.supported, isTrue);
    expect(h.repo.systemUpdatesCapabilities.canCheck, isFalse);
    await expectLater(
      h.repo.reviewSystemUpdate(
        SystemUpdateRequest(
          inventory: inventory,
          action: SystemUpdateAction.check,
        ),
      ),
      throwsA(_reason(SystemUpdatesExceptionReason.unavailableMethod)),
    );
    expect(h.wire.updateRequests, isEmpty);
  });

  test(
    'load is local only, bounded, immutable, and uses boot state without GUID',
    () async {
      final h = await _connected();
      final boundary = h.wire.requests.length;
      final i = await h.repo.loadSystemUpdates();
      expect(h.wire.boot.containsKey('guid'), isFalse);
      expect(i.bootPool, 'boot-pool');
      expect(i.currentVersion, _current);
      expect(i.bootHealthy, isTrue);
      expect(i.bootFreeBytes, 12 * 1024 * 1024 * 1024);
      expect(i.checked, isFalse);
      expect(i.versions, isEmpty);
      expect(i.downloadPercent, isNull);
      expect(i.blockedReason, isNull);
      expect(() => i.environments.clear(), throwsUnsupportedError);
      expect(() => i.versions.clear(), throwsUnsupportedError);
      expect(h.wire.requests.skip(boundary).map((r) => r['method']), [
        'system.version_short',
        'failover.licensed',
        'core.get_jobs',
        'boot.get_state',
        'boot.environment.query',
      ]);
      expect(h.wire.requests.last['params'], [
        [],
        {'limit': 129},
      ]);
      expect(
        h.wire.requests.singleWhere(
          (r) => r['method'] == 'core.get_jobs',
        )['params'],
        [
          [
            [
              'state',
              'in',
              ['WAITING', 'RUNNING'],
            ],
          ],
          {
            'limit': 129,
            'select': ['id', 'method', 'state'],
          },
        ],
      );
      expect(h.wire.updateRequests, isEmpty);
    },
  );

  test('unknown capacity remains unknown and prevents install only', () async {
    final h = await _connected();
    h.wire.boot.addAll({'size': null, 'allocated': null, 'free': null});
    final i = await _checked(h);
    expect(i.bootSizeBytes, isNull);
    expect(i.bootAllocatedBytes, isNull);
    expect(i.bootFreeBytes, isNull);
    expect(i.blockedReason, isNull);
    expect(i.installBlockedReason, isNotNull);
    await h.repo.reviewSystemUpdate(_request(i, SystemUpdateAction.download));
    await expectLater(
      h.repo.reviewSystemUpdate(_request(i, SystemUpdateAction.install)),
      throwsA(_reason(SystemUpdatesExceptionReason.invalidRequest)),
    );
    expect(h.wire.writes, isEmpty);
  });

  final malformedLocal = <String, void Function(_Wire)>{
    'version drift': (w) => w.version = '25.10.3',
    'HA null': (w) => w.licensed = null,
    'missing pool name': (w) => w.boot.remove('name'),
    'health not boolean': (w) => w.boot['healthy'] = 'true',
    'scan not object': (w) => w.boot['scan'] = [],
    'negative size': (w) => w.boot['size'] = -1,
    'floating free': (w) => w.boot['free'] = 123.0,
    'unsafe integer': (w) => w.boot['free'] = 9007199254740992,
    'inconsistent totals': (w) => w.boot['free'] = 1,
    'duplicate environment': (w) => w.rows.add({...w.rows.last}),
    'wrong pool dataset': (w) => w.rows.last['dataset'] = 'tank/ROOT/25.04.2',
    'invalid created identity': (w) => w.rows.last['created'] = 'not-a-date',
    'floating job id': (w) => w.activeJobs = [
      {'id': 1.0, 'method': 'update.run', 'state': 'RUNNING'},
    ],
    'too many jobs': (w) => w.activeJobs = List.generate(
      129,
      (i) => {'id': i, 'method': 'unrelated.job', 'state': 'RUNNING'},
    ),
    'too many environments': (w) =>
        w.rows = List.generate(129, (i) => _be('env-$i')),
  };
  for (final entry in malformedLocal.entries) {
    test('malformed local ${entry.key} fails without source contact', () async {
      final h = await _connected();
      entry.value(h.wire);
      await expectLater(
        h.repo.loadSystemUpdates(),
        throwsA(
          _reason(
            entry.key == 'invalid created identity'
                ? SystemUpdatesExceptionReason.unavailable
                : SystemUpdatesExceptionReason.invalidResponse,
          ),
        ),
      );
      expect(h.wire.updateRequests, isEmpty);
    });
  }

  for (final entry in <String, void Function(_Wire)>{
    'HA licensed': (w) => w.licensed = true,
    'degraded pool': (w) => w.boot['status'] = 'DEGRADED',
    'active resilver': (w) =>
        w.boot['scan'] = {'function': 'RESILVER', 'state': 'SCANNING'},
    'different next boot': (w) {
      w.rows.first['activated'] = false;
      w.rows.last['activated'] = true;
    },
    'conflicting update job': (w) => w.activeJobs = [
      {'id': 41, 'method': 'update.run', 'state': 'WAITING'},
    ],
  }.entries) {
    test('${entry.key} is inspectable but check review is blocked', () async {
      final h = await _connected();
      entry.value(h.wire);
      final i = await h.repo.loadSystemUpdates();
      expect(i.blockedReason, isNotNull);
      await expectLater(
        h.repo.reviewSystemUpdate(_request(i, SystemUpdateAction.check)),
        throwsA(_reason(SystemUpdatesExceptionReason.invalidRequest)),
      );
      expect(h.wire.updateRequests, isEmpty);
    });
  }

  test('check review is strictly local and explicit execution checks exact public methods', () async {
    final h = await _connected();
    final review = await _review(h, SystemUpdateAction.check);
    expect(h.wire.updateRequests, isEmpty);
    expect(review.target, 'CHECK $_current');
    expect(review.warnings.join(' '), contains('may initialize'));
    final result = await h.repo.executeSystemUpdate(review, review.target);
    expect(result.outcome, SystemUpdateOutcome.checked);
    expect(result.inventory!.checked, isTrue);
    expect(result.inventory!.versions.single.version, _next);
    expect(h.wire.updateRequests.map((r) => [r['method'], r['params']]), [
      ['update.status', []],
      ['update.available_versions', []],
    ]);
    expect(h.wire.writes, isEmpty);
    final boundary = h.wire.updateRequests.length;
    expect((await h.repo.loadSystemUpdates()).checked, isTrue);
    expect(h.wire.updateRequests.length, boundary);
  });

  test('successful empty offers differs from sanitized source error and never infers progress', () async {
    final h = await _connected();
    h.wire.offers.clear();
    (h.wire.status['status'] as Map)['new_version'] = null;
    final empty = await _checked(h);
    expect(empty.checked, isTrue);
    expect(empty.checkError, isNull);
    expect(empty.versions, isEmpty);
    expect(empty.downloadPercent, isNull);
    h.wire.status = {
      'code': 'ERROR',
      'status': null,
      'error': {'errname': 'ENONET', 'reason': _secret},
      'update_download_progress': null,
    };
    final boundary = h.wire.updateRequests.length;
    final r = await _execute(h, SystemUpdateAction.check);
    expect(r.outcome, SystemUpdateOutcome.checked);
    expect(r.inventory!.checkError, 'ENONET');
    expect(r.message, contains('unknown'));
    expect(r.message, isNot(contains(_secret)));
    expect(h.wire.updateRequests.skip(boundary).map((r) => r['method']), [
      'update.status',
    ]);
    expect(h.wire.writes, isEmpty);
  });

  for (final percent in <Object?>[null, 0, 100]) {
    test('checked download progress preserves $percent truthfully', () async {
      final h = await _connected();
      h.wire.status['update_download_progress'] = percent == null
          ? null
          : {'version': _next, 'percent': percent, 'description': _secret};
      final i = await _checked(h);
      expect(i.downloadPercent, percent);
      expect(i.downloadVersion, percent == null ? null : _next);
    });
  }

  test('reboot-required source status holds applied fence without catalog or writes', () async {
    final h = await _connected();
    h.wire.status = {
      'code': 'ERROR',
      'status': null,
      'error': {'errname': 'EREBOOTREQUIRED', 'reason': _secret},
      'update_download_progress': null,
    };
    final result = await _execute(h, SystemUpdateAction.check);
    expect(result.outcome, SystemUpdateOutcome.checked);
    expect(result.rebootRequired, isTrue);
    expect(result.inventory!.checkError, 'EREBOOTREQUIRED');
    expect(result.message, isNot(contains(_secret)));
    expect(h.wire.updateRequests.map((r) => r['method']), ['update.status']);
    expect(h.wire.writes, isEmpty);
    await _expectFence(h);
  });

  test(
    'nonallowlisted remote error token becomes generic unavailable',
    () async {
      final h = await _connected();
      h.wire.status = {
        'code': 'ERROR',
        'status': null,
        'error': {'errname': _secret, 'reason': _secret},
        'update_download_progress': null,
      };
      final result = await _execute(h, SystemUpdateAction.check);
      expect(result.outcome, SystemUpdateOutcome.checked);
      expect(result.inventory!.checkError, 'UNAVAILABLE');
      expect(result.message, isNot(contains(_secret)));
      expect(h.wire.writes, isEmpty);
    },
  );

  test(
    'preexisting selected-version environment cannot masquerade as new install',
    () async {
      final h = await _connected();
      h.wire.rows.add(_be(_next));
      final inventory = await _checked(h);
      await expectLater(
        h.repo.reviewSystemUpdate(
          _request(inventory, SystemUpdateAction.install),
        ),
        throwsA(_reason(SystemUpdatesExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    },
  );

  final malformedCatalog = <String, void Function(_Wire)>{
    'bad status code': (w) => w.status['code'] = 'OTHER',
    'contradictory error': (w) => w.status['error'] = {'errname': 'ENONET'},
    'missing current profile': (w) => (w.currentStatus).remove('profile'),
    'malformed progress': (w) => w.status['update_download_progress'] = {
      'version': _next,
      'percent': 101,
    },
    'too many versions': (w) => w.offers = List.generate(129, (_) => _offer()),
    'duplicate target': (w) => w.offers.add(_offer()),
    'missing manifest': (w) =>
        (w.offers.first['version'] as Map).remove('manifest'),
    'mismatched train': (w) => w.manifest['train'] = 'other',
    'mismatched version': (w) => w.manifest['version'] = '25.10.3',
    'path filename': (w) => w.manifest['filename'] = '../update.sqsh',
    'short checksum': (w) => w.manifest['checksum'] = 'abcd',
    'zero filesize': (w) => w.manifest['filesize'] = 0,
    'floating filesize': (w) => w.manifest['filesize'] = 123.0,
    'unsafe filesize': (w) => w.manifest['filesize'] = 9007199254740992,
    'invalid profile': (w) => w.manifest['profile'] = 'GENERAL\n',
  };
  for (final entry in malformedCatalog.entries) {
    test(
      'malformed catalog ${entry.key} is unknown and never unlocks by retry',
      () async {
        final h = await _connected();
        entry.value(h.wire);
        final result = await _execute(h, SystemUpdateAction.check);
        expect(result.outcome, SystemUpdateOutcome.unknown);
        expect(result.message, isNot(contains(_secret)));
        expect(h.wire.writes, isEmpty);
        await _expectFence(h);
      },
    );
  }

  for (final version in ['25.10.0', _current, '25.10.3-BETA.1']) {
    test('non-new-stable offer $version remains inspect-only', () async {
      final h = await _connected();
      h.wire.offers = [_offer(version: version)];
      final i = await _checked(h);
      expect(i.versions.single.blockedReason, isNotNull);
      await expectLater(
        h.repo.reviewSystemUpdate(_request(i, SystemUpdateAction.download)),
        throwsA(_reason(SystemUpdatesExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    });
  }
  test('early-adopter release and current profile mismatch prevent mutation review', () async {
    for (final mismatch in [false, true]) {
      final h = await _connected();
      if (mismatch) {
        h.wire.currentStatus['matches_profile'] = false;
      } else {
        h.wire.manifest['profile'] = 'EARLY_ADOPTER';
      }
      final i = await _checked(h);
      await expectLater(
        h.repo.reviewSystemUpdate(_request(i, SystemUpdateAction.install)),
        throwsA(_reason(SystemUpdatesExceptionReason.invalidRequest)),
      );
      expect(h.wire.writes, isEmpty);
    }
  });

  test(
    'unkept inactive environment blocks install but does not block download',
    () async {
      final h = await _connected();
      h.wire.rows.last['keep'] = false;
      final i = await _checked(h);
      expect(i.installBlockedReason, contains('Keep'));
      await h.repo.reviewSystemUpdate(_request(i, SystemUpdateAction.download));
      await expectLater(
        h.repo.reviewSystemUpdate(_request(i, SystemUpdateAction.install)),
        throwsA(_reason(SystemUpdatesExceptionReason.invalidRequest)),
      );
    },
  );

  test(
    'forged, cross-session and invalidated reviews cannot dispatch',
    () async {
      final h = await _connected(), other = await _connected();
      final review = await _review(h, SystemUpdateAction.check);
      final forged = SystemUpdateReview(
        request: review.request,
        endpoint: review.endpoint,
        warnings: review.warnings,
      );
      for (final candidate in [
        forged,
        await _review(other, SystemUpdateAction.check),
      ]) {
        await expectLater(
          h.repo.executeSystemUpdate(candidate, candidate.target),
          throwsA(_reason(SystemUpdatesExceptionReason.staleReview)),
        );
      }
      await h.repo.loadSystemUpdates();
      await expectLater(
        h.repo.executeSystemUpdate(review, review.target),
        throwsA(_reason(SystemUpdatesExceptionReason.staleReview)),
      );
      expect(h.wire.updateRequests, isEmpty);
    },
  );

  test('wrong typed confirmation consumes review and successful check cannot replay', () async {
    final h = await _connected();
    var review = await _review(h, SystemUpdateAction.check);
    await expectLater(
      h.repo.executeSystemUpdate(review, '${review.target} '),
      throwsA(_reason(SystemUpdatesExceptionReason.staleReview)),
    );
    await expectLater(
      h.repo.executeSystemUpdate(review, review.target),
      throwsA(_reason(SystemUpdatesExceptionReason.staleReview)),
    );
    expect(h.wire.updateRequests, isEmpty);
    review = await _review(h, SystemUpdateAction.check);
    expect(
      (await h.repo.executeSystemUpdate(review, review.target)).outcome,
      SystemUpdateOutcome.checked,
    );
    final count = h.wire.updateRequests.length;
    await expectLater(
      h.repo.executeSystemUpdate(review, review.target),
      throwsA(_reason(SystemUpdatesExceptionReason.staleReview)),
    );
    expect(h.wire.updateRequests.length, count);
  });

  final localDrift = <String, void Function(_Wire)>{
    'running version': (w) => w.version = '25.10.3',
    'BE identity': (w) => w.rows.last['created'] = '2026-09-11T12:00:00',
    'BE keep': (w) => w.rows.last['keep'] = false,
    'next boot': (w) {
      w.rows.first['activated'] = false;
      w.rows.last['activated'] = true;
    },
    'capacity total': (w) {
      w.boot['size'] = (w.boot['size'] as int) + 1024;
      w.boot['free'] = (w.boot['free'] as int) + 1024;
    },
    'capacity allocation': (w) {
      w.boot['allocated'] = (w.boot['allocated'] as int) + 1024;
      w.boot['free'] = (w.boot['free'] as int) - 1024;
    },
  };
  for (final entry in localDrift.entries) {
    test(
      '${entry.key} drift after review rejects before any source call',
      () async {
        final h = await _connected();
        final review = await _review(h, SystemUpdateAction.install);
        final boundary = h.wire.updateRequests.length;
        entry.value(h.wire);
        expect(
          (await h.repo.executeSystemUpdate(review, review.target)).outcome,
          SystemUpdateOutcome.rejected,
        );
        expect(h.wire.updateRequests.length, boundary);
        expect(h.wire.writes, isEmpty);
      },
    );
  }

  for (final entry in <String, void Function(_Wire)>{
    'checksum': (w) => w.manifest['checksum'] = 'b' * 64,
    'filename': (w) => w.manifest['filename'] = 'different.update',
    'filesize': (w) => w.manifest['filesize'] = 1234567,
    'release profile': (w) => w.manifest['profile'] = 'MISSION_CRITICAL',
    'current profile': (w) => w.currentStatus['profile'] = 'MISSION_CRITICAL',
    'current train': (w) => w.currentStatus['train'] = 'TrueNAS-SCALE-Other',
    'release removed': (w) => w.offers.clear(),
  }.entries) {
    test(
      'source ${entry.key} drift is rechecked and never dispatches install',
      () async {
        final h = await _connected();
        final review = await _review(h, SystemUpdateAction.install);
        entry.value(h.wire);
        expect(
          (await h.repo.executeSystemUpdate(review, review.target)).outcome,
          SystemUpdateOutcome.rejected,
        );
        expect(h.wire.writes, isEmpty);
      },
    );
  }

  test(
    'boot drift during source check produces durable unknown without download',
    () async {
      final h = await _connected();
      final review = await _review(h, SystemUpdateAction.download);
      h.wire.beforeRequest = (r) {
        if (r['method'] == 'update.available_versions') {
          h.wire.rows.last['keep'] = false;
        }
      };
      expect(
        (await h.repo.executeSystemUpdate(review, review.target)).outcome,
        SystemUpdateOutcome.unknown,
      );
      expect(h.wire.writes, isEmpty);
      await _expectFence(h);
    },
  );

  for (final action in [
    SystemUpdateAction.download,
    SystemUpdateAction.install,
  ]) {
    test(
      '$action sends exactly one pinned job with resume and reboot disabled',
      () async {
        final h = await _connected();
        final result = await _execute(h, action);
        expect(result.outcome, SystemUpdateOutcome.pending);
        expect(result.job!.id, 42);
        expect(result.job!.endpoint, contains('synthetic.example'));
        expect(result.job!.version.checksum, 'a' * 64);
        expect(h.wire.writes, hasLength(1));
        expect(h.wire.writes.single['method'], _method(action));
        expect(h.wire.writes.single['params'], _arguments(action));
        expect(
          h.wire.requests.where(
            (r) => {
              'update.manual',
              'update.file',
              'core.job_abort',
              'system.reboot',
              'boot.environment.destroy',
              'boot.environment.keep',
            }.contains(r['method']),
          ),
          isEmpty,
        );
        await _expectFence(h);
      },
    );
  }

  test(
    'unowned and cross-session job handles are rejected without a poll',
    () async {
      final h = await _connected(), other = await _connected();
      final own = (await _execute(h, SystemUpdateAction.download)).job!;
      final foreign = (await _execute(other, SystemUpdateAction.download)).job!;
      final forged = SystemUpdateJob(
        id: own.id,
        action: own.action,
        endpoint: own.endpoint,
        currentVersion: own.currentVersion,
        version: own.version,
      );
      final boundary = h.wire.requests.length;
      for (final job in [foreign, forged]) {
        await expectLater(
          h.repo.pollSystemUpdate(job),
          throwsA(_reason(SystemUpdatesExceptionReason.staleReview)),
        );
      }
      expect(h.wire.requests.length, boundary);
      await _expectFence(h);
    },
  );

  for (final fault in <String, Object?>{
    'id': 42.0,
    'method': 'update.run',
    'arguments': [_train, '25.10.3'],
    'state': 'OTHER',
    'result': false,
  }.entries) {
    test(
      'poll mismatched ${fault.key} remains owned unknown and never unlocks',
      () async {
        final h = await _connected();
        final job = (await _execute(h, SystemUpdateAction.download)).job!;
        h.wire.jobState = 'SUCCESS';
        h.wire.jobOverrides[fault.key] = fault.value;
        expect(
          (await h.repo.pollSystemUpdate(job)).outcome,
          SystemUpdateOutcome.unknown,
        );
        await _expectFence(h);
        h.wire.jobOverrides.clear();
        expect(
          (await h.repo.pollSystemUpdate(job)).outcome,
          SystemUpdateOutcome.succeeded,
        );
        expect(h.wire.writes, hasLength(1));
      },
    );
  }

  for (final value in <Object?>[
    null,
    [],
    [{}, {}],
  ]) {
    test(
      'unverifiable job collection $value retains fence and supports manual recovery',
      () async {
        final h = await _connected();
        final job = (await _execute(h, SystemUpdateAction.download)).job!;
        h.wire.pollOverride = () => value;
        expect(
          (await h.repo.pollSystemUpdate(job)).outcome,
          SystemUpdateOutcome.unknown,
        );
        await _expectFence(h);
        h.wire.pollOverride = null;
        h.wire.jobState = 'FAILED';
        expect(
          (await h.repo.pollSystemUpdate(job)).outcome,
          SystemUpdateOutcome.failed,
        );
      },
    );
  }

  for (final percent in <Object?>[null, 0, 12.5, 100, -1, 101, '75']) {
    test(
      'manual running progress $percent is truthful and never inferred',
      () async {
        final h = await _connected();
        final job = (await _execute(h, SystemUpdateAction.download)).job!;
        h.wire.progress = percent == null ? null : {'percent': percent};
        final result = await h.repo.pollSystemUpdate(job);
        expect(result.outcome, SystemUpdateOutcome.pending);
        expect(
          result.percent,
          percent is num && percent >= 0 && percent <= 100 ? percent : null,
        );
        expect(result.job, same(job));
        expect(h.wire.requests.last['params'], [
          [
            ['id', '=', 42],
          ],
          {
            'limit': 2,
            'select': [
              'id',
              'method',
              'arguments',
              'state',
              'progress',
              'result',
            ],
          },
        ]);
        await _expectFence(h);
        expect(h.wire.writes, hasLength(1));
      },
    );
  }

  for (final terminal in ['FAILED', 'ABORTED', 'SUCCESS']) {
    test(
      'verified download $terminal releases own fence but never retries',
      () async {
        final h = await _connected();
        final job = (await _execute(h, SystemUpdateAction.download)).job!;
        h.wire.jobState = 'WAITING';
        expect(
          (await h.repo.pollSystemUpdate(job)).outcome,
          SystemUpdateOutcome.pending,
        );
        await _expectFence(h);
        h.wire.jobState = terminal;
        final result = await h.repo.pollSystemUpdate(job);
        expect(
          result.outcome,
          terminal == 'SUCCESS'
              ? SystemUpdateOutcome.succeeded
              : SystemUpdateOutcome.failed,
        );
        expect(result.rebootRequired, isFalse);
        expect(result.message, isNot(contains(_secret)));
        expect(await h.repo.execute(_create), isA<ManagementCompleted>());
        final i = await h.repo.loadSystemUpdates();
        expect(i.checked, isFalse);
        await h.repo.reviewSystemUpdate(_request(i, SystemUpdateAction.check));
        await expectLater(
          h.repo.pollSystemUpdate(job),
          throwsA(_reason(SystemUpdatesExceptionReason.staleReview)),
        );
        expect(
          h.wire.writes.where((r) => r['method'] == 'update.download'),
          hasLength(1),
        );
      },
    );
  }

  for (final receipt in <Object?>[
    null,
    true,
    0,
    -1,
    42.0,
    '42',
    9007199254740992,
  ]) {
    test(
      'invalid job receipt $receipt is durable unknown without replay',
      () async {
        final h = await _connected();
        h.wire.receipt = receipt;
        final result = await _execute(h, SystemUpdateAction.download);
        expect(result.outcome, SystemUpdateOutcome.unknown);
        expect(result.job, isNull);
        await _expectFence(h);
        expect(h.wire.writes, hasLength(1));
      },
    );
  }

  test(
    'mutation timeout and late receipt never replay or release unknown fence',
    () async {
      final h = await _connected(timeout: const Duration(milliseconds: 35));
      h.wire.suppressed.add('update.download');
      final result = await _execute(h, SystemUpdateAction.download);
      expect(result.outcome, SystemUpdateOutcome.unknown);
      final request = h.wire.writes.single;
      h.wire.respond(request, 42);
      await Future<void>.delayed(Duration.zero);
      await _expectFence(h);
      expect(h.wire.writes, hasLength(1));
    },
  );

  test(
    'source-check timeout is uncertain because status may initialize config',
    () async {
      final h = await _connected(timeout: const Duration(milliseconds: 35));
      h.wire.suppressed.add('update.status');
      expect(
        (await _execute(h, SystemUpdateAction.check)).outcome,
        SystemUpdateOutcome.unknown,
      );
      await _expectFence(h);
      expect(h.wire.writes, isEmpty);
      expect(h.wire.updateRequests, hasLength(1));
    },
  );

  test(
    'harmless local preflight failure does not latch mutation fence',
    () async {
      final h = await _connected();
      final review = await _review(h, SystemUpdateAction.check);
      h.wire.rejected.add('boot.get_state');
      expect(
        (await h.repo.executeSystemUpdate(review, review.target)).outcome,
        SystemUpdateOutcome.rejected,
      );
      expect(h.wire.updateRequests, isEmpty);
      expect(await h.repo.execute(_create), isA<ManagementCompleted>());
    },
  );

  test(
    'denied poll stays unknown and the same owned job remains recoverable',
    () async {
      final h = await _connected();
      final job = (await _execute(h, SystemUpdateAction.download)).job!;
      h.wire.rejectPoll = true;
      expect(
        (await h.repo.pollSystemUpdate(job)).outcome,
        SystemUpdateOutcome.unknown,
      );
      await _expectFence(h);
      h.wire.rejectPoll = false;
      h.wire.jobState = 'SUCCESS';
      expect(
        (await h.repo.pollSystemUpdate(job)).outcome,
        SystemUpdateOutcome.succeeded,
      );
      expect(h.wire.writes, hasLength(1));
    },
  );

  test('install success independently observes new next boot while current identity stays alive', () async {
    final h = await _connected();
    final job = (await _execute(h, SystemUpdateAction.install)).job!;
    h.wire.completeInstall();
    final result = await h.repo.pollSystemUpdate(job);
    expect(result.outcome, SystemUpdateOutcome.succeeded);
    expect(result.rebootRequired, isTrue);
    expect(h.wire.rows.singleWhere((r) => r['active'] == true)['id'], _current);
    expect(h.wire.rows.singleWhere((r) => r['activated'] == true)['id'], _next);
    await _expectFence(h);
    expect(h.wire.writes, hasLength(1));
    expect(
      h.wire.requests.where((r) => r['method'] == 'system.reboot'),
      isEmpty,
    );
  });

  for (final entry in <String, void Function(_Wire)>{
    'missing new BE': (w) => w.rows.removeLast(),
    'wrong new name': (w) {
      w.rows.last['id'] = 'wrong';
      w.rows.last['dataset'] = 'boot-pool/ROOT/wrong';
    },
    'current identity changed': (w) =>
        w.rows.first['created'] = '2026-09-11T12:00:00',
    'current already rebooted': (w) {
      w.rows.first['active'] = false;
      w.rows.last['active'] = true;
    },
    'old environment missing': (w) => w.rows.removeAt(1),
    'old keep changed': (w) => w.rows[1]['keep'] = false,
    'new not activatable': (w) => w.rows.last['can_activate'] = false,
    'running version changed': (w) => w.version = _next,
    'unhealthy boot pool': (w) => w.boot['healthy'] = false,
    'HA became licensed': (w) => w.licensed = true,
    'extra unreviewed BE': (w) => w.rows.add(_be('external-change')),
    'new conflicting job': (w) => w.activeJobs = [
      {'id': 99, 'method': 'system.reboot', 'state': 'RUNNING'},
    ],
  }.entries) {
    test(
      'install SUCCESS with ${entry.key} remains unknown and blocked',
      () async {
        final h = await _connected();
        final job = (await _execute(h, SystemUpdateAction.install)).job!;
        h.wire.completeInstall();
        entry.value(h.wire);
        expect(
          (await h.repo.pollSystemUpdate(job)).outcome,
          SystemUpdateOutcome.unknown,
        );
        await _expectFence(
          h,
          localReadable: entry.key != 'running version changed',
        );
        expect(h.wire.writes, hasLength(1));
      },
    );
  }

  test('fresh connection resets old unknown without replay and rejects previous review', () async {
    final first = _Wire(), second = _Wire();
    final repo = TrueNasSessionRepository(
      connector: _Connector([first, second]),
      managementRequestTimeout: const Duration(milliseconds: 35),
    );
    addTearDown(repo.close);
    await _connect(repo);
    final h = _Harness(repo, first);
    final review = await _review(h, SystemUpdateAction.download);
    first.receipt = null;
    expect(
      (await repo.executeSystemUpdate(review, review.target)).outcome,
      SystemUpdateOutcome.unknown,
    );
    await _expectFence(h);
    await _connect(repo);
    await expectLater(
      repo.executeSystemUpdate(review, review.target),
      throwsA(_reason(SystemUpdatesExceptionReason.staleReview)),
    );
    expect(await repo.execute(_create), isA<ManagementCompleted>());
    expect(first.writes, hasLength(1));
    expect(second.updateRequests, isEmpty);
  });
}

SystemUpdateRequest _request(
  SystemUpdateInventory i,
  SystemUpdateAction action,
) => SystemUpdateRequest(
  inventory: i,
  action: action,
  version: action == SystemUpdateAction.check ? null : i.versions.first,
);

Future<SystemUpdateInventory> _checked(_Harness h) async {
  final result = await _execute(h, SystemUpdateAction.check);
  expect(result.outcome, SystemUpdateOutcome.checked);
  return result.inventory!;
}

Future<SystemUpdateReview> _review(
  _Harness h,
  SystemUpdateAction action,
) async {
  final i = action == SystemUpdateAction.check
      ? await h.repo.loadSystemUpdates()
      : await _checked(h);
  return h.repo.reviewSystemUpdate(_request(i, action));
}

Future<SystemUpdateResult> _execute(
  _Harness h,
  SystemUpdateAction action,
) async {
  final r = await _review(h, action);
  return h.repo.executeSystemUpdate(r, r.target);
}

Future<void> _expectFence(_Harness h, {bool localReadable = true}) async {
  final boundary = h.wire.requests.length;
  expect(h.repo.replicationCapabilities.canDelete, isTrue);
  expect(h.repo.cloudSyncCapabilities.canDelete, isTrue);
  await expectLater(
    h.repo.reviewReplication(
      ReplicationRequest(
        inventory: ReplicationInventory(
          endpoint: 'wss://synthetic.example/api/current',
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
          endpoint: 'wss://synthetic.example/api/current',
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
    h.repo.execute(_create),
    throwsA(
      isA<ManagementException>().having(
        (e) => e.reason,
        'reason',
        ManagementExceptionReason.busy,
      ),
    ),
  );
  await expectLater(
    h.repo.loadSmbShares(),
    throwsA(
      isA<SmbSharesException>().having(
        (e) => e.reason,
        'reason',
        SmbSharesExceptionReason.busy,
      ),
    ),
  );
  await expectLater(
    h.repo.loadNfsShares(),
    throwsA(
      isA<NfsSharesException>().having(
        (e) => e.reason,
        'reason',
        NfsSharesExceptionReason.busy,
      ),
    ),
  );
  expect(h.wire.requests.length, boundary);
  if (!localReadable) {
    await expectLater(
      h.repo.loadSystemUpdates(),
      throwsA(_reason(SystemUpdatesExceptionReason.invalidResponse)),
    );
    return;
  }
  final local = await h.repo.loadSystemUpdates();
  await expectLater(
    h.repo.reviewSystemUpdate(_request(local, SystemUpdateAction.check)),
    throwsA(_reason(SystemUpdatesExceptionReason.busy)),
  );
}

String _method(SystemUpdateAction action) =>
    action == SystemUpdateAction.download ? 'update.download' : 'update.run';
List<Object?> _arguments(SystemUpdateAction action) =>
    action == SystemUpdateAction.download
    ? [_train, _next]
    : [
        {
          'dataset_name': null,
          'resume': false,
          'train': _train,
          'version': _next,
          'reboot': false,
        },
      ];

Map<String, Object?> _be(
  String id, {
  bool active = false,
  bool activated = false,
}) => {
  'id': id,
  'dataset': 'boot-pool/ROOT/$id',
  'created': '2026-09-10T12:00:00',
  'used_bytes': 1073741824,
  'used': '1 GiB',
  'active': active,
  'activated': activated,
  'keep': true,
  'can_activate': true,
};
Map<String, Object?> _offer({String version = _next}) => {
  'train': _train,
  'version': {
    'version': version,
    'manifest': {
      'train': _train,
      'version': version,
      'filename': 'TrueNAS-SCALE-$version.update',
      'checksum': 'a' * 64,
      'filesize': 1780000000,
      'profile': 'GENERAL',
    },
    'release_notes': 'Synthetic release notes only.',
    'release_notes_url': 'https://www.truenas.com/docs/scale/',
  },
};

final class _Harness {
  _Harness(this.repo, this.wire);
  final TrueNasSessionRepository repo;
  final _Wire wire;
}

Future<_Harness> _connected({
  String version = _current,
  Set<String> methods = _methods,
  Map<String, Map<String, Object?>> overrides = const {},
  Duration timeout = const Duration(seconds: 2),
}) async {
  final wire = _Wire(version: version, methods: methods, overrides: overrides);
  final repo = TrueNasSessionRepository(
    connector: _Connector([wire]),
    managementRequestTimeout: timeout,
  );
  addTearDown(repo.close);
  await _connect(repo);
  return _Harness(repo, wire);
}

Future<ServerSummary> _connect(TrueNasSessionRepository repo) => repo.connect(
  serverInput: 'https://synthetic.example',
  username: 'fixture-user',
  apiKey: 'fixture-key',
);

final class _Connector implements RpcConnector {
  _Connector(this.wires);
  final List<_Wire> wires;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => wires.removeAt(0);
}

final class _Wire implements RpcTransport {
  _Wire({
    this.version = _current,
    this.methods = _methods,
    this.overrides = const {},
  });
  String version;
  final Set<String> methods;
  final Map<String, Map<String, Object?>> overrides;
  final _incoming = StreamController<String>();
  final requests = <Map<String, dynamic>>[];
  Object? licensed = false, receipt = 42;
  List<Object?> activeJobs = [];
  Map<String, Object?> boot = {
    'name': 'boot-pool',
    'path': '/',
    'status': 'ONLINE',
    'healthy': true,
    'warning': false,
    'scan': null,
    'size': 16 * 1024 * 1024 * 1024,
    'allocated': 4 * 1024 * 1024 * 1024,
    'free': 12 * 1024 * 1024 * 1024,
  };
  List<Map<String, Object?>> rows = [
    _be(_current, active: true, activated: true),
    _be('25.04.2'),
  ];
  List<Map<String, Object?>> offers = [_offer()];
  Map<String, Object?> status = {
    'code': 'NORMAL',
    'error': null,
    'status': {
      'current_version': {
        'train': _train,
        'profile': 'GENERAL',
        'matches_profile': true,
      },
      'new_version': _offer()['version'],
    },
    'update_download_progress': null,
  };
  Map get currentStatus => (status['status'] as Map)['current_version'] as Map;
  Map get manifest => (offers.first['version'] as Map)['manifest'] as Map;
  final suppressed = <String>{}, rejected = <String>{};
  bool rejectPoll = false;
  void Function(Map<String, dynamic>)? beforeRequest;
  Object? Function()? pollOverride;
  String jobState = 'RUNNING';
  Object? progress;
  final jobOverrides = <String, Object?>{};
  List<Map<String, dynamic>> get updateRequests => requests
      .where((r) => (r['method'] as String).startsWith('update.'))
      .toList();
  List<Map<String, dynamic>> get writes => requests
      .where(
        (r) => {
          'update.download',
          'update.run',
          'pool.dataset.create',
        }.contains(r['method']),
      )
      .toList();
  void completeInstall() {
    jobState = 'SUCCESS';
    for (final row in rows) {
      row['activated'] = false;
    }
    rows.add(_be(_next, activated: true)..['created'] = '2026-09-12T12:00:00');
  }

  @override
  Stream<String> get inboundFrames => _incoming.stream;
  @override
  Future<void> send(String frame) async {
    final r = jsonDecode(frame) as Map<String, dynamic>;
    requests.add(r);
    beforeRequest?.call(r);
    final method = r['method'] as String;
    if (suppressed.contains(method)) return;
    if (rejected.contains(method)) {
      reject(r);
      return;
    }
    Object? result;
    switch (method) {
      case 'auth.login_ex':
        result = {'response_type': 'SUCCESS'};
      case 'auth.me':
        result = {'username': 'fixture-user'};
      case 'system.info':
        result = {'version': version};
      case 'core.get_methods':
        result = {
          for (final name in methods)
            name: {
              'accepts': <Object?>[],
              'returns': [
                {'type': 'object', 'properties': <String, Object?>{}},
              ],
              'filterable': false,
              'check_pipes': <Object?>[],
              'roles': ['FULL_ADMIN'],
              'job': {'update.download', 'update.run'}.contains(name),
              'no_auth_required': false,
              'uploadable': false,
              'downloadable': false,
              ...?overrides[name],
            },
        };
      case 'system.version_short':
        result = version;
      case 'failover.licensed':
        result = licensed;
      case 'boot.get_state':
        result = boot;
      case 'boot.environment.query':
        result = rows;
      case 'update.status':
        result = status;
      case 'update.available_versions':
        result = offers;
      case 'update.download':
      case 'update.run':
        result = receipt;
      case 'pool.dataset.create':
        result = {'id': 'tank/documents'};
      case 'core.get_jobs':
        final filters = (r['params'] as List).first as List;
        final poll =
            filters.isNotEmpty && (filters.first as List).first == 'id';
        if (!poll) {
          result = activeJobs;
          break;
        }
        if (rejectPoll) {
          reject(r);
          return;
        }
        if (pollOverride != null) {
          result = pollOverride!();
          break;
        }
        final submitted = writes.lastWhere(
          (r) => (r['method'] as String).startsWith('update.'),
        );
        result = [
          {
            'id': 42,
            'method': submitted['method'],
            'arguments': submitted['params'],
            'state': jobState,
            'progress': progress,
            'result': true,
            ...jobOverrides,
          },
        ];
      default:
        throw StateError('Unexpected synthetic method $method');
    }
    respond(r, result);
  }

  void respond(Map<String, dynamic> r, Object? result) {
    if (!_incoming.isClosed) {
      _incoming.add(
        jsonEncode({'jsonrpc': '2.0', 'id': r['id'], 'result': result}),
      );
    }
  }

  void reject(Map<String, dynamic> r) => _incoming.add(
    jsonEncode({
      'jsonrpc': '2.0',
      'id': r['id'],
      'error': {
        'code': -1,
        'message': _secret,
        'data': {'errno': 13, 'details': _secret},
      },
    }),
  );
  @override
  Future<void> close() async {
    if (!_incoming.isClosed) await _incoming.close();
  }
}
