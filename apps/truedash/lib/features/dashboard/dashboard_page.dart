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
      if (value is DashboardHome) _home(value, ref, key),
      if (value is List<DashboardAlert>) _alerts(value, ref, key),
      if (value is DashboardStorage) _storage(context, value, ref, key),
      if (value is DashboardWorkloads) _workloads(value, ref, key),
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
      const SizedBox(height: TdSpacing.inline),
      const Text('Read-only pool and dataset inventory.'),
      const SizedBox(height: TdSpacing.sectionMobile),
      _inventoryPanel(
        'Pools',
        storage.pools.map((pool) => _storagePoolRow(context, pool)).toList(),
        storage.poolsAvailable
            ? 'No pools were provided.'
            : 'Pool inventory is unavailable on this server.',
      ),
      const SizedBox(height: TdSpacing.related),
      _inventoryPanel(
        'Datasets',
        storage.datasets
            .map((dataset) => _datasetRow(context, dataset))
            .toList(),
        storage.datasetsAvailable
            ? 'No datasets were provided.'
            : 'Dataset inventory is unavailable on this server.',
      ),
      const SizedBox(height: TdSpacing.related),
      const TdPanel(
        title: 'VDEVs and disks unavailable',
        child: Text(
          'This read-only console has no approved VDEV or disk query.',
        ),
      ),
      const SizedBox(height: TdSpacing.related),
      const TdPanel(
        title: 'Snapshots unavailable',
        child: Text('This read-only console has no approved snapshot query.'),
      ),
    ],
  );

  Widget _workloads(
    DashboardWorkloads workloads,
    WidgetRef ref,
    String key,
  ) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _titleWithRefresh('Workloads', ref, key),
      const SizedBox(height: TdSpacing.inline),
      const Text('Read-only service inventory and normalized status.'),
      const SizedBox(height: TdSpacing.sectionMobile),
      _FilteredWorkloads(services: workloads.services),
      const SizedBox(height: TdSpacing.related),
      const TdPanel(
        title: 'Apps and containers unavailable',
        child: Text(
          'This read-only console has no approved apps or containers query.',
        ),
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

  Widget _datasetRow(BuildContext context, DashboardDataset dataset) =>
      Semantics(
        button: true,
        label: 'Dataset ${dataset.name}, pool ${dataset.poolName}',
        child: InkWell(
          onTap: () => _showDetail(context, 'Dataset details', [
            ('Dataset', dataset.name),
            ('Pool context', dataset.poolName),
          ]),
          child: Text(dataset.name, style: TdTypography.body),
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
