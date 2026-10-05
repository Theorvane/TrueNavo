import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'cloud_sync_controller.dart';
import 'cloud_sync_editor.dart';
import 'cloud_sync_review.dart';

class CloudSyncPage extends ConsumerStatefulWidget {
  const CloudSyncPage({super.key});
  @override
  ConsumerState<CloudSyncPage> createState() => _CloudSyncPageState();
}

class _CloudSyncPageState extends ConsumerState<CloudSyncPage> {
  bool _reviewing = false;
  String? _error;
  String _filter = '';
  Future<void> _change(
    AuthenticatedSession session,
    CloudSyncInventory inventory,
    CloudSyncAction action, [
    CloudSyncTask? task,
  ]) async {
    if (_reviewing) return;
    setState(() {
      _reviewing = true;
      _error = null;
    });
    var expired = false;
    final watch = ref.listenManual(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) expired = true;
    });
    final inventoryWatch = ref.listenManual(cloudSyncInventoryProvider, (_, b) {
      if (b.isLoading || !identical(inventory, b.asData?.value)) expired = true;
    });
    try {
      CloudSyncSettings? settings;
      if (action == CloudSyncAction.create ||
          action == CloudSyncAction.update) {
        settings = await showDialog<CloudSyncSettings>(
          context: context,
          barrierDismissible: false,
          builder: (_) => CloudSyncEditor(
            inventory: inventory,
            session: session,
            task: task,
          ),
        );
        if (settings == null) return;
      }
      if (!mounted ||
          expired ||
          !identical(session, ref.read(dashboardActiveSessionProvider))) {
        return;
      }
      await reviewCloudSyncChange(
        context: context,
        ref: ref,
        session: session,
        request: CloudSyncRequest(
          inventory: inventory,
          action: action,
          task: task,
          settings: settings,
        ),
      );
    } on Object {
      if (mounted && !expired) {
        setState(
          () => _error = 'This operation could not be reviewed safely. Nothing was submitted. Reload cloud sync information.',
        );
      }
    } finally {
      watch.close();
      inventoryWatch.close();
      if (mounted) setState(() => _reviewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider),
        api = ref.watch(cloudSyncSessionProvider),
        state = ref.watch(cloudSyncControllerProvider),
        controller = ref.read(cloudSyncControllerProvider.notifier);
    final caps = api?.cloudSyncCapabilities;
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) {
        setState(() {
          _error = null;
          _filter = '';
        });
      }
    });
    final available = session?.endpoint != null && caps?.supported == true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Cloud sync'),
        actions: [
          IconButton(
            key: const Key('cloud-sync-refresh'),
            tooltip: 'Reload local cloud sync information',
            onPressed: available && !state.locked && !_reviewing
                ? () => ref.invalidate(cloudSyncInventoryProvider)
                : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SingleChildScrollView(
        key: const Key('cloud-sync-workspace-scroll'),
        padding: const EdgeInsets.all(20),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('DATA PROTECTION', style: TdTypography.micro),
                const SizedBox(height: 8),
                const Text('Cloud sync', style: TdTypography.titleLarge),
                const SizedBox(height: 8),
                const Text(
                  'Review transfers, schedules and both endpoints. Local inventory does not list remote files or verify credentials.',
                ),
                const SizedBox(height: 20),
                if (state.result case final result?)
                  TdPanel(
                    title: 'Operation · ${result.outcome.name}',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(result.message),
                        if (result.percent != null) ...[
                          const SizedBox(height: 8),
                          LinearProgressIndicator(value: result.percent! / 100),
                          Text(
                            '${result.percent!.toStringAsFixed(0)}% · server-reported',
                          ),
                        ],
                        if (controller.canPoll)
                          TextButton(
                            key: const Key('cloud-sync-poll'),
                            onPressed: controller.poll,
                            child: const Text('Check owned job progress'),
                          ),
                        if (controller.canAcknowledge)
                          TextButton(
                            onPressed: controller.acknowledgeAfterReconnect,
                            child: const Text(
                              'I inspected the original server; reload',
                            ),
                          ),
                      ],
                    ),
                  ),
                if (_error != null) Text(_error!),
                if (!available)
                  TdPanel(
                    title: 'Cloud sync unavailable',
                    child: Text(
                      caps?.blockedReason ??
                          'Connect to inspect cloud sync tasks.',
                    ),
                  )
                else
                  ref
                      .watch(cloudSyncInventoryProvider)
                      .when(
                        skipLoadingOnRefresh: false,
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (_, _) => const TdPanel(
                          title: 'Information unavailable',
                          child: Text(
                            'Cloud sync inventory could not be validated. Remote details were withheld. Reload manually.',
                          ),
                        ),
                        data: (inventory) {
                          final visible = inventory.tasks
                              .where(
                                (t) =>
                                    '${t.id} ${t.settings.description} ${t.settings.path} ${t.provider}'
                                        .toLowerCase()
                                        .contains(_filter.toLowerCase()),
                              )
                              .toList();
                          final locked =
                              state.locked ||
                              _reviewing ||
                              inventory.conflictingJob;
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              CloudSyncChart(tasks: inventory.tasks),
                              const SizedBox(height: 20),
                              TdPanel(
                                title: 'Tasks · ${inventory.tasks.length}',
                                description:
                                    'Timezone ${inventory.timezone}. Scheduled enablement is not backup health.',
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (inventory.conflictingJob)
                                      const Text(
                                        'A cloud sync or conflicting storage job is active. Native changes are blocked.',
                                      ),
                                    TextField(
                                      key: const Key('cloud-sync-filter'),
                                      decoration: const InputDecoration(
                                        labelText: 'Filter tasks',
                                        prefixIcon: Icon(Icons.search),
                                      ),
                                      onChanged: (v) =>
                                          setState(() => _filter = v),
                                    ),
                                    const SizedBox(height: 12),
                                    Align(
                                      alignment: Alignment.centerLeft,
                                      child: FilledButton.icon(
                                        key: const Key('cloud-sync-create'),
                                        onPressed: !locked && caps!.canCreate
                                            ? () => _change(
                                                session!,
                                                inventory,
                                                CloudSyncAction.create,
                                              )
                                            : null,
                                        icon: const Icon(Icons.add),
                                        label: const Text('Create task'),
                                      ),
                                    ),
                                    if (visible.isEmpty)
                                      const Padding(
                                        padding: EdgeInsets.only(top: 16),
                                        child: Text(
                                          'No matching cloud sync tasks.',
                                        ),
                                      ),
                                    for (final task in visible)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 16),
                                        child: Card(
                                          child: Padding(
                                            padding: const EdgeInsets.all(16),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.stretch,
                                              children: [
                                                Text(
                                                  task
                                                          .settings
                                                          .description
                                                          .isEmpty
                                                      ? 'Task #${task.id}'
                                                      : task
                                                            .settings
                                                            .description,
                                                  style:
                                                      TdTypography.titleSmall,
                                                ),
                                                Text(
                                                  '#${task.id} · ${task.provider} · ${task.state}',
                                                ),
                                                Text(
                                                  '${task.settings.direction} ${task.settings.transferMode} · ${task.settings.enabled ? 'Scheduled' : 'Disabled'}',
                                                ),
                                                Text(task.settings.path),
                                                Text(
                                                  'Remote: ${task.settings.bucket.isEmpty ? '' : '${task.settings.bucket}/'}${task.settings.folder}',
                                                ),
                                                Text(
                                                  'Cron: ${task.settings.minute} ${task.settings.hour} ${task.settings.dom} ${task.settings.month} ${task.settings.dow}',
                                                ),
                                                if (task.blockedReason != null)
                                                  Text(task.blockedReason!),
                                                Wrap(
                                                  spacing: 8,
                                                  runSpacing: 8,
                                                  children: [
                                                    for (final action in [
                                                      CloudSyncAction.update,
                                                      CloudSyncAction.run,
                                                      CloudSyncAction.delete,
                                                    ])
                                                      TextButton(
                                                        key: Key(
                                                          'cloud-sync-${action.name}-${task.id}',
                                                        ),
                                                        onPressed:
                                                            !locked &&
                                                                task.blockedReason ==
                                                                    null &&
                                                                caps!.allows(
                                                                  action,
                                                                ) &&
                                                                CloudSyncRequest(
                                                                      inventory:
                                                                          inventory,
                                                                      action:
                                                                          action,
                                                                      task:
                                                                          task,
                                                                      settings:
                                                                          action ==
                                                                              CloudSyncAction.update
                                                                          ? task.settings
                                                                          : null,
                                                                    ).validationError ==
                                                                    null
                                                            ? () => _change(
                                                                session!,
                                                                inventory,
                                                                action,
                                                                task,
                                                              )
                                                            : null,
                                                        child: Text(
                                                          switch (action) {
                                                            CloudSyncAction
                                                                .update =>
                                                              'Edit / enable',
                                                            CloudSyncAction
                                                                .run =>
                                                              'Run now',
                                                            CloudSyncAction
                                                                .delete =>
                                                              'Delete task',
                                                            _ => '',
                                                          },
                                                        ),
                                                      ),
                                                  ],
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'Advanced and encrypted tasks are display-only. Use TrueNAS for credentials, additional providers, restore, scripts, snapshots and remote browsing. TrueNavo is not an official TrueNAS application.',
                              ),
                            ],
                          );
                        },
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class CloudSyncChart extends StatelessWidget {
  const CloudSyncChart({required this.tasks, super.key});
  final List<CloudSyncTask> tasks;
  @override
  Widget build(BuildContext context) {
    final push = tasks.where((t) => t.settings.direction == 'PUSH').length,
        pull = tasks.length - push,
        enabled = tasks.where((t) => t.settings.enabled).length;
    return TdPanel(
      title: 'Transfer direction',
      description:
          'Configuration counts, not transferred bytes or successful backups.',
      child: Wrap(
        spacing: 24,
        runSpacing: 16,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Semantics(
            key: const Key('cloud-sync-chart-semantics'),
            label:
                '${tasks.length} tasks: $push push, $pull pull; $enabled enabled. Not backup success.',
            child: ExcludeSemantics(
              child: SizedBox(
                width: 112,
                height: 112,
                child: CustomPaint(
                  key: const Key('cloud-sync-chart'),
                  painter: _CloudRing(
                    push,
                    tasks.length,
                    Theme.of(context).colorScheme.primary,
                    Theme.of(context).colorScheme.tertiary,
                    Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                  child: Center(
                    child: Text(
                      '${tasks.length}',
                      style: TdTypography.metricMedium,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CloudLegend(
                label: 'PUSH · $push',
                color: Theme.of(context).colorScheme.primary,
              ),
              _CloudLegend(
                label: 'PULL · $pull',
                color: Theme.of(context).colorScheme.tertiary,
              ),
              const SizedBox(height: 12),
              Text('Scheduled · $enabled'),
              if (tasks.isEmpty) const Text('No configured tasks'),
            ],
          ),
        ],
      ),
    );
  }
}

class _CloudLegend extends StatelessWidget {
  const _CloudLegend({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ExcludeSemantics(
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
      const SizedBox(width: 8),
      Flexible(child: Text(label)),
    ],
  );
}

class _CloudRing extends CustomPainter {
  _CloudRing(this.push, this.total, this.first, this.second, this.track);
  final int push, total;
  final Color first, second, track;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size,
        ring = rect.deflate(8),
        paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 12
          ..color = track;
    canvas.drawArc(ring, 0, math.pi * 2, false, paint);
    if (total == 0) return;
    paint.color = first;
    canvas.drawArc(
      ring,
      -math.pi / 2,
      2 * math.pi * push / total,
      false,
      paint,
    );
    paint.color = second;
    canvas.drawArc(
      ring,
      -math.pi / 2 + 2 * math.pi * push / total,
      2 * math.pi * (total - push) / total,
      false,
      paint,
    );
  }

  @override
  bool shouldRepaint(_CloudRing old) =>
      push != old.push ||
      total != old.total ||
      first != old.first ||
      second != old.second ||
      track != old.track;
}
