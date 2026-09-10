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

enum DashboardStatus { neutral, success, warning, critical, info, stale }

DashboardStatus dashboardSeverityStatus(String value) {
  switch (value.trim().toLowerCase()) {
    case 'critical':
    case 'alert':
    case 'error':
    case 'emergency':
      return DashboardStatus.critical;
    case 'warning':
    case 'warn':
      return DashboardStatus.warning;
    case 'info':
    case 'notice':
      return DashboardStatus.info;
    default:
      return DashboardStatus.info;
  }
}

DashboardStatus dashboardOperationalStatus(String value) {
  switch (value.trim().toLowerCase()) {
    case 'healthy':
    case 'online':
    case 'running':
    case 'active':
    case 'success':
    case 'finished':
      return DashboardStatus.success;
    case 'degraded':
    case 'warning':
    case 'waiting':
    case 'pending':
    case 'queued':
      return DashboardStatus.warning;
    case 'critical':
    case 'faulted':
    case 'offline':
    case 'unavail':
    case 'unavailable':
    case 'removed':
    case 'failed':
    case 'failure':
    case 'error':
    case 'aborted':
      return DashboardStatus.critical;
    case 'stale':
      return DashboardStatus.stale;
    case 'unknown':
    case 'stopped':
    case 'disabled':
    case 'idle':
      return DashboardStatus.neutral;
    default:
      return DashboardStatus.info;
  }
}

final class DashboardHealth {
  const DashboardHealth({required this.status, required this.summary});
  final DashboardStatus status;
  final String summary;
}

final class DashboardHome {
  const DashboardHome({
    required this.serverName,
    required this.version,
    required this.pools,
    required this.alerts,
    required this.poolsAvailable,
    required this.alertsAvailable,
    required this.activeAlertCount,
    required this.criticalAlertCount,
    required this.warningAlertCount,
    required this.criticalPoolCount,
    required this.warningPoolCount,
  });
  final String serverName;
  final String version;
  final List<DashboardPool> pools;
  final List<DashboardAlert> alerts;
  final bool poolsAvailable;
  final bool alertsAvailable;

  /// Counts are derived from the complete alert response; [alerts] is display-bounded.
  final int? activeAlertCount;
  final int? criticalAlertCount;
  final int? warningAlertCount;

  /// Counts are derived from the complete pool response; [pools] is display-bounded.
  final int? criticalPoolCount;
  final int? warningPoolCount;

  DashboardHealth get health => dashboardHealthFor(
    pools,
    alerts,
    criticalAlertCount: criticalAlertCount,
    warningAlertCount: warningAlertCount,
    criticalPoolCount: criticalPoolCount,
    warningPoolCount: warningPoolCount,
    alertsAvailable: alertsAvailable,
  );
}

DashboardHealth dashboardHealthFor(
  List<DashboardPool> pools,
  List<DashboardAlert> alerts, {
  int? criticalAlertCount,
  int? warningAlertCount,
  int? criticalPoolCount,
  int? warningPoolCount,
  bool alertsAvailable = true,
}) {
  final criticalAlerts =
      criticalAlertCount ??
      alerts.where((alert) => alert.status == DashboardStatus.critical).length;
  final warningAlerts =
      warningAlertCount ??
      alerts.where((alert) => alert.status == DashboardStatus.warning).length;
  final criticalPools =
      criticalPoolCount ??
      pools.where((pool) => pool.statusKind == DashboardStatus.critical).length;
  final warningPools =
      warningPoolCount ??
      pools.where((pool) => pool.statusKind == DashboardStatus.warning).length;
  if (criticalAlerts + criticalPools > 0) {
    return const DashboardHealth(
      status: DashboardStatus.critical,
      summary: 'Needs attention',
    );
  }
  if (warningAlerts + warningPools > 0) {
    return const DashboardHealth(
      status: DashboardStatus.warning,
      summary: 'Review recommended',
    );
  }
  if (!alertsAvailable) {
    return const DashboardHealth(
      status: DashboardStatus.stale,
      summary: 'Alert state unavailable',
    );
  }
  if (pools.isEmpty && alerts.isEmpty) {
    return const DashboardHealth(
      status: DashboardStatus.info,
      summary: 'Current state',
    );
  }
  return const DashboardHealth(
    status: DashboardStatus.success,
    summary: 'Operating normally',
  );
}

final class DashboardAlert {
  const DashboardAlert({
    required this.level,
    required this.message,
    required this.status,
  });
  final String level;
  final String message;
  final DashboardStatus status;
}

