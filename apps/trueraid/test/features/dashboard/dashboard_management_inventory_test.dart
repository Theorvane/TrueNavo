import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/dashboard/dashboard_repository.dart';
import 'package:truenas_api/truenas_api.dart';

void main() {
  test(
    'retains exact dataset IDs across pool attribution and sorting',
    () async {
      final storage = await _storage([
        {'id': 'tank/z-data', 'name': 'tank/z-data'},
        {'id': 'tank'},
        {'id': 'tank/A_1.2:archive', 'name': 'tank/A_1.2:archive'},
        {'id': 'other/data', 'name': 'other/data'},
      ]);

      expect(storage.datasets.map((item) => item.managementId), [
        'tank',
        'tank/A_1.2:archive',
        'tank/z-data',
        'other/data',
      ]);
      expect(storage.datasets.first.poolName, 'tank');
      expect(storage.datasets.last.poolName, isEmpty);
    },
  );

  test(
    'dataset display names and transformed IDs are never write targets',
    () async {
      final storage = await _storage([
        {'name': 'tank/display-only'},
        {'id': 42, 'name': 'tank/numeric-id'},
        {'id': ' tank/trimmed ', 'name': ' tank/trimmed '},
        {'id': 'tank/mismatch', 'name': 'tank/other-name'},
        {'id': 'tank/leading', 'name': ' tank/leading'},
        {'id': 'tank/non-ascii-한글', 'name': 'tank/non-ascii-한글'},
        {'id': 'tank/snapshot@name', 'name': 'tank/snapshot@name'},
        {'id': 'tank/..', 'name': 'tank/..'},
        {'id': 'tank/a b', 'name': 'tank/a b'},
      ]);

      expect(storage.datasets, hasLength(9));
      expect(
        storage.datasets.map((item) => item.managementId),
        everyElement(isNull),
      );
      expect(
        storage.datasets.map((item) => item.name),
        contains('tank/trimmed'),
      );
    },
  );

  test(
    'malformed and overlong dataset identities cannot become truncated targets',
    () async {
      final longId = 'tank/${'a' * 160}';
      final storage = await _storage([
        {'id': longId, 'name': longId},
        {'id': 'tank/line\n', 'name': 'tank/line\n'},
        {'id': 'tank//empty', 'name': 'tank//empty'},
        {'id': 'tank/\u200bhidden', 'name': 'tank/\u200bhidden'},
        {'id': longId, 'name': 'tank/short-display'},
      ]);

      expect(storage.datasets, hasLength(1));
      expect(storage.datasets.single.name, 'tank/short-display');
      expect(storage.datasets.single.managementId, isNull);
    },
  );

  test(
    'dataset duplicate IDs and duplicate display identities disable writes',
    () async {
      final storage = await _storage([
        {'id': 'tank/duplicate', 'name': 'tank/duplicate'},
        {'id': 'tank/duplicate', 'name': 'tank/duplicate'},
        {'id': 'tank/ambiguous', 'name': 'tank/ambiguous'},
        {'id': 'tank/ambiguous', 'name': 'tank/different'},
        {'id': 'tank/display', 'name': 'tank/display'},
        {'name': ' tank/display '},
      ]);

      expect(
        storage.datasets.map((item) => item.managementId),
        everyElement(isNull),
      );
    },
  );

  test('protected system datasets remain display-only', () async {
    final storage = await _storage([
      for (final path in [
        'boot-pool',
        'freenas-boot/ROOT',
        'tank/ix-apps',
        'tank/ix-applications/data',
        'tank/${'a' * 129}',
      ])
        {'id': path, 'name': path},
    ]);

    expect(storage.datasets, hasLength(5));
    expect(
      storage.datasets.map((item) => item.managementId),
      everyElement(isNull),
    );
  });

  test(
    'a dataset duplicate outside the display bound still disables its target',
    () async {
      final storage = await _storage([
        {'id': 'tank/duplicate', 'name': 'tank/duplicate'},
        for (var index = 1; index < 50; index++)
          {'id': 'tank/data$index', 'name': 'tank/data$index'},
        {'id': 'tank/duplicate', 'name': 'tank/duplicate'},
      ]);

      expect(storage.datasets, hasLength(50));
      expect(
        storage.datasets
            .singleWhere((item) => item.name == 'tank/duplicate')
            .managementId,
        isNull,
      );
    },
  );

  test(
    'services retain only the exact service field as command identifiers',
    () async {
      final services = await _services([
        {'service': 'ssh', 'name': 'Secure Shell', 'id': 1, 'state': 'RUNNING'},
        {'service': 'nfs_v4_1', 'state': 'STOPPED'},
        {'name': 'smb', 'id': 2},
        {'id': 'ftp'},
        {'service': ' ssh '},
        {'service': 'SSH'},
        {'service': 'ssh\n'},
        {'service': 'nfs/other'},
        {'service': 42},
        {'service': 'a' * 65},
        {'service': 'a' * 161},
        {'service': '서비스'},
      ]);

      expect(services.take(2).map((item) => item.managementId), [
        'ssh',
        'nfs_v4_1',
      ]);
      expect(
        services.skip(2).map((item) => item.managementId),
        everyElement(isNull),
      );
      expect(services.first.name, 'ssh');
      expect(services.first.statusKind, DashboardStatus.success);
      expect(services[10].name, endsWith('…'));
    },
  );

  test(
    'service duplicates outside the display bound still disable writes',
    () async {
      final services = await _services([
        {'service': 'ssh'},
        for (var index = 1; index < 50; index++) {'service': 'service$index'},
        {'service': 'ssh'},
      ]);

      expect(services, hasLength(50));
      expect(services.first.managementId, isNull);
      expect(services[1].managementId, 'service1');
    },
  );

  test('manually created display models do not imply management authority', () {
    const dataset = DashboardDataset(name: 'tank/data', poolName: 'tank');
    const service = DashboardService(
      name: 'ssh',
      status: 'Running',
      statusKind: DashboardStatus.success,
    );

    expect(dataset.managementId, isNull);
    expect(service.managementId, isNull);
  });
}

Future<DashboardStorage> _storage(List<Object?> datasets) async {
  final result = await DashboardRepository(
    _Queries({
      'pool.query': [
        {'name': 'tank', 'status': 'ONLINE'},
      ],
      'pool.dataset.query': datasets,
    }),
  ).loadStorage({'pool.query', 'pool.dataset.query'});
  return (result as DashboardData<DashboardStorage>).value;
}

Future<List<DashboardService>> _services(List<Object?> services) async {
  final result = await DashboardRepository(
    _Queries({'service.query': services}),
  ).loadWorkloads({'service.query'});
  return (result as DashboardData<DashboardWorkloads>).value.services;
}

final class _Queries implements AuthenticatedSessionQueries {
  _Queries(this.responses);
  final Map<String, Object?> responses;

  @override
  Future<Object?> query(String method) async => responses[method];
}
