import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../alerts/alerts_page.dart';

import '../../app_shell/app_destination.dart';
import '../apps/apps_page.dart';
import '../management/management_page.dart';
import '../reporting/reporting_page.dart';
import '../snapshots/snapshots_page.dart';
import 'dashboard_charts.dart';
import 'dashboard_controller.dart';
import 'dashboard_layout.dart';
import 'dashboard_layout_controller.dart';
import 'dashboard_layout_editor.dart';
import 'dashboard_repository.dart';
import 'live_metrics.dart';

class DashboardPage extends ConsumerWidget {
  const DashboardPage({required this.destination, super.key});
  final AppDestination destination;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (destination == AppDestination.alerts &&
        ref.watch(dashboardActiveSessionProvider)?.repository
            is AuthenticatedAlertsSession) {
      return const AlertsPage();
    }
    final key = destination.name;
    final load = ref.watch(dashboardLoadProvider(key));
    return load.when(
      loading: () => const TdStateView(
        kind: TdStateKind.loading,
        title: 'Loading current server state',
        description: 'Reading available, read-only server information.',
      ),
      error: (_, _) => _failure(ref, key),
      data: (result) => switch (result) {
        DashboardUnavailable() => const TdStateView(
          kind: TdStateKind.empty,
          title: 'This view is unavailable on this server',
          description: 'The connected server does not provide the required read-only API.',
        ),
        DashboardNoConnection() => const TdStateView(
          kind: TdStateKind.empty,
          title: 'No live server connection',
          description:
              'Connect to the selected server to view live, read-only data.',
        ),
        DashboardFailure() => _failure(ref, key),
        DashboardData(:final value) => _data(context, value, ref, key),
      },
    );
  }

  Widget _failure(WidgetRef ref, String key) => TdStateView(
    kind: TdStateKind.error,
    title: 'Unable to load current server state',
    description: 'Check the connection and try the read-only refresh again.',
    actionLabel: 'Refresh',
    onAction: () => ref.invalidate(dashboardLoadProvider(key)),
  );

  Widget _data(
    BuildContext context,
    Object? value,
    WidgetRef ref,
    String key,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (value is DashboardHome) _home(context, value, ref, key),
      if (value is List<DashboardAlert>) _alerts(value, ref, key),
      if (value is DashboardStorage) _storage(context, value, ref, key),
      if (value is DashboardWorkloads) _workloads(context, value, ref, key),
      if (value is DashboardJobs) _jobs(value, ref, key),
    ],
  );

  Widget _home(
    BuildContext context,
    DashboardHome home,
    WidgetRef ref,
    String key,
  ) {
    final td = context.tdTheme;
    final statusColor = _statusColor(context, home.health.status);
    final identity = ref.watch(dashboardLayoutIdentityProvider);
    final preferences = identity == null
        ? null
        : ref.watch(dashboardLayoutControllerProvider(identity));
    final layout = preferences?.layout ?? DashboardLayout.defaults();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Semantics(
                header: true,
                label: '${home.serverName}, ${home.version}',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'SYSTEM OVERVIEW',
                      style: TdTypography.micro.copyWith(
                        color: td.actionPrimary,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const SizedBox(height: TdSpacing.inline),
                    Text(home.serverName, style: TdTypography.titleLarge),
                    const SizedBox(height: TdSpacing.inlineTight),
                    Text(
                      home.version,
                      style: TdTypography.metadata.copyWith(
                        color: td.textSecondary,
                      ),
                    ),
                    if (home.edition case final edition?) ...[
                      const SizedBox(height: TdSpacing.inlineTight),
                      Text(
                        edition == DashboardEdition.community
                            ? 'Community Edition'
                            : 'Enterprise',
                        style: TdTypography.metadata,
                      ),
                    ],
                  ],
                ),
              ),
            ),
            const SizedBox(width: TdSpacing.related),
            _refresh(ref, key),
          ],
        ),
        const SizedBox(height: TdSpacing.component),
        Container(
          width: double.infinity,
          decoration: BoxDecoration(
            color: statusColor.withValues(alpha: .09),
            borderRadius: BorderRadius.circular(TdRadius.card),
            border: Border.all(color: statusColor.withValues(alpha: .32)),
          ),
          padding: const EdgeInsets.all(TdSpacing.component),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: statusColor.withValues(alpha: .14),
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  _healthIcon(home.health.status),
                  color: statusColor,
                  size: 22,
                ),
              ),
              const SizedBox(width: TdSpacing.related),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Server health',
                      style: TdTypography.metadata.copyWith(
                        color: td.textSecondary,
                      ),
                    ),
                    const SizedBox(height: TdSpacing.inlineTight),
                    TdStatusBadge(
                      status: _status(home.health.status),
                      label: home.health.summary,
                    ),
                    const SizedBox(height: TdSpacing.inline),
                    Text(
                      _healthDetail(home),
                      style: TdTypography.metadata.copyWith(
                        color: td.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        if (home.system case final system?) ...[
          const SizedBox(height: TdSpacing.component),
          Card(
            key: const Key('dashboard-system-facts'),
            child: Padding(
              padding: const EdgeInsets.all(TdSpacing.component),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('System details', style: TdTypography.titleMedium),
                  const SizedBox(height: TdSpacing.inline),
                  Wrap(
                    spacing: TdSpacing.component,
                    runSpacing: TdSpacing.inline,
                    children: [
                      if (system.uptimeSeconds case final seconds?)
                        _systemDetail('Uptime', _uptimeLabel(seconds)),
                      if (system.cpuModel case final model?)
                        _systemDetail('CPU', model),
                      if (system.logicalCores case final cores?)
                        _systemDetail('Logical cores', cores.toString()),
                      if (system.physicalCores case final cores?)
                        _systemDetail('Physical cores', cores.toString()),
                      if (system.memoryBytes case final bytes?)
                        _systemDetail('Installed memory', _memoryLabel(bytes)),
                      if (system.manufacturer case final manufacturer?)
                        _systemDetail('Manufacturer', manufacturer),
                      if (system.product case final product?)
                        _systemDetail('Product', product),
                      if (system.eccMemory case final ecc?)
                        _systemDetail('ECC memory', ecc ? 'Yes' : 'No'),
                    ],
                  ),
                  if (system.loadAverage case final averages?) ...[
                    const SizedBox(height: TdSpacing.component),
                    const Divider(),
                    const SizedBox(height: TdSpacing.inline),
                    _loadAverageChart(averages),
                    Align(
                      alignment: AlignmentDirectional.centerEnd,
                      child: TextButton.icon(
                        key: const Key('dashboard-load-history'),
                        onPressed: () => Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) =>
                                const ReportingPage(initialGraphName: 'load'),
                          ),
                        ),
                        icon: const Icon(Icons.show_chart),
                        label: const Text('View load history'),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
        const SizedBox(height: TdSpacing.inline),
        Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton.icon(
            key: const Key('dashboard-customize'),
            onPressed:
                identity == null || preferences!.loading || preferences.saving
                ? null
                : () => showDialog<void>(
                    context: context,
                    builder: (_) => DashboardLayoutEditor(
                      identity: identity,
                      serverName: home.serverName,
                      initial: layout,
                    ),
                  ),
            icon: const Icon(Icons.dashboard_customize_outlined),
            label: Text(
              preferences?.loading == true ? 'Loading layout…' : 'Customize',
            ),
          ),
        ),
        if (preferences?.message != null)
          Padding(
            padding: const EdgeInsets.only(bottom: TdSpacing.related),
            child: Text(preferences!.message!, style: TdTypography.metadata),
          ),
        if (preferences?.loading != true && layout.visible.isEmpty)
          const TdPanel(
            title: 'Your dashboard, your way',
            description: 'All optional sections are hidden. Use Customize to restore graphs and metrics.',
            child: SizedBox.shrink(),
          ),
        // Wait for persisted visibility before mounting optional widgets. In
        // particular, a hidden live section must not briefly subscribe while
        // its saved layout is still being read.
        for (final section
            in preferences?.loading == true
                ? const <DashboardSection>[]
                : layout.visible)
          Padding(
            key: ValueKey('dashboard-section-${section.name}'),
            padding: const EdgeInsets.only(top: TdSpacing.component),
            child: switch (section) {
              DashboardSection.metrics => _metrics(context, home),
              DashboardSection.charts => DashboardCharts(home: home),
              DashboardSection.liveMetrics => const DashboardLiveMetrics(),
              DashboardSection.performanceHistory => TdPanel(
                title: 'Performance history',
                description: 'CPU, memory, network and disk metrics reported by your server.',
                child: OutlinedButton.icon(
                  key: const Key('dashboard-performance-graphs'),
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ReportingPage(),
                    ),
                  ),
                  icon: const Icon(Icons.insights_rounded),
                  label: const Text('Explore performance graphs'),
                ),
              ),
            },
          ),
      ],
    );
  }

  String _healthDetail(DashboardHome home) {
    if (!home.alertsAvailable) {
      return 'Alert severity is unavailable on this server.';
    }
    final count =
        (home.criticalAlertCount ?? 0) + (home.warningAlertCount ?? 0);
    return count == 0
        ? 'No primary alerts reported.'
        : '$count primary ${count == 1 ? 'alert' : 'alerts'} across all active alerts.';
  }

  Widget _metrics(BuildContext context, DashboardHome home) {
    final metrics = [
      (
        icon: Icons.storage_rounded,
        label: 'Pools shown',
        value: home.poolsAvailable ? '${home.pools.length}' : '—',
        note: home.poolsAvailable ? 'current pools' : 'unavailable',
      ),
      (
        icon: Icons.notifications_active_outlined,
        label: 'Active alerts',
        value: home.alertsAvailable ? '${home.activeAlertCount}' : '—',
        note: home.alertsAvailable ? 'reported now' : 'unavailable',
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final textScale = MediaQuery.textScalerOf(context).scale(14) / 14;
        final columns = constraints.maxWidth >= 280 * textScale ? 2 : 1;
        final width = columns == 2
            ? (constraints.maxWidth - TdSpacing.related) / 2
            : constraints.maxWidth;
        return Wrap(
          spacing: TdSpacing.related,
          runSpacing: TdSpacing.related,
          children: [
            for (final metric in metrics)
              SizedBox(
                width: width,
                child: _metricTile(
                  context,
                  icon: metric.icon,
                  label: metric.label,
                  value: metric.value,
                  note: metric.note,
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _metricTile(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String value,
    required String note,
  }) {
    final td = context.tdTheme;
    return Semantics(
      label: '$label, $value, $note',
      child: Container(
        constraints: const BoxConstraints(minHeight: 112),
        decoration: BoxDecoration(
          color: td.surfaceBase,
          borderRadius: BorderRadius.circular(TdRadius.card),
          border: Border.all(color: td.borderSubtle),
        ),
        padding: const EdgeInsets.all(TdSpacing.component),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 18, color: td.actionPrimary),
                const SizedBox(width: TdSpacing.inline),
                Expanded(
                  child: Text(
                    label,
                    style: TdTypography.metadata.copyWith(
                      color: td.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: TdSpacing.related),
            Text(value, style: TdTypography.metricMedium),
            const SizedBox(height: TdSpacing.inlineTight),
            Text(
              note,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TdTypography.micro.copyWith(color: td.textMuted),
            ),
          ],
        ),
      ),
    );
  }

  Color _statusColor(BuildContext context, DashboardStatus status) {
    final td = context.tdTheme;
    return switch (status) {
      DashboardStatus.success => td.statusSuccess,
      DashboardStatus.warning => td.statusWarning,
      DashboardStatus.critical => td.statusCritical,
      DashboardStatus.info => td.statusInfo,
      DashboardStatus.neutral || DashboardStatus.stale => td.textSecondary,
    };
  }

  IconData _healthIcon(DashboardStatus status) => switch (status) {
    DashboardStatus.success => Icons.check_circle_outline_rounded,
    DashboardStatus.warning => Icons.warning_amber_rounded,
    DashboardStatus.critical => Icons.error_outline_rounded,
    DashboardStatus.info => Icons.info_outline_rounded,
    DashboardStatus.neutral ||
    DashboardStatus.stale => Icons.help_outline_rounded,
  };

  Widget _poolCapacity(DashboardPool pool) => Semantics(
    label:
        '${pool.name}, ${pool.status}, ${pool.capacity ?? 'capacity unavailable'}',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(child: Text(pool.name, style: TdTypography.bodyLarge)),
            const SizedBox(width: TdSpacing.inline),
            Flexible(
              child: TdStatusBadge(
                status: _status(pool.statusKind),
                label: pool.status,
              ),
            ),
          ],
        ),
        const SizedBox(height: TdSpacing.related),
        if (pool.capacityPercent != null) ...[
          ClipRRect(
            borderRadius: BorderRadius.circular(99),
            child: LinearProgressIndicator(value: pool.capacityPercent! / 100),
          ),
          const SizedBox(height: TdSpacing.inline),
        ],
        Text(
          pool.capacity == null
              ? 'Capacity unavailable'
              : '${pool.capacity} used',
          style: TdTypography.metadata,
        ),
      ],
    ),
  );

  Widget _alerts(List<DashboardAlert> alerts, WidgetRef ref, String key) =>
      _FilteredAlerts(
        alerts: alerts,
        title: _titleWithRefresh('Alerts', ref, key),
      );

  Widget _storage(
    BuildContext context,
    DashboardStorage storage,
    WidgetRef ref,
    String key,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _titleWithRefresh('Storage', ref, key),
      _managementLink(context, storage: true),
      const SizedBox(height: TdSpacing.inline),
      const Text('Read-only pool and dataset inventory.'),
      const SizedBox(height: TdSpacing.inline),
      Wrap(
        spacing: TdSpacing.related,
        runSpacing: TdSpacing.inline,
        children: [
          Text(
            storage.poolsAvailable
                ? '${storage.pools.length} ${storage.pools.length == 1 ? 'pool' : 'pools'}'
                : 'Pools unavailable',
          ),
          Text(
            storage.datasetsAvailable
                ? '${storage.datasets.length} ${storage.datasets.length == 1 ? 'dataset' : 'datasets'}'
                : 'Datasets unavailable',
          ),
        ],
      ),
      if (!storage.poolsAvailable || !storage.datasetsAvailable) ...[
        const SizedBox(height: TdSpacing.inline),
        Semantics(
          container: true,
          label: 'Storage inventory is partial',
          child: const Text('Partial inventory'),
        ),
      ],
      const SizedBox(height: TdSpacing.sectionMobile),
      _inventoryPanel(
        'Pools',
        storage.pools
            .map(
              (pool) => _storagePoolGroup(
                context,
                pool,
                storage.datasets
                    .where((dataset) => dataset.poolName == pool.name)
                    .toList(),
                storage.datasetsAvailable,
              ),
            )
            .toList(),
        storage.poolsAvailable
            ? 'No pools were provided.'
            : 'Pool inventory is unavailable on this server.',
      ),
      const SizedBox(height: TdSpacing.related),
      _inventoryPanel(
        storage.datasets.any((dataset) => dataset.poolName.isEmpty)
            ? 'Other datasets'
            : 'Datasets',
        storage.datasets
            .where((dataset) => dataset.poolName.isEmpty)
            .map((dataset) => _datasetRow(context, dataset))
            .toList(),
        !storage.datasetsAvailable
            ? 'Dataset inventory is unavailable on this server.'
            : storage.datasets.isEmpty
            ? 'No datasets were provided.'
            : 'All datasets are grouped with their pools.',
      ),
      const SizedBox(height: TdSpacing.related),
      const TdPanel(
        title: 'VDEVs and disks unavailable',
        child: Text(
          'This read-only console has no approved VDEV or disk query.',
        ),
      ),
      const SizedBox(height: TdSpacing.related),
      TdPanel(
        title: 'Snapshots',
        description: 'Browse filesystem history and review creation or deletion of one snapshot.',
        child: FilledButton.icon(
          key: const Key('dashboard-snapshots-workspace'),
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SnapshotsPage()),
          ),
          icon: const Icon(Icons.history_rounded),
          label: const Text('Open snapshots'),
        ),
      ),
      const SizedBox(height: TdSpacing.related),
      const TdPanel(
        title: 'ACL management unavailable',
        child: Text(
          'This read-only console has no approved ACL query or mutation.',
        ),
      ),
    ],
  );

  Widget _workloads(
    BuildContext context,
    DashboardWorkloads workloads,
    WidgetRef ref,
    String key,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _titleWithRefresh('Workloads', ref, key),
      _managementLink(context, storage: false),
      const SizedBox(height: TdSpacing.inline),
      const Text('Read-only service inventory and normalized status.'),
      const SizedBox(height: TdSpacing.sectionMobile),
      _FilteredWorkloads(services: workloads.services),
      const SizedBox(height: TdSpacing.related),
      TdPanel(
        title: 'Applications',
        description: 'Browse installed apps and the catalog, and review supported lifecycle changes.',
        child: FilledButton.icon(
          key: const Key('dashboard-apps-workspace'),
          onPressed: () => Navigator.of(context)
              .push(MaterialPageRoute<void>(builder: (_) => const AppsPage())),
          icon: const Icon(Icons.apps_rounded),
          label: const Text('Open applications'),
        ),
      ),
    ],
  );

  Widget _managementLink(BuildContext context, {required bool storage}) =>
      TextButton.icon(
        onPressed: () => Navigator.of(context).push(
          MaterialPageRoute<void>(
            builder: (_) => ManagementPage(initialStorage: storage),
          ),
        ),
        icon: const Icon(Icons.tune_rounded, size: 18),
        label: Text(storage ? 'Manage storage' : 'Manage services'),
      );

  Widget _inventoryPanel(String title, List<Widget> items, String empty) =>
      TdPanel(
        title: title,
        child: items.isEmpty
            ? Text(empty)
            : Column(
                children: [
                  for (var index = 0; index < items.length; index++) ...[
                    items[index],
                    if (index < items.length - 1)
                      const Divider(height: TdSpacing.group),
                  ],
                ],
              ),
      );

  Widget _storagePoolGroup(
    BuildContext context,
    DashboardPool pool,
    List<DashboardDataset> datasets,
    bool datasetsAvailable,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _storagePoolRow(context, pool),
      const SizedBox(height: TdSpacing.inline),
      Semantics(
        header: true,
        child: Text('Datasets in ${pool.name}', style: TdTypography.titleSmall),
      ),
      const SizedBox(height: TdSpacing.inline),
      if (!datasetsAvailable)
        const Text('Dataset inventory is unavailable on this server.')
      else if (datasets.isEmpty)
        const Text('No datasets were provided for this pool.')
      else
        for (final dataset in datasets) _datasetRow(context, dataset),
    ],
  );

  Widget _datasetRow(BuildContext context, DashboardDataset dataset) =>
      Semantics(
        button: true,
        label: dataset.poolName.isEmpty
            ? 'Dataset ${dataset.name}, pool context unavailable'
            : 'Dataset ${dataset.name}, pool ${dataset.poolName}',
        child: InkWell(
          onTap: () => _showDetail(context, 'Dataset details', [
            ('Dataset', dataset.name),
            (
              'Pool context',
              dataset.poolName.isEmpty ? 'Unavailable' : dataset.poolName,
            ),
          ]),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(dataset.name, style: TdTypography.body),
            ),
          ),
        ),
      );

  Widget _storagePoolRow(BuildContext context, DashboardPool pool) => Semantics(
    button: true,
    label: '${pool.name}, ${pool.status}',
    child: InkWell(
      onTap: () => _showDetail(context, 'Pool details', [
        ('Pool', pool.name),
        ('Status', pool.status),
        ('Capacity', pool.capacity ?? 'Capacity unavailable'),
      ]),
      child: _poolCapacity(pool),
    ),
  );

  Widget _jobs(DashboardJobs jobs, WidgetRef ref, String key) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _titleWithRefresh('Jobs', ref, key),
      const SizedBox(height: TdSpacing.inline),
      Text('${jobs.items.length} recent jobs reported by the server.'),
      const SizedBox(height: TdSpacing.sectionMobile),
      _FilteredJobs(jobs: jobs.items),
    ],
  );

  Widget _refresh(WidgetRef ref, String key) => TdButton(
    label: 'Refresh',
    icon: Icons.refresh,
    variant: TdButtonVariant.secondary,
    onPressed: () => ref.invalidate(dashboardLoadProvider(key)),
  );

  Widget _titleWithRefresh(String title, WidgetRef ref, String key) => Row(
    children: [
      Expanded(child: Text(title, style: TdTypography.titleLarge)),
      _refresh(ref, key),
    ],
  );

  TdStatus _status(DashboardStatus status) => switch (status) {
    DashboardStatus.neutral => TdStatus.neutral,
    DashboardStatus.success => TdStatus.success,
    DashboardStatus.warning => TdStatus.warning,
    DashboardStatus.critical => TdStatus.critical,
    DashboardStatus.info => TdStatus.info,
    DashboardStatus.stale => TdStatus.stale,
  };
}

