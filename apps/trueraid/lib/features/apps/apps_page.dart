import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'app_install_page.dart';
import 'app_config_page.dart';
import 'apps_controller.dart';
import 'apps_status_chart.dart';

class AppsPage extends ConsumerStatefulWidget {
  const AppsPage({super.key});
  @override
  ConsumerState<AppsPage> createState() => _AppsPageState();
}

class _AppsPageState extends ConsumerState<AppsPage> {
  bool _catalog = false;
  bool _cachedOnly = false;
  String _search = '';
  String? _train;
  String? _category;
  bool _recommendedOnly = false;
  InstalledApp? _expandedInstalledApp;
  InstalledApp? _expandedImageApp;
  AuthenticatedSession? _detailsSession;
  CatalogOverview? _preferredSource;
  List<String>? _preferredDraft;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    if (!identical(_detailsSession, session)) {
      _detailsSession = session;
      _expandedInstalledApp = null;
      _expandedImageApp = null;
    }
    final capability = ref.watch(appsSessionProvider)?.appsCapabilities;
    final operation = ref.watch(appsControllerProvider);
    final td = context.tdTheme;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Applications'),
        actions: [
          IconButton(
            key: const Key('apps-refresh'),
            tooltip: 'Refresh applications',
            onPressed: operation.locked
                ? null
                : () {
                    ref.invalidate(appsInventoryProvider);
                    if (_catalog) {
                      ref.invalidate(appsCatalogProvider(_cachedOnly));
                      ref.invalidate(catalogOverviewProvider);
                    }
                  },
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1180),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                Text(
                  'APPLICATION WORKSPACE',
                  style: TdTypography.micro.copyWith(
                    color: td.actionPrimary,
                    letterSpacing: 1.1,
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Your services, in one place',
                  style: TdTypography.titleLarge,
                ),
                const SizedBox(height: 8),
                Text(
                  session?.endpoint ?? 'No authenticated server',
                  style: TdTypography.metadata,
                ),
                const SizedBox(height: 20),
                const AppsOperationBanner(),
                if (capability?.supported != true || session?.endpoint == null)
                  TdPanel(
                    title: 'Applications unavailable',
                    child: Text(
                      capability?.blockedReason ??
                          'Connect to a supported TrueNAS server.',
                    ),
                  )
                else ...[
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      ChoiceChip(
                        key: const Key('apps-installed-tab'),
                        label: const Text('Installed'),
                        selected: !_catalog,
                        onSelected: (_) => setState(() {
                          _catalog = false;
                          _search = '';
                        }),
                      ),
                      ChoiceChip(
                        key: const Key('apps-catalog-tab'),
                        label: const Text('Discover apps'),
                        selected: _catalog,
                        onSelected: (_) => setState(() {
                          _catalog = true;
                          _search = '';
                        }),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  TextField(
                    key: ValueKey('apps-search-$_catalog'),
                    decoration: InputDecoration(
                      labelText: _catalog
                          ? 'Search catalog'
                          : 'Search installed apps',
                      prefixIcon: const Icon(Icons.search_rounded),
                    ),
                    onChanged: (text) =>
                        setState(() => _search = text.trim().toLowerCase()),
                  ),
                  const SizedBox(height: 20),
                  if (_catalog) ...[
                    SwitchListTile.adaptive(
                      key: const Key('apps-cached-catalog-only'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text('Server-cached list only'),
                      subtitle: const Text(
                        'Requires this server connection. Only the catalogue list is read from its existing cache; version details and installation are unavailable in this mode.',
                      ),
                      value: _cachedOnly,
                      onChanged: (value) {
                        ref.invalidate(appsCatalogProvider(value));
                        setState(() {
                          _cachedOnly = value;
                          _train = null;
                          _category = null;
                        });
                      },
                    ),
                    _catalogView(session!),
                  ] else
                    _installedView(session!),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _installedView(AuthenticatedSession session) => ref
      .watch(appsInventoryProvider)
      .when(
        skipLoadingOnRefresh: false,
        loading: () => const LinearProgressIndicator(),
        error: (_, _) => _retry(
          'Application inventory unavailable',
          () => ref.invalidate(appsInventoryProvider),
        ),
        data: (inventory) {
          final visible = inventory.apps
              .where((app) => app.name.toLowerCase().contains(_search))
              .toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 12,
                runSpacing: 8,
                children: [
                  TdStatusBadge(
                    status: inventory.ready
                        ? TdStatus.success
                        : TdStatus.warning,
                    label: 'Docker · ${inventory.dockerStatus}',
                  ),
                  Text(
                    'Applications pool · ${inventory.pool ?? 'Not configured'}',
                  ),
                ],
              ),
              if (inventory.blockedReason != null)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(inventory.blockedReason!),
                ),
              const SizedBox(height: 16),
              AppsStatusChart(
                states: inventory.apps.map((app) => app.state).toList(),
              ),
              const SizedBox(height: 20),
              if (inventory.apps.isEmpty)
                TdPanel(
                  title: 'No applications installed',
                  child: FilledButton.icon(
                    onPressed: () => setState(() => _catalog = true),
                    icon: const Icon(Icons.explore_outlined),
                    label: const Text('Explore catalog'),
                  ),
                )
              else if (visible.isEmpty)
                const Text('No installed applications match this search.'),
              for (final app in visible)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _installedCard(session, inventory, app),
                ),
            ],
          );
        },
      );

