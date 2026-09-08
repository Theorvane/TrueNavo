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
        title: 'Loading server data',
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
    title: 'Unable to load server data',
    description:
        'No server details were saved. Check the connection and try again.',
    actionLabel: 'Refresh',
    onAction: () => ref.invalidate(dashboardLoadProvider(key)),
  );

  Widget _data(Object? value, WidgetRef ref, String key) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      if (value is DashboardHome) ...[
        Text(value.serverName, style: TdTypography.titleLarge),
        const SizedBox(height: TdSpacing.inline),
        Text(value.version),
        const SizedBox(height: TdSpacing.sectionMobile),
        _section(
          'Storage pools',
          value.pools.map(_pool).toList(),
          'No pool capacity was provided by the server.',
        ),
      ] else if (value is List<DashboardAlert>)
        _section(
          'Alerts',
          value.map((alert) => '${alert.level}: ${alert.message}').toList(),
          'No active alerts.',
        )
      else if (value is DashboardManage) ...[
        _section('Pools', value.pools.map(_pool).toList(), 'No pools.'),
        _section('Datasets', value.datasets, 'No datasets.'),
        _section('Services', value.services, 'No services.'),
      ] else if (value is DashboardJobs)
        _section(
          'Jobs',
          value.items.map((job) => '${job.name} · ${job.status}').toList(),
          'No jobs.',
        ),
      const SizedBox(height: TdSpacing.sectionMobile),
      TdButton(
        label: 'Refresh',
        variant: TdButtonVariant.secondary,
        onPressed: () => ref.invalidate(dashboardLoadProvider(key)),
      ),
    ],
  );

  String _pool(DashboardPool pool) => [
    pool.name,
    pool.status,
    if (pool.capacity != null) pool.capacity!,
  ].join(' · ');

  Widget _section(String title, List<String> values, String empty) => TdPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: TdTypography.titleSmall),
        const SizedBox(height: TdSpacing.related),
        if (values.isEmpty)
          Text(empty)
        else
          for (final value in values)
            Padding(
              padding: const EdgeInsets.only(bottom: TdSpacing.inline),
              child: Text(value),
            ),
      ],
    ),
  );
}
