import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'rsync_charts.dart';
import 'rsync_controller.dart';
import 'rsync_editor.dart';
import 'rsync_labels.dart';
import 'rsync_review.dart';

class RsyncPage extends ConsumerStatefulWidget {
  const RsyncPage({super.key});
  @override
  ConsumerState<RsyncPage> createState() => _RsyncPageState();
}

class _RsyncPageState extends ConsumerState<RsyncPage> {
  bool _reviewing = false;
  String? _error;
  Future<void> _change(
    AuthenticatedSession session,
    RsyncRequest intent,
  ) async {
    if (_reviewing ||
        !ref.read(rsyncControllerProvider.notifier).allowsRequest(intent)) {
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
    final inventoryWatch = ref.listenManual(rsyncInventoryProvider, (_, b) {
      if (b.isLoading || !identical(intent.inventory, b.asData?.value)) {
        expired = true;
      }
    });
    bool current() =>
        mounted &&
        !expired &&
        identical(session, ref.read(dashboardActiveSessionProvider)) &&
        !ref.read(rsyncInventoryProvider).isLoading &&
        identical(
          intent.inventory,
          ref.read(rsyncInventoryProvider).asData?.value,
        );
    try {
      if (!current()) return;
      var request = intent;
      if (intent.action == RsyncAction.create ||
          intent.action == RsyncAction.update) {
        final edited = await showDialog<RsyncRequest>(
          context: context,
          barrierDismissible: false,
          builder: (_) => RsyncEditor(
            session: session,
            inventory: intent.inventory,
            task: intent.task,
          ),
        );
        if (edited == null || !current()) return;
        request = edited;
      }
      if (!current() || request.validationError != null) return;
      final api = ref.read(rsyncSessionProvider);
      if (api == null) return;
      final review = await api.reviewRsync(request);
      if (!mounted || !current()) return;
      if (!identical(review.request, request) ||
          review.endpoint != session.endpoint) {
        throw StateError('Mismatching Rsync intent');
      }
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => RsyncReviewDialog(session: session, review: review),
      );
      if (confirmed != true || !current()) return;
      await ref
          .read(rsyncControllerProvider.notifier)
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
        api = ref.watch(rsyncSessionProvider);
    final state = ref.watch(rsyncControllerProvider),
        controller = ref.read(rsyncControllerProvider.notifier);
    final caps = api?.rsyncCapabilities;
    final available = session?.endpoint != null && caps?.supported == true;
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) setState(() => _error = null);
    });
    final canRefresh =
        available && !state.busy && !state.unknown && !_reviewing;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Rsync'),
        actions: [
          IconButton(
            key: const Key('rsync-refresh'),
            tooltip: 'Read current Rsync tasks',
            onPressed: canRefresh
                ? () => ref.invalidate(rsyncInventoryProvider)
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SingleChildScrollView(
        key: const Key('rsync-scroll'),
        padding: const EdgeInsets.all(20),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'DATA PROTECTION · RSYNC',
                  style: TdTypography.micro,
                ),
                const SizedBox(height: 8),
                const Text(
                  'File transfers & schedules',
                  style: TdTypography.titleLarge,
                ),
                const SizedBox(height: 12),
                Text(session?.endpoint ?? 'No authenticated connection'),
                const Text(
                  'Last-read configuration and recorded job metadata. No automatic polling, remote probing, host-key scanning or transfer. An enabled schedule is not a running task; reported success does not establish matching contents or recoverability.',
                ),
                const SizedBox(height: 16),
                if (state.busy) const LinearProgressIndicator(),
                if (state.result case final result?)
                  TdPanel(
                    title: state.unknown
                        ? 'Verify before continuing'
                        : state.pendingJob
                        ? 'Owned transfer needs verification'
                        : 'Last Rsync operation',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(result.message),
                        if (state.pendingJob && state.connectionCurrent) ...[
                          Text(
                            'Job ${state.job!.id} · Run transfer once · Task ${state.job!.taskId}',
                          ),
                          const Text(
                            'All other writes remain locked. Check this issued job explicitly; inventory refresh does not release its lock. There is no automatic retry, cancel or polling.',
                          ),
                          OutlinedButton(
                            key: const Key('rsync-check-job'),
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
                            key: const Key('rsync-acknowledge'),
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
                    title: 'Rsync unavailable',
                    child: Text(
                      caps?.blockedReason ??
                          'Connect to a supported TrueNAS instance.',
                    ),
                  )
                else if (state.locked && !state.connectionCurrent)
                  const TdPanel(
                    title: 'Original operation needs attention',
                    child: Text(
                      'Previous task and destination details are hidden. Verify the original server before continuing.',
                    ),
                  )
                else
                  ref
                      .watch(rsyncInventoryProvider)
                      .when(
                        skipLoadingOnRefresh: false,
                        skipLoadingOnReload: false,
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (_, _) => TdPanel(
                          title: 'Rsync inventory unavailable',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Task, public SSH identity, local dataset or job metadata could not be verified. Remote details were withheld. Unknown is not an empty or successful inventory.',
                              ),
                              OutlinedButton(
                                key: const Key('rsync-retry'),
                                onPressed: canRefresh
                                    ? () =>
                                          ref.invalidate(rsyncInventoryProvider)
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
                            const SizedBox(height: 12),
                            RsyncConfigurationChart(
                              enabled: inventory.tasks
                                  .where((t) => t.enabled)
                                  .length,
                              disabled: inventory.tasks
                                  .where((t) => !t.enabled)
                                  .length,
                            ),
                            const SizedBox(height: 16),
                            RsyncReportedStates(
                              states: {
                                for (final state in RsyncReportedState.values)
                                  state: inventory.tasks
                                      .where(
                                        (t) =>
                                            _reported(t.lastJobState) == state,
                                      )
                                      .length,
                              },
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              key: const Key('rsync-create'),
                              onPressed:
                                  !_reviewing &&
                                      !state.locked &&
                                      caps!.allows(RsyncAction.create) &&
                                      inventory.blockedReason == null &&
                                      inventory.tasks.length < 128 &&
                                      inventory.connections.isNotEmpty &&
                                      inventory.users.isNotEmpty &&
                                      inventory.datasets.any(
                                        (d) => d.blockedReason == null,
                                      )
                                  ? () => _change(
                                      session!,
                                      RsyncRequest(
                                        inventory: inventory,
                                        action: RsyncAction.create,
                                      ),
                                    )
                                  : null,
                              child: const Text('Create disabled task'),
                            ),
                            if (inventory.tasks.isEmpty)
                              const Padding(
                                padding: EdgeInsets.only(top: 16),
                                child: TdPanel(
                                  title: 'No Rsync tasks',
                                  child: Text(
                                    'No task was reported in this inventory. No destination is inferred.',
                                  ),
                                ),
                              ),
                            for (final task in inventory.tasks)
                              Padding(
                                padding: const EdgeInsets.only(top: 16),
                                child: TdPanel(
                                  title: 'Task ${task.id}',
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      if (task.description.isNotEmpty)
                                        Text(task.description),
                                      Text(
                                        '${_mode(task.mode)} · ${_direction(task.direction)} · ${task.enabled ? 'Schedule enabled' : 'Schedule disabled'}',
                                      ),
                                      Text(
                                        'Dataset locked: ${task.locked ? 'Yes' : 'No'}',
                                      ),
                                      Text(
                                        'Last recorded state: ${_reported(task.lastJobState).label} (may be stale)',
                                      ),
                                      if (task.supported &&
                                          task.settings != null) ...[
                                        Text(
                                          'Local dataset: ${task.settings!.path}',
                                        ),
                                        Text(
                                          'Local user: ${task.settings!.user}',
                                        ),
                                        Text(
                                          'Cross-filesystem protection: ${task.crossFilesystemProtection ? 'Configured' : 'Edit to configure before running or enabling'}',
                                        ),
                                        Text(
                                          'SSH connection ID: ${task.settings!.connectionId}',
                                        ),
                                        for (final c
                                            in inventory.connections.where(
                                              (c) =>
                                                  c.id ==
                                                  task.settings!.connectionId,
                                            ))
                                          Text(
                                            'Destination: ${c.destination} · ${task.settings!.remotePath}',
                                          ),
                                        Text(
                                          'Schedule: ${task.settings!.cron.expression} · ${inventory.timezone}',
                                        ),
                                      ] else
                                        Text(
                                          task.blockedReason ?? 'Unsupported or dataset-locked configuration. Details and actions remain restricted.',
                                        ),
                                      const SizedBox(height: 12),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          for (final action in [
                                            RsyncAction.update,
                                            task.enabled
                                                ? RsyncAction.disable
                                                : RsyncAction.enable,
                                            RsyncAction.run,
                                            RsyncAction.delete,
                                          ])
                                            OutlinedButton(
                                              key: Key(
                                                'rsync-${action.name}-${task.id}',
                                              ),
                                              onPressed:
                                                  !_reviewing &&
                                                      !state.locked &&
                                                      caps!.allows(action) &&
                                                      task.supported &&
                                                      inventory.blockedReason ==
                                                          null &&
                                                      (action ==
                                                              RsyncAction.update
                                                          ? !task.enabled
                                                          : RsyncRequest(
                                                                  inventory:
                                                                      inventory,
                                                                  action:
                                                                      action,
                                                                  task: task,
                                                                ).validationError ==
                                                                null)
                                                  ? () => _change(
                                                      session!,
                                                      RsyncRequest(
                                                        inventory: inventory,
                                                        action: action,
                                                        task: task,
                                                      ),
                                                    )
                                                  : null,
                                              child: Text(
                                                rsyncActionLabel(action),
                                              ),
                                            ),
                                        ],
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            const SizedBox(height: 16),
                            const Text(
                              'Bounded native scope: dedicated local leaf dataset → SSH keychain connection, PUSH only. MODULE, PULL, home-directory keys, raw options, remote probes, key scans and log excerpts require the TrueNAS web workflow. Disabling or deleting a schedule does not stop an active transfer.',
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
}

RsyncReportedState _reported(String? state) => switch (state) {
  'SUCCESS' => RsyncReportedState.succeeded,
  'FAILED' => RsyncReportedState.failed,
  'ABORTED' => RsyncReportedState.aborted,
  'RUNNING' => RsyncReportedState.running,
  'WAITING' => RsyncReportedState.waiting,
  _ => RsyncReportedState.unknown,
};
String _mode(String value) => switch (value) {
  'SSH' => 'SSH',
  'MODULE' => 'Module',
  _ => 'Unsupported mode',
};
String _direction(String value) => switch (value) {
  'PUSH' => 'Push to remote',
  'PULL' => 'Pull from remote',
  _ => 'Unsupported direction',
};
