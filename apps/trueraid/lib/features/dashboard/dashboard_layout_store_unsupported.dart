import 'dashboard_layout_store.dart';

DashboardLayoutStore createDashboardLayoutStore() => _UnavailableStore();

class _UnavailableStore implements DashboardLayoutStore {
  @override
  Future<String?> read(String key) =>
      Future.error(StateError('Local layout storage is unavailable.'));
  @override
  Future<void> write(String key, String value) =>
      Future.error(StateError('Local layout storage is unavailable.'));
}