Widget _systemDetail(String label, String value) => ConstrainedBox(
  constraints: const BoxConstraints(maxWidth: 220),
  child: Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    mainAxisSize: MainAxisSize.min,
    children: [
      Text(label, style: TdTypography.micro),
      Text(value, softWrap: true, style: TdTypography.metadata),
    ],
  ),
);

String _uptimeLabel(int seconds) {
  final days = seconds ~/ 86400;
  final hours = seconds % 86400 ~/ 3600;
  final minutes = seconds % 3600 ~/ 60;
  if (days > 0) return '${days}d ${hours}h';
  if (hours > 0) return '${hours}h ${minutes}m';
  if (minutes > 0) return '${minutes}m';
  return '${seconds}s';
}

String _memoryLabel(int bytes) =>
    '${(bytes / 1073741824).toStringAsFixed(1)} GiB';

Widget _loadAverageChart(({double one, double five, double fifteen}) averages) {
  final values = <(String, double)>[
    ('1 minute', averages.one),
    ('5 minutes', averages.five),
    ('15 minutes', averages.fifteen),
  ];
  final maximum = values
      .map((entry) => entry.$2)
      .reduce((left, right) => left > right ? left : right);
  return Column(
    key: const Key('dashboard-load-average'),
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      const Text('Load average · 1 / 5 / 15 minutes'),
      const Text(
        'Snapshot on refresh; bars compare these three values, not CPU usage %.',
      ),
      const SizedBox(height: TdSpacing.inline),
      for (final (label, value) in values)
        Padding(
          padding: const EdgeInsets.only(bottom: TdSpacing.inlineTight),
          child: Row(
            children: [
              SizedBox(width: 82, child: Text(label)),
              Expanded(
                child: ExcludeSemantics(
                  child: LinearProgressIndicator(
                    value: maximum == 0 ? 0 : value / maximum,
                    minHeight: 8,
                  ),
                ),
              ),
              const SizedBox(width: TdSpacing.inline),
              SizedBox(
                width: 52,
                child: Text(value.toStringAsFixed(2), textAlign: TextAlign.end),
              ),
            ],
          ),
        ),
    ],
  );
}

