/// Version families are presentation-only. They never grant an RPC method.
enum DashboardVersionFamily { v25_04, v25_10, v26Plus, unknownUnsupported }

/// Read-only capabilities supported by this operations console.
enum DashboardFeature {
  systemInfo,
  pools,
  datasets,
  services,
  alerts,
  jobs,
  vdevs,
  disks,
  snapshots,
  apps,
}

/// Session-scoped capability foundation.
///
/// The version classification helps the UI describe compatibility, while the
/// advertised method set is the sole authority for an enabled feature.
final class DashboardCapabilities {
  DashboardCapabilities.forSession({
    required String version,
    required Set<String> availableMethodNames,
  }) : versionFamily = _classify(version),
       allowedMethods = Set.unmodifiable(
         availableMethodNames.intersection(_boundedMethods),
       );

  static const _boundedMethods = <String>{
    'system.info',
    'pool.query',
    'pool.dataset.query',
    'service.query',
    'alert.list',
    'core.get_jobs',
  };

  final DashboardVersionFamily versionFamily;
  final Set<String> allowedMethods;

  bool supports(DashboardFeature feature) => switch (feature) {
    DashboardFeature.systemInfo => allowedMethods.contains('system.info'),
    DashboardFeature.pools => allowedMethods.contains('pool.query'),
    DashboardFeature.datasets => allowedMethods.contains('pool.dataset.query'),
    DashboardFeature.services => allowedMethods.contains('service.query'),
    DashboardFeature.alerts => allowedMethods.contains('alert.list'),
    DashboardFeature.jobs => allowedMethods.contains('core.get_jobs'),
    // No version family is permitted to infer these unapproved RPC contracts.
    DashboardFeature.vdevs ||
    DashboardFeature.disks ||
    DashboardFeature.snapshots ||
    DashboardFeature.apps => false,
  };

  static DashboardVersionFamily _classify(String version) {
    final normalized = version.toLowerCase();
    if (RegExp(r'(^|[^0-9])25\.04([^0-9]|$)').hasMatch(normalized)) {
      return DashboardVersionFamily.v25_04;
    }
    if (RegExp(r'(^|[^0-9])25\.10([^0-9]|$)').hasMatch(normalized)) {
      return DashboardVersionFamily.v25_10;
    }
    final match = RegExp(r'(^|[^0-9])(\d{2,})\.').firstMatch(normalized);
    if (match != null && int.parse(match.group(2)!) >= 26) {
      return DashboardVersionFamily.v26Plus;
    }
    return DashboardVersionFamily.unknownUnsupported;
  }
}
