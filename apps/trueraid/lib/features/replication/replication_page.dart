import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'replication_controller.dart';
import 'replication_editor.dart';
import 'replication_review.dart';

class ReplicationPage extends ConsumerStatefulWidget {
  const ReplicationPage({super.key});
  @override
  ConsumerState<ReplicationPage> createState() => _ReplicationPageState();
}

class _ReplicationPageState extends ConsumerState<ReplicationPage> {
  final _scroll = ScrollController();
  bool _reviewing = false;
  String? _error;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _change(
    AuthenticatedSession session,
    ReplicationInventory inventory,
    ReplicationAction action, [
    ReplicationTask? task,
  ]) async {
    if (_reviewing) return;
    setState(() {
      _reviewing = true;
      _error = null;
    });
    // Once a connection or inventory changes, a formerly open form cannot be revived.
    var expired = false;
    final connection = ref.listenManual(dashboardActiveSessionProvider, (
      previous,
      next,
    ) {
      if (!identical(previous, next)) expired = true;
    });
    final observation = ref.listenManual(replicationInventoryProvider, (
      _,
      next,
    ) {
      if (next.isLoading || !identical(next.asData?.value, inventory)) {
        expired = true;
      }
    });
    try {
      ReplicationSettings? settings;
      if (action == ReplicationAction.create ||
          action == ReplicationAction.update) {
        settings = await showDialog<ReplicationSettings>(
          context: context,
          barrierDismissible: false,
          builder: (_) => ReplicationEditorDialog(
            session: session,
            inventory: inventory,
            task: task,
          ),
        );
        if (settings == null) return;
      }
      if (!mounted ||
          expired ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          !identical(
            inventory,
            ref.read(replicationInventoryProvider).asData?.value,
          )) {
        return;
      }
      final request = ReplicationRequest(
        inventory: inventory,
        action: action,
        task: task,
        settings: settings,
      );
      if (request.validationError case final error?) {
        setState(() => _error = error);
        return;
      }
      await reviewReplicationChange(
        context: context,
        ref: ref,
        session: session,
        request: request,
      );
    } on Object {
      if (mounted &&
          !expired &&
          identical(session, ref.read(dashboardActiveSessionProvider))) {
        setState(
          () => _error = 'This task could not be reviewed safely. Nothing was submitted. Reload the inventory.',
        );
      }
    } finally {
      connection.close();
      observation.close();
      if (mounted) {
        setState(() => _reviewing = false);
        if (_scroll.hasClients &&
            (ref.read(replicationControllerProvider).result != null ||
                _error != null)) {
          _scroll.jumpTo(0);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final caps = ref.watch(replicationSessionProvider)?.replicationCapabilities;
    final state = ref.watch(replicationControllerProvider);
    final available = session?.endpoint != null && caps?.supported == true;
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (!identical(previous, next)) setState(() => _error = null);
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('Replication'),
        actions: [
          IconButton(
            key: const Key('replication-refresh'),
            tooltip: 'Reload replication inventory',
            onPressed: available && !state.locked && !_reviewing
                ? () => ref.invalidate(replicationInventoryProvider)
                : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SingleChildScrollView(
        key: const Key('replication-workspace-scroll'),
        controller: _scroll,
        padding: const EdgeInsets.all(TdSpacing.component),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('DATA PROTECTION', style: TdTypography.micro),
                const SizedBox(height: TdSpacing.related),
                const Text('Replication', style: TdTypography.titleLarge),
                const SizedBox(height: TdSpacing.related),
                Text(session?.endpoint ?? 'No authenticated connection'),
                const SizedBox(height: TdSpacing.component),
                const ReplicationOperationBanner(),
                if (_error case final error?)
                  Padding(
                    padding: const EdgeInsets.only(bottom: TdSpacing.related),
                    child: Text(error),
                  ),
                if (!available)
                  TdPanel(
                    title: 'Replication unavailable',
                    child: Text(
                      caps?.blockedReason ??
                          'Connect to a supported TrueNAS instance.',
                    ),
                  )
                else if (state.locked && !state.connectionCurrent)
                  const TdPanel(
                    title: 'Original task needs attention',
                    child: Text(
                      'Previous task details are hidden. Verify the original server before acknowledging this operation.',
                    ),
                  )
                else
                  ref
                      .watch(replicationInventoryProvider)
                      .when(
                        skipLoadingOnRefresh: false,
                        skipLoadingOnReload: false,
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (_, _) => TdPanel(
                          title: 'Replication information unavailable',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Remote details were withheld. Reads are not automatically retried.',
                              ),
                              OutlinedButton(
                                key: const Key('replication-retry'),
                                onPressed: state.locked || _reviewing
                                    ? null
                                    : () => ref.invalidate(
                                        replicationInventoryProvider,
                                      ),
                                child: const Text('Retry inventory read'),
                              ),
                            ],
                          ),
                        ),
                        data: (inventory) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            ReplicationSummary(inventory: inventory),
                            const SizedBox(height: TdSpacing.component),
                            const Text(
                              'Create and manage local, single-source, manual PUSH tasks. Remote, recursive, scheduled and other advanced tasks remain visible but require the advanced TrueNAS workflow. No transfer rate or backup-health estimate is inferred from task counts.',
                            ),
                            const SizedBox(height: TdSpacing.related),
                            if (!caps!.canCreate ||
                                !caps.canUpdate ||
                                !caps.canDelete ||
                                !caps.canRun)
                              const Text(
                                'Some actions are unavailable because required public methods or permissions are missing. Disabled actions send nothing.',
                              ),
                            if (inventory.conflictingJob)
                              const Text(
                                'A storage or replication job is active. Changes are blocked until its outcome is known.',
                              ),
                            Align(
                              alignment: Alignment.centerLeft,
                              child: FilledButton.icon(
                                key: const Key('replication-create'),
                                icon: const Icon(Icons.add_rounded),
                                label: const Text('Create local task'),
                                onPressed:
                                    !state.locked &&
                                        !_reviewing &&
                                        caps.canCreate &&
                                        !inventory.conflictingJob
                                    ? () => _change(
                                        session!,
                                        inventory,
                                        ReplicationAction.create,
                                      )
                                    : null,
                              ),
                            ),
                            const SizedBox(height: TdSpacing.component),
                            if (inventory.tasks.isEmpty)
                              const TdPanel(
                                title: 'No replication tasks',
                                child: Text(
                                  'Choose a source and a dedicated destination to prepare a manual task. Nothing is selected or started automatically.',
                                ),
                              ),
                            for (final task in inventory.tasks)
                              Padding(
                                padding: const EdgeInsets.only(
                                  bottom: TdSpacing.related,
                                ),
                                child: _TaskCard(
                                  task: task,
                                  inventory: inventory,
                                  caps: caps,
                                  enabled:
                                      !state.locked &&
                                      !_reviewing &&
                                      !inventory.conflictingJob,
                                  onAction: (action) => _change(
                                    session!,
                                    inventory,
                                    action,
                                    task,
                                  ),
                                ),
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

class ReplicationSummary extends StatelessWidget {
  const ReplicationSummary({required this.inventory, super.key});
  final ReplicationInventory inventory;
  @override
  Widget build(BuildContext context) {
    final enabled = inventory.tasks.where((task) => task.enabled).length;
    final native = inventory.tasks.where((task) => task.available).length;
    final counts = <String, int>{};
    for (final task in inventory.tasks) {
      counts.update(task.state, (n) => n + 1, ifAbsent: () => 1);
    }
    return TdPanel(
      title: 'Task overview',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final chart = Semantics(
            label:
                '${inventory.tasks.length} tasks: $enabled enabled, ${inventory.tasks.length - enabled} disabled.',
            child: SizedBox(
              width: 136,
              height: 136,
              child: CustomPaint(
                key: const Key('replication-enablement-donut'),
                painter: _EnablementPainter(
                  enabled: enabled,
                  total: inventory.tasks.length,
                  color: Theme.of(context).colorScheme.primary,
                  track: Theme.of(context).colorScheme.surfaceContainerHighest,
                ),
                child: Center(
                  child: Text(
                    '${inventory.tasks.length}',
                    style: TdTypography.titleLarge,
                  ),
                ),
              ),
            ),
          );
          final legend = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '$enabled enabled · ${inventory.tasks.length - enabled} disabled',
              ),
              const SizedBox(height: TdSpacing.related),
              Wrap(
                spacing: TdSpacing.component,
                runSpacing: TdSpacing.related,
                children: [
                  _EnablementLegendEntry(
                    label: 'Enabled',
                    color: Theme.of(context).colorScheme.primary,
                    swatchKey: const Key('replication-enabled-swatch'),
                  ),
                  _EnablementLegendEntry(
                    label: 'Disabled',
                    color: Theme.of(context)
                        .colorScheme
                        .surfaceContainerHighest,
                    swatchKey: const Key('replication-disabled-swatch'),
                  ),
                ],
              ),
              const SizedBox(height: TdSpacing.related),
              Text(
                '$native native-editable · ${inventory.tasks.length - native} advanced',
              ),
              Text(
                '${inventory.datasets.where((d) => d.available).length} available datasets',
              ),
              const SizedBox(height: TdSpacing.related),
              const Text(
                'Server-reported task states',
                style: TdTypography.label,
              ),
              if (counts.isEmpty) const Text('No task states'),
              Wrap(
                spacing: TdSpacing.related,
                runSpacing: TdSpacing.related,
                children: [
                  for (final entry in counts.entries)
                    Text('${entry.key}: ${entry.value}'),
                ],
              ),
            ],
          );
          return constraints.maxWidth < 540 ||
                  MediaQuery.textScalerOf(context).scale(16) > 24
              ? Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    chart,
                    const SizedBox(height: TdSpacing.component),
                    legend,
                  ],
                )
              : Row(
                  children: [
                    chart,
                    const SizedBox(width: TdSpacing.component),
                    Expanded(child: legend),
                  ],
                );
        },
      ),
    );
  }
}

