import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../server_profiles/server_profiles_controller.dart';
import 'dashboard_repository.dart';
import 'dashboard_capabilities.dart';

/// A live session is usable only for the durable profile that was selected
/// when it authenticated. Profile switches are intentionally display-only and
/// never reconnect the session.
final dashboardActiveSessionProvider = Provider<AuthenticatedSession?>((ref) {
  final session = ref.watch(activeAuthenticatedSessionProvider);
  final selectedProfileId = ref.watch(
    serverProfilesControllerProvider.select((state) => state.selectedProfileId),
  );
  return session?.profileId == selectedProfileId ? session : null;
});

final dashboardRepositoryProvider = Provider<DashboardRepository?>((ref) {
  final session = ref.watch(dashboardActiveSessionProvider);
  final repository = session?.repository;
  if (repository case final AuthenticatedSessionQueries queries) {
    return DashboardRepository(queries);
  }
  return null;
});

/// Capability state is derived from, and discarded with, the active session.
final dashboardCapabilityRegistryProvider = Provider<DashboardCapabilities?>((
  ref,
) {
  final session = ref.watch(dashboardActiveSessionProvider);
  if (session == null) return null;
  return DashboardCapabilities.forSession(
    version: session.version,
    availableMethodNames: session.availableMethodNames,
  );
});

final dashboardCapabilitiesProvider = Provider<Set<String>>(
  (ref) =>
      ref.watch(dashboardCapabilityRegistryProvider)?.allowedMethods ??
      const {},
);

final dashboardControllerProvider = Provider<DashboardController?>((ref) {
  final repository = ref.watch(dashboardRepositoryProvider);
  return repository == null
      ? null
      : DashboardController(
          repository,
          ref.watch(dashboardCapabilitiesProvider),
        );
});

/// Refreshable feature state used by all four read-only dashboard pages.
final dashboardLoadProvider =
    FutureProvider.family<DashboardResult<Object?>, String>((ref, view) async {
      final controller = ref.watch(dashboardControllerProvider);
      return controller?.load(view) ?? const DashboardNoConnection();
    });

final class DashboardController {
  const DashboardController(this._repository, this._methods);
  final DashboardRepository _repository;
  final Set<String> _methods;

  Future<DashboardResult<Object?>> load(String view) => switch (view) {
    'home' => _repository.loadHome(_methods),
    'alerts' => _repository.loadAlerts(_methods),
    'storage' => _repository.loadStorage(_methods),
    'workloads' => _repository.loadWorkloads(_methods),
    'jobs' => _repository.loadJobs(_methods),
    _ => Future.value(const DashboardUnavailable()),
  };
}
