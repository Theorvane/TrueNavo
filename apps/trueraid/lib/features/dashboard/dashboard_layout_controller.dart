import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'dashboard_controller.dart';
import 'dashboard_layout.dart';
import 'dashboard_layout_store.dart';
import 'dashboard_layout_store_platform.dart';

final dashboardLayoutIdentityProvider = Provider<DashboardLayoutIdentity?>((
  ref,
) {
  final session = ref.watch(dashboardActiveSessionProvider);
  return session == null
      ? null
      : DashboardLayoutIdentity.fromEndpoint(
          profileId: session.profileId,
          endpoint: session.endpoint,
        );
});

final dashboardLayoutStoreProvider = Provider<DashboardLayoutStore>(
  (ref) => createDashboardLayoutStore(),
);

final dashboardLayoutControllerProvider = NotifierProvider.autoDispose
    .family<
      DashboardLayoutController,
      DashboardLayoutState,
      DashboardLayoutIdentity
    >(DashboardLayoutController.new);

final class DashboardLayoutState {
  const DashboardLayoutState({
    required this.layout,
    this.loading = false,
    this.saving = false,
    this.message,
  });
  final DashboardLayout layout;
  final bool loading;
  final bool saving;
  final String? message;
}

final class DashboardLayoutController extends Notifier<DashboardLayoutState> {
  DashboardLayoutController(this.identity);
  final DashboardLayoutIdentity identity;
  var _generation = 0;
  var _disposed = false;

  @override
  DashboardLayoutState build() {
    final store = ref.watch(dashboardLayoutStoreProvider);
    _disposed = false;
    final generation = ++_generation;
    ref.onDispose(() {
      _disposed = true;
      _generation++;
    });
    Future<void>.microtask(() => _load(store, generation));
    return DashboardLayoutState(
      layout: DashboardLayout.defaults(),
      loading: true,
    );
  }

  bool _current(int generation) => !_disposed && generation == _generation;

  Future<void> _load(DashboardLayoutStore store, int generation) async {
    try {
      final raw = await store.read(identity.storageKey);
      if (!_current(generation)) return;
      final layout = raw == null
          ? DashboardLayout.defaults()
          : DashboardLayout.decode(raw);
      state = DashboardLayoutState(
        layout: layout ?? DashboardLayout.defaults(),
        message: layout == null
            ? 'Saved layout could not be read. Default sections are shown.'
            : null,
      );
    } catch (_) {
      if (!_current(generation)) return;
      state = DashboardLayoutState(
        layout: DashboardLayout.defaults(),
        message:
            'Local layout storage is unavailable. Default sections are shown.',
      );
    }
  }

  Future<bool> save(DashboardLayout layout) async {
    if (_disposed ||
        state.loading ||
        state.saving ||
        ref.read(dashboardLayoutIdentityProvider) != identity) {
      return false;
    }
    final generation = ++_generation;
    final previous = state.layout;
    state = DashboardLayoutState(layout: previous, saving: true);
    try {
      await ref
          .read(dashboardLayoutStoreProvider)
          .write(identity.storageKey, layout.encode());
      if (!_current(generation)) return false;
      state = DashboardLayoutState(
        layout: layout,
        message: 'Layout saved on this device.',
      );
      return true;
    } catch (_) {
      if (!_current(generation)) return false;
      state = DashboardLayoutState(
        layout: previous,
        message: 'Layout was not saved. Check local storage and try again.',
      );
      return false;
    }
  }

  Future<bool> reset() => save(DashboardLayout.defaults());
}
