import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truedash/features/connection/connection_controller.dart';
import 'package:truedash/features/dashboard/dashboard_controller.dart';
import 'package:truedash/features/dashboard/dashboard_repository.dart';
import 'package:truedash/features/server_profiles/server_profile.dart';
import 'package:truedash/features/server_profiles/server_profiles_controller.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  test('does not query an unavailable view', () async {
    final queries = _Queries();
    final repository = DashboardRepository(queries);

    final result = await repository.loadAlerts(const <String>{});

    expect(result, isA<DashboardUnavailable>());
    expect(queries.calledMethods, isEmpty);
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
          (index) => {'level': 'WARNING', 'formatted': 'Alert $index'},
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
    expect(pools[0].capacity, '1');
    expect(pools[0].capacityPercent, 1);
    expect(pools[1].capacity, '1%');
    expect(pools[1].capacityPercent, 1);
    expect(pools[2].capacity, '120');
    expect(pools[2].capacityPercent, 100);
  });

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
            (index) => {'level': 'INFO', 'formatted': 'Alert $index'},
          ),
          {'level': 'CRITICAL', 'formatted': 'A disk has failed'},
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

  test('keeps inventory loading confined to Manage', () async {
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
    final manageResult = await repository.loadManage(methods);

    expect(homeResult, isA<DashboardData<DashboardHome>>());
    final manage = (manageResult as DashboardData<DashboardManage>).value;
    expect(manage.datasets, hasLength(50));
    expect(manage.services, hasLength(50));
  });

  test('keeps core home state when advertised alert query fails', () async {
    final queries = _Queries(
      results: {
        'system.info': {'hostname': 'atlas', 'version': '24.10'},
        'pool.query': [
          {'name': 'tank', 'status': 'HEALTHY'},
        ],
        'alert.list': [
          {'level': 'WARNING', 'formatted': 'A scrub is recommended'},
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
