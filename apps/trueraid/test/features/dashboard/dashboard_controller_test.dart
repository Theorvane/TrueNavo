import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_controller.dart';
import 'package:trueraid/features/dashboard/dashboard_capabilities.dart';
import 'package:trueraid/features/dashboard/dashboard_repository.dart';
import 'package:trueraid/features/server_profiles/server_profile.dart';
import 'package:trueraid/features/server_profiles/server_profiles_controller.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  test('does not query an unavailable view', () async {
    final queries = _Queries();
    final repository = DashboardRepository(queries);

    final result = await repository.loadAlerts(const <String>{});

    expect(result, isA<DashboardUnavailable>());
    expect(queries.calledMethods, isEmpty);
  });

  test('classifies versions without expanding the bounded RPC surface', () {
    final capabilities = DashboardCapabilities.forSession(
      version: 'TrueNAS-SCALE-25.10.1',
      availableMethodNames: const {'pool.query', 'vdev.query'},
    );
    final v25_04 = DashboardCapabilities.forSession(
      version: 'TrueNAS-SCALE-25.04.2',
      availableMethodNames: const {},
    );
    final v26Plus = DashboardCapabilities.forSession(
      version: 'TrueNAS-SCALE-26.0',
      availableMethodNames: const {},
    );
    final unsupported = DashboardCapabilities.forSession(
      version: '24.10.3',
      availableMethodNames: const {},
    );

    expect(capabilities.versionFamily, DashboardVersionFamily.v25_10);
    expect(v25_04.versionFamily, DashboardVersionFamily.v25_04);
    expect(v26Plus.versionFamily, DashboardVersionFamily.v26Plus);
    expect(
      unsupported.versionFamily,
      DashboardVersionFamily.unknownUnsupported,
    );
    expect(capabilities.supports(DashboardFeature.pools), isTrue);
    expect(capabilities.supports(DashboardFeature.vdevs), isFalse);
    expect(capabilities.allowedMethods, const {'pool.query'});
  });

  test(
    'loads bounded storage with dataset pool context and no unsupported RPCs',
    () async {
      final queries = _Queries(
        results: {
          'pool.query': [
            {'name': 'tank', 'status': 'HEALTHY'},
          ],
          'pool.dataset.query': [
            {'name': 'tank/media'},
          ],
        },
      );

      final result = await DashboardRepository(queries)
          .loadStorage(const {'pool.query', 'pool.dataset.query'});

      final storage = (result as DashboardData<DashboardStorage>).value;
      expect(storage.pools.single.name, 'tank');
      expect(storage.datasets.single.poolName, 'tank');
      expect(storage.datasets.single.name, 'tank/media');
      expect(queries.calledMethods, ['pool.query', 'pool.dataset.query']);
    },
  );

  test('sorts storage and attributes datasets only to known pools', () async {
    final queries = _Queries(
      results: {
        'pool.query': [
          {'name': 'zeta', 'status': 'HEALTHY'},
          {'name': 'Alpha', 'status': 'DEGRADED'},
          'not-a-pool',
        ],
        'pool.dataset.query': [
          {'name': 'zeta/photos'},
          {'name': 'unknown/private'},
          {'name': 'Alpha/media'},
          {'name': 'Alpha'},
          {'name': '   '},
          42,
        ],
      },
    );

    final result = await DashboardRepository(queries)
        .loadStorage(const {'pool.query', 'pool.dataset.query'});

    final storage = (result as DashboardData<DashboardStorage>).value;
    expect(storage.pools.map((pool) => pool.name), ['Alpha', 'zeta']);
    expect(storage.datasets.map((dataset) => dataset.name), [
      'Alpha',
      'Alpha/media',
      'zeta/photos',
      'unknown/private',
    ]);
    expect(storage.datasets.map((dataset) => dataset.poolName), [
      'Alpha',
      'Alpha',
      'zeta',
      '',
    ]);
    expect(queries.calledMethods, ['pool.query', 'pool.dataset.query']);
  });

  test('does not invent dataset pool context without pool inventory', () async {
    final queries = _Queries(
      results: {
        'pool.dataset.query': [
          {'name': 'tank/media'},
        ],
      },
    );

    final result = await DashboardRepository(queries)
        .loadStorage(const {'pool.dataset.query'});

    final storage = (result as DashboardData<DashboardStorage>).value;
    expect(storage.poolsAvailable, isFalse);
    expect(storage.datasetsAvailable, isTrue);
    expect(storage.datasets.single.poolName, isEmpty);
    expect(queries.calledMethods, ['pool.dataset.query']);
  });

  test(
    'rejects overlong identities instead of creating a truncated collision',
    () async {
      final sharedPrefix = 'p' * 160;
      final queries = _Queries(
        results: {
          'pool.query': [
            {'name': '${sharedPrefix}a', 'status': 'HEALTHY'},
          ],
          'pool.dataset.query': [
            {'name': '${sharedPrefix}b/media'},
          ],
        },
      );

      final result = await DashboardRepository(queries)
          .loadStorage(const {'pool.query', 'pool.dataset.query'});

      final storage = (result as DashboardData<DashboardStorage>).value;
      expect(storage.pools, isEmpty);
      expect(storage.datasets, isEmpty);
    },
  );

  test('rejects an overlong pool in a literal ellipsis collision', () async {
    final prefix = 'p' * 159;
    final queries = _Queries(
      results: {
        'pool.query': [
          {'name': '${prefix}raw-suffix', 'status': 'HEALTHY'},
        ],
        'pool.dataset.query': [
          {'name': '$prefix…/media'},
        ],
      },
    );

    final result = await DashboardRepository(queries)
        .loadStorage(const {'pool.query', 'pool.dataset.query'});

    final storage = (result as DashboardData<DashboardStorage>).value;
    expect(storage.pools, isEmpty);
    expect(storage.datasets, isEmpty);
  });

  test('trims pool identity before deterministic dataset grouping', () async {
    final queries = _Queries(
      results: {
        'pool.query': [
          {'name': ' tank ', 'status': 'HEALTHY'},
        ],
        'pool.dataset.query': [
          {'name': 'tank/media'},
        ],
      },
    );

    final result = await DashboardRepository(queries)
        .loadStorage(const {'pool.query', 'pool.dataset.query'});

    final storage = (result as DashboardData<DashboardStorage>).value;
    expect(storage.pools.single.name, 'tank');
    expect(storage.datasets.single.poolName, 'tank');
  });

  test('rejects malformed top-level storage payloads', () async {
    final queries = _Queries(
      results: {
        'pool.query': {'name': 'not-a-list'},
        'pool.dataset.query': 'not-a-list',
      },
    );

    final result = await DashboardRepository(queries)
        .loadStorage(const {'pool.query', 'pool.dataset.query'});

    expect(result, isA<DashboardFailure<DashboardStorage>>());
  });

  test('keeps valid pools when the dataset payload is malformed', () async {
    final queries = _Queries(
      results: {
        'pool.query': [
          {'name': 'tank', 'status': 'HEALTHY'},
        ],
        'pool.dataset.query': {'name': 'not-a-list'},
      },
    );

    final result = await DashboardRepository(queries)
        .loadStorage(const {'pool.query', 'pool.dataset.query'});

    final storage = (result as DashboardData<DashboardStorage>).value;
    expect(storage.poolsAvailable, isTrue);
    expect(storage.datasetsAvailable, isFalse);
    expect(storage.pools.single.name, 'tank');
  });

  test('rejects arbitrary capacity text at the repository boundary', () async {
    const marker = 'Authorization: Bearer REVIEW_SECRET_MARKER';
    final queries = _Queries(
      results: {
        'pool.query': [
          {'name': 'tank', 'status': marker, 'capacity': marker},
          {'name': 'backup', 'status': 'HEALTHY', 'capacity': '72.5%'},
          {'name': 'archive', 'status': 'HEALTHY', 'used_pct': '0.5%'},
        ],
      },
    );

    final result = await DashboardRepository(queries)
        .loadStorage(const {'pool.query'});

    final pools = (result as DashboardData<DashboardStorage>).value.pools;
    expect(pools.singleWhere((pool) => pool.name == 'tank').capacity, isNull);
    expect(
      pools.singleWhere((pool) => pool.name == 'tank').capacityPercent,
      isNull,
    );
    expect(pools.singleWhere((pool) => pool.name == 'tank').status, 'Unknown');
    expect(
      pools.singleWhere((pool) => pool.name == 'backup').capacity,
      '72.5%',
    );
    expect(
      pools.singleWhere((pool) => pool.name == 'backup').capacityPercent,
      72.5,
    );
    expect(
      pools.singleWhere((pool) => pool.name == 'archive').capacity,
      '0.5%',
    );
    expect(
      pools.singleWhere((pool) => pool.name == 'archive').capacityPercent,
      0.5,
    );
    expect(pools.map((pool) => pool.capacity).join(), isNot(contains(marker)));
  });

  test(
    'rejects overlong dataset identities without lossy truncation',
    () async {
      final prefix = 'tank/${'x' * 155}';
      final validUnicodeName = 'tank/${'x' * 153}😀';
      final queries = _Queries(
        results: {
          'pool.query': [
            {'name': 'tank', 'status': 'HEALTHY'},
          ],
          'pool.dataset.query': [
            {'name': '${prefix}a'},
            {'name': '${prefix}b'},
            {
              'name': String.fromCharCodes([
                0x74,
                0x61,
                0x6e,
                0x6b,
                0x2f,
                0xD800,
              ]),
            },
            {'name': validUnicodeName},
          ],
        },
      );

      final result = await DashboardRepository(queries)
          .loadStorage(const {'pool.query', 'pool.dataset.query'});

      final datasets =
          (result as DashboardData<DashboardStorage>).value.datasets;
      expect(datasets.map((dataset) => dataset.name), [validUnicodeName]);
      expect(datasets.single.name, isNot(contains('�')));
    },
  );

  test(
    'keeps datasets ungrouped when normalized pool identity is duplicate',
    () async {
      final queries = _Queries(
        results: {
          'pool.query': [
            {'name': 'tank', 'status': 'HEALTHY'},
            {'name': ' tank ', 'status': 'DEGRADED'},
          ],
          'pool.dataset.query': [
            {'name': 'tank/media'},
          ],
        },
      );

      final result = await DashboardRepository(queries)
          .loadStorage(const {'pool.query', 'pool.dataset.query'});

      final storage = (result as DashboardData<DashboardStorage>).value;
      expect(storage.pools, hasLength(2));
      expect(storage.datasets.single.poolName, isEmpty);
    },
  );

  test('bounds storage parsing to the first 50 response records', () async {
    final malformedPrefix = List<Object?>.filled(50, 'malformed');
    final queries = _Queries(
      results: {
        'pool.query': [
          ...malformedPrefix,
          {'name': 'late-pool', 'status': 'HEALTHY'},
        ],
        'pool.dataset.query': [
          ...malformedPrefix,
          {'name': 'late-pool/media'},
        ],
      },
    );

    final result = await DashboardRepository(queries)
        .loadStorage(const {'pool.query', 'pool.dataset.query'});

    final storage = (result as DashboardData<DashboardStorage>).value;
    expect(storage.pools, isEmpty);
    expect(storage.datasets, isEmpty);
  });

  test('keeps partial storage when dataset inventory is unavailable', () async {
    final queries = _Queries(
      results: {
        'pool.query': [
          {'name': 'tank', 'status': 'HEALTHY'},
        ],
      },
    );

    final result = await DashboardRepository(queries)
        .loadStorage(const {'pool.query'});

    final storage = (result as DashboardData<DashboardStorage>).value;
    expect(storage.poolsAvailable, isTrue);
    expect(storage.datasetsAvailable, isFalse);
  });

  test('returns failure when every advertised storage query fails', () async {
    final queries = _Queries(
      failingMethods: const {'pool.query', 'pool.dataset.query'},
    );

    final result = await DashboardRepository(queries)
        .loadStorage(const {'pool.query', 'pool.dataset.query'});

    expect(result, isA<DashboardFailure<DashboardStorage>>());
    expect(queries.calledMethods, ['pool.query', 'pool.dataset.query']);
  });

  test('returns unavailable when no storage query is advertised', () async {
    final queries = _Queries();

    final result = await DashboardRepository(queries).loadStorage(const {});

    expect(result, isA<DashboardUnavailable<DashboardStorage>>());
    expect(queries.calledMethods, isEmpty);
  });

  test(
    'keeps partial storage when an advertised companion query fails',
    () async {
      final queries = _Queries(
        results: {
          'pool.query': [
            {'name': 'tank', 'status': 'HEALTHY'},
          ],
        },
        failingMethods: const {'pool.dataset.query'},
      );

      final result = await DashboardRepository(queries)
          .loadStorage(const {'pool.query', 'pool.dataset.query'});

      final storage = (result as DashboardData<DashboardStorage>).value;
      expect(storage.poolsAvailable, isTrue);
      expect(storage.datasetsAvailable, isFalse);
      expect(storage.pools.single.name, 'tank');
      expect(queries.calledMethods, ['pool.query', 'pool.dataset.query']);
    },
  );

  test('loads workloads only through service.query', () async {
    final queries = _Queries(
      results: {
        'service.query': [
          {'service': 'ssh', 'state': 'RUNNING'},
        ],
      },
    );

    final result = await DashboardRepository(queries)
        .loadWorkloads(const {'service.query'});

    final workloads = (result as DashboardData<DashboardWorkloads>).value;
    expect(workloads.services.single.statusKind, DashboardStatus.success);
    expect(queries.calledMethods, ['service.query']);
  });

  test('maps a supported jobs response into bounded display items', () async {
    final queries = _Queries(
      result: [
        {'id': 7, 'method': 'pool.scrub', 'state': 'SUCCESS'},
      ],
    );
    final repository = DashboardRepository(queries);

    final result = await repository.loadJobs({'core.get_jobs'});

    expect(result, isA<DashboardData<DashboardJobs>>());
    final jobs = (result as DashboardData<DashboardJobs>).value;
    expect(jobs.items.single.id, '7');
    expect(jobs.items.single.name, 'pool.scrub');
    expect(jobs.items.single.statusKind, DashboardStatus.success);
    expect(queries.calledMethods, ['core.get_jobs']);
  });

  test('normalizes severities and derives health from alerts and pools', () {
    expect(dashboardSeverityStatus('CRITICAL'), DashboardStatus.critical);
    expect(dashboardSeverityStatus('warning'), DashboardStatus.warning);
    expect(dashboardSeverityStatus('notice'), DashboardStatus.info);
    expect(dashboardOperationalStatus('FAILED'), DashboardStatus.critical);
    expect(dashboardOperationalStatus('CRITICAL'), DashboardStatus.critical);
    expect(dashboardOperationalStatus('removed'), DashboardStatus.critical);
    expect(dashboardOperationalStatus('running'), DashboardStatus.success);

    final health = dashboardHealthFor(
      const [
        DashboardPool(
          name: 'tank',
          status: 'Healthy',
          statusKind: DashboardStatus.success,
        ),
      ],
      const [
        DashboardAlert(
          level: 'Warning',
          message: 'A scrub is recommended',
          status: DashboardStatus.warning,
        ),
      ],
    );

    expect(health.status, DashboardStatus.warning);
    expect(health.summary, 'Review recommended');
  });

  test('treats unavailable alerts conservatively unless pool health needs attention', () {
    const healthyPool = DashboardPool(
      name: 'tank',
      status: 'Healthy',
      statusKind: DashboardStatus.success,
    );
    const warningPool = DashboardPool(
      name: 'backup',
      status: 'Degraded',
      statusKind: DashboardStatus.warning,
    );

    final unavailableAlerts = dashboardHealthFor(
      const [healthyPool],
      const [],
      criticalPoolCount: 0,
      warningPoolCount: 0,
      alertsAvailable: false,
    );
    final poolWarning = dashboardHealthFor(
      const [warningPool],
      const [],
      criticalPoolCount: 0,
      warningPoolCount: 1,
      alertsAvailable: false,
    );

    expect(unavailableAlerts.status, DashboardStatus.stale);
    expect(unavailableAlerts.summary, 'Alert state unavailable');
    expect(poolWarning.status, DashboardStatus.warning);
    expect(poolWarning.summary, 'Review recommended');
  });

  test('projects bounded system facts without serial or license', () async {
    final queries = _Queries(
      results: {
        'system.info': {
          'hostname': 'atlas',
          'version': '25.10',
          'uptime_seconds': 93600.75,
          'model': 'Example CPU',
          'cores': 8,
          'physical_cores': 4,
          'physmem': 17179869184,
          'system_manufacturer': 'Example Co',
          'system_product': 'NAS',
          'ecc_memory': true,
          'loadavg': [1.25, 0.5, 0],
          'system_serial': 'private-serial',
          'license': {'secret': 'private-license'},
        },
      },
    );
    final result = await DashboardRepository(queries)
        .loadHome(const {'system.info'});
    final home = (result as DashboardData<DashboardHome>).value;
    expect(home.system?.uptimeSeconds, 93600);
    expect(home.system?.logicalCores, 8);
    expect(home.system?.physicalCores, 4);
    expect(home.system?.memoryBytes, 17179869184);
    expect(home.system?.product, 'NAS');
    expect(home.system?.eccMemory, true);
    expect(home.system?.loadAverage, (one: 1.25, five: 0.5, fifteen: 0.0));
    expect(queries.calledMethods, ['system.info']);
  });
  test('shows only advertised known product editions', () async {
    for (final (raw, expected) in <(String, DashboardEdition?)>[
      ('COMMUNITY_EDITION', DashboardEdition.community),
      ('ENTERPRISE', DashboardEdition.enterprise),
      ('unexpected', null),
    ]) {
      final queries = _Queries(
        results: {
          'system.info': {'hostname': 'atlas', 'version': '25.10'},
          'system.product_type': raw,
        },
      );
      final result = await DashboardRepository(queries)
          .loadHome(const {'system.info', 'system.product_type'});
      final home = (result as DashboardData<DashboardHome>).value;
      expect(home.edition, expected);
      expect(queries.calledMethods, ['system.info', 'system.product_type']);
    }
  });

  test('edition read failure does not fail the Home dashboard', () async {
    final queries = _Queries(
      results: {
        'system.info': {'hostname': 'atlas', 'version': '25.10'},
      },
      failingMethods: {'system.product_type'},
    );
    final result = await DashboardRepository(queries)
        .loadHome(const {'system.info', 'system.product_type'});
    final home = (result as DashboardData<DashboardHome>).value;
    expect(home.serverName, 'atlas');
    expect(home.edition, isNull);
    expect(queries.calledMethods, ['system.info', 'system.product_type']);
  });

  test('omits malformed optional system facts without losing Home', () async {
    final queries = _Queries(
      results: {
        'system.info': {
          'hostname': 'atlas',
          'version': '25.10',
          'uptime_seconds': -1,
          'model': 'bad\nmodel',
          'cores': 2.5,
          'physical_cores': 0,
          'physmem': double.infinity,
          'system_manufacturer': {},
          'system_product': '  ',
          'ecc_memory': 'yes',
          'loadavg': [1, double.infinity, 3],
        },
      },
    );
    final result = await DashboardRepository(queries)
        .loadHome(const {'system.info'});
    final home = (result as DashboardData<DashboardHome>).value;
    expect(home.serverName, 'atlas');
    expect(home.system, isNull);
  });
  test(
    'accepts zero load and rejects incomplete or typed load tuples',
    () async {
      for (final (raw, expected) in <(Object, bool)>[
        ([0, 0, 0], true),
        ([1, 2], false),
        ([1, 2, 3, 4], false),
        (['1', 2, 3], false),
        ([-1, 2, 3], false),
      ]) {
        final queries = _Queries(
          results: {
            'system.info': {
              'hostname': 'atlas',
              'version': '25.10',
              'loadavg': raw,
            },
          },
        );
        final result = await DashboardRepository(queries)
            .loadHome(const {'system.info'});
        final home = (result as DashboardData<DashboardHome>).value;
        expect(
          home.system?.loadAverage != null,
          expected,
          reason: raw.toString(),
        );
      }
    },
  );

  test(
    'rejects malformed Home pool identities through the public path',
    () async {
      final malformedSurrogate = String.fromCharCodes([
        0x62,
        0x61,
        0x64,
        0xD800,
      ]);
      final sharedPrefix = 'x' * 160;
      final queries = _Queries(
        results: {
          'system.info': {'hostname': 'atlas', 'version': '24.10'},
          'pool.query': [
            'scalar-row',
            {'name': malformedSurrogate, 'status': 'HEALTHY'},
            {'name': '${sharedPrefix}a', 'status': 'HEALTHY'},
            {'name': '${sharedPrefix}b', 'status': 'HEALTHY'},
            {'name': 'valid', 'status': 'HEALTHY'},
          ],
        },
      );

      final result = await DashboardRepository(queries)
          .loadHome(const {'system.info', 'pool.query'});

      final pools = (result as DashboardData<DashboardHome>).value.pools;
      expect(pools.map((pool) => pool.name), ['valid']);
    },
  );

  test(
    'rejects control and bidi characters from pool and dataset identities',
    () async {
      final queries = _Queries(
        results: {
          'system.info': {'hostname': 'atlas', 'version': '24.10'},
          'pool.query': [
            {'name': 'safe\nforged', 'status': 'HEALTHY'},
            {'name': '\ntank', 'status': 'HEALTHY'},
            {'name': 'backup\n', 'status': 'HEALTHY'},
            {'name': 'safe\u202Eevil', 'status': 'HEALTHY'},
            {'name': 'tank', 'status': 'HEALTHY'},
          ],
          'pool.dataset.query': [
            {'name': 'tank/safe\nforged'},
            {'name': '\ntank/media'},
            {'name': 'tank/archive\n'},
            {'name': 'tank/safe\u202Eevil'},
            {'name': 'tank/media'},
          ],
        },
      );
      final repository = DashboardRepository(queries);

      final homeResult = await repository.loadHome(const {
        'system.info',
        'pool.query',
      });
      final storageResult = await repository.loadStorage(const {
        'pool.query',
        'pool.dataset.query',
      });

      final home = (homeResult as DashboardData<DashboardHome>).value;
      final storage = (storageResult as DashboardData<DashboardStorage>).value;
      expect(home.pools.map((pool) => pool.name), ['tank']);
      expect(storage.pools.map((pool) => pool.name), ['tank']);
      expect(storage.datasets.map((dataset) => dataset.name), ['tank/media']);
    },
  );

  test('rejects visually blank and invisible-only identity segments', () async {
    final supplementaryTag = String.fromCharCode(0xE0001);
    final queries = _Queries(
      results: {
        'system.info': {'hostname': 'atlas', 'version': '24.10'},
        'pool.query': [
          {'name': '\u200B', 'status': 'HEALTHY'},
          {'name': '\u115F', 'status': 'HEALTHY'},
          {'name': '\u1160', 'status': 'HEALTHY'},
          {'name': '\u17B4', 'status': 'HEALTHY'},
          {'name': '\u3164', 'status': 'HEALTHY'},
          {'name': '\uFFA0', 'status': 'HEALTHY'},
          {'name': supplementaryTag, 'status': 'HEALTHY'},
          {'name': 'tank', 'status': 'HEALTHY'},
        ],
        'pool.dataset.query': [
          {'name': '\u200B'},
          {'name': '\u115F/media'},
          {'name': '\u3164/media'},
          {'name': '$supplementaryTag/media'},
          {'name': 'tank/\u200B'},
          {'name': 'tank/\u17B4'},
          {'name': 'tank/\uFFA0'},
          {'name': 'tank/$supplementaryTag'},
          {'name': 'tank/media'},
        ],
      },
    );
    final repository = DashboardRepository(queries);

    final homeResult = await repository.loadHome(const {
      'system.info',
      'pool.query',
    });
    final storageResult = await repository.loadStorage(const {
      'pool.query',
      'pool.dataset.query',
    });

    final home = (homeResult as DashboardData<DashboardHome>).value;
    final storage = (storageResult as DashboardData<DashboardStorage>).value;
    expect(home.pools.map((pool) => pool.name), ['tank']);
    expect(storage.pools.map((pool) => pool.name), ['tank']);
    expect(storage.datasets.map((dataset) => dataset.name), ['tank/media']);
  });

  test('bounds and sanitizes parsed home data', () async {
    final longName = 'x' * 200;
    final queries = _Queries(
      results: {
        'system.info': {'hostname': longName, 'version': '24.10'},
        'pool.query': List.generate(
          55,
          (index) => {
            'name': 'pool-$index',
            'status': 'HEALTHY',
            'capacity': 120,
          },
        ),
        'alert.list': List.generate(
          55,
          (index) => {
            'level': 'WARNING',
            'dismissed': false,
            'formatted': 'Alert $index',
          },
        ),
      },
    );
    final repository = DashboardRepository(queries);

    final result = await repository.loadHome(const {
      'system.info',
      'pool.query',
      'alert.list',
    });

    final home = (result as DashboardData<DashboardHome>).value;
    expect(home.serverName.length, 160);
    expect(home.pools, hasLength(50));
    expect(home.alerts, hasLength(50));
    expect(home.activeAlertCount, 55);
    expect(home.warningAlertCount, 55);
    expect(home.pools.first.capacityPercent, 100);
    expect(home.alerts.first.status, DashboardStatus.warning);
    expect(queries.calledMethods, ['system.info', 'pool.query', 'alert.list']);
  });

  test(
    'normalizes unknown pool status without retaining remote text',
    () async {
      final longStatus = 'x' * 200;
      final queries = _Queries(
        results: {
          'system.info': {'hostname': 'atlas', 'version': '24.10'},
          'pool.query': [
            {'name': 'tank', 'status': longStatus},
          ],
        },
      );
      final repository = DashboardRepository(queries);

      final homeResult = await repository.loadHome(const {
        'system.info',
        'pool.query',
      });
      final storageResult = await repository.loadStorage(const {'pool.query'});

      final homePool =
          (homeResult as DashboardData<DashboardHome>).value.pools.single;
      final storagePool =
          (storageResult as DashboardData<DashboardStorage>).value.pools.single;
      for (final pool in [homePool, storagePool]) {
        expect(pool.status, 'Unknown');
        expect(pool.statusKind, DashboardStatus.neutral);
      }
    },
  );

  test('normalizes pool capacity according to its source field', () async {
    final queries = _Queries(
      results: {
        'system.info': {'hostname': 'atlas', 'version': '24.10'},
        'pool.query': [
          {'name': 'percent', 'capacity': 1},
          {'name': 'ratio', 'used_pct': 0.01},
          {'name': 'capped', 'capacity': 120},
        ],
      },
    );

    final result = await DashboardRepository(queries)
        .loadHome(const {'system.info', 'pool.query'});

    final pools = (result as DashboardData<DashboardHome>).value.pools;
    expect(pools[0].capacity, '1%');
    expect(pools[0].capacityPercent, 1);
    expect(pools[1].capacity, '1%');
    expect(pools[1].capacityPercent, 1);
    expect(pools[2].capacity, '100%');
    expect(pools[2].capacityPercent, 100);
  });

  for (final home in [true, false]) {
    final view = home ? 'Home' : 'Storage';
    test('$view derives capacity from the 25.10 pool byte shape', () async {
      // Synthetic values reproduce the observed field shape without NAS data.
      final pools = await _loadCapacityPools(
        home: home,
        rows: const [
          {'name': 'partial', 'size': 1000, 'allocated': 475, 'free': 525},
          {'name': 'empty', 'size': 1000, 'allocated': 0, 'free': 1000},
          {'name': 'full', 'size': 1000, 'allocated': 1000, 'free': 0},
          {'name': 'without-free', 'size': 1000, 'allocated': 250},
          {
            'name': 'largest-exact',
            'size': 9007199254740991,
            'allocated': 9007199254740991,
            'free': 0,
          },
        ],
      );
      for (final entry in {
        'partial': 47.5,
        'empty': 0.0,
        'full': 100.0,
        'without-free': 25.0,
        'largest-exact': 100.0,
      }.entries) {
        expect(
          pools[entry.key]!.capacityPercent,
          entry.value,
          reason: entry.key,
        );
      }
      expect(pools['partial']!.capacity, '47.5%');
      expect(pools['empty']!.capacity, '0%');
      expect(pools['full']!.capacity, '100%');
    });

    test(
      '$view bounds labels without rounding chart capacity values',
      () async {
        const cases = [
          (name: 'long', size: 100000, allocated: 47643, label: '47.6%'),
          (name: 'repeating', size: 3, allocated: 1, label: '33.3%'),
          (name: 'tiny', size: 10000, allocated: 1, label: '<0.1%'),
          (name: 'nearly-full', size: 10000, allocated: 9999, label: '>99.9%'),
          (name: 'empty', size: 1000, allocated: 0, label: '0%'),
          (name: 'full', size: 1000, allocated: 1000, label: '100%'),
          (name: 'lower-boundary', size: 1000, allocated: 1, label: '0.1%'),
          (name: 'upper-boundary', size: 1000, allocated: 999, label: '99.9%'),
          (name: 'integer', size: 100, allocated: 25, label: '25%'),
          (name: 'round-integer', size: 10000, allocated: 4796, label: '48%'),
        ];
        final pools = await _loadCapacityPools(
          home: home,
          rows: [
            {'name': 'negative-zero', 'capacity': -0.0},
            for (final fixture in cases) ...[
              {
                'name': '${fixture.name}-bytes',
                'size': fixture.size,
                'allocated': fixture.allocated,
                'free': fixture.size - fixture.allocated,
              },
              {
                'name': '${fixture.name}-literal',
                'capacity': fixture.allocated / fixture.size * 100,
              },
              {
                'name': '${fixture.name}-percent',
                'capacity': '${fixture.allocated / fixture.size * 100}%',
              },
              {
                'name': '${fixture.name}-ratio',
                'used_pct': fixture.allocated / fixture.size,
              },
            ],
          ],
        );
        expect(pools['negative-zero']!.capacity, '0%');
        expect(pools['negative-zero']!.capacityPercent, 0);
        for (final fixture in cases) {
          for (final source in ['bytes', 'literal', 'percent', 'ratio']) {
            final pool = pools['${fixture.name}-$source']!;
            expect(pool.capacity, fixture.label, reason: pool.name);
            expect(
              pool.capacityPercent,
              fixture.allocated / fixture.size * 100,
              reason: pool.name,
            );
          }
        }
      },
    );

    test(
      '$view keeps invalid or incomplete byte capacity unavailable',
      () async {
        final invalid = <Map<String, Object?>>[
          {'size': 1000},
          {'allocated': 475},
          {'size': 0, 'allocated': 0},
          {'size': -1000, 'allocated': 0},
          {'size': 1000, 'allocated': -1},
          {'size': 1000, 'allocated': 1001},
          {'size': 1000, 'allocated': 475, 'free': -1},
          {'size': 1000, 'allocated': 475, 'free': 524},
          {'size': 1000, 'allocated': 475, 'free': 1001},
          {'size': 1000, 'allocated': 475, 'free': null},
          {'size': 1000, 'allocated': 475, 'free': '525'},
          {'size': 1000, 'allocated': 475, 'free': 525.5},
          {'size': 1000.5, 'allocated': 475},
          {'size': 1000, 'allocated': 475.5},
          {'size': '1000', 'allocated': 475},
          {'size': 1000, 'allocated': '475'},
          {'size': double.infinity, 'allocated': 475},
          {'size': 1000, 'allocated': double.nan},
          {'size': 1000, 'allocated': true},
          {'size': 1000, 'allocated': null},
          {'size': null, 'allocated': 475},
          {'size': 9007199254740992, 'allocated': 475},
          {'size': 9007199254740991, 'allocated': 9007199254740992},
          {'size': 9223372036854775807, 'allocated': 9223372036854775807},
          {},
        ];
        final pools = await _loadCapacityPools(
          home: home,
          rows: [
            for (var i = 0; i < invalid.length; i++)
              {'name': 'invalid-$i', ...invalid[i]},
          ],
        );
        expect(pools, hasLength(invalid.length));
        for (final pool in pools.values) {
          expect(pool.capacityPercent, isNull, reason: pool.name);
          expect(pool.capacity, isNull, reason: pool.name);
        }
      },
    );

    test(
      '$view preserves explicit percentage precedence over byte totals',
      () async {
        final pools = await _loadCapacityPools(
          home: home,
          rows: [
            for (final row in <Map<String, Object?>>[
              {'name': 'capacity', 'capacity': '72.5%', 'used_pct': 0.5},
              {'name': 'ratio', 'used_pct': 0.5},
              {'name': 'null-with-ratio', 'capacity': null, 'used_pct': 0.5},
              {'name': 'zero', 'capacity': 0},
              {'name': 'clamped', 'capacity': 120},
              {
                'name': 'invalid-capacity',
                'capacity': 'invalid',
                'used_pct': 0.5,
              },
              {'name': 'invalid-ratio', 'used_pct': 'invalid'},
              {'name': 'null-capacity', 'capacity': null},
              {'name': 'null-ratio', 'used_pct': null},
              {'name': 'nonfinite-capacity', 'capacity': double.infinity},
              {'name': 'invalid-bytes', 'capacity': 12, 'size': -1},
            ])
              {'size': 1000, 'allocated': 475, 'free': 525, ...row},
          ],
        );
        for (final entry in <String, double?>{
          'capacity': 72.5,
          'ratio': 50,
          'null-with-ratio': 50,
          'zero': 0,
          'clamped': 100,
          'invalid-capacity': null,
          'invalid-ratio': null,
          'null-capacity': null,
          'null-ratio': null,
          'nonfinite-capacity': null,
          'invalid-bytes': 12,
        }.entries) {
          expect(
            pools[entry.key]!.capacityPercent,
            entry.value,
            reason: entry.key,
          );
        }
      },
    );
  }

  test('keeps home alert display bounded while deriving priority health and total from every alert', () async {
    final queries = _Queries(
      results: {
        'system.info': {'hostname': 'atlas', 'version': '24.10'},
        'pool.query': [
          {'name': 'tank', 'status': 'HEALTHY'},
        ],
        'alert.list': [
          ...List.generate(
            50,
            (index) => {
              'level': 'INFO',
              'dismissed': false,
              'formatted': 'Alert $index',
            },
          ),
          {
            'level': 'CRITICAL',
            'dismissed': false,
            'formatted': 'A disk has failed',
          },
        ],
      },
    );

    final result = await DashboardRepository(queries)
        .loadHome(const {'system.info', 'pool.query', 'alert.list'});

    final home = (result as DashboardData<DashboardHome>).value;
    expect(home.alerts, hasLength(50));
    expect(home.activeAlertCount, 51);
    expect(home.criticalAlertCount, 1);
    expect(home.health.status, DashboardStatus.critical);
    expect(home.health.summary, 'Needs attention');
  });

  test('derives home health from pools after the display cutoff', () async {
    for (final status in ['CRITICAL', 'DEGRADED']) {
      final queries = _Queries(
        results: {
          'system.info': {'hostname': 'atlas', 'version': '24.10'},
          'pool.query': [
            ...List.generate(
              50,
              (index) => {'name': 'pool-$index', 'status': 'HEALTHY'},
            ),
            {'name': 'pool-50', 'status': status},
          ],
        },
      );

      final result = await DashboardRepository(queries)
          .loadHome(const {'system.info', 'pool.query'});

      final home = (result as DashboardData<DashboardHome>).value;
      expect(home.pools, hasLength(50));
      expect(home.pools.last.name, 'pool-49');
      expect(
        status == 'CRITICAL' ? home.criticalPoolCount : home.warningPoolCount,
        1,
      );
      expect(
        home.health.status,
        status == 'CRITICAL'
            ? DashboardStatus.critical
            : DashboardStatus.warning,
      );
    }
  });

  test('maps a false healthy fallback as unhealthy', () async {
    final queries = _Queries(
      results: {
        'system.info': {'hostname': 'atlas', 'version': '24.10'},
        'pool.query': [
          {'name': 'tank', 'healthy': false},
          {'name': 'backup', 'status': 'DEGRADED', 'healthy': false},
        ],
      },
    );

    final result = await DashboardRepository(queries)
        .loadHome(const {'system.info', 'pool.query'});

    final home = (result as DashboardData<DashboardHome>).value;
    expect(home.pools.first.status, 'Unhealthy');
    expect(home.pools.first.statusKind, DashboardStatus.critical);
    expect(home.pools[1].statusKind, DashboardStatus.warning);
    expect(home.health.status, DashboardStatus.critical);
  });

  test(
    'maps an UNAVAIL pool in a Home response to critical health and badge',
    () async {
      final queries = _Queries(
        results: {
          'system.info': {'hostname': 'atlas', 'version': '24.10'},
          'pool.query': [
            {'name': 'tank', 'status': 'UNAVAIL'},
          ],
        },
      );

      final result = await DashboardRepository(queries)
          .loadHome(const {'system.info', 'pool.query'});

      final home = (result as DashboardData<DashboardHome>).value;
      expect(home.pools.single.statusKind, DashboardStatus.critical);
      expect(home.health.status, DashboardStatus.critical);
    },
  );

  test('keeps storage inventory loading outside Home', () async {
    final queries = _Queries(
      results: {
        'system.info': {'hostname': 'atlas', 'version': '24.10'},
        'pool.query': const [],
        'pool.dataset.query': List.generate(
          55,
          (index) => {'name': 'data-$index'},
        ),
        'service.query': List.generate(
          55,
          (index) => {'service': 'svc-$index', 'state': 'RUNNING'},
        ),
      },
    );
    final repository = DashboardRepository(queries);
    const methods = {
      'system.info',
      'pool.query',
      'pool.dataset.query',
      'service.query',
    };

    final homeResult = await repository.loadHome(methods);
    expect(queries.calledMethods, ['system.info', 'pool.query']);
    final manageResult = await repository.loadStorage(methods);

    expect(homeResult, isA<DashboardData<DashboardHome>>());
    final manage = (manageResult as DashboardData<DashboardStorage>).value;
    expect(manage.datasets, hasLength(50));
  });

  test('keeps core home state when advertised alert query fails', () async {
    final queries = _Queries(
      results: {
        'system.info': {'hostname': 'atlas', 'version': '24.10'},
        'pool.query': [
          {'name': 'tank', 'status': 'HEALTHY'},
        ],
        'alert.list': [
          {
            'level': 'WARNING',
            'dismissed': false,
            'formatted': 'A scrub is recommended',
          },
        ],
      },
      failingMethods: {'alert.list'},
    );

    final result = await DashboardRepository(queries)
        .loadHome(const {'system.info', 'pool.query', 'alert.list'});

    expect(result, isA<DashboardData<DashboardHome>>());
    final home = (result as DashboardData<DashboardHome>).value;
    expect(home.serverName, 'atlas');
    expect(home.pools.single.name, 'tank');
    expect(home.alerts, isEmpty);
    expect(home.alertsAvailable, isFalse);
    expect(home.activeAlertCount, isNull);
    expect(home.criticalAlertCount, isNull);
    expect(home.warningAlertCount, isNull);
    expect(home.health.status, DashboardStatus.stale);
    expect(home.health.summary, 'Alert state unavailable');
    expect(queries.calledMethods, ['system.info', 'pool.query', 'alert.list']);
  });

  test('returns no connection for a handshake-only session', () async {
    final container = ProviderContainer(
      overrides: [
        activeAuthenticatedSessionProvider.overrideWithValue(
          AuthenticatedSession(
            profileId: 'one',
            repository: _HandshakeOnlyRepository(),
            availableMethodNames: const {'system.info'},
          ),
        ),
      ],
    );
    addTearDown(container.dispose);

    expect(container.read(dashboardRepositoryProvider), isNull);
    expect(
      await container.read(dashboardLoadProvider('home').future),
      isA<DashboardNoConnection>(),
    );
  });

  test(
    'switching profiles disables dashboard queries without reconnecting',
    () async {
      final repository = _QueryingRepository();
      final container = ProviderContainer(
        overrides: [
          activeAuthenticatedSessionProvider.overrideWithValue(
            AuthenticatedSession(
              profileId: 'one',
              repository: repository,
              availableMethodNames: const {'system.info'},
            ),
          ),
        ],
      );
      addTearDown(container.dispose);
      final profiles = container.read(
        serverProfilesControllerProvider.notifier,
      );
      await profiles.registerAndSelect(_profile('one'));
      await profiles.registerAndSelect(_profile('two'));
      await profiles.select('one');

      expect(
        await container.read(dashboardLoadProvider('home').future),
        isA<DashboardData<DashboardHome>>(),
      );
      repository.calledMethods.clear();

      await profiles.select('two');

      expect(container.read(dashboardRepositoryProvider), isNull);
      expect(container.read(dashboardCapabilitiesProvider), isEmpty);
      expect(
        await container.read(dashboardLoadProvider('home').future),
        isA<DashboardNoConnection>(),
      );
      expect(repository.calledMethods, isEmpty);
    },
  );
}

