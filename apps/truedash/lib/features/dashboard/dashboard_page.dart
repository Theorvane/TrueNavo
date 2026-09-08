import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truedash_design_system/truedash_design_system.dart';

import '../../app_shell/app_destination.dart';
import 'dashboard_controller.dart';
import 'dashboard_repository.dart';

class DashboardPage extends ConsumerWidget {
  const DashboardPage({required this.destination, super.key});
  final AppDestination destination;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        DashboardData(:final value) => _data(value, ref, key),
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

  Widget _data(Object? value, WidgetRef ref, String key) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (value is DashboardHome) _home(value, ref, key),
      if (value is List<DashboardAlert>) _alerts(value, ref, key),
      if (value is DashboardManage) _manage(value, ref, key),
      if (value is DashboardJobs) _jobs(value, ref, key),
    ],
  );

  Widget _home(DashboardHome home, WidgetRef ref, String key) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Semantics(
        header: true,
        label: '${home.serverName}, ${home.version}',
        child: Text(home.serverName, style: TdTypography.titleLarge),
      ),
      const SizedBox(height: TdSpacing.inline),
      Text(home.version, style: TdTypography.body),
      const SizedBox(height: TdSpacing.component),
      TdPanel(
        title: 'Server health',
        description:
            'Current state from available pools and all active alerts.',
        action: _refresh(ref, key),
        child: _healthSummary(home),
      ),
      const SizedBox(height: TdSpacing.sectionMobile),
      _metrics(home),
      const SizedBox(height: TdSpacing.sectionMobile),
      TdPanel(
        title: 'Storage pools',
        description:
            'Capacity reflects the latest values reported by the server.',
        child: home.pools.isEmpty
            ? Text(
                home.poolsAvailable
                    ? 'No storage pools were provided by the server.'
                    : 'Pool status is unavailable on this server.',
              )
            : Column(
                children: [
                  for (final pool in home.pools) ...[
                    _poolCapacity(pool),
                    if (pool != home.pools.last)
                      const Divider(height: TdSpacing.group),
                  ],
                ],
              ),
      ),
    ],
  );

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

  /// Keeps the status-first health summary usable when the panel is narrow.
  Widget _healthSummary(DashboardHome home) => LayoutBuilder(
    builder: (context, constraints) {
      final badge = TdStatusBadge(
        status: _status(home.health.status),
        label: home.health.summary,
      );
      final detail = Text(_healthDetail(home), style: TdTypography.body);

      if (constraints.maxWidth < 400) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            badge,
            const SizedBox(height: TdSpacing.related),
            detail,
          ],
        );
      }

      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Flexible(child: badge),
          const SizedBox(width: TdSpacing.related),
          Expanded(child: detail),
        ],
      );
    },
  );

  Widget _metrics(DashboardHome home) {
    final cards = <Widget>[
      TdMetricCard(
        label: 'Pools shown',
        value: home.poolsAvailable ? '${home.pools.length}' : '—',
        freshness: home.poolsAvailable
            ? 'Up to 50 current results'
            : 'Unavailable on this server',
      ),
      TdMetricCard(
        label: 'Active alerts',
        value: home.alertsAvailable ? '${home.activeAlertCount}' : '—',
        freshness: home.alertsAvailable
            ? 'All reported alerts'
            : 'Unavailable on this server',
      ),
    ];
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth < 480
            ? constraints.maxWidth
            : math.min((constraints.maxWidth - TdSpacing.related) / 2, 280.0);
        return Wrap(
          spacing: TdSpacing.related,
          runSpacing: TdSpacing.related,
          children: [
            for (final card in cards) SizedBox(width: width, child: card),
          ],
        );
      },
    );
  }

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

  Widget _alerts(List<DashboardAlert> alerts, WidgetRef ref, String key) {
    final groups = <DashboardStatus, List<DashboardAlert>>{
      DashboardStatus.critical: [],
      DashboardStatus.warning: [],
      DashboardStatus.info: [],
    };
    for (final alert in alerts) {
      (groups[alert.status] ?? groups[DashboardStatus.info])!.add(alert);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _titleWithRefresh('Alerts', ref, key),
        const SizedBox(height: TdSpacing.inline),
        Text(
          'Showing ${alerts.length} active alerts from the current server state.',
        ),
        const SizedBox(height: TdSpacing.sectionMobile),
        _alertGroup(
          'Critical',
          DashboardStatus.critical,
          groups[DashboardStatus.critical]!,
        ),
        _alertGroup(
          'Warnings',
          DashboardStatus.warning,
          groups[DashboardStatus.warning]!,
        ),
        _alertGroup(
          'Information',
          DashboardStatus.info,
          groups[DashboardStatus.info]!,
        ),
      ],
    );
  }

  Widget _alertGroup(
    String title,
    DashboardStatus status,
    List<DashboardAlert> alerts,
  ) => Padding(
    padding: const EdgeInsets.only(bottom: TdSpacing.related),
    child: TdPanel(
      title: '$title (${alerts.length})',
      child: alerts.isEmpty
          ? Text('No ${title.toLowerCase()} alerts.', style: TdTypography.body)
          : Column(
              children: [
                for (final alert in alerts) ...[
                  Semantics(
                    label: '${alert.level} alert: ${alert.message}',
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Flexible(
                          child: TdStatusBadge(
                            status: _status(status),
                            label: alert.level,
                          ),
                        ),
                        const SizedBox(width: TdSpacing.related),
                        Expanded(
                          child: Text(alert.message, style: TdTypography.body),
                        ),
                      ],
                    ),
                  ),
                  if (alert != alerts.last)
                    const Divider(height: TdSpacing.group),
                ],
              ],
            ),
    ),
  );

  Widget _manage(DashboardManage manage, WidgetRef ref, String key) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _titleWithRefresh('Manage inventory', ref, key),
      const SizedBox(height: TdSpacing.inline),
      const Text('Read-only inventory and service health.'),
      const SizedBox(height: TdSpacing.sectionMobile),
      _inventoryPanel(
        'Pools',
        manage.pools.map(_poolCapacity).toList(),
        'No pools were provided.',
      ),
      const SizedBox(height: TdSpacing.related),
      _inventoryPanel(
        'Datasets',
        manage.datasets.map((dataset) => _namedRow(dataset.name)).toList(),
        'No datasets were provided.',
      ),
      const SizedBox(height: TdSpacing.related),
      _inventoryPanel(
        'Services',
        manage.services.map(_serviceRow).toList(),
        'No services were provided.',
      ),
    ],
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

  Widget _namedRow(String name) => Semantics(
    label: 'Dataset $name',
    child: Text(name, style: TdTypography.body),
  );

  Widget _serviceRow(DashboardService service) => Semantics(
    label: '${service.name}, ${service.status}',
    child: Row(
      children: [
        Expanded(child: Text(service.name, style: TdTypography.body)),
        const SizedBox(width: TdSpacing.inline),
        Flexible(
          child: TdStatusBadge(
            status: _status(service.statusKind),
            label: service.status,
          ),
        ),
      ],
    ),
  );

  Widget _jobs(DashboardJobs jobs, WidgetRef ref, String key) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _titleWithRefresh('Jobs', ref, key),
      const SizedBox(height: TdSpacing.inline),
      Text('${jobs.items.length} recent jobs reported by the server.'),
      const SizedBox(height: TdSpacing.sectionMobile),
      TdPanel(
        title: 'Recent jobs',
        child: jobs.items.isEmpty
            ? const Text('No jobs were provided.')
            : Column(
                children: [
                  for (final job in jobs.items) ...[
                    Semantics(
                      label: '${job.name}, job ${job.id}, ${job.status}',
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(job.name, style: TdTypography.bodyLarge),
                                const SizedBox(height: TdSpacing.inlineTight),
                                Text(
                                  'Job ID: ${job.id}',
                                  style: TdTypography.metadata,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: TdSpacing.inline),
                          Flexible(
                            child: TdStatusBadge(
                              status: _status(job.statusKind),
                              label: job.status,
                            ),
                          ),
                        ],
                      ),
                    ),
                    if (job != jobs.items.last)
                      const Divider(height: TdSpacing.group),
                  ],
                ],
              ),
      ),
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
