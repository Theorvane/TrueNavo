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
    expect(queries.calledMethods, ['core.get_jobs']);
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
  _Queries({this.result});
  final Object? result;
  final calledMethods = <String>[];

  @override
  Future<Object?> query(String method) async {
    calledMethods.add(method);
    return result;
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