class _EnablementLegendEntry extends StatelessWidget {
  const _EnablementLegendEntry({
    required this.label,
    required this.color,
    required this.swatchKey,
  });
  final String label;
  final Color color;
  final Key swatchKey;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ExcludeSemantics(
        child: SizedBox.square(
          dimension: 12,
          child: DecoratedBox(
            key: swatchKey,
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          ),
        ),
      ),
      const SizedBox(width: TdSpacing.related),
      Flexible(child: Text(label)),
    ],
  );
}

class _EnablementPainter extends CustomPainter {
  const _EnablementPainter({
    required this.enabled,
    required this.total,
    required this.color,
    required this.track,
  });
  final int enabled, total;
  final Color color, track;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..color = track;
    canvas.drawOval(rect.deflate(10), paint);
    if (total > 0 && enabled > 0) {
      paint.color = color;
      canvas.drawArc(
        rect.deflate(10),
        -math.pi / 2,
        math.pi * 2 * enabled / total,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EnablementPainter old) =>
      old.enabled != enabled ||
      old.total != total ||
      old.color != color ||
      old.track != track;
}

class _TaskCard extends StatelessWidget {
  const _TaskCard({
    required this.task,
    required this.inventory,
    required this.caps,
    required this.enabled,
    required this.onAction,
  });
  final ReplicationTask task;
  final ReplicationInventory inventory;
  final ReplicationCapabilities caps;
  final bool enabled;
  final ValueChanged<ReplicationAction> onAction;
  @override
  Widget build(BuildContext context) => TdPanel(
    title: task.name,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${task.transport} · ${task.direction} · ${task.enabled ? 'Enabled' : 'Disabled'} · ${task.state}',
        ),
        Text('Source: ${task.source}'),
        Text('Destination: ${task.destination}'),
        if (task.settings case final settings?)
          Text('Retention: ${settings.retention} · ${settings.namingSchema}'),
        if (!task.available)
          Text(
            task.blockedReason ??
                'Advanced task: inspect and manage it in TrueNAS.',
          ),
        const SizedBox(height: TdSpacing.related),
        Wrap(
          spacing: TdSpacing.related,
          runSpacing: TdSpacing.related,
          children: [
            for (final action in [
              ReplicationAction.update,
              task.enabled
                  ? ReplicationAction.disable
                  : ReplicationAction.enable,
              ReplicationAction.run,
              ReplicationAction.delete,
            ])
              OutlinedButton(
                key: Key('replication-${action.name}-${task.id}'),
                onPressed:
                    enabled &&
                        task.available &&
                        caps.supports(action) &&
                        (action != ReplicationAction.run || task.enabled)
                    ? () => onAction(action)
                    : null,
                child: Text(switch (action) {
                  ReplicationAction.update => 'Edit',
                  ReplicationAction.enable => 'Enable',
                  ReplicationAction.disable => 'Disable',
                  ReplicationAction.run => 'Review run',
                  ReplicationAction.delete => 'Delete task',
                  _ => action.name,
                }),
              ),
          ],
        ),
      ],
    ),
  );
}

