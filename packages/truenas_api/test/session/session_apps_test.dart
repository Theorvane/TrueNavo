import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

const _methods = {
  'app.query',
  'catalog.apps',
  'catalog.get_app_details',
  'catalog.config',
  'catalog.trains',
  'catalog.update',
  'catalog.sync',
  'docker.status',
  'docker.config',
  'core.get_jobs',
  'app.used_ports',
  'app.outdated_docker_images',
  'app.pull_images',
  'app.create',
  'app.start',
  'app.stop',
  'app.redeploy',
  'app.upgrade',
  'app.upgrade_summary',
  'app.delete',
  'app.config',
  'app.update',
};
Map<String, Object?> _row({
  String name = 'demo',
  String version = '1.0.0',
  String state = 'RUNNING',
}) => {
  'id': name,
  'name': name,
  'state': state,
  'version': version,
  'custom_app': false,
  'upgrade_available': true,
  'latest_version': '1.1.0',
  'image_updates_available': true,
  'metadata': {'name': 'demo', 'train': 'community'},
};
Map<String, Object?> _details(String version) => {
  'version': version,
  'human_version': '$version-app',
  'healthy': true,
  'supported': true,
  'app_metadata': {'name': 'demo', 'train': 'community', 'version': version},
  'schema': {
    'groups': [
      {'name': 'Configuration', 'description': 'Demo configuration'},
    ],
    'questions': [
      {
        'variable': 'enabled',
        'label': 'Enabled',
        'group': 'Configuration',
        'schema': {'type': 'boolean', 'default': true},
      },
      {
        'variable': 'password',
        'label': 'Password',
        'group': 'Configuration',
        'schema': {'type': 'string', 'private': true, 'required': true},
      },
      {
        'variable': 'port',
        'label': 'Port',
        'group': 'Configuration',
        'schema': {
          'type': 'int',
          'min': 1,
          'max': 65535,
          'default': 30013,
          r'$ref': ['definitions/port'],
        },
      },
    ],
  },
};
Map<String, Object?> get _values => {
  'enabled': true,
  'password': 'private-fixture-secret',
  'port': 30013,
};
Map<String, Object?> _configDetails() => {
  ..._details('1.0.0'),
  'schema': <String, Object?>{
    'questions': <Object?>[
      {
        'variable': 'preferences',
        'label': 'Preferences',
        'schema': {
          'type': 'dict',
          'attrs': [
            {
              'variable': 'enabled',
              'label': 'Enabled',
              'schema': {'type': 'boolean', 'default': false},
            },
            {
              'variable': 'title',
              'label': 'Title',
              'schema': {'type': 'string', 'min_length': 1},
            },
            {
              'variable': 'password',
              'label': 'Password',
              'schema': {'type': 'string', 'private': true},
            },
          ],
        },
      },
      {
        'variable': 'workers',
        'label': 'Workers',
        'schema': {'type': 'int', 'min': 1, 'max': 10, 'default': 1},
      },
      {
        'variable': 'fixed',
        'label': 'Fixed',
        'schema': {'type': 'string', 'immutable': true},
      },
    ],
  },
};
Matcher _reason(AppsExceptionReason reason) =>
    isA<AppsException>().having((e) => e.reason, 'reason', reason);