  Widget _installedCard(
    AuthenticatedSession session,
    AppsInventory inventory,
    InstalledApp app,
  ) {
    final locked = ref.watch(appsControllerProvider).locked || !inventory.ready;
    bool allowed(String method) =>
        session.availableMethodNames.contains(method);
    final canStart = app.state == 'STOPPED' && allowed('app.start');
    final canStop = app.state == 'RUNNING' && allowed('app.stop');
    return TdPanel(
      title: app.name,
      description:
          '${app.customApp ? 'Custom application' : app.catalogApp ?? 'Catalog application'} · ${app.version}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TdStatusBadge(
            status: app.state == 'RUNNING'
                ? TdStatus.success
                : app.state == 'STOPPED'
                ? TdStatus.neutral
                : TdStatus.warning,
            label: app.state,
          ),
          if (app.upgradeAvailable || app.imageUpdatesAvailable) ...[
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                if (app.upgradeAvailable)
                  TdStatusBadge(
                    status: TdStatus.warning,
                    label: app.latestVersion == null
                        ? 'App update available'
                        : 'App update: ${app.latestVersion}',
                  ),
                if (app.imageUpdatesAvailable)
                  const TdStatusBadge(
                    status: TdStatus.warning,
                    label: 'Container image update available',
                  ),
              ],
            ),
          ],
          if (app.imageUpdatesAvailable &&
              allowed('app.outdated_docker_images')) ...[
            const SizedBox(height: 8),
            TextButton.icon(
              key: ValueKey('app-outdated-images-${app.name}'),
              onPressed: () => setState(() {
                _expandedImageApp = identical(_expandedImageApp, app)
                    ? null
                    : app;
              }),
              icon: Icon(
                identical(_expandedImageApp, app)
                    ? Icons.expand_less
                    : Icons.expand_more,
              ),
              label: Text(
                identical(_expandedImageApp, app)
                    ? 'Hide outdated images'
                    : 'Check outdated images',
              ),
            ),
            if (identical(_expandedImageApp, app))
              ref
                  .watch(outdatedAppImagesProvider((session, app)))
                  .when(
                    skipLoadingOnRefresh: false,
                    loading: () => const LinearProgressIndicator(),
                    error: (_, _) => OutlinedButton(
                      key: ValueKey('app-outdated-images-retry-${app.name}'),
                      onPressed: () => ref.invalidate(
                        outdatedAppImagesProvider((session, app)),
                      ),
                      child: const Text('Retry image check'),
                    ),
                    data: (images) => Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (images.isEmpty)
                          const Text('No outdated images currently reported.'),
                        for (final name in images) SelectableText(name),
                      ],
                    ),
                  ),
          ],
          const SizedBox(height: 8),
          TextButton.icon(
            key: ValueKey('app-details-${app.name}'),
            onPressed: () => setState(() {
              _expandedInstalledApp = identical(_expandedInstalledApp, app)
                  ? null
                  : app;
            }),
            icon: Icon(
              identical(_expandedInstalledApp, app)
                  ? Icons.expand_less
                  : Icons.expand_more,
            ),
            label: Text(
              identical(_expandedInstalledApp, app)
                  ? 'Hide app details'
                  : 'Show app details',
            ),
          ),
          if (identical(_expandedInstalledApp, app))
            ref
                .watch(installedAppDetailsProvider((session, app)))
                .when(
                  skipLoadingOnRefresh: false,
                  loading: () => const LinearProgressIndicator(),
                  error: (_, _) => OutlinedButton(
                    key: ValueKey('app-details-retry-${app.name}'),
                    onPressed: () => ref.invalidate(
                      installedAppDetailsProvider((session, app)),
                    ),
                    child: const Text('Retry details read'),
                  ),
                  data: (details) => Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text('Active workloads'),
                      Wrap(
                        spacing: 12,
                        runSpacing: 4,
                        children: [
                          Text(
                            'Running containers: ${details.workloads.runningContainers}',
                          ),
                          Text(
                            'Port mappings: ${details.workloads.portMappings}',
                          ),
                          Text('Volumes: ${details.workloads.volumes}'),
                          Text('Images: ${details.workloads.images}'),
                        ],
                      ),
                      const SizedBox(height: 8),
                      const Text('Server-provided notes'),
                      SelectableText(
                        details.notes?.isNotEmpty == true
                            ? details.notes!
                            : 'No notes',
                      ),
                      const SizedBox(height: 8),
                      const Text(
                        'Portals · copy an address to open it yourself',
                      ),
                      if (details.portals.isEmpty) const Text('No portals'),
                      for (final entry in details.portals.entries) ...[
                        Text(entry.key),
                        SelectableText(entry.value),
                      ],
                    ],
                  ),
                ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              OutlinedButton.icon(
                key: ValueKey('app-edit-${app.name}'),
                onPressed: !locked && !app.customApp && allowed('app.config')
                    ? () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) =>
                              AppConfigPage(session: session, app: app),
                        ),
                      )
                    : null,
                icon: const Icon(Icons.tune_rounded),
                label: const Text('Settings'),
              ),
              OutlinedButton.icon(
                key: ValueKey('app-start-${app.name}'),
                onPressed: !locked && canStart
                    ? () => _lifecycle(session, app, AppLifecycleAction.start)
                    : null,
                icon: const Icon(Icons.play_arrow_rounded),
                label: const Text('Start'),
              ),
              OutlinedButton.icon(
                key: ValueKey('app-stop-${app.name}'),
                onPressed: !locked && canStop
                    ? () => _lifecycle(session, app, AppLifecycleAction.stop)
                    : null,
                icon: const Icon(Icons.stop_rounded),
                label: const Text('Stop'),
              ),
              OutlinedButton.icon(
                key: ValueKey('app-redeploy-${app.name}'),
                onPressed:
                    !locked && app.state == 'RUNNING' && allowed('app.redeploy')
                    ? () =>
                          _lifecycle(session, app, AppLifecycleAction.redeploy)
                    : null,
                icon: const Icon(Icons.restart_alt),
                label: const Text('Redeploy'),
              ),
              OutlinedButton.icon(
                key: ValueKey('app-upgrade-${app.name}'),
                onPressed:
                    !locked &&
                        !app.customApp &&
                        app.upgradeAvailable &&
                        allowed('app.upgrade') &&
                        allowed('app.upgrade_summary')
                    ? () => _upgrade(session, app)
                    : null,
                icon: const Icon(Icons.system_update_alt),
                label: const Text('Upgrade'),
              ),
              OutlinedButton.icon(
                key: ValueKey('app-uninstall-${app.name}'),
                onPressed: !locked && allowed('app.delete')
                    ? () => _uninstall(session, app)
                    : null,
                icon: const Icon(Icons.delete_outline),
                label: const Text('Uninstall'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _catalogView(AuthenticatedSession session) => ref
      .watch(appsCatalogProvider(_cachedOnly))
      .when(
        skipLoadingOnRefresh: false,
        loading: () => const LinearProgressIndicator(),
        error: (_, _) => _retry(
          'Catalog unavailable',
          () => ref.invalidate(appsCatalogProvider(_cachedOnly)),
        ),
        data: (catalog) {
          final overviewAvailable =
              session.repository is AuthenticatedCatalogOverviewSession &&
              session.availableMethodNames.containsAll({
                'catalog.trains',
                'catalog.config',
              });
          final overview = overviewAvailable
              ? ref.watch(catalogOverviewProvider).asData?.value
              : null;
          if (!identical(_preferredSource, overview)) {
            _preferredSource = overview;
            _preferredDraft = overview == null
                ? null
                : List<String>.of(overview.preferredTrains);
          }
          final trains = {
            ...catalog.map((app) => app.train),
            ...?overview?.availableTrains,
          }.toList()..sort();
          final selectedTrain = trains.contains(_train) ? _train : null;
          final categories =
              catalog
                  .where(
                    (app) =>
                        selectedTrain == null || app.train == selectedTrain,
                  )
                  .expand((app) => app.categories)
                  .toSet()
                  .toList()
                ..sort();
          final selectedCategory = categories.contains(_category)
              ? _category
              : null;
          final visible = catalog
              .where(
                (app) =>
                    (selectedTrain == null || selectedTrain == app.train) &&
                    (selectedCategory == null ||
                        app.categories.contains(selectedCategory)) &&
                    (!_recommendedOnly || app.recommended) &&
                    '${app.title} ${app.name} ${app.description} ${app.categories.join(' ')} ${app.tags.join(' ')}'
                        .toLowerCase()
                        .contains(_search),
              )
              .toList();
          final unavailablePreferred =
              _preferredDraft
                  ?.where((train) => !overview!.availableTrains.contains(train))
                  .toList() ??
              const <String>[];
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (overviewAvailable) ...[
                ref
                    .watch(catalogOverviewProvider)
                    .when(
                      skipLoadingOnRefresh: false,
                      loading: () => const LinearProgressIndicator(),
                      error: (_, _) => const Text(
                        'Catalog train settings could not be read. The application list remains available.',
                      ),
                      data: (value) => Text(
                        'Server trains: ${value.availableTrains.isEmpty ? 'none' : value.availableTrains.join(', ')} · Preferred: ${value.preferredTrains.isEmpty ? 'none' : value.preferredTrains.join(', ')}',
                        key: const Key('catalog-train-overview'),
                      ),
                    ),
                const SizedBox(height: 12),
              ],
              if (overview != null &&
                  session.availableMethodNames.contains('catalog.sync')) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const Key('catalog-sync'),
                    onPressed:
                        _cachedOnly || ref.watch(appsControllerProvider).locked
                        ? null
                        : () => _syncCatalog(session, overview),
                    icon: const Icon(Icons.sync_rounded),
                    label: const Text('Sync catalog from upstream'),
                  ),
                ),
                if (_cachedOnly)
                  const Text('Catalog sync requires normal browsing mode.'),
                const SizedBox(height: 12),
              ],
              if (overview != null &&
                  session.availableMethodNames.contains('catalog.update')) ...[
                const Text('Preferred catalog trains'),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final train in {
                      ...overview.availableTrains,
                      ...overview.preferredTrains,
                    })
                      FilterChip(
                        key: ValueKey('catalog-preference-$train'),
                        label: Text(
                          overview.availableTrains.contains(train)
                              ? train
                              : '$train · unavailable',
                        ),
                        selected: _preferredDraft?.contains(train) ?? false,
                        onSelected:
                            ref.watch(appsControllerProvider).locked ||
                                (!overview.availableTrains.contains(train) &&
                                    !(_preferredDraft?.contains(train) ??
                                        false))
                            ? null
                            : (selected) => setState(() {
                                final next = List<String>.of(_preferredDraft!);
                                if (selected) {
                                  next.add(train);
                                } else {
                                  next.remove(train);
                                }
                                _preferredDraft = next;
                              }),
                      ),
                  ],
                ),
                if (unavailablePreferred.isNotEmpty)
                  const Text(
                    'Remove unavailable preferred trains before saving.',
                  ),
                const SizedBox(height: 8),
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton.icon(
                    key: const Key('catalog-preferences-save'),
                    onPressed:
                        ref.watch(appsControllerProvider).locked ||
                            unavailablePreferred.isNotEmpty ||
                            _sameTrainList(
                              _preferredDraft!,
                              overview.preferredTrains,
                            )
                        ? null
                        : () => _savePreferredTrains(
                            session,
                            overview,
                            List<String>.of(_preferredDraft!),
                          ),
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('Save server preference'),
                  ),
                ),
                const SizedBox(height: 16),
              ],
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    key: const Key('apps-train-all'),
                    label: const Text('All trains'),
                    selected: selectedTrain == null,
                    onSelected: (_) => setState(() {
                      _train = null;
                      _category = null;
                    }),
                  ),
                  for (final train in trains)
                    ChoiceChip(
                      key: ValueKey('apps-train-$train'),
                      label: Text(
                        overview?.preferredTrains.contains(train) == true
                            ? '$train · preferred'
                            : train,
                      ),
                      selected: selectedTrain == train,
                      onSelected: (_) => setState(() {
                        _train = train;
                        _category = null;
                      }),
                    ),
                ],
              ),
              if (categories.isNotEmpty) ...[
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    ChoiceChip(
                      key: const Key('apps-category-all'),
                      label: const Text('All categories'),
                      selected: selectedCategory == null,
                      onSelected: (_) => setState(() => _category = null),
                    ),
                    for (final category in categories)
                      ChoiceChip(
                        key: ValueKey('apps-category-$category'),
                        label: Text(category),
                        selected: selectedCategory == category,
                        onSelected: (_) => setState(() => _category = category),
                      ),
                  ],
                ),
              ],
              const SizedBox(height: 12),
              Align(
                alignment: Alignment.centerLeft,
                child: FilterChip(
                  key: const Key('apps-recommended-only'),
                  label: const Text('Recommended only'),
                  selected: _recommendedOnly,
                  onSelected: (value) =>
                      setState(() => _recommendedOnly = value),
                ),
              ),
              const SizedBox(height: 12),
              Text('${visible.length} catalog applications'),
              const SizedBox(height: 16),
              if (visible.isEmpty)
                const Text('No catalog applications match these filters.'),
              LayoutBuilder(
                builder: (context, constraints) {
                  final columns =
                      constraints.maxWidth >= 720 &&
                          MediaQuery.textScalerOf(context).scale(16) <= 24
                      ? 2
                      : 1;
                  final width =
                      (constraints.maxWidth - (columns - 1) * 12) / columns;
                  return Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final app in visible)
                        SizedBox(
                          width: width,
                          child: TdPanel(
                            title: app.title,
                            description: '${app.train} · ${app.name}',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  app.description,
                                  maxLines: 4,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                if (app.categories.isNotEmpty)
                                  Text(
                                    'Categories: ${app.categories.join(', ')}',
                                  ),
                                if (app.tags.isNotEmpty)
                                  Text('Tags: ${app.tags.join(', ')}'),
                                if (app.recommended)
                                  const Chip(label: Text('Recommended')),
                                const SizedBox(height: 12),
                                if (!app.healthy || !app.supported)
                                  const Text(
                                    'This catalog entry is not currently installable.',
                                  ),
                                if (_cachedOnly)
                                  const Text(
                                    'Switch off server-cached list only to inspect versions or install.',
                                  ),
                                FilledButton.tonalIcon(
                                  key: ValueKey(
                                    'catalog-open-${app.train}-${app.name}',
                                  ),
                                  onPressed:
                                      !_cachedOnly &&
                                          app.healthy &&
                                          app.supported &&
                                          session.availableMethodNames.contains(
                                            'app.create',
                                          ) &&
                                          !ref
                                              .watch(appsControllerProvider)
                                              .locked
                                      ? () => Navigator.of(context).push(
                                          MaterialPageRoute<void>(
                                            builder: (_) => AppInstallPage(
                                              session: session,
                                              app: app,
                                            ),
                                          ),
                                        )
                                      : null,
                                  icon: const Icon(Icons.add_box_outlined),
                                  label: const Text('Choose version & install'),
                                ),
                              ],
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            ],
          );
        },
      );

  Widget _retry(String title, VoidCallback retry) => TdPanel(
    title: title,
    child: OutlinedButton(onPressed: retry, child: const Text('Retry read')),
  );

  Future<void> _savePreferredTrains(
    AuthenticatedSession session,
    CatalogOverview overview,
    List<String> desired,
  ) async {
    final confirmed = await confirmAppOperation(
      context,
      title: 'Change catalog preferences',
      endpoint: session.endpoint!,
      target: 'catalog preferences',
      warning: 'This changes which catalog trains the server prefers. No automatic retry will be made.',
      reviewLines: [
        'Current: ${overview.preferredTrains.join(', ')}',
        'Requested: ${desired.join(', ')}',
      ],
      expectedSession: session,
    );
    if (confirmed && mounted) {
      await ref
          .read(appsControllerProvider.notifier)
          .updatePreferredTrains(session, overview, desired);
    }
  }

  Future<void> _syncCatalog(
    AuthenticatedSession session,
    CatalogOverview overview,
  ) async {
    final confirmed = await confirmAppOperation(
      context,
      title: 'Sync application catalog',
      endpoint: session.endpoint!,
      target: 'catalog sync',
      warning: 'The server will fetch upstream catalog changes. This can take time and may change available apps or trains. No automatic retry will be made.',
      expectedSession: session,
    );
    if (confirmed && mounted) {
      await ref
          .read(appsControllerProvider.notifier)
          .syncCatalog(session, overview);
    }
  }

  Future<void> _lifecycle(
    AuthenticatedSession session,
    InstalledApp app,
    AppLifecycleAction action,
  ) async {
    final confirmed = await confirmAppOperation(
      context,
      title:
          '${action.name == 'start'
              ? 'Start'
              : action.name == 'stop'
              ? 'Stop'
              : 'Redeploy'} application',
      endpoint: session.endpoint!,
      target: app.name,
      warning: action == AppLifecycleAction.start
          ? 'Start the application and its configured services.'
          : 'Connected users may be interrupted. No automatic retry will be made.',
    );
    if (confirmed && mounted) {
      await ref
          .read(appsControllerProvider.notifier)
          .changeState(session, app, action);
    }
  }

  Future<void> _uninstall(
    AuthenticatedSession session,
    InstalledApp app,
  ) async {
    final confirmed = await confirmAppOperation(
      context,
      title: 'Uninstall application',
      endpoint: session.endpoint!,
      target: app.name,
      warning:
          'This stops and removes the application. Docker-managed volumes may '
          'be deleted. TrueNAS ixVolumes and host-path data are not selected for deletion; '
          'images are retained. This is not a backup or a guarantee that every volume survives.',
    );
    if (confirmed && mounted) {
      await ref
          .read(appsControllerProvider.notifier)
          .uninstall(
            session,
            AppUninstallRequest(app: app, confirmedName: app.name),
          );
    }
  }

  Future<void> _upgrade(AuthenticatedSession session, InstalledApp app) async {
    try {
      ref.invalidate(appsCatalogProvider(false));
      final catalog = await ref.read(appsCatalogProvider(false).future);
      if (!mounted ||
          !identical(session, ref.read(dashboardActiveSessionProvider))) {
        return;
      }
      final matches = catalog.where(
        (entry) => entry.name == app.catalogApp && entry.train == app.train,
      );
      if (matches.length != 1) throw StateError('Catalog source unavailable.');
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) => AppInstallPage(
            session: session,
            app: matches.single,
            upgrading: app,
          ),
        ),
      );
    } on Object {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The installed catalog source could not be resolved. No change was sent.',
            ),
          ),
        );
      }
    }
  }
}

