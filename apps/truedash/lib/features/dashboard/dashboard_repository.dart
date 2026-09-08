import 'package:truenas_api/truenas_api.dart';

sealed class DashboardResult<T> {
  const DashboardResult();
}

final class DashboardData<T> extends DashboardResult<T> {
  const DashboardData(this.value);
  final T value;
}

final class DashboardUnavailable<T> extends DashboardResult<T> {
  const DashboardUnavailable();
}

final class DashboardNoConnection<T> extends DashboardResult<T> {
  const DashboardNoConnection();
}

final class DashboardFailure<T> extends DashboardResult<T> {
  const DashboardFailure();
}

final class DashboardHome {
  const DashboardHome({
    required this.serverName,
    required this.version,
    required this.pools,
  });
  final String serverName;
  final String version;
  final List<DashboardPool> pools;
}

final class DashboardAlert {
  const DashboardAlert({required this.level, required this.message});
  final String level;
  final String message;
}

final class DashboardManage {
  const DashboardManage({
    required this.pools,
    required this.datasets,
    required this.services,
  });
  final List<DashboardPool> pools;
  final List<String> datasets;
  final List<String> services;
}

final class DashboardJobs {
  const DashboardJobs(this.items);
  final List<DashboardJob> items;
}

final class DashboardPool {
  const DashboardPool({
    required this.name,
    required this.status,
    this.capacity,
  });
  final String name;
  final String status;
  final String? capacity;
}

final class DashboardJob {
  const DashboardJob({
    required this.id,
    required this.name,
    required this.status,
  });
  final String id;
  final String name;
  final String status;
}

/// App-owned parser over the narrow authenticated query capability. Raw RPC
/// values are consumed immediately and never retained or persisted.
final class DashboardRepository {
  DashboardRepository(this._queries);
  final AuthenticatedSessionQueries _queries;

  Future<DashboardResult<DashboardHome>> loadHome(Set<String> methods) async {
    if (!methods.contains('system.info')) return const DashboardUnavailable();
    try {
      final info = await _queries.query('system.info');
      final pools = methods.contains('pool.query')
          ? _pools(await _queries.query('pool.query'))
          : const <DashboardPool>[];
      final map = _map(info);
      return DashboardData(
        DashboardHome(
          serverName: _text(map['hostname'] ?? map['name'], fallback: 'Server'),
          version: _text(map['version'], fallback: 'Unknown version'),
          pools: pools,
        ),
      );
    } on Object {
      return const DashboardFailure();
    }
  }

  Future<DashboardResult<List<DashboardAlert>>> loadAlerts(
    Set<String> methods,
  ) => _load(
    'alert.list',
    methods,
    (value) => _list(value)
        .map((item) {
          final map = _map(item);
          return DashboardAlert(
            level: _text(map['level'] ?? map['klass'], fallback: 'Info'),
            message: _text(
              map['formatted'] ?? map['message'] ?? map['text'],
              fallback: 'Alert',
            ),
          );
        })
        .take(50)
        .toList(),
  );

  Future<DashboardResult<DashboardManage>> loadManage(
    Set<String> methods,
  ) async {
    const required = {'pool.query', 'pool.dataset.query', 'service.query'};
    if (!methods.containsAll(required)) return const DashboardUnavailable();
    try {
      return DashboardData(
        DashboardManage(
          pools: _pools(await _queries.query('pool.query')),
          datasets: _names(await _queries.query('pool.dataset.query')),
          services: _names(await _queries.query('service.query')),
        ),
      );
    } on Object {
      return const DashboardFailure();
    }
  }

  Future<DashboardResult<DashboardJobs>> loadJobs(Set<String> methods) => _load(
    'core.get_jobs',
    methods,
    (value) => DashboardJobs(
      _list(value)
          .map((item) {
            final map = _map(item);
            return DashboardJob(
              id: _text(map['id'], fallback: '—'),
              name: _text(map['method'] ?? map['description'], fallback: 'Job'),
              status: _text(map['state'] ?? map['status'], fallback: 'Unknown'),
            );
          })
          .take(50)
          .toList(),
    ),
  );

  Future<DashboardResult<T>> _load<T>(
    String method,
    Set<String> methods,
    T Function(Object? value) parse,
  ) async {
    if (!methods.contains(method)) return const DashboardUnavailable();
    try {
      return DashboardData(parse(await _queries.query(method)));
    } on Object {
      return const DashboardFailure();
    }
  }

  List<DashboardPool> _pools(Object? value) => _list(value)
      .map((item) {
        final map = _map(item);
        final capacity = map['capacity'] ?? map['used_pct'];
        return DashboardPool(
          name: _text(map['name'], fallback: 'Pool'),
          status: _text(map['status'] ?? map['healthy'], fallback: 'Unknown'),
          capacity: capacity == null
              ? null
              : _text(capacity, fallback: 'Unknown'),
        );
      })
      .take(50)
      .toList();

  List<String> _names(Object? value) => _list(value)
      .map((item) {
        final map = _map(item);
        return _text(
          map['name'] ?? map['service'] ?? map['id'],
          fallback: 'Unnamed',
        );
      })
      .take(50)
      .toList();

  Map _map(Object? value) => value is Map ? value : const {};
  List _list(Object? value) => value is List ? value : const [];
  String _text(Object? value, {required String fallback}) {
    final text = value is String || value is num || value is bool
        ? '$value'
        : '';
    if (text.isEmpty) return fallback;
    return text.length > 160 ? '${text.substring(0, 159)}…' : text;
  }
}
