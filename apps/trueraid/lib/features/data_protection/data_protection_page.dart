import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../cloud_sync/cloud_sync_page.dart';
import '../cloud_sync/cloud_sync_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../replication/replication_controller.dart';
import '../replication/replication_page.dart';
import '../rsync/rsync_controller.dart';
import '../rsync/rsync_page.dart';
import '../snapshot_schedules/snapshot_schedules_controller.dart';
import '../snapshot_schedules/snapshot_schedules_page.dart';
import 'data_protection_overview.dart';

class DataProtectionPage extends ConsumerStatefulWidget {
  const DataProtectionPage({super.key});
  @override
  ConsumerState<DataProtectionPage> createState() => _DataProtectionPageState();
}

class _DataProtectionPageState extends ConsumerState<DataProtectionPage> {
  final _search = TextEditingController();
  ProtectionFamily? _family;
  bool _attentionOnly = false;
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  void _refresh() => ref.invalidate(dataProtectionOverviewProvider);
  void _open(ProtectionFamily family) {
    // Overview never issues a mutation or forwards a stale issued review.
    // Its direct typed read replaces the SDK inventory lease. Refresh only the
    // destination provider so an earlier cached workspace cannot reuse it.
    switch (family) {
      case ProtectionFamily.snapshots:
        ref.invalidate(snapshotSchedulesInventoryProvider);
      case ProtectionFamily.replication:
        ref.invalidate(replicationInventoryProvider);
      case ProtectionFamily.cloudSync:
        ref.invalidate(cloudSyncInventoryProvider);
      case ProtectionFamily.rsync:
        ref.invalidate(rsyncInventoryProvider);
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => switch (family) {
          ProtectionFamily.snapshots => const SnapshotSchedulesPage(),
          ProtectionFamily.replication => const ReplicationPage(),
          ProtectionFamily.cloudSync => const CloudSyncPage(),
          ProtectionFamily.rsync => const RsyncPage(),
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (old, next) {
      if (!identical(old, next)) {
        _search.clear();
        _family = null;
        _attentionOnly = false;
      }
    });
    final data = ref.watch(dataProtectionOverviewProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Data protection'),
        actions: [
          IconButton(
            key: const Key('protection-refresh'),
            tooltip: 'Refresh local inventories',
            onPressed: data.isLoading ? null : _refresh,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: data.when(
        skipLoadingOnRefresh: false,
        skipLoadingOnReload: false,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Data protection is unavailable. Connect to the selected server or finish the pending operation, then refresh. No automatic retry or task execution occurs.',
                ),
                const SizedBox(height: 16),
                FilledButton(onPressed: _refresh, child: const Text('Refresh')),
              ],
            ),
          ),
        ),
        data: (overview) => _content(overview),
      ),
    );
  }

  Widget _content(DataProtectionOverview overview) {
    final tasks = overview.tasks
        .where(
          (t) =>
              (_family == null || t.family == _family) &&
              t.matches(_search.text) &&
              (!_attentionOnly ||
                  t.reportedState == ProtectionReportedState.failed ||
                  t.reportedState == ProtectionReportedState.attention ||
                  t.restriction != null),
        )
        .toList();
    return SingleChildScrollView(
      key: const Key('protection-scroll'),
      padding: const EdgeInsets.all(16),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text('DATA PROTECTION', style: TdTypography.label),
              const SizedBox(height: 8),
              Text('Policies at a glance', style: TdTypography.titleLarge),
              const SizedBox(height: 12),
              Text(overview.endpoint),
              const SizedBox(height: 8),
              Text(
                'Read ${overview.loadedSources} of ${ProtectionFamily.values.length} supported inventories · observed ${overview.observedAt.toIso8601String()} (client UTC)',
              ),
              const SizedBox(height: 12),
              const Text(
                'Configuration and last reported states only. These are not backup health, restored-data verification or transfer history. Reads are sequential, not an atomic server snapshot. Recorded Rsync states may be stale: RUNNING or WAITING does not establish a current transfer, and SUCCESS does not verify a complete file copy. Refresh manually after changing a policy.',
              ),
              if (overview.loadedSources != ProtectionFamily.values.length) ...[
                const SizedBox(height: 12),
                const Text(
                  'PARTIAL COVERAGE: unavailable inventories are excluded from every total and chart; they are not counted as empty.',
                ),
              ],
              const SizedBox(height: 20),
              LayoutBuilder(
                builder: (context, constraints) {
                  final cards = [
                    _EnablementCard(overview),
                    _ReportedStateCard(overview),
                  ];
                  if (constraints.maxWidth < 820) {
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        cards[0],
                        const SizedBox(height: 16),
                        cards[1],
                      ],
                    );
                  }
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(child: cards[0]),
                      const SizedBox(width: 16),
                      Expanded(child: cards[1]),
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),
              for (final source in overview.sources) ...[
                TdPanel(
                  title: source.family.label,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(
                        source.loaded
                            ? '${source.tasks.length} configured policies · ${source.tasks.where((t) => t.enabled).length} enabled'
                            : source.unavailable!,
                      ),
                      if (source.conflictingJob)
                        const Padding(
                          padding: EdgeInsets.only(top: 8),
                          child: Text(
                            'The server reports a conflicting active job. Open the workspace for its current restrictions.',
                          ),
                        ),
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.icon(
                          key: Key('protection-open-${source.family.name}'),
                          onPressed: () => _open(source.family),
                          icon: const Icon(Icons.open_in_new),
                          label: const Text('Open workspace'),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 12),
              ],
              TdPanel(
                title: 'Policy explorer',
                description: 'Open a workspace to review changes. This overview never runs, aborts or deletes a policy.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const Key('protection-search'),
                      controller: _search,
                      maxLength: 120,
                      autocorrect: false,
                      enableSuggestions: false,
                      decoration: const InputDecoration(
                        labelText: 'Filter loaded policies',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('All'),
                          selected: _family == null,
                          onSelected: (_) => setState(() => _family = null),
                        ),
                        for (final f in ProtectionFamily.values)
                          ChoiceChip(
                            label: Text(switch (f) {
                              ProtectionFamily.snapshots => 'Snapshots',
                              ProtectionFamily.replication => 'Replication',
                              ProtectionFamily.cloudSync => 'Cloud Sync',
                              ProtectionFamily.rsync => 'Rsync',
                            }),
                            selected: _family == f,
                            onSelected: (_) => setState(() => _family = f),
                          ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Material(
                      type: MaterialType.transparency,
                      child: CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: const Text('Failed, held or restricted only'),
                        value: _attentionOnly,
                        onChanged: (value) =>
                            setState(() => _attentionOnly = value ?? false),
                      ),
                    ),
                    Text(
                      '${tasks.length} matching policies; charts above always include all loaded policies.',
                    ),
                    const SizedBox(height: 12),
                    if (tasks.isEmpty)
                      const Text(
                        'No matching policies in the inventories that were successfully read.',
                      ),
                    for (final task in tasks)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: _TaskCard(task, () => _open(task.family)),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'TrueCloud Backup and VMware are not included in this overview yet. A cron expression is shown as configured; no exact next-run time, future retention deletion or recovery guarantee is calculated. Opening a native workspace reloads only its own inventory before a new review.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _TaskCard extends StatelessWidget {
  const _TaskCard(this.task, this.open);
  final ProtectionTaskSummary task;
  final VoidCallback open;
  @override
  Widget build(BuildContext context) => Card(
    child: Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(task.name, style: TdTypography.titleSmall),
          const SizedBox(height: 8),
          Text(
            '${task.family.label} #${task.id} · ${task.enabled ? 'Enabled' : 'Disabled'}',
          ),
          Text('Last reported: ${task.state}'),
          Text('Source / local: ${task.source}'),
          Text('Destination / remote: ${task.destination}'),
          const SizedBox(height: 8),
          Text(task.schedule),
          if (task.restriction != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text('Native editing restriction: ${task.restriction}'),
            ),
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: Key('protection-task-${task.identity}'),
              onPressed: open,
              child: const Text('Inspect in workspace'),
            ),
          ),
        ],
      ),
    ),
  );
}