enum _StatusFilter { all, critical, warning, info, running, neutral }

String _filterLabel(_StatusFilter filter) => switch (filter) {
  _StatusFilter.all => 'All statuses',
  _StatusFilter.critical => 'Critical',
  _StatusFilter.warning => 'Warning',
  _StatusFilter.info => 'Information',
  _StatusFilter.running => 'Running',
  _StatusFilter.neutral => 'Inactive',
};

bool _matchesFilter(DashboardStatus status, _StatusFilter filter) =>
    switch (filter) {
      _StatusFilter.all => true,
      _StatusFilter.critical => status == DashboardStatus.critical,
      _StatusFilter.warning => status == DashboardStatus.warning,
      _StatusFilter.info => status == DashboardStatus.info,
      _StatusFilter.running => status == DashboardStatus.success,
      _StatusFilter.neutral => status == DashboardStatus.neutral,
    };

TdStatus _tdStatus(DashboardStatus status) => switch (status) {
  DashboardStatus.neutral => TdStatus.neutral,
  DashboardStatus.success => TdStatus.success,
  DashboardStatus.warning => TdStatus.warning,
  DashboardStatus.critical => TdStatus.critical,
  DashboardStatus.info => TdStatus.info,
  DashboardStatus.stale => TdStatus.stale,
};