void main() {
  group('configuration editor', () {
    for (final rawNumber in [
      '9007199254740992',
      '9223372036854775809',
      '-9223372036854775808',
      '-9223372036854775809',
    ]) {
      test(
        'raw large numeric sibling $rawNumber cannot be round-tripped',
        () async {
          final h = await _connect();
          h.transport.rawConfigNumericToken = rawNumber;
          await expectLater(
            _configReview(h),
            throwsA(_reason(AppsExceptionReason.invalidResponse)),
          );
          expect(h.transport.writes, isEmpty);
        },
      );
    }
    test('newly oversized unknown number rejects before update', () async {
      final h = await _connect();
      final review = await _configReview(h);
      h.transport.rawConfigNumericToken = '9223372036854775809';
      expect(
        (await h.repo.updateApp(
          AppConfigUpdateRequest(
            review: review,
            patches: [AppConfigPatch(fieldId: '/workers', value: 4)],
          ),
        )).outcome,
        AppOperationOutcome.rejected,
      );
      expect(h.transport.writes, isEmpty);
    });
    for (final scenario in ['allowed', 'collision', 'malformed', 'duplicate']) {
      test('changed semantic port preflight $scenario', () async {
        final h = await _connect();
        final questions =
            (h.transport.configDetails['schema'] as Map)['questions'] as List;
        for (final name in ['port_a', 'port_b']) {
          questions.add({
            'variable': name,
            'label': name,
            'schema': {
              'type': 'int',
              'min': 1,
              'max': 65535,
              r'$ref': ['definitions/port'],
            },
          });
        }
        h.transport.savedConfig.addAll({'port_a': 30013, 'port_b': 30014});
        h.transport.usedPorts = scenario == 'collision'
            ? [30013, 30014, 30015]
            : scenario == 'malformed'
            ? {'bad': true}
            : [30013, 30014];
        final review = await _configReview(h);
        final patches = [
          AppConfigPatch(fieldId: '/port_a', value: 30015),
          if (scenario == 'duplicate')
            AppConfigPatch(fieldId: '/port_b', value: 30015),
        ];
        if (scenario == 'duplicate') {
          await expectLater(
            h.repo.updateApp(
              AppConfigUpdateRequest(review: review, patches: patches),
            ),
            throwsA(_reason(AppsExceptionReason.invalidInput)),
          );
        } else {
          final result = await h.repo.updateApp(
            AppConfigUpdateRequest(review: review, patches: patches),
          );
          expect(
            result.outcome,
            scenario == 'allowed'
                ? AppOperationOutcome.submitted
                : AppOperationOutcome.rejected,
          );
          if (scenario == 'allowed') {
            expect(
              (await h.repo.pollAppJob(result.job!)).outcome,
              AppOperationOutcome.verified,
            );
            expect(h.transport.savedConfig['port_a'], 30015);
            expect(h.transport.savedConfig['port_b'], 30014);
            final reads = h.transport.requests.map((r) => r['method']).toList();
            final usedIndex = reads.indexOf('app.used_ports');
            expect(reads[usedIndex + 1], 'app.config');
            expect(reads[usedIndex + 2], 'app.update');
          }
        }
        expect(h.transport.writes.length, scenario == 'allowed' ? 1 : 0);
      });
    }
    test('editing no semantic port performs no used-port query', () async {
      final h = await _connect();
      final review = await _configReview(h);
      final result = await h.repo.updateApp(
        AppConfigUpdateRequest(
          review: review,
          patches: [AppConfigPatch(fieldId: '/workers', value: 4)],
        ),
      );
      expect(result.outcome, AppOperationOutcome.submitted);
      expect(
        h.transport.requests.where((r) => r['method'] == 'app.used_ports'),
        isEmpty,
      );
    });
    test(
      'read-only account can inspect safe review but cannot submit settings',
      () async {
        final h = await _connect(methods: _methods.difference({'app.update'}));
        final review = await _configReview(h);
        expect(review.schema.supported, isTrue);
        expect(
          review.schema.fields
              .singleWhere((field) => field.id == '/preferences/password')
              .currentValue,
          isNull,
        );
        await expectLater(
          h.repo.updateApp(
            AppConfigUpdateRequest(
              review: review,
              patches: [AppConfigPatch(fieldId: '/workers', value: 4)],
            ),
          ),
          throwsA(_reason(AppsExceptionReason.unavailableMethod)),
        );
        expect(h.transport.writes, isEmpty);
      },
    );
    test(
      'failed update may already have changed config and remains unknown',
      () async {
        final h = await _connect();
        final review = await _configReview(h);
        final result = await h.repo.updateApp(
          AppConfigUpdateRequest(
            review: review,
            patches: [AppConfigPatch(fieldId: '/workers', value: 4)],
          ),
        );
        h.transport.savedConfig['workers'] = 4;
        h.transport.jobState = 'FAILED';
        expect(
          (await h.repo.pollAppJob(result.job!)).outcome,
          AppOperationOutcome.unknown,
        );
        final app = (await h.repo.loadAppsInventory()).apps.single;
        await expectLater(
          h.repo.changeAppState(app, AppLifecycleAction.stop),
          throwsA(_reason(AppsExceptionReason.busy)),
        );
        expect(h.transport.writes, hasLength(1));
      },
    );
    test(
      'review exposes nonsecret scalars and exact installed schema only',
      () async {
        final h = await _connect();
        final review = await _configReview(h);
        expect(
          review.schema.fields.any(
            (field) => field.currentValue == 'Current title',
          ),
          isTrue,
        );
        final private = review.schema.fields.singleWhere(
          (field) => field.id == '/preferences/password',
        );
        expect(private.secret, isTrue);
        expect(private.currentValue, isNull);
        expect(private.editable, isFalse);
        expect(
          jsonEncode(
            review.schema.parameters.map((p) => p.schema.raw).toList(),
          ),
          isNot(contains('existing-private-password')),
        );
        expect(review.toString(), isNot(contains('existing-private-password')));
        final query = h.transport.requests.singleWhere(
          (r) =>
              r['method'] == 'app.query' &&
              (((r['params'] as List)[1] as Map)['extra']
                      as Map)['include_app_schema'] ==
                  true,
        );
        expect(
          (((query['params'] as List)[1] as Map)['extra']
              as Map)['retrieve_config'],
          isFalse,
        );
        expect(
          h.transport.requests.where(
            (r) => r['method'] == 'catalog.get_app_details',
          ),
          isEmpty,
        );
        expect(h.transport.writes, isEmpty);
      },
    );
    test(
      'nested leaf update preserves secret unknown and list siblings exactly',
      () async {
        final h = await _connect();
        final before = jsonDecode(jsonEncode(h.transport.savedConfig)) as Map;
        final review = await _configReview(h);
        final request = AppConfigUpdateRequest(
          review: review,
          patches: [
            AppConfigPatch(fieldId: '/preferences/enabled', value: false),
          ],
        );
        final result = await h.repo.updateApp(request);
        expect(result.outcome, AppOperationOutcome.submitted);
        final values =
            ((h.transport.writes.single['params'] as List)[1] as Map)['values']
                as Map;
        expect(values.keys, ['preferences']);
        expect(values['preferences'], {
          ...before['preferences'] as Map,
          'enabled': false,
        });
        expect(values.containsKey('ix_context'), isFalse);
        expect(
          request.toString(),
          isNot(contains('existing-private-password')),
        );
        h.transport.redactUpdateArgs = true;
        expect(
          (await h.repo.pollAppJob(result.job!)).outcome,
          AppOperationOutcome.verified,
        );
        expect(h.transport.savedConfig, {
          ...before,
          'preferences': {...before['preferences'] as Map, 'enabled': false},
        });
        expect(h.transport.requests.last['method'], 'app.config');
      },
    );
    test('stopped app stays stopped while configuration is verified', () async {
      final h = await _connect();
      h.transport.rows.single['state'] = 'STOPPED';
      final review = await _configReview(h);
      final result = await h.repo.updateApp(
        AppConfigUpdateRequest(
          review: review,
          patches: [AppConfigPatch(fieldId: '/workers', value: 4)],
        ),
      );
      expect(
        (await h.repo.pollAppJob(result.job!)).outcome,
        AppOperationOutcome.verified,
      );
      expect(h.transport.rows.single['state'], 'STOPPED');
    });
    for (final field in [
      '/preferences/password',
      '/fixed',
      '/unknown',
      '/ix_context',
    ]) {
      test('unsupported leaf $field cannot be changed', () async {
        final h = await _connect();
        final review = await _configReview(h);
        await expectLater(
          h.repo.updateApp(
            AppConfigUpdateRequest(
              review: review,
              patches: [AppConfigPatch(fieldId: field, value: 'new-secret')],
            ),
          ),
          throwsA(_reason(AppsExceptionReason.invalidInput)),
        );
        expect(h.transport.writes, isEmpty);
      });
    }
    for (final drift in [
      'config-secret',
      'config-unknown',
      'schema',
      'version',
      'pool',
    ]) {
      test('$drift drift rejects before updating configuration', () async {
        final h = await _connect();
        final review = await _configReview(h);
        switch (drift) {
          case 'config-secret':
            (h.transport.savedConfig['preferences'] as Map)['password'] =
                'changed-secret';
          case 'config-unknown':
            (h.transport.savedConfig['preferences'] as Map)['unknown'] =
                'other';
          case 'schema':
            h.transport.configDetails['human_version'] =
                'changed-schema-metadata';
          case 'version':
            h.transport.rows.single['version'] = '1.0.1';
          case 'pool':
            h.transport.pool = 'other';
        }
        expect(
          (await h.repo.updateApp(
            AppConfigUpdateRequest(
              review: review,
              patches: [AppConfigPatch(fieldId: '/workers', value: 4)],
            ),
          )).outcome,
          AppOperationOutcome.rejected,
        );
        expect(h.transport.writes, isEmpty);
      });
    }
    test('post-job secret drift is unknown and holds mutation lock', () async {
      final h = await _connect();
      final review = await _configReview(h);
      final result = await h.repo.updateApp(
        AppConfigUpdateRequest(
          review: review,
          patches: [AppConfigPatch(fieldId: '/workers', value: 4)],
        ),
      );
      h.transport.configReadbackMismatch = true;
      final unknown = await h.repo.pollAppJob(result.job!);
      expect(unknown.outcome, AppOperationOutcome.unknown);
      expect(unknown.userMessage, isNot(contains('changed-server-secret')));
      final app = (await h.repo.loadAppsInventory()).apps.single;
      await expectLater(
        h.repo.changeAppState(app, AppLifecycleAction.stop),
        throwsA(_reason(AppsExceptionReason.busy)),
      );
    });
    test(
      'completed update invalidates its previous configuration review',
      () async {
        final h = await _connect();
        final review = await _configReview(h);
        final result = await h.repo.updateApp(
          AppConfigUpdateRequest(
            review: review,
            patches: [AppConfigPatch(fieldId: '/workers', value: 4)],
          ),
        );
        expect(
          (await h.repo.pollAppJob(result.job!)).outcome,
          AppOperationOutcome.verified,
        );
        await expectLater(
          h.repo.updateApp(
            AppConfigUpdateRequest(
              review: review,
              patches: [AppConfigPatch(fieldId: '/workers', value: 5)],
            ),
          ),
          throwsA(_reason(AppsExceptionReason.staleSnapshot)),
        );
      },
    );
    test(
      'forged configuration review never grants mutation authority',
      () async {
        final h = await _connect();
        final review = await _configReview(h);
        final forged = AppConfigReview(
          app: review.app,
          schema: review.schema,
          warnings: review.warnings,
        );
        await expectLater(
          h.repo.updateApp(
            AppConfigUpdateRequest(
              review: forged,
              patches: [AppConfigPatch(fieldId: '/workers', value: 4)],
            ),
          ),
          throwsA(_reason(AppsExceptionReason.staleSnapshot)),
        );
        expect(h.transport.writes, isEmpty);
      },
    );
    test(
      'configuration update timeout never retries or leaks retained settings',
      () async {
        final h = await _connect();
        final review = await _configReview(h);
        h.transport.writeFailure = 'timeout';
        final result = await h.repo.updateApp(
          AppConfigUpdateRequest(
            review: review,
            patches: [AppConfigPatch(fieldId: '/workers', value: 4)],
          ),
        );
        expect(result.outcome, AppOperationOutcome.unknown);
        expect(result.toString(), isNot(contains('existing-private-password')));
        expect(h.transport.writes, hasLength(1));
      },
    );
  });
  test('disconnected inventory sends no request', () async {
    final h = _Harness();
    addTearDown(h.repo.close);
    expect(h.repo.appsCapabilities.supported, isFalse);
    await expectLater(
      h.repo.loadAppsInventory(),
      throwsA(_reason(AppsExceptionReason.notAuthenticated)),
    );
    expect(h.transport.requests, isEmpty);
  });
  for (final version in ['25.04.2', '25.10-BETA.1', '26.0.1']) {
    test(
      'unsupported server $version does not discover applications',
      () async {
        final h = await _connect(version: version);
        expect(h.repo.appsCapabilities.supported, isFalse);
        await expectLater(
          h.repo.loadAppsCatalog(),
          throwsA(_reason(AppsExceptionReason.unsupportedVersion)),
        );
        expect(
          h.transport.requests.where((r) => r['method'] == 'catalog.apps'),
          isEmpty,
        );
      },
    );
  }
  test('missing job read permission gates capability', () async {
    final h = await _connect(methods: _methods.difference({'core.get_jobs'}));
    expect(h.repo.appsCapabilities.supported, isFalse);
    await expectLater(
      h.repo.loadAppsInventory(),
      throwsA(_reason(AppsExceptionReason.unavailableMethod)),
    );
  });
  test(
    'catalog overview reads bounded server trains and preferred settings only',
    () async {
      final h = await _connect();
      final overview = await h.repo.loadCatalogOverview();
      expect(overview.availableTrains, ['community', 'stable']);
      expect(overview.preferredTrains, ['stable']);
      expect(
        () => overview.availableTrains.add('other'),
        throwsUnsupportedError,
      );
      expect(() => overview.preferredTrains.clear(), throwsUnsupportedError);
      expect(
        h.transport.requests
            .where((r) => r['method'] == 'catalog.trains')
            .single['params'],
        [],
      );
      expect(
        h.transport.requests
            .where((r) => r['method'] == 'catalog.config')
            .single['params'],
        [],
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test(
    'malformed catalog overview fails closed without returning settings',
    () async {
      final h = await _connect();
      h.transport.catalogTrains = ['community', 'community'];
      await expectLater(
        h.repo.loadCatalogOverview(),
        throwsA(_reason(AppsExceptionReason.invalidResponse)),
      );
      h.transport.catalogTrains = ['community', 'stable'];
      h.transport.preferredTrains = ['\u202Eunsafe'];
      await expectLater(
        h.repo.loadCatalogOverview(),
        throwsA(_reason(AppsExceptionReason.invalidResponse)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test('missing catalog overview method issues no partial request', () async {
    final h = await _connect(methods: _methods.difference({'catalog.config'}));
    await expectLater(
      h.repo.loadCatalogOverview(),
      throwsA(_reason(AppsExceptionReason.unavailableMethod)),
    );
    expect(
      h.transport.requests.where((r) => r['method'] == 'catalog.trains'),
      isEmpty,
    );
  });
  test(
    'preferred trains update uses exact reviewed list and verifies readback',
    () async {
      final h = await _connect();
      final overview = await h.repo.loadCatalogOverview();
      final result = await h.repo.updateCatalogPreferredTrains(overview, [
        'community',
      ]);
      expect(result.outcome, AppOperationOutcome.verified);
      expect(h.transport.writes.single['method'], 'catalog.update');
      expect(h.transport.writes.single['params'], [
        {
          'preferred_trains': ['community'],
        },
      ]);
      expect(h.transport.preferredTrains, ['community']);
      expect((await h.repo.loadCatalogOverview()).preferredTrains, [
        'community',
      ]);
      expect(
        (await h.repo.updateCatalogPreferredTrains(overview, [
          'stable',
        ])).outcome,
        AppOperationOutcome.rejected,
      );
    },
  );
  test('stale catalog preference review rejects without a write', () async {
    final h = await _connect();
    final overview = await h.repo.loadCatalogOverview();
    h.transport.preferredTrains = ['community'];
    final result = await h.repo.updateCatalogPreferredTrains(overview, [
      'stable',
      'community',
    ]);
    expect(result.outcome, AppOperationOutcome.rejected);
    expect(h.transport.writes, isEmpty);
  });
  test('invalid catalog preference target and no-op never write', () async {
    final h = await _connect();
    final overview = await h.repo.loadCatalogOverview();
    expect(
      (await h.repo.updateCatalogPreferredTrains(overview, [
        'missing',
      ])).outcome,
      AppOperationOutcome.rejected,
    );
    expect(
      (await h.repo.updateCatalogPreferredTrains(overview, ['stable'])).outcome,
      AppOperationOutcome.rejected,
    );
    expect(h.transport.writes, isEmpty);
  });
  test(
    'uncertain catalog update is not replayed on the same session',
    () async {
      final h = await _connect();
      final overview = await h.repo.loadCatalogOverview();
      h.transport.catalogUpdateTimeout = true;
      expect(
        (await h.repo.updateCatalogPreferredTrains(overview, [
          'community',
        ])).outcome,
        AppOperationOutcome.unknown,
      );
      expect(h.transport.writes.length, 1);
      await expectLater(
        h.repo.updateCatalogPreferredTrains(overview, ['community']),
        throwsA(_reason(AppsExceptionReason.busy)),
      );
      expect(h.transport.writes.length, 1);
    },
  );
  for (final mismatch in ['response', 'readback']) {
    test(
      'catalog update $mismatch mismatch remains unknown and locked',
      () async {
        final h = await _connect();
        final overview = await h.repo.loadCatalogOverview();
        h.transport.catalogUpdateMismatch = mismatch;
        final result = await h.repo.updateCatalogPreferredTrains(overview, [
          'community',
        ]);
        expect(result.outcome, AppOperationOutcome.unknown);
        expect(h.transport.writes.length, 1);
        final fresh = await h.repo.loadCatalogOverview();
        await expectLater(
          h.repo.updateCatalogPreferredTrains(fresh, ['stable', 'community']),
          throwsA(_reason(AppsExceptionReason.busy)),
        );
        expect(h.transport.writes.length, 1);
      },
    );
  }
  test(
    'catalog sync submits no arguments and verifies its owned successful job',
    () async {
      final h = await _connect();
      final overview = await h.repo.loadCatalogOverview();
      final result = await h.repo.syncCatalog(overview);
      expect(result.outcome, AppOperationOutcome.submitted);
      expect(result.job!.operation, 'catalog.sync');
      expect(h.transport.writes.single['params'], []);
      h.transport.jobState = 'RUNNING';
      h.transport.progress = 47;
      final running = await h.repo.pollAppJob(result.job!);
      expect(running.outcome, AppOperationOutcome.running);
      expect(running.progressPercent, 47);
      h.transport.jobState = 'SUCCESS';
      h.transport.catalogTrains = ['community', 'stable', 'testing'];
      expect(
        (await h.repo.pollAppJob(result.job!)).outcome,
        AppOperationOutcome.verified,
      );
      expect(
        (await h.repo.loadCatalogOverview()).availableTrains,
        contains('testing'),
      );
      expect(
        (await h.repo.syncCatalog(overview)).outcome,
        AppOperationOutcome.rejected,
      );
      expect(h.transport.writes.length, 1);
    },
  );
  test(
    'catalog sync stale overview and missing permission never dispatch',
    () async {
      final h = await _connect();
      final overview = await h.repo.loadCatalogOverview();
      h.transport.preferredTrains = ['community'];
      expect(
        (await h.repo.syncCatalog(overview)).outcome,
        AppOperationOutcome.rejected,
      );
      expect(h.transport.writes, isEmpty);
      final denied = await _connect(
        methods: _methods.difference({'catalog.sync'}),
      );
      final deniedOverview = await denied.repo.loadCatalogOverview();
      await expectLater(
        denied.repo.syncCatalog(deniedOverview),
        throwsA(_reason(AppsExceptionReason.unavailableMethod)),
      );
      expect(denied.transport.writes, isEmpty);
    },
  );
  test('catalog sync timeout fences any replay on the same session', () async {
    final h = await _connect();
    final overview = await h.repo.loadCatalogOverview();
    h.transport.writeFailure = 'timeout';
    expect(
      (await h.repo.syncCatalog(overview)).outcome,
      AppOperationOutcome.unknown,
    );
    expect(h.transport.writes.length, 1);
    final fresh = await h.repo.loadCatalogOverview();
    await expectLater(
      h.repo.syncCatalog(fresh),
      throwsA(_reason(AppsExceptionReason.busy)),
    );
    expect(h.transport.writes.length, 1);
  });
  for (final mismatch in [
    'job-id',
    'job-method',
    'job-arguments',
    'empty-job',
  ]) {
    test('catalog sync $mismatch is unknown and not retried', () async {
      final h = await _connect();
      final overview = await h.repo.loadCatalogOverview();
      final result = await h.repo.syncCatalog(overview);
      h.transport.pollMismatch = mismatch;
      expect(
        (await h.repo.pollAppJob(result.job!)).outcome,
        AppOperationOutcome.unknown,
      );
      expect(h.transport.writes.length, 1);
    });
  }
  test(
    'catalog sync success without valid fresh settings stays unknown',
    () async {
      final h = await _connect();
      final overview = await h.repo.loadCatalogOverview();
      final result = await h.repo.syncCatalog(overview);
      h.transport.catalogTrains = ['community', 'community'];
      expect(
        (await h.repo.pollAppJob(result.job!)).outcome,
        AppOperationOutcome.unknown,
      );
      expect(h.transport.writes.length, 1);
    },
  );
  test(
    'failed catalog sync job releases mutation ownership but clears reviews',
    () async {
      final h = await _connect();
      final overview = await h.repo.loadCatalogOverview();
      final result = await h.repo.syncCatalog(overview);
      h.transport.jobState = 'FAILED';
      expect(
        (await h.repo.pollAppJob(result.job!)).outcome,
        AppOperationOutcome.failed,
      );
      expect(
        (await h.repo.syncCatalog(overview)).outcome,
        AppOperationOutcome.rejected,
      );
      final fresh = await h.repo.loadCatalogOverview();
      expect(
        (await h.repo.syncCatalog(fresh)).outcome,
        AppOperationOutcome.submitted,
      );
      expect(h.transport.writes.length, 2);
    },
  );
  test(
    'installed notes and portals are read only on exact selected app',
    () async {
      final h = await _connect();
      final app = (await h.repo.loadAppsInventory()).apps.single;
      final details = await h.repo.loadInstalledAppDetails(app);
      expect(details.app, same(app));
      expect(details.notes, 'Operator note\nSecond line');
      expect(details.portals, {'Web UI': 'https://nas.example:3000/ui'});
      expect(details.workloads.runningContainers, 2);
      expect(details.workloads.portMappings, 1);
      expect(details.workloads.volumes, 1);
      expect(details.workloads.images, 2);
      expect(() => details.portals.clear(), throwsUnsupportedError);
      expect(h.transport.requests.last['method'], 'app.query');
      expect(h.transport.requests.last['params'], [
        [
          ['id', '=', 'demo'],
        ],
        {
          'limit': 2,
          'select': [
            'id',
            'name',
            'version',
            'notes',
            'portals',
            'active_workloads',
          ],
          'extra': {'retrieve_config': false, 'include_app_schema': false},
        },
      ]);
      expect(h.transport.writes, isEmpty);
    },
  );
  test(
    'outdated image names require exact selected app and are immutable',
    () async {
      final h = await _connect();
      final app = (await h.repo.loadAppsInventory()).apps.single;
      final images = await h.repo.loadOutdatedAppImages(app);
      expect(images, ['example/media:latest']);
      expect(() => images.clear(), throwsUnsupportedError);
      expect(
        h.transport.requests[h.transport.requests.length - 2]['method'],
        'app.query',
      );
      expect(h.transport.requests[h.transport.requests.length - 2]['params'], [
        [
          ['id', '=', 'demo'],
        ],
        {
          'limit': 2,
          'select': ['id', 'name', 'version', 'image_updates_available'],
          'extra': {'retrieve_config': false, 'include_app_schema': false},
        },
      ]);
      expect(h.transport.requests.last['method'], 'app.outdated_docker_images');
      expect(h.transport.requests.last['params'], ['demo']);
      expect(h.transport.writes, isEmpty);
    },
  );
  test('outdated image check rejects stale and malformed responses', () async {
    final h = await _connect();
    final app = (await h.repo.loadAppsInventory()).apps.single;
    h.transport.rows.single['image_updates_available'] = false;
    await expectLater(
      h.repo.loadOutdatedAppImages(app),
      throwsA(_reason(AppsExceptionReason.staleSnapshot)),
    );
    expect(h.transport.requests.last['method'], 'app.query');
    h.transport.rows.single['image_updates_available'] = true;
    h.transport.outdatedImages = ['bad\nname'];
    await expectLater(
      h.repo.loadOutdatedAppImages(app),
      throwsA(_reason(AppsExceptionReason.invalidResponse)),
    );
    expect(h.transport.writes, isEmpty);
  });
  test(
    'outdated image check rejects an old inventory handle before RPC',
    () async {
      final h = await _connect();
      final oldApp = (await h.repo.loadAppsInventory()).apps.single;
      await h.repo.loadAppsInventory();
      final before = h.transport.requests.length;
      await expectLater(
        h.repo.loadOutdatedAppImages(oldApp),
        throwsA(_reason(AppsExceptionReason.staleSnapshot)),
      );
      expect(h.transport.requests.length, before);
    },
  );
  test(
    'image pull submits only no-redeploy job and verifies identity',
    () async {
      final h = await _connect();
      final app = (await h.repo.loadAppsInventory()).apps.single;
      final names = await h.repo.loadOutdatedAppImages(app);
      final result = await h.repo.pullAppImages(
        AppImagePullRequest(
          app: app,
          expectedImages: names,
          confirmedName: app.name,
        ),
      );
      expect(result.outcome, AppOperationOutcome.submitted);
      expect(h.transport.writes.single['method'], 'app.pull_images');
      expect(h.transport.writes.single['params'], [
        'demo',
        {'redeploy': false},
      ]);
      expect(
        (await h.repo.pollAppJob(result.job!)).outcome,
        AppOperationOutcome.verified,
      );
    },
  );
  test('image pull rejects changed list and wrong confirmation', () async {
    final h = await _connect();
    final app = (await h.repo.loadAppsInventory()).apps.single;
    final names = await h.repo.loadOutdatedAppImages(app);
    await expectLater(
      h.repo.pullAppImages(
        AppImagePullRequest(
          app: app,
          expectedImages: names,
          confirmedName: 'wrong',
        ),
      ),
      throwsA(_reason(AppsExceptionReason.invalidInput)),
    );
    h.transport.outdatedImages = ['different/image:latest'];
    expect(
      (await h.repo.pullAppImages(
        AppImagePullRequest(
          app: app,
          expectedImages: names,
          confirmedName: app.name,
        ),
      )).outcome,
      AppOperationOutcome.rejected,
    );
    expect(h.transport.writes, isEmpty);
  });
  test(
    'failed image pull is uncertain because download may be partial',
    () async {
      final h = await _connect();
      final app = (await h.repo.loadAppsInventory()).apps.single;
      final names = await h.repo.loadOutdatedAppImages(app);
      final result = await h.repo.pullAppImages(
        AppImagePullRequest(
          app: app,
          expectedImages: names,
          confirmedName: app.name,
        ),
      );
      h.transport.jobState = 'FAILED';
      expect(
        (await h.repo.pollAppJob(result.job!)).outcome,
        AppOperationOutcome.unknown,
      );
    },
  );
  test('image pull rejects a job that claims redeploy was enabled', () async {
    final h = await _connect();
    final app = (await h.repo.loadAppsInventory()).apps.single;
    final names = await h.repo.loadOutdatedAppImages(app);
    final result = await h.repo.pullAppImages(
      AppImagePullRequest(
        app: app,
        expectedImages: names,
        confirmedName: app.name,
      ),
    );
    h.transport.pollMismatch = 'pull-redeploy';
    expect(
      (await h.repo.pollAppJob(result.job!)).outcome,
      AppOperationOutcome.unknown,
    );
  });
  test('image pull keeps a stopped app stopped', () async {
    final h = await _connect();
    h.transport.rows.single['state'] = 'STOPPED';
    final app = (await h.repo.loadAppsInventory()).apps.single;
    final names = await h.repo.loadOutdatedAppImages(app);
    final result = await h.repo.pullAppImages(
      AppImagePullRequest(
        app: app,
        expectedImages: names,
        confirmedName: app.name,
      ),
    );
    expect(
      (await h.repo.pollAppJob(result.job!)).outcome,
      AppOperationOutcome.verified,
    );
    expect(h.transport.rows.single['state'], 'STOPPED');
  });
  var invalidImageCase = 0;
  for (final invalidImages in [
    ['duplicate:1', 'duplicate:1'],
    List<String>.filled(65, 'image:1'),
  ]) {
    final caseNumber = ++invalidImageCase;
    test('outdated image list rejects invalid case $caseNumber', () async {
      final h = await _connect();
      final app = (await h.repo.loadAppsInventory()).apps.single;
      h.transport.outdatedImages = invalidImages;
      await expectLater(
        h.repo.loadOutdatedAppImages(app),
        throwsA(_reason(AppsExceptionReason.invalidResponse)),
      );
      expect(h.transport.writes, isEmpty);
    });
  }
  for (final badPortal in [
    'javascript:alert(1)',
    'https://name:secret@host/ui',
    'http://host/\nnext',
  ]) {
    test('unsafe installed portal is withheld: $badPortal', () async {
      final h = await _connect();
      final app = (await h.repo.loadAppsInventory()).apps.single;
      h.transport.appPortals = {'Web UI': badPortal};
      await expectLater(
        h.repo.loadInstalledAppDetails(app),
        throwsA(_reason(AppsExceptionReason.invalidResponse)),
      );
      expect(h.transport.writes, isEmpty);
    });
  }
  var workloadCase = 0;
  for (final badWorkloads in [
    {'containers': -1, 'used_ports': [], 'volumes': [], 'images': []},
    {
      'containers': 1,
      'used_ports': ['not a port mapping'],
      'volumes': [],
      'images': [],
    },
    {
      'containers': 1,
      'used_ports': [],
      'volumes': List.filled(2049, <String, Object?>{}),
      'images': [],
    },
  ]) {
    final caseNumber = ++workloadCase;
    test(
      'malformed workload summary $caseNumber is withheld without writes',
      () async {
        final h = await _connect();
        final app = (await h.repo.loadAppsInventory()).apps.single;
        h.transport.appWorkloads = badWorkloads;
        await expectLater(
          h.repo.loadInstalledAppDetails(app),
          throwsA(_reason(AppsExceptionReason.invalidResponse)),
        );
        expect(h.transport.writes, isEmpty);
      },
    );
  }
  test(
    'oversized installed notes and stale inventory handle fail closed',
    () async {
      final h = await _connect();
      final oldApp = (await h.repo.loadAppsInventory()).apps.single;
      h.transport.appNotes = 'x' * 4097;
      await expectLater(
        h.repo.loadInstalledAppDetails(oldApp),
        throwsA(_reason(AppsExceptionReason.invalidResponse)),
      );
      h.transport.appNotes = null;
      await h.repo.loadAppsInventory();
      await expectLater(
        h.repo.loadInstalledAppDetails(oldApp),
        throwsA(_reason(AppsExceptionReason.staleSnapshot)),
      );
    },
  );
  for (final badField in ['latest_version', 'image_updates_available']) {
    test('invalid $badField inventory value fails closed', () async {
      final h = await _connect();
      h.transport.rows.single[badField] = 42;
      await expectLater(
        h.repo.loadAppsInventory(),
        throwsA(_reason(AppsExceptionReason.invalidResponse)),
      );
      expect(h.transport.writes, isEmpty);
    });
  }
  test('inventory and catalogue reads are bounded and never retrieve configuration', () async {
    final h = await _connect();
    final inventory = await h.repo.loadAppsInventory();
    expect(inventory.ready, isTrue);
    expect(inventory.apps.single.catalogApp, 'demo');
    expect(inventory.apps.single.latestVersion, '1.1.0');
    expect(inventory.apps.single.imageUpdatesAvailable, isTrue);
    expect(() => inventory.apps.clear(), throwsUnsupportedError);
    final query = h.transport.requests.last['params'] as List;
    expect((query[1] as Map)['limit'], 1025);
    expect((query[1] as Map)['extra'], {
      'retrieve_config': false,
      'include_app_schema': false,
    });
    expect((query[1] as Map)['select'], isNot(contains('config')));
    expect(
      (query[1] as Map)['select'],
      containsAll(['latest_version', 'image_updates_available']),
    );
    final catalog = await h.repo.loadAppsCatalog();
    expect(catalog.single.name, 'demo');
    expect(catalog.single.categories, ['Media', 'Productivity']);
    expect(catalog.single.tags, ['streaming', 'library']);
    expect(catalog.single.recommended, isTrue);
    expect(() => catalog.single.categories.clear(), throwsUnsupportedError);
    expect(() => catalog.single.tags.clear(), throwsUnsupportedError);
    expect(h.transport.requests.last['params'], [
      {
        'cache': true,
        'cache_only': false,
        'retrieve_all_trains': true,
        'trains': [],
      },
    ]);
    expect(await h.repo.loadAppVersions(catalog.single), ['1.1.0', '1.0.0']);
    expect(h.transport.writes, isEmpty);
  });
  test(
    'catalog classification rejects malformed or excessive metadata',
    () async {
      final h = await _connect();
      for (final invalid in <Object?>[
        {'categories': 'Media'},
        {
          'categories': [null],
        },
        {
          'categories': ['bad\nlabel'],
        },
        {'categories': List.filled(17, 'Media')},
        {'tags': List.filled(33, 'tag')},
        {'recommended': 'yes'},
      ]) {
        h.transport.catalogRowOverride = {
          'name': 'demo',
          'title': 'Demo',
          'description': 'Demo application',
          'healthy': true,
          ...(invalid as Map<String, Object?>),
        };
        await expectLater(
          h.repo.loadAppsCatalog(),
          throwsA(_reason(AppsExceptionReason.invalidResponse)),
        );
      }
      expect(h.transport.writes, isEmpty);
    },
  );
  test(
    'legacy missing classification remains an empty public subset',
    () async {
      final h = await _connect();
      h.transport.catalogRowOverride = {
        'name': 'demo',
        'title': 'Demo',
        'description': 'Demo application',
        'healthy': true,
      };
      final app = (await h.repo.loadAppsCatalog()).single;
      expect(app.categories, isEmpty);
      expect(app.tags, isEmpty);
      expect(app.recommended, isFalse);
      expect(h.transport.writes, isEmpty);
    },
  );
  test(
    'cached-only catalog list cannot open versions until normal reload',
    () async {
      final h = await _connect();
      final cached = (await h.repo.loadAppsCatalog(cachedOnly: true)).single;
      expect(h.transport.requests.last['params'], [
        {
          'cache': true,
          'cache_only': true,
          'retrieve_all_trains': true,
          'trains': [],
        },
      ]);
      await expectLater(
        h.repo.loadAppVersions(cached),
        throwsA(_reason(AppsExceptionReason.invalidInput)),
      );
      await expectLater(
        h.repo.loadAppVersionDetails(cached, '1.1.0'),
        throwsA(_reason(AppsExceptionReason.invalidInput)),
      );
      expect(
        h.transport.requests.where(
          (r) => r['method'] == 'catalog.get_app_details',
        ),
        isEmpty,
      );
      final normal = (await h.repo.loadAppsCatalog()).single;
      await expectLater(
        h.repo.loadAppVersions(cached),
        throwsA(_reason(AppsExceptionReason.staleSnapshot)),
      );
      expect(await h.repo.loadAppVersions(normal), ['1.1.0', '1.0.0']);
      expect(h.transport.writes, isEmpty);
    },
  );
  test(
    'catalogue and installed handles are bound to their issuing connection',
    () async {
      final first = await _connect();
      final second = await _connect();
      final catalog = (await first.repo.loadAppsCatalog()).single;
      final app = (await first.repo.loadAppsInventory()).apps.single;
      await expectLater(
        second.repo.loadAppVersions(catalog),
        throwsA(_reason(AppsExceptionReason.staleSnapshot)),
      );
      await expectLater(
        second.repo.changeAppState(app, AppLifecycleAction.stop),
        throwsA(_reason(AppsExceptionReason.staleSnapshot)),
      );
      expect(second.transport.writes, isEmpty);
    },
  );
  test(
    'independent inventory and catalogue reads queue without a busy failure',
    () async {
      final h = await _connect();
      final results = await Future.wait<Object>([
        h.repo.loadAppsInventory(),
        h.repo.loadAppsCatalog(),
      ]);
      expect((results[0] as AppsInventory).ready, isTrue);
      expect(results[1] as List<CatalogApp>, hasLength(1));
      expect(h.transport.writes, isEmpty);
    },
  );
  test('catalogue reload invalidates previously reviewed forms', () async {
    final h = await _connect();
    final details = await _review(h);
    await h.repo.loadAppsCatalog();
    await expectLater(
      h.repo.installApp(
        AppInstallRequest(
          details: details,
          appName: 'new-demo',
          values: _values,
        ),
      ),
      throwsA(_reason(AppsExceptionReason.invalidInput)),
    );
    expect(h.transport.writes, isEmpty);
  });
  for (final name in ['latest', '1.1', '1.1.0-beta', '1.1.0/other']) {
    test(
      'version $name cannot resolve as a concrete reviewed version',
      () async {
        final h = await _connect();
        final catalog = (await h.repo.loadAppsCatalog()).single;
        await expectLater(
          h.repo.loadAppVersionDetails(catalog, name),
          throwsA(_reason(AppsExceptionReason.invalidInput)),
        );
      },
    );
  }
  test('install uses reviewed concrete version and verifies its owned job by readback', () async {
    final h = await _connect();
    final details = await _review(h);
    expect(details.supported, isTrue);
    final request = AppInstallRequest(
      details: details,
      appName: 'new-demo',
      values: _values,
    );
    expect(request.toString(), isNot(contains('private-fixture-secret')));
    final result = await h.repo.installApp(request);
    expect(result.outcome, AppOperationOutcome.submitted);
    expect(h.transport.writes.single['params'], [
      {
        'app_name': 'new-demo',
        'catalog_app': 'demo',
        'train': 'community',
        'version': '1.1.0',
        'values': _values,
        'custom_app': false,
      },
    ]);
    final terminal = await h.repo.pollAppJob(result.job!);
    expect(terminal.outcome, AppOperationOutcome.verified);
    expect(terminal.toString(), isNot(contains('private-fixture-secret')));
    final jobQuery =
        h.transport.requests.firstWhere(
              (r) => r['method'] == 'core.get_jobs',
            )['params']
            as List;
    expect(jobQuery.first, [
      ['id', '=', result.job!.id],
    ]);
    expect((jobQuery[1] as Map)['select'], isNot(contains('result')));
    expect((jobQuery[1] as Map)['select'], isNot(contains('error')));
    expect(h.transport.requests.last['method'], 'app.query');
    final before = h.transport.requests.length;
    expect(
      (await h.repo.pollAppJob(result.job!)).outcome,
      AppOperationOutcome.verified,
    );
    expect(h.transport.requests.length, before);
  });
  for (final scenario in [
    'duplicate-name',
    'pool-changed',
    'service-stopped',
    'schema-changed',
    'port-used',
  ]) {
    test('$scenario rejects install before submitting a job', () async {
      final h = await _connect();
      final details = await _review(h);
      var name = 'new-demo';
      switch (scenario) {
        case 'duplicate-name':
          name = 'demo';
        case 'pool-changed':
          h.transport.pool = 'other';
        case 'service-stopped':
          h.transport.status = 'STOPPED';
        case 'schema-changed':
          final schema = h.transport.details['1.1.0']!['schema'] as Map;
          (((schema['questions'] as List).first as Map)['schema']
                  as Map)['default'] =
              false;
        case 'port-used':
          h.transport.usedPorts = [30013];
      }
      final result = await h.repo.installApp(
        AppInstallRequest(details: details, appName: name, values: _values),
      );
      expect(result.outcome, AppOperationOutcome.rejected);
      expect(h.transport.writes, isEmpty);
    });
  }
  for (final scenario in [
    'missing-secret',
    'unknown-key',
    'invalid-port',
    'reserved-key',
  ]) {
    test('$scenario cannot bypass the native values schema', () async {
      final h = await _connect();
      final details = await _review(h);
      final values = _values;
      switch (scenario) {
        case 'missing-secret':
          values.remove('password');
        case 'unknown-key':
          values['unreviewed'] = true;
        case 'invalid-port':
          values['port'] = -1;
        case 'reserved-key':
          values['ix_context'] = {};
      }
      await expectLater(
        h.repo.installApp(
          AppInstallRequest(
            details: details,
            appName: 'new-demo',
            values: values,
          ),
        ),
        throwsA(_reason(AppsExceptionReason.invalidInput)),
      );
      expect(h.transport.writes, isEmpty);
    });
  }
  test(
    'all lifecycle actions verify expected running or stopped state',
    () async {
      final h = await _connect();
      for (final action in [
        AppLifecycleAction.stop,
        AppLifecycleAction.start,
        AppLifecycleAction.redeploy,
      ]) {
        final app = (await h.repo.loadAppsInventory()).apps.single;
        final submitted = await h.repo.changeAppState(app, action);
        expect(submitted.outcome, AppOperationOutcome.submitted);
        expect(
          (await h.repo.pollAppJob(submitted.job!)).outcome,
          AppOperationOutcome.verified,
        );
      }
      expect(h.transport.writes.map((r) => r['method']), [
        'app.stop',
        'app.start',
        'app.redeploy',
      ]);
    },
  );
  test(
    'fresh installed identity and pool checks reject lifecycle drift',
    () async {
      final h = await _connect();
      final app = (await h.repo.loadAppsInventory()).apps.single;
      h.transport.rows.single['version'] = '1.0.1';
      expect(
        (await h.repo.changeAppState(app, AppLifecycleAction.stop)).outcome,
        AppOperationOutcome.rejected,
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test(
    'upgrade sends selected newer version and disables hostpath snapshots',
    () async {
      final h = await _connect();
      final app = (await h.repo.loadAppsInventory()).apps.single;
      final details = await _review(h);
      final review = await h.repo.loadAppUpgradeReview(app, details);
      final result = await h.repo.upgradeApp(
        AppUpgradeRequest(app: app, details: details, review: review),
      );
      expect(result.outcome, AppOperationOutcome.submitted);
      expect(h.transport.writes.single['params'], [
        'demo',
        {
          'app_version': '1.1.0',
          'values': <String, Object?>{},
          'snapshot_hostpaths': false,
        },
      ]);
      expect(
        (await h.repo.pollAppJob(result.job!)).outcome,
        AppOperationOutcome.verified,
      );
    },
  );
  test(
    'upgrade cannot serve as a rollback or run against stopped apps',
    () async {
      final h = await _connect();
      h.transport.rows.single['state'] = 'STOPPED';
      final app = (await h.repo.loadAppsInventory()).apps.single;
      final details = await _review(h);
      await expectLater(
        h.repo.upgradeApp(
          AppUpgradeRequest(app: app, details: details, values: _values),
        ),
        throwsA(_reason(AppsExceptionReason.invalidInput)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test(
    'upgrade preserves nested saved storage and secrets without reading them',
    () async {
      final h = await _connect();
      final before = jsonDecode(jsonEncode(h.transport.savedConfig));
      final app = (await h.repo.loadAppsInventory()).apps.single;
      final details = await _review(h);
      final review = await h.repo.loadAppUpgradeReview(app, details);
      final result = await h.repo.upgradeApp(
        AppUpgradeRequest(app: app, details: details, review: review),
      );
      expect(
        (await h.repo.pollAppJob(result.job!)).outcome,
        AppOperationOutcome.verified,
      );
      expect(h.transport.savedConfig, before);
      expect((h.transport.writes.single['params'] as List)[1], {
        'app_version': '1.1.0',
        'values': {},
        'snapshot_hostpaths': false,
      });
      expect(
        h.transport.requests.where((r) => r['method'] == 'app.config'),
        isEmpty,
      );
    },
  );
  test(
    'upgrade rejects configuration overrides even with a genuine review',
    () async {
      final h = await _connect();
      final app = (await h.repo.loadAppsInventory()).apps.single;
      final details = await _review(h);
      final review = await h.repo.loadAppUpgradeReview(app, details);
      await expectLater(
        h.repo.upgradeApp(
          AppUpgradeRequest(
            app: app,
            details: details,
            review: review,
            values: _values,
          ),
        ),
        throwsA(_reason(AppsExceptionReason.invalidInput)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test(
    'upgrade requires an issued summary and rejects forged reviews',
    () async {
      final h = await _connect();
      final app = (await h.repo.loadAppsInventory()).apps.single;
      final details = await _review(h);
      final review = AppUpgradeReview(
        app: app,
        details: details,
        changelog: 'Fake',
        humanVersion: '1.1.0',
      );
      await expectLater(
        h.repo.upgradeApp(
          AppUpgradeRequest(app: app, details: details, review: review),
        ),
        throwsA(_reason(AppsExceptionReason.staleSnapshot)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test('summary target mismatch cannot produce a reviewed upgrade', () async {
    final h = await _connect();
    final app = (await h.repo.loadAppsInventory()).apps.single;
    final details = await _review(h);
    h.transport.upgradeSummary['upgrade_version'] = '1.2.0';
    await expectLater(
      h.repo.loadAppUpgradeReview(app, details),
      throwsA(_reason(AppsExceptionReason.invalidResponse)),
    );
    expect(h.transport.writes, isEmpty);
  });
  test('summary changed after review rejects before dispatch', () async {
    final h = await _connect();
    final app = (await h.repo.loadAppsInventory()).apps.single;
    final details = await _review(h);
    final review = await h.repo.loadAppUpgradeReview(app, details);
    h.transport.upgradeSummary['changelog'] = 'Changed release instructions';
    expect(
      (await h.repo.upgradeApp(
        AppUpgradeRequest(app: app, details: details, review: review),
      )).outcome,
      AppOperationOutcome.rejected,
    );
    expect(h.transport.writes, isEmpty);
  });
  test(
    'native upgrade availability is required even if target is newer',
    () async {
      final h = await _connect();
      h.transport.rows.single['upgrade_available'] = false;
      final app = (await h.repo.loadAppsInventory()).apps.single;
      final details = await _review(h);
      await expectLater(
        h.repo.loadAppUpgradeReview(app, details),
        throwsA(_reason(AppsExceptionReason.invalidInput)),
      );
      expect(h.transport.writes, isEmpty);
    },
  );
  test('server migration does not require the target installer form to be supported', () async {
    final h = await _connect();
    h.transport.details['1.1.0']!['schema'] = <String, Object?>{
      'questions': null,
    };
    final app = (await h.repo.loadAppsInventory()).apps.single;
    final details = await _review(h);
    expect(details.supported, isFalse);
    expect(details.upgradeSupported, isTrue);
    final review = await h.repo.loadAppUpgradeReview(app, details);
    final result = await h.repo.upgradeApp(
      AppUpgradeRequest(app: app, details: details, review: review),
    );
    expect(result.outcome, AppOperationOutcome.submitted);
    expect(
      (await h.repo.pollAppJob(result.job!)).outcome,
      AppOperationOutcome.verified,
    );
  });
  for (final field in ['name', 'train', 'version']) {
    test('catalog app_metadata $field mismatch cannot issue a form', () async {
      final h = await _connect();
      (h.transport.details['1.1.0']!['app_metadata'] as Map)[field] = 'other';
      await expectLater(
        _review(h),
        throwsA(_reason(AppsExceptionReason.invalidResponse)),
      );
      expect(h.transport.writes, isEmpty);
    });
  }
  test(
    'successful job with transitional runtime state remains checkable',
    () async {
      final h = await _connect();
      final app = (await h.repo.loadAppsInventory()).apps.single;
      final result = await h.repo.changeAppState(app, AppLifecycleAction.stop);
      h.transport.settledState = 'STOPPING';
      expect(
        (await h.repo.pollAppJob(result.job!)).outcome,
        AppOperationOutcome.running,
      );
      h.transport.settledState = null;
      expect(
        (await h.repo.pollAppJob(result.job!)).outcome,
        AppOperationOutcome.verified,
      );
      expect(h.transport.writes, hasLength(1));
    },
  );
  test('uninstall requires exact name and keeps image, ix-volume and all force flags false', () async {
    final h = await _connect();
    final app = (await h.repo.loadAppsInventory()).apps.single;
    await expectLater(
      h.repo.uninstallApp(AppUninstallRequest(app: app, confirmedName: 'Demo')),
      throwsA(_reason(AppsExceptionReason.invalidInput)),
    );
    expect(h.transport.writes, isEmpty);
    final result = await h.repo.uninstallApp(
      AppUninstallRequest(app: app, confirmedName: 'demo'),
    );
    expect(h.transport.writes.single['params'], [
      'demo',
      {
        'remove_images': false,
        'remove_ix_volumes': false,
        'force_remove_ix_volumes': false,
        'force_remove_custom_app': false,
      },
    ]);
    expect(
      (await h.repo.pollAppJob(result.job!)).outcome,
      AppOperationOutcome.verified,
    );
    expect(h.transport.requests.last['params'], [
      [
        ['id', '=', 'demo'],
      ],
      {
        'limit': 2,
        'select': [
          'id',
          'name',
          'state',
          'version',
          'custom_app',
          'metadata',
          'upgrade_available',
          'latest_version',
          'image_updates_available',
        ],
        'extra': {'retrieve_config': false, 'include_app_schema': false},
      },
    ]);
    expect(h.transport.writes.length, 1);
  });
  test(
    'fabricated jobs cannot query server jobs or complete another operation',
    () async {
      final h = await _connect();
      final app = (await h.repo.loadAppsInventory()).apps.single;
      final result = await h.repo.changeAppState(app, AppLifecycleAction.stop);
      final fake = AppJob(
        id: result.job!.id,
        appName: result.job!.appName,
        operation: result.job!.operation,
      );
      final before = h.transport.requests.length;
      expect(
        (await h.repo.pollAppJob(fake)).outcome,
        AppOperationOutcome.unknown,
      );
      expect(h.transport.requests.length, before);
      expect(
        (await h.repo.pollAppJob(result.job!)).outcome,
        AppOperationOutcome.verified,
      );
    },
  );
  for (final mismatch in [
    'job-id',
    'job-method',
    'job-arguments',
    'readback',
    'empty-job',
  ]) {
    test('$mismatch yields unknown and locks further app mutations', () async {
      final h = await _connect();
      final app = (await h.repo.loadAppsInventory()).apps.single;
      final result = await h.repo.changeAppState(app, AppLifecycleAction.stop);
      h.transport.pollMismatch = mismatch;
      expect(
        (await h.repo.pollAppJob(result.job!)).outcome,
        AppOperationOutcome.unknown,
      );
      final current = (await h.repo.loadAppsInventory()).apps.single;
      await expectLater(
        h.repo.changeAppState(
          current,
          current.state == 'STOPPED'
              ? AppLifecycleAction.start
              : AppLifecycleAction.stop,
        ),
        throwsA(_reason(AppsExceptionReason.busy)),
      );
      expect(h.transport.writes.length, 1);
    });
  }
  test(
    'timeout never retries and locks even without a returned job ID',
    () async {
      final h = await _connect();
      final details = await _review(h);
      h.transport.writeFailure = 'timeout';
      final request = AppInstallRequest(
        details: details,
        appName: 'new-demo',
        values: _values,
      );
      expect(
        (await h.repo.installApp(request)).outcome,
        AppOperationOutcome.unknown,
      );
      await expectLater(
        h.repo.installApp(
          AppInstallRequest(
            details: details,
            appName: 'other-demo',
            values: _values,
          ),
        ),
        throwsA(_reason(AppsExceptionReason.busy)),
      );
      expect(h.transport.writes.length, 1);
    },
  );
  test('remote failure messages never reach an operation result', () async {
    final h = await _connect();
    final details = await _review(h);
    h.transport.writeFailure = 'remote';
    final result = await h.repo.installApp(
      AppInstallRequest(details: details, appName: 'new-demo', values: _values),
    );
    expect(result.outcome, AppOperationOutcome.unknown);
    expect(result.userMessage, isNot(contains('private-fixture-secret')));
    expect(result.job, isNull);
  });
  test('valid progress is projected without its description or logs', () async {
    final h = await _connect();
    final app = (await h.repo.loadAppsInventory()).apps.single;
    final result = await h.repo.changeAppState(app, AppLifecycleAction.stop);
    h.transport.jobState = 'RUNNING';
    h.transport.progress = 42;
    final running = await h.repo.pollAppJob(result.job!);
    expect(running.outcome, AppOperationOutcome.running);
    expect(running.progressPercent, 42);
    h.transport.progress = 101;
    expect((await h.repo.pollAppJob(result.job!)).progressPercent, isNull);
    h.transport.jobState = 'SUCCESS';
    expect(
      (await h.repo.pollAppJob(result.job!)).outcome,
      AppOperationOutcome.verified,
    );
  });
  test('terminal failed jobs release ownership but invalidate prior installed handles', () async {
    final h = await _connect();
    final app = (await h.repo.loadAppsInventory()).apps.single;
    final result = await h.repo.changeAppState(app, AppLifecycleAction.stop);
    h.transport.jobState = 'FAILED';
    expect(
      (await h.repo.pollAppJob(result.job!)).outcome,
      AppOperationOutcome.failed,
    );
    await expectLater(
      h.repo.changeAppState(app, AppLifecycleAction.stop),
      throwsA(_reason(AppsExceptionReason.staleSnapshot)),
    );
  });
}

Future<AppVersionDetails> _review(_Harness h) async {
  final catalog = (await h.repo.loadAppsCatalog()).single;
  return h.repo.loadAppVersionDetails(catalog, '1.1.0');
}

Future<AppConfigReview> _configReview(_Harness h) async {
  final app = (await h.repo.loadAppsInventory()).apps.single;
  return h.repo.loadAppConfigReview(app);
}

Future<_Harness> _connect({
  String version = '25.10.1',
  Set<String> methods = _methods,
}) async {
  final h = _Harness(version: version, methods: methods);
  addTearDown(h.repo.close);
  await h.repo.connect(
    serverInput: 'https://nas.example',
    apiKey: 'fixture-key',
    username: 'admin',
  );
  return h;
}

class _Harness {
  _Harness({String version = '25.10.1', Set<String> methods = _methods}) {
    transport = _Transport(version, methods);
    repo = TrueNasSessionRepository(
      connector: _Connector(transport),
      managementRequestTimeout: const Duration(milliseconds: 50),
    );
  }
  late final _Transport transport;
  late final TrueNasSessionRepository repo;
}

class _Connector implements RpcConnector {
  _Connector(this.transport);
  final RpcTransport transport;
  @override
  Future<RpcTransport> connect(Uri endpoint) async => transport;
}

class _Transport implements RpcTransport {
  _Transport(this.version, this.methods);
  final String version;
  final Set<String> methods;
  final inbound = StreamController<String>();
  final requests = <Map<String, Object?>>[];
  final rows = [_row()];
  final details = {'1.0.0': _details('1.0.0'), '1.1.0': _details('1.1.0')};
  final configDetails = _configDetails();
  final savedConfig = <String, Object?>{
    'preferences': <String, Object?>{
      'enabled': true,
      'title': 'Current title',
      'password': 'existing-private-password',
      'unknown': 'preserve',
      'list': [
        {'hidden': true},
      ],
    },
    'workers': 3,
    'fixed': 'unchanged',
    'network': {'port': 32123},
    'storage': {'hostpath': '/mnt/tank/existing'},
    'credentials': {'password': 'existing-private-password'},
  };
  String pool = 'tank';
  String status = 'RUNNING';
  Object? usedPorts = <int>[];
  Map<String, Object?>? catalogRowOverride;
  Object? appNotes = 'Operator note\nSecond line';
  Object? appPortals = <String, Object?>{
    'Web UI': 'https://nas.example:3000/ui',
  };
  Object? appWorkloads = <String, Object?>{
    'containers': 2,
    'used_ports': [<String, Object?>{}],
    'volumes': [<String, Object?>{}],
    'images': ['demo:1.0.0', 'sidecar:2.0.0'],
  };
  Object? outdatedImages = ['example/media:latest'];
  List<String> catalogTrains = ['community', 'stable'];
  List<String> preferredTrains = ['stable'];
  bool catalogUpdateTimeout = false;
  String? catalogUpdateMismatch;
  String? rawConfigNumericToken;
  String? writeFailure;
  String? pollMismatch;
  String jobState = 'SUCCESS';
  String? settledState;
  bool redactUpdateArgs = false;
  bool configReadbackMismatch = false;
  final upgradeSummary = <String, Object?>{
    'latest_version': '1.1.0',
    'latest_human_version': '1.1.0-app',
    'upgrade_version': '1.1.0',
    'upgrade_human_version': '1.1.0-app',
    'available_versions_for_upgrade': [
      {'version': '1.1.0', 'human_version': '1.1.0-app'},
    ],
    'changelog': 'A reviewed release.\nMigration preserves existing values.',
  };
  num progress = 100;
  int nextJob = 800;
  Map<String, Object?>? submitted;
  int? jobId;
  Iterable<Map<String, Object?>> get writes => requests.where(
    (r) => {
      'app.create',
      'app.start',
      'app.stop',
      'app.redeploy',
      'app.upgrade',
      'app.delete',
      'app.update',
      'app.pull_images',
      'catalog.update',
      'catalog.sync',
    }.contains(r['method']),
  );
  @override
  Stream<String> get inboundFrames => inbound.stream;
  @override
  Future<void> send(String frame) async {
    final r = Map<String, Object?>.from(jsonDecode(frame) as Map);
    requests.add(r);
    Object? result;
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
              'job': m != 'app.query' && m.startsWith('app.'),
              'no_auth_required': false,
            },
        };
      case 'docker.status':
        result = {'status': status, 'description': ''};
      case 'docker.config':
        result = {'pool': pool};
      case 'app.used_ports':
        result = usedPorts;
      case 'catalog.apps':
        result = {
          'community': {
            'demo':
                catalogRowOverride ??
                {
                  'name': 'demo',
                  'title': 'Demo',
                  'description': 'Demo application',
                  'healthy': true,
                  'categories': ['Media', 'Productivity'],
                  'tags': ['streaming', 'library'],
                  'recommended': true,
                },
          },
        };
      case 'catalog.trains':
        result = catalogTrains;
      case 'catalog.config':
        result = {
          'id': 'official',
          'label': 'TRUENAS',
          'preferred_trains':
              catalogUpdateMismatch == 'readback' &&
                  requests.any(
                    (request) => request['method'] == 'catalog.update',
                  )
              ? ['stable']
              : preferredTrains,
          'location': '/mnt/catalog',
        };
      case 'catalog.update':
        if (catalogUpdateTimeout) return;
        preferredTrains = List<String>.from(
          ((r['params'] as List).single as Map)['preferred_trains'] as List,
        );
        result = {
          'id': 'official',
          'label': 'TRUENAS',
          'preferred_trains': catalogUpdateMismatch == 'response'
              ? ['stable']
              : preferredTrains,
          'location': '/mnt/catalog',
        };
      case 'catalog.sync':
        if (writeFailure == 'timeout') return;
        submitted = r;
        jobId = nextJob++;
        result = jobId;
      case 'catalog.get_app_details':
        result = {'name': 'demo', 'versions': details};
      case 'app.upgrade_summary':
        result = upgradeSummary;
      case 'app.outdated_docker_images':
        result = outdatedImages;
      case 'app.query':
        final filter = (r['params'] as List).first as List;
        result = filter.isEmpty
            ? rows
            : rows
                  .where((row) => row['id'] == (filter.single as List).last)
                  .toList();
        final options = (r['params'] as List)[1] as Map;
        if ((options['select'] as List).contains('notes')) {
          result = (result as List)
              .map(
                (row) => {
                  ...row as Map,
                  'notes': appNotes,
                  'portals': appPortals,
                  'active_workloads': appWorkloads,
                },
              )
              .toList();
        }
        if ((options['extra'] as Map)['include_app_schema'] == true) {
          result = (result as List)
              .map((row) => {...row as Map, 'version_details': configDetails})
              .toList();
        }
      case 'app.config':
        result = {
          ...savedConfig,
          if (rawConfigNumericToken != null)
            'unknown_numeric_sibling': 'unsafe-number-fixture',
          'ix_context': {'private': 'server-context-secret'},
        };
      case 'app.create':
      case 'app.start':
      case 'app.stop':
      case 'app.redeploy':
      case 'app.upgrade':
      case 'app.delete':
      case 'app.update':
      case 'app.pull_images':
        if (writeFailure == 'timeout') return;
        if (writeFailure == 'remote') {
          inbound.add(
            jsonEncode({
              'jsonrpc': '2.0',
              'id': r['id'],
              'error': {
                'code': -32001,
                'message': 'private-fixture-secret',
                'data': {'password': 'private-fixture-secret'},
              },
            }),
          );
          return;
        }
        submitted = r;
        jobId = nextJob++;
        result = jobId;
      case 'core.get_jobs':
        if (jobState == 'SUCCESS') _complete();
        final arguments = jsonDecode(jsonEncode(submitted!['params'])) as List;
        if (submitted!['method'] == 'app.update' && redactUpdateArgs) {
          arguments[1] = {'values': '********'};
        }
        if (pollMismatch == 'job-arguments') {
          if (arguments.isEmpty) {
            arguments.add('unexpected');
          } else {
            arguments[0] = 'other-app';
          }
        }
        if (pollMismatch == 'pull-redeploy') {
          arguments[1] = {'redeploy': true};
        }
        result = pollMismatch == 'empty-job'
            ? []
            : [
                {
                  'id': pollMismatch == 'job-id' ? jobId! + 1 : jobId,
                  'method': pollMismatch == 'job-method'
                      ? 'app.delete'
                      : submitted!['method'],
                  'arguments': arguments,
                  'state': jobState,
                  'progress': {
                    'percent': progress,
                    'description': 'private-fixture-secret',
                  },
                  'result': {'password': 'private-fixture-secret'},
                  'error': 'private-fixture-secret',
                },
              ];
    }
    var response = jsonEncode({
      'jsonrpc': '2.0',
      'id': r['id'],
      'result': result,
    });
    if (r['method'] == 'app.config' && rawConfigNumericToken != null) {
      response = response.replaceFirst(
        '"unsafe-number-fixture"',
        rawConfigNumericToken!,
      );
    }
    inbound.add(response);
  }

  void _complete() {
    final args = submitted!['params'] as List;
    if (submitted!['method'] == 'catalog.sync') return;
    if (submitted!['method'] == 'app.create') {
      final options = args.single as Map;
      final name = options['app_name'] as String;
      if (rows.every((r) => r['id'] != name)) {
        rows.add(_row(name: name, version: options['version'] as String));
      }
    } else if (submitted!['method'] == 'app.delete') {
      rows.removeWhere((row) => row['id'] == args.first);
    } else {
      final row = rows.firstWhere((row) => row['id'] == args.first);
      if (submitted!['method'] == 'app.upgrade') {
        row['version'] = (args[1] as Map)['app_version'];
        savedConfig.addAll(
          Map<String, Object?>.from((args[1] as Map)['values'] as Map),
        );
      }
      if (submitted!['method'] == 'app.update') {
        savedConfig.addAll(
          Map<String, Object?>.from((args[1] as Map)['values'] as Map),
        );
        if (configReadbackMismatch) {
          (savedConfig['preferences'] as Map)['password'] =
              'changed-server-secret';
        }
      }
      if (submitted!['method'] != 'app.pull_images' &&
          (submitted!['method'] != 'app.update' || row['state'] != 'STOPPED')) {
        row['state'] = submitted!['method'] == 'app.stop'
            ? 'STOPPED'
            : 'RUNNING';
      }
      if (settledState != null) row['state'] = settledState;
      if (pollMismatch == 'readback') row['version'] = '9.9.9';
    }
  }

  @override
  Future<void> close() async => inbound.close();
}