Future<Map<String, DashboardPool>> _loadCapacityPools({
  required bool home,
  required List<Map<String, Object?>> rows,
}) async {
  final queries = _Queries(
    results: {
      'system.info': {'hostname': 'fixture', 'version': '25.10.1'},
      'pool.query': rows,
    },
  );
  final repository = DashboardRepository(queries);
  final List<DashboardPool> pools;
  if (home) {
    final result = await repository.loadHome(const {
      'system.info',
      'pool.query',
    });
    pools = (result as DashboardData<DashboardHome>).value.pools;
    expect(queries.calledMethods, ['system.info', 'pool.query']);
  } else {
    final result = await repository.loadStorage(const {'pool.query'});
    pools = (result as DashboardData<DashboardStorage>).value.pools;
    expect(queries.calledMethods, ['pool.query']);
  }
  return {for (final pool in pools) pool.name: pool};
}

ServerProfile _profile(String id) => ServerProfile(
  id: id,
  displayName: id,
  originalHostInput: id,
  normalizedEndpoint: 'wss://$id',
  lastKnownVersion: '1',
);

final class _Queries implements AuthenticatedSessionQueries {
  _Queries({this.result, this.results, this.failingMethods = const {}});
  final Object? result;
  final Map<String, Object?>? results;
  final Set<String> failingMethods;
  final calledMethods = <String>[];

  @override
  Future<Object?> query(String method) async {
    calledMethods.add(method);
    if (failingMethods.contains(method)) throw StateError('$method failed');
    return results?[method] ?? result;
  }
}

class _HandshakeOnlyRepository implements SessionRepository {
  @override
  Future<void> close() async {}

  @override
  Future<ServerSummary> connect({
    required String serverInput,
    required String? apiKey,
    required String? username,
    bool rememberApiKey = false,
    bool Function()? isConnectionCurrent,
  }) => throw UnimplementedError();
}

final class _QueryingRepository extends _HandshakeOnlyRepository
    implements AuthenticatedSessionQueries {
  final calledMethods = <String>[];

  @override
  Future<Object?> query(String method) async {
    calledMethods.add(method);
    return const <String, Object?>{};
  }
}