class _EnablementCard extends StatelessWidget {
  const _EnablementCard(this.overview);
  final DataProtectionOverview overview;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TdPanel(
      title: 'Configured enablement',
      description: 'Manual replication enablement does not schedule a run.',
      child: Wrap(
        spacing: 20,
        runSpacing: 16,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Semantics(
            key: const Key('protection-enablement-semantics'),
            label:
                '${overview.tasks.length} loaded policies: ${overview.enabled} enabled, ${overview.disabled} disabled. Not backup health.',
            child: ExcludeSemantics(
              child: SizedBox(
                width: 132,
                height: 132,
                child: CustomPaint(
                  key: const Key('protection-enablement-chart'),
                  painter: _EnablementRing(
                    overview.enabled,
                    overview.tasks.length,
                    colors.primary,
                    colors.tertiary,
                    colors.outlineVariant,
                  ),
                  child: Center(
                    child: Text(
                      '${overview.tasks.length}',
                      style: TdTypography.metricMedium,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              _Legend(colors.primary, 'Enabled · ${overview.enabled}'),
              _Legend(colors.tertiary, 'Disabled · ${overview.disabled}'),
              if (overview.tasks.isEmpty) const Text('No loaded policies'),
            ],
          ),
        ],
      ),
    );
  }
}

class _ReportedStateCard extends StatelessWidget {
  const _ReportedStateCard(this.overview);
  final DataProtectionOverview overview;
  @override
  Widget build(BuildContext context) => TdPanel(
    title: 'Last reported state',
    description: 'No run time or freshness is inferred. PENDING is unknown, not running.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final state in ProtectionReportedState.values)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Semantics(
              label:
                  '${state.label}: ${overview.count(state)} of ${overview.tasks.length} loaded policies',
              child: ExcludeSemantics(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('${state.label} · ${overview.count(state)}'),
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      value: overview.tasks.isEmpty
                          ? 0
                          : overview.count(state) / overview.tasks.length,
                      minHeight: 7,
                    ),
                  ],
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class _Legend extends StatelessWidget {
  const _Legend(this.color, this.label);
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      ExcludeSemantics(
        child: Container(
          width: 12,
          height: 12,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
      const SizedBox(width: 8),
      Flexible(child: Text(label)),
    ],
  );
}

class _EnablementRing extends CustomPainter {
  _EnablementRing(this.enabled, this.total, this.on, this.off, this.empty);
  final int enabled, total;
  final Color on, off, empty;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(9);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12;
    paint.color = total == 0 ? empty : off;
    canvas.drawArc(rect, -math.pi / 2, math.pi * 2, false, paint);
    if (total > 0 && enabled > 0) {
      paint.color = on;
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * enabled / total,
        false,
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EnablementRing old) =>
      enabled != old.enabled ||
      total != old.total ||
      on != old.on ||
      off != old.off ||
      empty != old.empty;
}
