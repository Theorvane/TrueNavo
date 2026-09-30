import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../management/server_operation_lock.dart';

final appsSessionProvider = Provider<AuthenticatedAppsSession?>((ref) {
  final repository = ref.watch(dashboardActiveSessionProvider)?.repository;
  return repository is AuthenticatedAppsSession
      ? repository as AuthenticatedAppsSession
      : null;
});
final appsInventoryProvider = FutureProvider<AppsInventory>((ref) async {
  final api = ref.watch(appsSessionProvider);
  if (api == null) throw StateError('No authenticated Apps session.');
  return api.loadAppsInventory();
});
final installedAppDetailsProvider = FutureProvider.autoDispose
    .family<InstalledAppDetails, (AuthenticatedSession, InstalledApp)>((
      ref,
      selection,
    ) async {
      if (!identical(ref.watch(dashboardActiveSessionProvider), selection.$1)) {
        throw StateError('The selected Apps session changed.');
      }
      final api = selection.$1.repository;
      if (api is! AuthenticatedAppsSession) {
        throw StateError('No authenticated Apps session.');
      }
      return (api as AuthenticatedAppsSession).loadInstalledAppDetails(
        selection.$2,
      );
    });
final outdatedAppImagesProvider = FutureProvider.autoDispose
    .family<List<String>, (AuthenticatedSession, InstalledApp)>((
      ref,
      selection,
    ) async {
      if (!identical(ref.watch(dashboardActiveSessionProvider), selection.$1)) {
        throw StateError('The selected Apps session changed.');
      }
      final api = selection.$1.repository;
      if (api is! AuthenticatedAppsSession) {
        throw StateError('No authenticated Apps session.');
      }
      return (api as AuthenticatedAppsSession).loadOutdatedAppImages(
        selection.$2,
      );
    });
final appRollbackVersionsProvider = FutureProvider.autoDispose
    .family<List<String>, (AuthenticatedSession, InstalledApp)>((
      ref,
      selection,
    ) async {
      if (!identical(ref.watch(dashboardActiveSessionProvider), selection.$1)) {
        throw StateError('The selected Apps session changed.');
      }
      final api = selection.$1.repository;
      if (api is! AuthenticatedAppsSession) {
        throw StateError('No authenticated Apps session.');
      }
      return (api as AuthenticatedAppsSession).loadAppRollbackVersions(
        selection.$2,
      );
    });
final appsCatalogProvider = FutureProvider.family<List<CatalogApp>, bool>((
  ref,
  cachedOnly,
) async {
  final api = ref.watch(appsSessionProvider);
  if (api == null) throw StateError('No authenticated Apps session.');
  return api.loadAppsCatalog(cachedOnly: cachedOnly);
});
final catalogOverviewProvider = FutureProvider<CatalogOverview>((ref) async {
  final api = ref.watch(dashboardActiveSessionProvider)?.repository;
  if (api is! AuthenticatedCatalogOverviewSession) {
    throw StateError('Catalog settings are unavailable.');
  }
  return (api as AuthenticatedCatalogOverviewSession).loadCatalogOverview();
});
final appVersionsProvider = FutureProvider.autoDispose
    .family<List<String>, CatalogApp>((ref, app) async {
      final api = ref.watch(appsSessionProvider);
      if (api == null) throw StateError('No authenticated Apps session.');
      return api.loadAppVersions(app);
    });
final appVersionDetailsProvider = FutureProvider.autoDispose
    .family<AppVersionDetails, (CatalogApp, String)>((ref, selection) async {
      final api = ref.watch(appsSessionProvider);
      if (api == null) throw StateError('No authenticated Apps session.');
      return api.loadAppVersionDetails(selection.$1, selection.$2);
    });
final appUpgradeReviewProvider = FutureProvider.autoDispose
    .family<AppUpgradeReview, (InstalledApp, AppVersionDetails)>((
      ref,
      selection,
    ) async {
      final api = ref.watch(appsSessionProvider);
      if (api == null) throw StateError('No authenticated Apps session.');
      return api.loadAppUpgradeReview(selection.$1, selection.$2);
    });
final appConfigReviewProvider = FutureProvider.autoDispose
    .family<AppConfigReview, InstalledApp>((ref, app) async {
      final api = ref.watch(appsSessionProvider);
      if (api == null) throw StateError('No authenticated Apps session.');
      return api.loadAppConfigReview(app);
    });

final class AppsState {
  const AppsState({
    this.busy = false,
    this.result,
    this.target,
    this.server,
    this.connectionCurrent = true,
  });
  final bool busy;
  final AppOperationResult? result;
  final String? target, server;
  final bool connectionCurrent;
  bool get pending =>
      result?.outcome == AppOperationOutcome.submitted ||
      result?.outcome == AppOperationOutcome.running;
  bool get unknown => result?.outcome == AppOperationOutcome.unknown;
  bool get locked => busy || pending || unknown;
}

final appsControllerProvider = NotifierProvider<AppsController, AppsState>(
  AppsController.new,
);

/// The route does not own a job. Its own read-only job ID remains tracked after
/// navigation; uncertain outcomes never cause an automatic mutation replay.
class AppsController extends Notifier<AppsState> {
  AuthenticatedSession? _session;
  ServerOperationLock? _lock;
  Object? _owner;
  Timer? _timer;
  int _generation = 0;
  int _automaticPolls = 0;

