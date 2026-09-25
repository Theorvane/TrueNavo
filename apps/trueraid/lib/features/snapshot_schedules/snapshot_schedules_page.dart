import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'snapshot_calendar_editor.dart';
import 'snapshot_schedules_controller.dart';
import 'snapshot_schedule_editor.dart';
import 'snapshot_schedule_enablement_chart.dart';
import 'snapshot_schedule_review.dart';

class SnapshotSchedulesPage extends ConsumerStatefulWidget {
  const SnapshotSchedulesPage({super.key});
  @override
  ConsumerState<SnapshotSchedulesPage> createState() =>
      _SnapshotSchedulesPageState();
}

class _SnapshotSchedulesPageState extends ConsumerState<SnapshotSchedulesPage> {
  String _search = '';
  final _scroll = ScrollController();
  bool _reviewing = false;
  bool _reviewReady = false;
  String? _error;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _action(
    AuthenticatedSession session,
    SnapshotScheduleInventory inventory,
    SnapshotScheduleTask task,
    SnapshotScheduleAction action,
  ) async {
    if (_reviewing) return;
    final request = SnapshotScheduleRequest(
      inventory: inventory,
      action: action,
      task: task,
    );
    final invalid = request.validationError;
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _reviewing = true;
      _reviewReady = false;
      _error = null;
    });
    try {
      await reviewSnapshotScheduleChange(
        context: context,
        ref: ref,
        session: session,
        inventory: inventory,
        request: request,
        onReviewReady: () {
          if (mounted) setState(() => _reviewReady = true);
        },
      );
    } on Object {
      if (mounted &&
          identical(session, ref.read(dashboardActiveSessionProvider))) {
        setState(
          () => _error = 'This schedule could not be reviewed. Reload current inventory and try again. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _reviewing = false);
      if (mounted &&
          _scroll.hasClients &&
          ref.read(snapshotSchedulesControllerProvider).result != null) {
        await _scroll.animateTo(
          0,
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOut,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final caps = ref
        .watch(snapshotSchedulesSessionProvider)
        ?.snapshotSchedulesCapabilities;
    final state = ref.watch(snapshotSchedulesControllerProvider);
    final available = caps?.supported == true && session?.endpoint != null;
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (!identical(previous, next)) {
        setState(() {
          _search = '';
          _error = null;
        });
      }
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('Snapshot schedules'),
        actions: [
          IconButton(
            key: const Key('schedules-refresh'),
            tooltip: 'Reload schedules',
            onPressed: available && !state.locked && !_reviewing
                ? () => ref.invalidate(snapshotSchedulesInventoryProvider)
                : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SnapshotSchedulesWorkspace(
        controller: _scroll,
        children: [
          const Text('AUTOMATIC RECOVERY POINTS', style: TdTypography.micro),
          const SizedBox(height: TdSpacing.related),
          const Text('Snapshot schedules', style: TdTypography.titleLarge),
          const SizedBox(height: TdSpacing.related),
          Text(session?.endpoint ?? 'No authenticated server'),
          const SizedBox(height: TdSpacing.component),
          const SnapshotSchedulesOperationBanner(),
          if (!available)
            TdPanel(
              title: 'Schedules unavailable',
              child: Text(
                caps?.blockedReason ?? 'Connect to a supported TrueNAS server.',
              ),
            )
          else if (state.locked && !state.connectionCurrent)
            const TdPanel(
              title: 'Original operation needs attention',
              child: Text(
                'The previous schedule inventory is hidden. Resolve the original outcome before another change.',
              ),
            )
          else
            ref
                .watch(snapshotSchedulesInventoryProvider)
                .when(
                  skipLoadingOnReload: false,
                  skipLoadingOnRefresh: false,
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, _) => TdPanel(
                    title: 'Schedule inventory unavailable',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'Server details were withheld. This read is not retried automatically.',
                        ),
                        OutlinedButton(
                          onPressed: state.locked
                              ? null
                              : () => ref.invalidate(
                                  snapshotSchedulesInventoryProvider,
                                ),
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),
                  data: (inventory) {
                    final reportedErrors = inventory.tasks
                        .where(
                          (task) => [
                            'ERROR',
                            'FAILED',
                          ].contains(task.state.toUpperCase()),
                        )
                        .length;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _SummaryCounts(
                          total: inventory.tasks.length,
                          errors: reportedErrors,
                        ),
                        const SizedBox(height: TdSpacing.component),
                        SnapshotScheduleEnablementChart(tasks: inventory.tasks),
                        const SizedBox(height: TdSpacing.component),
                        Text('Server timezone: ${inventory.timezone}'),
                        const Text(
                          'Next run is not calculated locally. Reload for server-reported state.',
                        ),
                        const SizedBox(height: TdSpacing.component),
                        TextField(
                          key: const Key('schedules-search'),
                          decoration: const InputDecoration(
                            labelText: 'Find a dataset or task',
                            prefixIcon: Icon(Icons.search_rounded),
                          ),
                          onChanged: (value) =>
                              setState(() => _search = value.toLowerCase()),
                        ),
                        const SizedBox(height: TdSpacing.related),
                        Align(
                          alignment: Alignment.centerLeft,
                          child: FilledButton.icon(
                            key: const Key('schedules-create'),
                            onPressed:
                                !state.locked && !_reviewing && caps!.canCreate
                                ? () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          SnapshotScheduleEditorPage(
                                            session: session!,
                                            inventory: inventory,
                                          ),
                                    ),
                                  )
                                : null,
                            icon: const Icon(Icons.add_rounded),
                            label: const Text('Create schedule'),
                          ),
                        ),
                        if (!caps!.canCreate)
                          const Text(
                            'Schedule creation is unavailable to this connection.',
                          ),
                        const SizedBox(height: TdSpacing.component),
                        if (inventory.tasks.isEmpty)
                          const Text(
                            'No periodic snapshot schedules were returned.',
                          ),
                        for (final task in inventory.tasks.where(
                          (task) => '${task.id} ${task.settings.dataset}'
                              .toLowerCase()
                              .contains(_search),
                        )) ...[
                          TdPanel(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  task.settings.dataset,
                                  style: TdTypography.titleSmall,
                                ),
                                const SizedBox(height: TdSpacing.related),
                                Text(
                                  'Task #${task.id} · ${task.settings.enabled ? 'Enabled' : 'Disabled'} · State: ${task.state}',
                                ),
                                const SizedBox(height: TdSpacing.related),
                                Text(
                                  scheduleCalendar(task.settings.cron).summary,
                                ),
                                Text(
                                  'Window ${task.settings.cron.begin}–${task.settings.cron.end} · ${inventory.timezone}',
                                ),
                                Text(
                                  'Retention: ${task.settings.lifetimeValue} ${task.settings.lifetimeUnit.toLowerCase()}',
                                ),
                                Text(
                                  'Scope: ${task.settings.recursive ? 'Recursive' : 'Selected dataset only'} · ${task.settings.exclude.length} exclusions',
                                ),
                                Text('Naming: ${task.settings.namingSchema}'),
                                if (task.vmwareSync)
                                  const Text(
                                    'VMware synchronization is configured on this task.',
                                  ),
                                if (task.blockedReason != null)
                                  Text(task.blockedReason!),
                                const SizedBox(height: TdSpacing.related),
                                Wrap(
                                  spacing: TdSpacing.related,
                                  runSpacing: TdSpacing.related,
                                  children: [
                                    OutlinedButton.icon(
                                      key: ValueKey('schedule-edit-${task.id}'),
                                      onPressed: !state.locked && !_reviewing
                                          ? () => Navigator.of(context).push(
                                              MaterialPageRoute<void>(
                                                builder: (_) =>
                                                    SnapshotScheduleEditorPage(
                                                      session: session!,
                                                      inventory: inventory,
                                                      task: task,
                                                    ),
                                              ),
                                            )
                                          : null,
                                      icon: const Icon(
                                        Icons.edit_calendar_outlined,
                                      ),
                                      label: const Text('Inspect & edit'),
                                    ),
                                    OutlinedButton.icon(
                                      key: ValueKey('schedule-run-${task.id}'),
                                      onPressed:
                                          !state.locked &&
                                              !_reviewing &&
                                              task.editable &&
                                              task.settings.enabled &&
                                              caps.canRun
                                          ? () => _action(
                                              session!,
                                              inventory,
                                              task,
                                              SnapshotScheduleAction.run,
                                            )
                                          : null,
                                      icon: const Icon(
                                        Icons.play_arrow_rounded,
                                      ),
                                      label: const Text('Review run now'),
                                    ),
                                    TextButton.icon(
                                      key: ValueKey(
                                        'schedule-delete-${task.id}',
                                      ),
                                      onPressed:
                                          !state.locked &&
                                              !_reviewing &&
                                              task.editable &&
                                              caps.canDelete
                                          ? () => _action(
                                              session!,
                                              inventory,
                                              task,
                                              SnapshotScheduleAction.delete,
                                            )
                                          : null,
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                      ),
                                      label: const Text('Review deletion'),
                                    ),
                                  ],
                                ),
                                if (!caps.canRun)
                                  const Text(
                                    'Running tasks is unavailable to this connection.',
                                  ),
                                if (!task.settings.enabled)
                                  const Text(
                                    'Run now is unavailable until this task is enabled in a separate reviewed change.',
                                  ),
                                if (!caps.canDelete)
                                  const Text(
                                    'Schedule deletion is unavailable to this connection.',
                                  ),
                              ],
                            ),
                          ),
                          const SizedBox(height: TdSpacing.component),
                        ],
                      ],
                    );
                  },
                ),
          if (_reviewing && !_reviewReady) const LinearProgressIndicator(),
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: context.tdTheme.statusCritical),
            ),
          const SizedBox(height: TdSpacing.component),
          const Text(
            'Snapshots are recovery points, not independent backups. Scheduling does not guarantee application-consistent data. Retention and matching naming patterns can affect later snapshot expiry.',
          ),
        ],
      ),
    );
  }
}