class _StatusFilterField extends StatelessWidget {
  const _StatusFilterField({
    required this.fieldKey,
    required this.value,
    required this.onChanged,
  });
  final Key fieldKey;
  final _StatusFilter value;
  final ValueChanged<_StatusFilter> onChanged;

  @override
  Widget build(BuildContext context) => DropdownButtonFormField<_StatusFilter>(
    key: fieldKey,
    initialValue: value,
    isExpanded: true,
    decoration: const InputDecoration(labelText: 'Status filter'),
    items: [
      for (final filter in _StatusFilter.values)
        DropdownMenuItem(value: filter, child: Text(_filterLabel(filter))),
    ],
    onChanged: (filter) {
      if (filter != null) onChanged(filter);
    },
  );
}

class _FilteredAlerts extends StatefulWidget {
  const _FilteredAlerts({required this.alerts, required this.title});
  final List<DashboardAlert> alerts;
  final Widget title;

  @override
  State<_FilteredAlerts> createState() => _FilteredAlertsState();
}

class _FilteredAlertsState extends State<_FilteredAlerts> {
  var _filter = _StatusFilter.all;

  @override
  Widget build(BuildContext context) {
    final alerts = widget.alerts
        .where((alert) => _matchesFilter(alert.status, _filter))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        widget.title,
        const SizedBox(height: TdSpacing.inline),
        _StatusFilterField(
          fieldKey: const Key('alerts-severity-filter'),
          value: _filter,
          onChanged: (value) => setState(() => _filter = value),
        ),
        const SizedBox(height: TdSpacing.related),
        Text(
          'Showing ${alerts.length} active alerts from the current server state.',
        ),
        const SizedBox(height: TdSpacing.related),
        TdPanel(
          title: 'Alerts (${alerts.length})',
          child: alerts.isEmpty
              ? const Text('No alerts match this filter.')
              : Column(
                  children: [
                    for (final alert in alerts) ...[
                      Semantics(
                        button: true,
                        label: '${alert.level} alert: ${alert.message}',
                        child: InkWell(
                          onTap: () => _showDetail(context, 'Alert details', [
                            ('Severity', alert.level),
                            ('Message', alert.message),
                          ]),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Flexible(
                                child: TdStatusBadge(
                                  status: _tdStatus(alert.status),
                                  label: alert.level,
                                ),
                              ),
                              const SizedBox(width: TdSpacing.related),
                              Expanded(child: Text(alert.message)),
                            ],
                          ),
                        ),
                      ),
                      if (alert != alerts.last)
                        const Divider(height: TdSpacing.group),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _FilteredWorkloads extends StatefulWidget {
  const _FilteredWorkloads({required this.services});
  final List<DashboardService> services;

  @override
  State<_FilteredWorkloads> createState() => _FilteredWorkloadsState();
}

class _FilteredWorkloadsState extends State<_FilteredWorkloads> {
  var _filter = _StatusFilter.all;

  @override
  Widget build(BuildContext context) {
    final services = widget.services
        .where((service) => _matchesFilter(service.statusKind, _filter))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusFilterField(
          fieldKey: const Key('workloads-status-filter'),
          value: _filter,
          onChanged: (value) => setState(() => _filter = value),
        ),
        const SizedBox(height: TdSpacing.related),
        TdPanel(
          title: 'Services (${services.length})',
          child: services.isEmpty
              ? const Text('No services match this filter.')
              : Column(
                  children: [
                    for (final service in services) ...[
                      Semantics(
                        button: true,
                        label: '${service.name}, ${service.status}',
                        child: InkWell(
                          onTap: () => _showDetail(context, 'Service details', [
                            ('Service', service.name),
                            ('Status', service.status),
                          ]),
                          child: Row(
                            children: [
                              Expanded(child: Text(service.name)),
                              const SizedBox(width: TdSpacing.inline),
                              Flexible(
                                child: TdStatusBadge(
                                  status: _tdStatus(service.statusKind),
                                  label: service.status,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (service != services.last)
                        const Divider(height: TdSpacing.group),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

class _FilteredJobs extends StatefulWidget {
  const _FilteredJobs({required this.jobs});
  final List<DashboardJob> jobs;

  @override
  State<_FilteredJobs> createState() => _FilteredJobsState();
}

class _FilteredJobsState extends State<_FilteredJobs> {
  var _filter = _StatusFilter.all;

  @override
  Widget build(BuildContext context) {
    final jobs = widget.jobs
        .where((job) => _matchesFilter(job.statusKind, _filter))
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _StatusFilterField(
          fieldKey: const Key('jobs-status-filter'),
          value: _filter,
          onChanged: (value) => setState(() => _filter = value),
        ),
        const SizedBox(height: TdSpacing.related),
        TdPanel(
          title: 'Recent jobs (${jobs.length})',
          child: jobs.isEmpty
              ? const Text('No jobs match this filter.')
              : Column(
                  children: [
                    for (final job in jobs) ...[
                      Semantics(
                        button: true,
                        label: '${job.name}, job ${job.id}, ${job.status}',
                        child: InkWell(
                          onTap: () => _showDetail(context, 'Job details', [
                            ('Job ID', job.id),
                            ('Job', job.name),
                            ('Status', job.status),
                          ]),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(
                                child: Text(
                                  job.name,
                                  style: TdTypography.bodyLarge,
                                ),
                              ),
                              const SizedBox(width: TdSpacing.inline),
                              Flexible(
                                child: TdStatusBadge(
                                  status: _tdStatus(job.statusKind),
                                  label: job.status,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      if (job != jobs.last)
                        const Divider(height: TdSpacing.group),
                    ],
                  ],
                ),
        ),
      ],
    );
  }
}

void _showDetail(
  BuildContext context,
  String title,
  List<(String, String)> fields,
) {
  showDialog<void>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(title),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final field in fields) ...[
            Text(field.$1, style: TdTypography.metadata),
            Text(field.$2),
            const SizedBox(height: TdSpacing.related),
          ],
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}