/// Sanitized, derived alert state for the home view. It retains no raw payload.
final class _DashboardHomeAlerts {
  const _DashboardHomeAlerts({
    required this.items,
    required this.activeCount,
    required this.criticalCount,
    required this.warningCount,
  });
  final List<DashboardAlert> items;
  final int activeCount;
  final int criticalCount;
  final int warningCount;
}

/// Sanitized, derived pool state for the home view. It retains no raw payload.
final class _DashboardHomePools {
  const _DashboardHomePools({
    required this.items,
    required this.criticalCount,
    required this.warningCount,
  });
  final List<DashboardPool> items;
  final int criticalCount;
  final int warningCount;
}

final class DashboardStorage {
  const DashboardStorage({
    required this.pools,
    required this.datasets,
    required this.poolsAvailable,
    required this.datasetsAvailable,
  });
  final List<DashboardPool> pools;
  final List<DashboardDataset> datasets;
  final bool poolsAvailable;
  final bool datasetsAvailable;
}

/// The method may be unavailable, or it may be advertised but its response
/// failed. Keep those states distinct for storage availability.
final class _OptionalList<T> {
  const _OptionalList({required this.supported, this.items});
  final bool supported;
  final List<T>? items;
}

final class DashboardWorkloads {
  const DashboardWorkloads({
    required this.services,
    required this.servicesAvailable,
  });
  final List<DashboardService> services;
  final bool servicesAvailable;
}

final class DashboardJobs {
  const DashboardJobs(this.items);
  final List<DashboardJob> items;
}

final class DashboardPool {
  const DashboardPool({
    required this.name,
    required this.status,
    required this.statusKind,
    this.capacity,
    this.capacityPercent,
  });
  final String name;
  final String status;
  final DashboardStatus statusKind;
  final String? capacity;
  final double? capacityPercent;
}

final class DashboardDataset {
  const DashboardDataset({required this.name, required this.poolName});
  final String name;
  final String poolName;
}

final class DashboardService {
  const DashboardService({
    required this.name,
    required this.status,
    required this.statusKind,
  });
  final String name;
  final String status;
  final DashboardStatus statusKind;
}

final class DashboardJob {
  const DashboardJob({
    required this.id,
    required this.name,
    required this.status,
    required this.statusKind,
  });
  final String id;
  final String name;
  final String status;
  final DashboardStatus statusKind;
}

/// App-owned parser over the narrow authenticated query capability. Raw RPC
/// values are consumed immediately and never retained or persisted.
final class DashboardRepository {
  DashboardRepository(this._queries);
  final AuthenticatedSessionQueries _queries;

  Future<DashboardResult<DashboardHome>> loadHome(Set<String> methods) async {
    if (!methods.contains('system.info')) return const DashboardUnavailable();
    try {
      final map = _map(await _queries.query('system.info'));
      final homePools = methods.contains('pool.query')
          ? _homePools(await _queries.query('pool.query'))
          : const _DashboardHomePools(
              items: <DashboardPool>[],
              criticalCount: 0,
              warningCount: 0,
            );
      final homeAlerts = await _optionalHomeAlerts(methods);
      return DashboardData(
        DashboardHome(
          serverName: _text(map['hostname'] ?? map['name'], fallback: 'Server'),
          version: _text(map['version'], fallback: 'Unknown version'),
          pools: homePools.items,
          alerts: homeAlerts?.items ?? const <DashboardAlert>[],
          poolsAvailable: methods.contains('pool.query'),
          alertsAvailable: homeAlerts != null,
          activeAlertCount: homeAlerts?.activeCount,
          criticalAlertCount: homeAlerts?.criticalCount,
          warningAlertCount: homeAlerts?.warningCount,
          criticalPoolCount: homePools.criticalCount,
          warningPoolCount: homePools.warningCount,
        ),
      );
    } on Object {
      return const DashboardFailure();
    }
  }

  Future<DashboardResult<List<DashboardAlert>>> loadAlerts(
    Set<String> methods,
  ) => _load('alert.list', methods, _alerts);