class _SummaryCounts extends StatelessWidget {
  const _SummaryCounts({required this.total, required this.errors});
  final int total, errors;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    key: const Key('schedule-summary-counts'),
    builder: (context, constraints) {
      final textScale = MediaQuery.textScalerOf(context).scale(15) / 15;
      final horizontal =
          constraints.maxWidth >= 296 * textScale + TdSpacing.related;
      final totalCard = _Count(
        key: const Key('schedule-summary-total'),
        label: 'Schedules',
        value: total,
      );
      final errorCard = _Count(
        key: const Key('schedule-summary-errors'),
        label: 'Reported errors',
        value: errors,
      );
      if (!horizontal) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            totalCard,
            const SizedBox(height: TdSpacing.related),
            errorCard,
          ],
        );
      }
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: totalCard),
            const SizedBox(width: TdSpacing.related),
            Expanded(child: errorCard),
          ],
        ),
      );
    },
  );
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value, super.key});
  final String label;
  final int value;
  @override
  Widget build(BuildContext context) => TdPanel(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$value', style: TdTypography.titleLarge),
        const SizedBox(height: TdSpacing.inline),
        Text(label),
      ],
    ),
  );
}

class SnapshotSchedulesOperationBanner extends ConsumerStatefulWidget {
  const SnapshotSchedulesOperationBanner({super.key});
  @override
  ConsumerState<SnapshotSchedulesOperationBanner> createState() =>
      _SnapshotSchedulesOperationBannerState();
}