class ReplicationOperationBanner extends ConsumerWidget {
  const ReplicationOperationBanner({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(replicationControllerProvider);
    final controller = ref.read(replicationControllerProvider.notifier);
    if (state.result == null && !state.busy && state.recoveryMessage == null) {
      return const SizedBox.shrink();
    }
    final percent = state.result?.percent;
    return Padding(
      padding: const EdgeInsets.only(bottom: TdSpacing.component),
      child: TdPanel(
        title: state.busy
            ? 'Verifying replication operation'
            : state.unknown
            ? 'Outcome needs verification'
            : state.pending
            ? 'Replication job pending'
            : 'Replication result',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.server case final server?)
              Text('Original server: $server'),
            if (state.target case final target?) Text('Exact target: $target'),
            if (state.result case final result?) Text(result.message),
            if (state.recoveryMessage case final message?) Text(message),
            if (percent != null &&
                percent.isFinite &&
                percent >= 0 &&
                percent <= 100) ...[
              const SizedBox(height: TdSpacing.related),
              LinearProgressIndicator(value: percent / 100),
              Text(
                'Server-reported job progress: ${percent.toStringAsFixed(1)}%',
              ),
            ],
            if (state.locked)
              const Text(
                'No automatic job polling or replay. Other changes stay locked while this outcome is unresolved.',
              ),
            if (controller.canPoll)
              OutlinedButton(
                key: const Key('replication-poll'),
                onPressed: controller.poll,
                child: const Text('Check owned job once'),
              ),
            if (controller.canAcknowledge)
              OutlinedButton(
                key: const Key('replication-acknowledge'),
                onPressed: controller.acknowledgeAfterReconnect,
                child: const Text('Acknowledge after independent verification'),
              ),
          ],
        ),
      ),
    );
  }
}
