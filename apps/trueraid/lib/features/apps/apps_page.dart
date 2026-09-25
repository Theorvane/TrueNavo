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
  String _search = '';
  String? _train;

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
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
                    if (_catalog) ref.invalidate(appsCatalogProvider);
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
                  if (_catalog)
                    _catalogView(session!)
                  else
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
      .watch(appsCatalogProvider)
      .when(
        loading: () => const LinearProgressIndicator(),
        error: (_, _) => _retry(
          'Catalog unavailable',
          () => ref.invalidate(appsCatalogProvider),
        ),
        data: (catalog) {
          final trains = catalog.map((app) => app.train).toSet().toList()
            ..sort();
          final visible = catalog
              .where(
                (app) =>
                    (_train == null || _train == app.train) &&
                    '${app.title} ${app.name} ${app.description}'
                        .toLowerCase()
                        .contains(_search),
              )
              .toList();
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ChoiceChip(
                    label: const Text('All trains'),
                    selected: _train == null,
                    onSelected: (_) => setState(() => _train = null),
                  ),
                  for (final train in trains)
                    ChoiceChip(
                      label: Text(train),
                      selected: _train == train,
                      onSelected: (_) => setState(() => _train = train),
                    ),
                ],
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
                                const SizedBox(height: 12),
                                if (!app.healthy || !app.supported)
                                  const Text(
                                    'This catalog entry is not currently installable.',
                                  ),
                                FilledButton.tonalIcon(
                                  key: ValueKey(
                                    'catalog-open-${app.train}-${app.name}',
                                  ),
                                  onPressed:
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
      final catalog = await ref.read(appsCatalogProvider.future);
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
            ? 'Application operation in progress'
            : 'Application operation result',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (state.connectionCurrent && state.target != null)
              Text('${state.server}\n${state.target}'),
            if (state.result != null) Text(state.result!.userMessage),
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