  @override
  AppsState build() {
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (identical(_session, next)) return;
      _generation++;
      _timer?.cancel();
      _release();
      // Do not reveal an earlier account's app names on another connection.
      state = state.locked
          ? const AppsState(
              connectionCurrent: false,
              result: AppOperationResult(outcome: AppOperationOutcome.unknown),
            )
          : const AppsState();
    });
    ref.onDispose(() {
      _generation++;
      _timer?.cancel();
      _release();
    });
    return const AppsState();
  }

  Future<void> install(
    AuthenticatedSession session,
    AppInstallRequest request,
  ) => _perform(session, request.appName, (api) => api.installApp(request));
  Future<void> upgrade(
    AuthenticatedSession session,
    AppUpgradeRequest request,
  ) => _perform(session, request.app.name, (api) => api.upgradeApp(request));
  Future<void> updateConfiguration(
    AuthenticatedSession session,
    AppConfigUpdateRequest request,
  ) => _perform(
    session,
    request.review.app.name,
    (api) => api.updateApp(request),
  );
  Future<void> uninstall(
    AuthenticatedSession session,
    AppUninstallRequest request,
  ) => _perform(session, request.app.name, (api) => api.uninstallApp(request));
  Future<void> changeState(
    AuthenticatedSession session,
    InstalledApp app,
    AppLifecycleAction action,
  ) => _perform(session, app.name, (api) => api.changeAppState(app, action));
  Future<void> pullImages(
    AuthenticatedSession session,
    AppImagePullRequest request,
  ) => _perform(session, request.app.name, (api) => api.pullAppImages(request));
  Future<void> rollback(
    AuthenticatedSession session,
    AppRollbackRequest request,
  ) => _perform(session, request.app.name, (api) => api.rollbackApp(request));

  Future<void> updatePreferredTrains(
    AuthenticatedSession session,
    CatalogOverview overview,
    List<String> desired,
  ) async {
    await _perform(
      session,
      'catalog preferences',
      (api) => (api as AuthenticatedCatalogOverviewSession)
          .updateCatalogPreferredTrains(overview, desired),
    );
    if (state.result?.outcome == AppOperationOutcome.verified) {
      ref.invalidate(catalogOverviewProvider);
      ref.invalidate(appsCatalogProvider(false));
      ref.invalidate(appsCatalogProvider(true));
    }
  }

  Future<void> syncCatalog(
    AuthenticatedSession session,
    CatalogOverview overview,
  ) => _perform(
    session,
    'catalog sync',
    (api) => (api as AuthenticatedCatalogOverviewSession).syncCatalog(overview),
  );

  Future<void> _perform(
    AuthenticatedSession session,
    String target,
    Future<AppOperationResult> Function(AuthenticatedAppsSession) operation,
  ) async {
    if (state.locked ||
        session.endpoint == null ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    final repository = session.repository;
    if (repository is! AuthenticatedAppsSession) return;
    _lock = ref.read(serverOperationLockProvider);
    _owner = _lock!.acquire();
    if (_owner == null) {
      state = const AppsState(
        result: AppOperationResult(outcome: AppOperationOutcome.rejected),
      );
      return;
    }
    final generation = ++_generation;
    _session = session;
    _automaticPolls = 0;
    state = AppsState(busy: true, target: target, server: session.endpoint);
    AppOperationResult result;
    try {
      result = await operation(repository as AuthenticatedAppsSession);
    } on AppsException {
      result = const AppOperationResult(outcome: AppOperationOutcome.rejected);
    } on Object {
      // The gateway returns known rejections. An unexpected exception may have
      // followed dispatch and cannot be assumed to mean nothing happened.
      result = const AppOperationResult(outcome: AppOperationOutcome.unknown);
    }
    if (!_current(generation)) return;
    _accept(result);
  }

  Future<void> checkJob() async {
    final session = _session;
    final job = state.result?.job;
    if (session == null ||
        job == null ||
        !state.pending ||
        state.busy ||
        !identical(session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    _timer?.cancel();
    final repository = session.repository;
    if (repository is! AuthenticatedAppsSession) return;
    final generation = _generation;
    state = AppsState(
      busy: true,
      result: state.result,
      server: state.server,
      target: state.target,
    );
    AppOperationResult result;
    try {
      result = await (repository as AuthenticatedAppsSession).pollAppJob(job);
    } on AppsException catch (error) {
      result = error.reason == AppsExceptionReason.busy
          ? state.result!
          : const AppOperationResult(outcome: AppOperationOutcome.unknown);
    } on Object {
      result = const AppOperationResult(outcome: AppOperationOutcome.unknown);
    }
    if (_current(generation)) _accept(result);
  }

  void _accept(AppOperationResult result) {
    state = AppsState(
      result: result,
      server: state.server,
      target: state.target,
    );
    if (state.pending) {
      // Bounded background reads only. After two minutes keep the job/lock and
      // expose manual Check progress; never infer completion from elapsed time.
      if (_automaticPolls++ < 60) {
        _timer = Timer(const Duration(seconds: 2), checkJob);
      }
    } else {
      _timer?.cancel();
      if (!state.unknown) _release();
      ref.invalidate(appsInventoryProvider);
      if (state.target == 'catalog sync' &&
          (result.outcome == AppOperationOutcome.verified ||
              result.outcome == AppOperationOutcome.failed)) {
        ref.invalidate(catalogOverviewProvider);
        ref.invalidate(appsCatalogProvider(false));
        ref.invalidate(appsCatalogProvider(true));
      }
    }
  }

  bool _current(int generation) =>
      ref.mounted &&
      generation == _generation &&
      identical(_session, ref.read(dashboardActiveSessionProvider));

  void acknowledgeAfterReconnect() {
    final current = ref.read(dashboardActiveSessionProvider);
    if (state.unknown &&
        !state.connectionCurrent &&
        current?.endpoint != null &&
        !identical(_session, current)) {
      _release();
      _session = null;
      state = const AppsState();
    }
  }

  void _release() {
    if (_owner != null) _lock?.release(_owner!);
    _owner = null;
  }
}
