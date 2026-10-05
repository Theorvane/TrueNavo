import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'pool_maintenance_charts.dart';
import 'pool_maintenance_controller.dart';
import 'pool_maintenance_editor.dart';
import 'pool_maintenance_labels.dart';
import 'pool_maintenance_review.dart';

class PoolMaintenancePage extends ConsumerStatefulWidget {
  const PoolMaintenancePage({super.key});
  @override
  ConsumerState<PoolMaintenancePage> createState() =>
      _PoolMaintenancePageState();
}

class _PoolMaintenancePageState extends ConsumerState<PoolMaintenancePage> {
  bool _reviewing = false;
  String? _error;
  Future<void> _change(
    AuthenticatedSession session,
    PoolMaintenanceRequest intent,
  ) async {
    if (_reviewing ||
        !ref
            .read(poolMaintenanceControllerProvider.notifier)
            .allowsRequest(intent)) {
      return;
    }
    setState(() {
      _reviewing = true;
      _error = null;
    });
    final initial = WidgetsBinding.instance.lifecycleState;
    var expired = initial != null && initial != AppLifecycleState.resumed;
    final lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) expired = true;
      },
    );
    final sessionWatch = ref.listenManual(dashboardActiveSessionProvider, (
      a,
      b,
    ) {
      if (!identical(a, b)) expired = true;
    });
    final inventoryWatch = ref.listenManual(poolMaintenanceInventoryProvider, (
      _,
      b,
    ) {
      if (b.isLoading || !identical(intent.inventory, b.asData?.value)) {
        expired = true;
      }
    });
    bool current() =>
        mounted &&
        !expired &&
        identical(session, ref.read(dashboardActiveSessionProvider)) &&
        !ref.read(poolMaintenanceInventoryProvider).isLoading &&
        identical(
          intent.inventory,
          ref.read(poolMaintenanceInventoryProvider).asData?.value,
        );
    try {
      if (!current()) return;
      var request = intent;
      if (intent.action == PoolMaintenanceAction.createSchedule ||
          intent.action == PoolMaintenanceAction.updateSchedule) {
        final edited = await showDialog<PoolMaintenanceRequest>(
          context: context,
          barrierDismissible: false,
          builder: (_) => PoolMaintenanceEditor(
            session: session,
            inventory: intent.inventory,
            pool: intent.pool,
            schedule: intent.schedule,
          ),
        );
        if (edited == null || !current()) return;
        request = edited;
      }
      if (!current() || request.validationError != null) return;
      final api = ref.read(poolMaintenanceSessionProvider);
      if (api == null) return;
      final review = await api.reviewPoolMaintenance(request);
      if (!mounted || !current()) return;
      if (!identical(review.request, request) ||
          review.endpoint != session.endpoint) {
        throw StateError('Mismatching maintenance intent');
      }
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            PoolMaintenanceReviewDialog(session: session, review: review),
      );
      if (confirmed != true || !current()) return;
      await ref
          .read(poolMaintenanceControllerProvider.notifier)
          .execute(
            expectedSession: session,
            review: review,
            confirmation: review.target,
          );
    } on Object {
      if (current()) {
        setState(
          () => _error = 'Maintenance review could not be completed safely. Remote details were withheld. Reload before reviewing again.',
        );
      }
    } finally {
      sessionWatch.close();
      inventoryWatch.close();
      lifecycle.dispose();
      if (mounted) setState(() => _reviewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider),
        api = ref.watch(poolMaintenanceSessionProvider);
    final state = ref.watch(poolMaintenanceControllerProvider),
        controller = ref.read(poolMaintenanceControllerProvider.notifier);
    final caps = api?.poolMaintenanceCapabilities;
    final available = session?.endpoint != null && caps?.supported == true;
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) setState(() => _error = null);
    });
    final canRefresh =
        available && !state.busy && !state.unknown && !_reviewing;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Pool maintenance'),
        actions: [
          IconButton(
            key: const Key('pool-maintenance-refresh'),
            tooltip: 'Read current pool maintenance',
            onPressed: canRefresh
                ? () => ref.invalidate(poolMaintenanceInventoryProvider)
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SingleChildScrollView(
        key: const Key('pool-maintenance-scroll'),
        padding: const EdgeInsets.all(20),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'STORAGE · POOL MAINTENANCE',
                  style: TdTypography.micro,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Scrubs & schedules',
                  style: TdTypography.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(session?.endpoint ?? 'No authenticated connection'),
                const Text(
                  'Last-read pool and scan state only. No automatic polling or scrub dispatch. Starting a scrub is a background job, not proof of completion or data integrity. Scrub schedules do not start scans immediately.',
                ),
                const SizedBox(height: 16),
                if (state.busy) const LinearProgressIndicator(),
                if (state.result case final result?)
                  TdPanel(
                    title: state.unknown
                        ? 'Verify before continuing'
                        : state.pendingJob
                        ? 'Owned scrub job needs verification'
                        : 'Last maintenance operation',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(result.message),
                        if (state.pendingJob && state.connectionCurrent) ...[
                          Text(
                            'Job ${state.job!.id} · ${poolMaintenanceActionLabel(state.job!.action)} · ${state.job!.poolName}',
                          ),
                          const Text(
                            'Other writes stay locked. Check once to inspect this owned job. Only an exact same-pool stop can interrupt a pending start. A pool scan progress update alone does not release the job lock.',
                          ),
                          OutlinedButton(
                            key: const Key('pool-maintenance-check-job'),
                            onPressed: controller.canCheck && !_reviewing
                                ? () {
                                    final lifecycle =
                                        WidgetsBinding.instance.lifecycleState;
                                    if (lifecycle == null ||
                                        lifecycle ==
                                            AppLifecycleState.resumed) {
                                      controller.checkJob();
                                    }
                                  }
                                : null,
                            child: const Text('Check owned job once'),
                          ),
                        ],
                        if (state.unknown)
                          OutlinedButton(
                            key: const Key('pool-maintenance-acknowledge'),
                            onPressed: controller.canAcknowledge
                                ? controller.acknowledgeAfterReconnect
                                : null,
                            child: const Text(
                              'I inspected the original server and reconnected',
                            ),
                          ),
                      ],
                    ),
                  ),
                if (_error case final error?) Text(error),
                const SizedBox(height: 16),
                if (!available)
                  TdPanel(
                    title: 'Pool maintenance unavailable',
                    child: Text(
                      caps?.blockedReason ??
                          'Connect to a supported TrueNAS instance.',
                    ),
                  )
                else if (state.locked && !state.connectionCurrent)
                  const TdPanel(
                    title: 'Original operation needs attention',
                    child: Text(
                      'Previous pool and schedule details are hidden. Verify the original server before continuing.',
                    ),
                  )
                else
                  ref
                      .watch(poolMaintenanceInventoryProvider)
                      .when(
                        skipLoadingOnRefresh: false,
                        skipLoadingOnReload: false,
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (_, _) => TdPanel(
                          title: 'Pool maintenance inventory unavailable',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Pool, scan, schedule or job metadata could not be verified. Remote details were withheld. Unknown is not an empty or healthy inventory.',
                              ),
                              OutlinedButton(
                                key: const Key('pool-maintenance-retry'),
                                onPressed: canRefresh
                                    ? () => ref.invalidate(
                                        poolMaintenanceInventoryProvider,
                                      )
                                    : null,
                                child: const Text('Retry reads'),
                              ),
                            ],
                          ),
                        ),
                        data: (inventory) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text('Server timezone: ${inventory.timezone}'),
                            if (inventory.blockedReason case final reason?)
                              Text(reason),
                            Text(
                              '${inventory.jobs.length} active server jobs reported · no arbitrary job details are displayed',
                            ),
                            const SizedBox(height: 12),
                            PoolScheduleChart(
                              enabled: inventory.schedules
                                  .where((s) => s.settings.enabled)
                                  .length,
                              disabled: inventory.schedules
                                  .where((s) => !s.settings.enabled)
                                  .length,
                            ),
                            if (inventory.pools.isEmpty)
                              const Padding(
                                padding: EdgeInsets.only(top: 16),
                                child: TdPanel(
                                  title: 'No supported data pools',
                                  child: Text(
                                    'No pool was reported in the current inventory. No maintenance target is inferred.',
                                  ),
                                ),
                              ),
                            for (final pool in inventory.pools)
                              Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: TdPanel(
                                  title: pool.name,
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        'Pool ID ${pool.id} · GUID ${pool.guid}',
                                      ),
                                      Text(
                                        '${pool.status} · reported healthy: ${pool.healthy ? 'yes' : 'no'} · warning: ${pool.warning ? 'yes' : 'no'}',
                                      ),
                                      if (pool.expansionState != null)
                                        Text(
                                          'Expansion: ${pool.expansionState}',
                                        ),
                                      PoolScanView(pool: pool),
                                      const SizedBox(height: 12),
                                      Wrap(
                                        spacing: 12,
                                        runSpacing: 12,
                                        children: [
                                          for (final action in [
                                            PoolMaintenanceAction.startScrub,
                                            PoolMaintenanceAction.stopScrub,
                                            PoolMaintenanceAction
                                                .createSchedule,
                                          ])
                                            _action(
                                              session!,
                                              caps!,
                                              inventory,
                                              pool,
                                              action,
                                            ),
                                        ],
                                      ),
                                      for (final schedule
                                          in inventory.schedules.where(
                                            (s) => s.poolId == pool.id,
                                          ))
                                        Padding(
                                          padding: const EdgeInsets.only(
                                            top: 20,
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              Text(
                                                'Schedule #${schedule.id}',
                                                style: TdTypography.titleSmall,
                                              ),
                                              Text(
                                                schedule
                                                        .settings
                                                        .description
                                                        .isEmpty
                                                    ? 'No schedule description'
                                                    : schedule
                                                          .settings
                                                          .description,
                                              ),
                                              Text(
                                                '${schedule.settings.enabled ? 'Enabled' : 'Disabled'} · threshold ${schedule.settings.threshold} days',
                                              ),
                                              Text(
                                                'Cron: ${schedule.settings.cron.expression} · ${inventory.timezone}',
                                              ),
                                              Wrap(
                                                spacing: 12,
                                                runSpacing: 12,
                                                children: [
                                                  _action(
                                                    session!,
                                                    caps!,
                                                    inventory,
                                                    pool,
                                                    PoolMaintenanceAction
                                                        .updateSchedule,
                                                    schedule,
                                                  ),
                                                  _action(
                                                    session,
                                                    caps,
                                                    inventory,
                                                    pool,
                                                    schedule.settings.enabled
                                                        ? PoolMaintenanceAction
                                                              .disableSchedule
                                                        : PoolMaintenanceAction
                                                              .enableSchedule,
                                                    schedule,
                                                  ),
                                                  _action(
                                                    session,
                                                    caps,
                                                    inventory,
                                                    pool,
                                                    PoolMaintenanceAction
                                                        .deleteSchedule,
                                                    schedule,
                                                  ),
                                                ],
                                              ),
                                            ],
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            const SizedBox(height: 20),
                            const Text(
                              'Pause/resume, boot-pool operations, resilver controls, pool topology changes and HA operations are not offered here. Disabling or deleting a schedule does not stop an active scrub.',
                            ),
                          ],
                        ),
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _action(
    AuthenticatedSession session,
    PoolMaintenanceCapabilities caps,
    PoolMaintenanceInventory inventory,
    PoolMaintenancePool pool,
    PoolMaintenanceAction action, [
    PoolScrubSchedule? schedule,
  ]) {
    final editing =
        action == PoolMaintenanceAction.createSchedule ||
        action == PoolMaintenanceAction.updateSchedule;
    final intent = PoolMaintenanceRequest(
      inventory: inventory,
      action: action,
      pool: pool,
      schedule: schedule,
      settings: editing
          ? schedule?.settings ??
                const PoolScrubScheduleSettings(enabled: false)
          : null,
    );
    // An unchanged edit is valid to open; its submitted form must differ.
    final validity = editing && action == PoolMaintenanceAction.updateSchedule
        ? PoolMaintenanceRequest(
            inventory: inventory,
            action: PoolMaintenanceAction.deleteSchedule,
            pool: pool,
            schedule: schedule,
          ).validationError
        : intent.validationError;
    return OutlinedButton(
      key: Key('pool-maintenance-${action.name}-${schedule?.id ?? pool.id}'),
      onPressed:
          !_reviewing &&
              caps.allows(action) &&
              validity == null &&
              ref
                  .read(poolMaintenanceControllerProvider.notifier)
                  .allowsRequest(intent)
          ? () => _change(session, intent)
          : null,
      child: Text(poolMaintenanceActionLabel(action)),
    );
  }
}