class _SnapshotSchedulesOperationBannerState
    extends ConsumerState<SnapshotSchedulesOperationBanner> {
  bool _acknowledged = false;
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(snapshotSchedulesControllerProvider);
    ref.watch(dashboardActiveSessionProvider);
    if (!state.busy && state.result == null && state.recoveryMessage == null) {
      return const SizedBox.shrink();
    }
    final controller = ref.read(snapshotSchedulesControllerProvider.notifier);
    return Padding(
      padding: const EdgeInsets.only(bottom: TdSpacing.component),
      child: TdPanel(
        title: state.busy
            ? 'Submitting once'
            : switch (state.result?.outcome) {
                SnapshotScheduleOutcome.verified => 'Schedule change verified',
                SnapshotScheduleOutcome.accepted => 'Run request accepted',
                SnapshotScheduleOutcome.rejected => 'Change not submitted',
                SnapshotScheduleOutcome.unknown => 'Outcome needs verification',
                null => 'Prior completion remains unverified',
              },
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (state.server != null)
                Text('Original server: ${state.server}'),
              if (state.target != null)
                Text('Original target: ${state.target}'),
              if (state.busy) const LinearProgressIndicator(),
              if (state.result != null) Text(state.result!.message),
              if (state.result?.outcome == SnapshotScheduleOutcome.accepted)
                const Text(
                  'The server queued this run. Snapshot creation and completion have not been verified. No completion estimate or background poll is shown.',
                ),
              if (state.recoveryMessage != null) Text(state.recoveryMessage!),
              if (controller.canAcknowledge) ...[
                CheckboxListTile(
                  key: const Key('schedules-reconnect-ack'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _acknowledged,
                  onChanged: (value) =>
                      setState(() => _acknowledged = value ?? false),
                  title: const Text(
                    'I independently inspected the original schedule and affected snapshots. I understand the prior outcome is still unverified in this app.',
                  ),
                ),
                OutlinedButton(
                  key: const Key('schedules-reconnect-release'),
                  onPressed: _acknowledged
                      ? () {
                          controller.acknowledgeAfterReconnect();
                          setState(() => _acknowledged = false);
                        }
                      : null,
                  child: const Text('Reload after reconnect'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class SnapshotSchedulesWorkspace extends StatelessWidget {
  const SnapshotSchedulesWorkspace({
    required this.children,
    this.controller,
    super.key,
  });
  final List<Widget> children;
  final ScrollController? controller;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1050),
        child: ListView(
          controller: controller,
          padding: const EdgeInsets.all(TdSpacing.component),
          children: children,
        ),
      ),
    ),
  );
}

SnapshotCalendarValue scheduleCalendar(SnapshotScheduleCron cron) =>
    SnapshotCalendarValue(
      minute: cron.minute,
      hour: cron.hour,
      dayOfMonth: cron.dom,
      month: cron.month,
      dayOfWeek: cron.dow,
    );