  Future<DashboardResult<DashboardStorage>> loadStorage(
    Set<String> methods,
  ) async {
    final pools = await _optionalList(methods, 'pool.query', _pools);
    final datasets = await _optionalList(
      methods,
      'pool.dataset.query',
      _datasets,
    );
    if (!pools.supported && !datasets.supported) {
      return const DashboardUnavailable();
    }
    if (pools.items == null && datasets.items == null) {
      return const DashboardFailure();
    }
    final poolItems = pools.items ?? const <DashboardPool>[];
    final poolIdentityCounts = <String, int>{};
    for (final pool in poolItems) {
      poolIdentityCounts.update(
        pool.name,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    final knownPoolNames = poolIdentityCounts.entries
        .where((entry) => entry.value == 1)
        .map((entry) => entry.key)
        .toSet();
    final datasetItems =
        (datasets.items ?? const <DashboardDataset>[])
            .map(
              (dataset) => DashboardDataset(
                name: dataset.name,
                poolName: knownPoolNames.contains(dataset.poolName)
                    ? dataset.poolName
                    : '',
              ),
            )
            .toList()
          ..sort(_compareDatasets);
    return DashboardData(
      DashboardStorage(
        pools: poolItems,
        datasets: datasetItems,
        poolsAvailable: pools.items != null,
        datasetsAvailable: datasets.items != null,
      ),
    );
  }

  Future<DashboardResult<DashboardWorkloads>> loadWorkloads(
    Set<String> methods,
  ) => _load(
    'service.query',
    methods,
    (value) =>
        DashboardWorkloads(services: _services(value), servicesAvailable: true),
  );

  Future<DashboardResult<DashboardJobs>> loadJobs(Set<String> methods) => _load(
    'core.get_jobs',
    methods,
    (value) => DashboardJobs(
      _list(value).take(50).map((item) {
        final map = _map(item);
        final status = _text(
          map['state'] ?? map['status'],
          fallback: 'Unknown',
        );
        return DashboardJob(
          id: _text(map['id'], fallback: '—'),
          name: _text(map['method'] ?? map['description'], fallback: 'Job'),
          status: status,
          statusKind: dashboardOperationalStatus(status),
        );
      }).toList(),
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

  /// A supported storage section can fail independently; do not hide useful
  /// pool or dataset inventory merely because its companion is unavailable.
  Future<_OptionalList<T>> _optionalList<T>(
    Set<String> methods,
    String method,
    List<T> Function(Object? value) parse,
  ) async {
    if (!methods.contains(method)) {
      return const _OptionalList(supported: false);
    }
    try {
      return _OptionalList(
        supported: true,
        items: parse(await _queries.query(method)),
      );
    } on Object {
      return const _OptionalList(supported: true);
    }
  }

  /// Alert state is supplemental to Home's system and pool state. A server can
  /// advertise the method but still reject the individual request.
  Future<_DashboardHomeAlerts?> _optionalHomeAlerts(Set<String> methods) async {
    if (!methods.contains('alert.list')) return null;
    try {
      return _homeAlerts(await _queries.query('alert.list'));
    } on Object {
      return null;
    }
  }

  _DashboardHomeAlerts _homeAlerts(Object? value) {
    final allAlerts = _list(value);
    var criticalCount = 0;
    var warningCount = 0;
    final items = <DashboardAlert>[];
    for (final item in allAlerts) {
      final alert = _alert(item);
      if (alert.status == DashboardStatus.critical) criticalCount++;
      if (alert.status == DashboardStatus.warning) warningCount++;
      if (items.length < 50) items.add(alert);
    }
    return _DashboardHomeAlerts(
      items: items,
      activeCount: allAlerts.length,
      criticalCount: criticalCount,
      warningCount: warningCount,
    );
  }

  List<DashboardAlert> _alerts(Object? value) =>
      _list(value).take(50).map(_alert).toList();

  DashboardAlert _alert(Object? item) {
    final map = _map(item);
    final level = _text(map['level'] ?? map['klass'], fallback: 'Info');
    return DashboardAlert(
      level: level,
      message: _text(
        map['formatted'] ?? map['message'] ?? map['text'],
        fallback: 'Alert',
      ),
      status: dashboardSeverityStatus(level),
    );
  }

  List<DashboardPool> _pools(Object? value) {
    if (value is! List) {
      throw const FormatException('Pool inventory must be a list.');
    }
    final pools = <DashboardPool>[];
    for (final item in value.take(50)) {
      if (item is! Map) continue;
      final name = item['name'];
      if (name is! String || name.trim().isEmpty) continue;
      final normalizedName = name.trim();
      if (!_isSafeIdentifier(normalizedName)) continue;
      pools.add(_pool({...item, 'name': normalizedName}));
    }
    pools.sort((left, right) => _compareText(left.name, right.name));
    return pools;
  }

  _DashboardHomePools _homePools(Object? value) {
    var criticalCount = 0;
    var warningCount = 0;
    final items = <DashboardPool>[];
    for (final item in _list(value)) {
      final pool = _pool(item);
      if (pool.statusKind == DashboardStatus.critical) criticalCount++;
      if (pool.statusKind == DashboardStatus.warning) warningCount++;
      if (items.length < 50) items.add(pool);
    }
    return _DashboardHomePools(
      items: items,
      criticalCount: criticalCount,
      warningCount: warningCount,
    );
  }

  DashboardPool _pool(Object? item) {
    final map = _map(item);
    final capacityValue = map['capacity'];
    final usedPercent = map['used_pct'];
    final rawCapacity = capacityValue ?? usedPercent;
    final isRatioSource = capacityValue == null && usedPercent != null;
    final capacityPercent = _capacityPercent(
      rawCapacity,
      isRatio: isRatioSource,
    );
    final capacity = capacityPercent == null
        ? null
        : _percentText(capacityPercent);
    final explicitStatus = map['status'];
    final healthy = map['healthy'];
    final normalizedStatus = explicitStatus is String
        ? _normalizedPoolStatus(explicitStatus)
        : null;
    final status =
        normalizedStatus ??
        (healthy is bool ? (healthy ? 'Healthy' : 'Unhealthy') : 'Unknown');
    final statusKind = healthy is bool && normalizedStatus == null
        ? (healthy ? DashboardStatus.success : DashboardStatus.critical)
        : dashboardOperationalStatus(status);
    return DashboardPool(
      name: _text(map['name'], fallback: 'Pool'),
      status: status,
      statusKind: statusKind,
      capacity: capacity,
      capacityPercent: capacityPercent,
    );
  }

  List<DashboardDataset> _datasets(Object? value) {
    if (value is! List) {
      throw const FormatException('Dataset inventory must be a list.');
    }
    final datasets = <DashboardDataset>[];
    for (final item in value.take(50)) {
      if (item is! Map) continue;
      final rawName = item['name'] ?? item['id'];
      if (rawName is! String || rawName.trim().isEmpty) continue;
      final normalizedName = rawName.trim();
      if (!_isSafeIdentifier(normalizedName)) continue;
      final rootName = normalizedName.split('/').first;
      datasets.add(DashboardDataset(name: normalizedName, poolName: rootName));
    }
    return datasets;
  }

  int _compareDatasets(DashboardDataset left, DashboardDataset right) {
    final leftPool = left.poolName.isEmpty ? '\uffff' : left.poolName;
    final rightPool = right.poolName.isEmpty ? '\uffff' : right.poolName;
    final poolOrder = _compareText(leftPool, rightPool);
    return poolOrder != 0 ? poolOrder : _compareText(left.name, right.name);
  }

  int _compareText(String left, String right) {
    final normalized = left.toLowerCase().compareTo(right.toLowerCase());
    return normalized != 0 ? normalized : left.compareTo(right);
  }

  List<DashboardService> _services(Object? value) =>
      _list(value).take(50).map((item) {
        final map = _map(item);
        final status = _text(
          map['state'] ?? map['status'] ?? map['enable'],
          fallback: 'Unknown',
        );
        return DashboardService(
          name: _text(
            map['service'] ?? map['name'] ?? map['id'],
            fallback: 'Unnamed',
          ),
          status: status,
          statusKind: dashboardOperationalStatus(status),
        );
      }).toList();

  double? _capacityPercent(Object? value, {required bool isRatio}) {
    final hasExplicitPercent = value is String && value.trim().endsWith('%');
    final number = switch (value) {
      num value => value.toDouble(),
      String value
          when RegExp(r'^(?:\d+(?:\.\d+)?|\.\d+)%?$').hasMatch(value.trim()) =>
        double.tryParse(
          value.trim().endsWith('%')
              ? value.trim().substring(0, value.trim().length - 1)
              : value.trim(),
        ),
      _ => null,
    };
    if (number == null || !number.isFinite) return null;
    final percent = isRatio && !hasExplicitPercent && number >= 0 && number <= 1
        ? number * 100
        : number;
    return percent.clamp(0, 100).toDouble();
  }

  String _percentText(double percent) =>
      '${percent == percent.roundToDouble() ? percent.round() : percent}%';

  String? _normalizedPoolStatus(String value) {
    return switch (value.trim().toLowerCase()) {
      'healthy' => 'Healthy',
      'online' => 'Online',
      'degraded' => 'Degraded',
      'warning' => 'Warning',
      'critical' => 'Critical',
      'faulted' => 'Faulted',
      'offline' => 'Offline',
      'unavail' => 'Unavailable',
      'removed' => 'Removed',
      'unknown' => 'Unknown',
      _ => null,
    };
  }

  bool _isSafeIdentifier(String value) {
    if (value.length > 160) return false;
    for (var index = 0; index < value.length; index++) {
      final unit = value.codeUnitAt(index);
      if (unit >= 0xD800 && unit <= 0xDBFF) {
        if (++index >= value.length) return false;
        final next = value.codeUnitAt(index);
        if (next < 0xDC00 || next > 0xDFFF) return false;
      } else if (unit >= 0xDC00 && unit <= 0xDFFF) {
        return false;
      }
    }
    return true;
  }

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