bool _sameTrainList(List<String> a, List<String> b) =>
    a.length == b.length &&
    List.generate(
      a.length,
      (index) => a[index] == b[index],
    ).every((same) => same);

class AppsOperationBanner extends ConsumerWidget {
  const AppsOperationBanner({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(appsControllerProvider);
    if (!state.busy && state.result == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TdPanel(
        title: state.unknown
            ? 'Outcome unknown'
            : state.busy || state.pending
            ? state.target == 'catalog sync'
                  ? 'Catalog sync in progress'
                  : state.target == 'catalog preferences'
                  ? 'Catalog settings update in progress'
                  : 'Application operation in progress'
            : state.target == 'catalog sync'
            ? 'Catalog sync result'
            : state.target == 'catalog preferences'
            ? 'Catalog settings result'
            : 'Application operation result',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.connectionCurrent && state.target != null)
              Text('${state.server}\n${state.target}'),
            if (state.result != null)
              Text(
                state.target == 'catalog sync'
                    ? switch (state.result!.outcome) {
                        AppOperationOutcome.submitted => 'The server accepted the sync job. Its result still needs verification.',
                        AppOperationOutcome.running =>
                          'The catalog sync job is still running.',
                        AppOperationOutcome.verified => 'The server completed the catalog sync job and fresh catalog settings were read.',
                        AppOperationOutcome.failed => 'The server reported that catalog sync failed or was aborted. Reload before another change.',
                        AppOperationOutcome.rejected => 'The catalog changed before sync could start. Reload and review again.',
                        AppOperationOutcome.unknown => 'The sync outcome could not be confirmed. Do not repeat it; inspect TrueNAS and reconnect.',
                      }
                    : state.result!.userMessage,
              ),
            if (state.busy || state.pending) ...[
              const SizedBox(height: 12),
              LinearProgressIndicator(
                value: state.result?.progressPercent == null
                    ? null
                    : state.result!.progressPercent! / 100,
              ),
              const SizedBox(height: 8),
              if (state.result?.job != null)
                Text(
                  'Job ${state.result!.job!.id} · '
                  '${state.result?.progressPercent?.toStringAsFixed(0) ?? '—'}%',
                ),
              TextButton(
                key: const Key('apps-check-job'),
                onPressed: state.busy
                    ? null
                    : () =>
                          ref.read(appsControllerProvider.notifier).checkJob(),
                child: const Text('Check progress'),
              ),
            ],
            if (state.unknown) ...[
              const Text(
                'No action was replayed. Inspect the original server before any retry.',
              ),
              if (!state.connectionCurrent)
                TextButton(
                  key: const Key('apps-acknowledge-unknown'),
                  onPressed: () => ref
                      .read(appsControllerProvider.notifier)
                      .acknowledgeAfterReconnect(),
                  child: const Text(
                    'I inspected the outcome after reconnecting',
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}

Future<bool> confirmAppOperation(
  BuildContext context, {
  required String title,
  required String endpoint,
  required String target,
  required String warning,
  List<String> reviewLines = const [],
  AuthenticatedSession? expectedSession,
}) async {
  var entered = '';
  return await showDialog<bool>(
        context: context,
        builder: (context) => Consumer(
          builder: (context, ref, child) {
            if (expectedSession != null &&
                !identical(
                  expectedSession,
                  ref.watch(dashboardActiveSessionProvider),
                )) {
              return AlertDialog(
                title: const Text('Connection changed'),
                content: const Text(
                  'The previous review has been hidden. Reopen settings for the current authenticated server.',
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Close review'),
                  ),
                ],
              );
            }
            return StatefulBuilder(
              builder: (context, setState) => AlertDialog(
                title: Text(title),
                content: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(endpoint),
                      const SizedBox(height: 8),
                      Text(warning),
                      if (reviewLines.isNotEmpty) ...[
                        const SizedBox(height: 16),
                        const Text(
                          'Settings to apply',
                          style: TdTypography.titleMedium,
                        ),
                        for (final line in reviewLines)
                          Padding(
                            padding: const EdgeInsets.only(top: 6),
                            child: Text(line),
                          ),
                      ],
                      const SizedBox(height: 16),
                      TextField(
                        key: const Key('app-confirm-name'),
                        decoration: InputDecoration(
                          labelText: 'Type $target exactly',
                        ),
                        onChanged: (value) => setState(() => entered = value),
                      ),
                    ],
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('app-confirm-submit'),
                    onPressed: entered == target
                        ? () => Navigator.pop(context, true)
                        : null,
                    child: const Text('Confirm'),
                  ),
                ],
              ),
            );
          },
        ),
      ) ??
      false;
}
