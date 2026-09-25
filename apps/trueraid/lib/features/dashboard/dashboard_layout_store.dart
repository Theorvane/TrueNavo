abstract interface class DashboardLayoutStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

/// Explicitly opt-in transient storage for isolated previews and tests.
/// Production uses the platform file store, never this fallback.
final class MemoryDashboardLayoutStore implements DashboardLayoutStore {
  final _values = <String, String>{};

  @override
  Future<String?> read(String key) async => _values[key];

  @override
  Future<void> write(String key, String value) async => _values[key] = value;
}