class PoolScanView extends StatelessWidget {
  const PoolScanView({required this.pool, super.key});
  final PoolMaintenancePool pool;
  @override
  Widget build(BuildContext context) {
    final scan = pool.scan;
    if (scan == null) {
      return const Text(
        'Scan metadata unavailable · no progress or completion is inferred.',
      );
    }
    final percent = scan.percentage;
    final known =
        percent != null && percent.isFinite && percent >= 0 && percent <= 100;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'Scan: ${scan.function ?? 'unknown type'} · ${scan.state ?? 'unknown state'}${scan.paused ? ' · paused' : ''}',
        ),
        if (known) ...[
          Text('Last-reported progress: ${percent.toStringAsFixed(1)}%'),
          Semantics(
            label:
                'Last-reported scan progress ${percent.toStringAsFixed(1)} percent',
            child: LinearProgressIndicator(
              key: Key('pool-maintenance-scan-${pool.id}'),
              value: percent / 100,
              minHeight: 12,
            ),
          ),
        ] else
          const Text('Scan progress unknown'),
        Text('Reported scan errors: ${scan.errors?.toString() ?? 'unknown'}'),
        Text(
          'Remaining estimate: ${scan.remainingSeconds == null ? 'unknown' : '${scan.remainingSeconds} seconds'}',
        ),
        if (scan.startTime != null)
          Text(
            'Scan started: ${scan.startTime!.toUtc().toIso8601String()} (UTC)',
          ),
        if (scan.endTime != null)
          Text('Scan ended: ${scan.endTime!.toUtc().toIso8601String()} (UTC)'),
      ],
    );
  }
}
