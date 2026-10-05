import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'quota_editor_page.dart';
import 'quotas_controller.dart';

export 'quota_editor_page.dart';

class QuotasPage extends ConsumerWidget {
  const QuotasPage({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final capability = ref.watch(quotasSessionProvider)?.quotaCapabilities;
    return Scaffold(
      appBar: AppBar(title: const Text('User and group quotas')),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('DATASET LIMITS', style: TdTypography.micro),
                  const SizedBox(height: 8),
                  const Text(
                    'Space for each identity',
                    style: TdTypography.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  Text(session?.endpoint ?? 'No authenticated server'),
                  const SizedBox(height: 12),
                  const Text(
                    'Manage the byte and object limits for a specific user or '
                    'group on an existing filesystem dataset.',
                  ),
                  const SizedBox(height: 16),
                  const QuotaOperationBanner(),
                  if (session?.endpoint == null ||
                      capability?.supported != true)
                    TdPanel(
                      title: 'Quotas unavailable',
                      child: Text(
                        session?.endpoint == null
                            ? 'A live connection is required.'
                            : capability?.blockedReason ??
                                  'Connect to a supported TrueNAS server.',
                      ),
                    )
                  else
                    ref
                        .watch(quotaDatasetsProvider)
                        .when(
                          skipLoadingOnRefresh: false,
                          skipLoadingOnReload: false,
                          loading: () => const LinearProgressIndicator(),
                          error: (error, _) => QuotaReadError(
                            title: 'Could not load datasets',
                            error: error,
                            onRefresh: () =>
                                ref.invalidate(quotaDatasetsProvider),
                          ),
                          data: (datasets) => _QuotaWorkspace(
                            key: ObjectKey(session),
                            session: session!,
                            datasets: datasets,
                            capability: capability!,
                          ),
                        ),
                  const SizedBox(height: 20),
                  const Text(
                    'User and group limits can overlap. Their usage is not a '
                    'total for the dataset or pool. An object count is not '
                    'storage capacity.',
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Unlimited removes this identity limit. Other dataset, '
                    'user or group limits may still restrict writes.',
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _QuotaWorkspace extends ConsumerStatefulWidget {
  const _QuotaWorkspace({
    required this.session,
    required this.datasets,
    required this.capability,
    super.key,
  });
  final AuthenticatedSession session;
  final List<QuotaDataset> datasets;
  final QuotaCapabilities capability;

  @override
  ConsumerState<_QuotaWorkspace> createState() => _QuotaWorkspaceState();
}

class _QuotaWorkspaceState extends ConsumerState<_QuotaWorkspace> {
  String? _datasetId;
  var _kind = QuotaKind.user;

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(quotasControllerProvider);
    if (widget.datasets.isEmpty) {
      return const TdPanel(
        title: 'No datasets returned',
        child: Text('No filesystem datasets are available to this account.'),
      );
    }
    final dataset =
        widget.datasets
            .where((dataset) => dataset.id == _datasetId)
            .firstOrNull ??
        widget.datasets.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('quota-dataset-${dataset.id}'),
          initialValue: dataset.id,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Filesystem dataset'),
          items: [
            for (final item in widget.datasets)
              DropdownMenuItem(
                value: item.id,
                child: Text(
                  item.id,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: state.busy
              ? null
              : (value) => setState(() => _datasetId = value),
        ),
        const SizedBox(height: 8),
        Text('Dataset: ${dataset.id}'),
        const SizedBox(height: 12),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            key: const Key('quota-refresh-datasets'),
            onPressed: state.busy
                ? null
                : () => ref.invalidate(quotaDatasetsProvider),
            icon: const Icon(Icons.refresh),
            label: const Text('Refresh datasets'),
          ),
        ),
        const SizedBox(height: 16),
        if (!dataset.editable)
          TdPanel(
            title: 'Dataset protected',
            child: Text(dataset.blockedReason!),
          )
        else ...[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final kind in QuotaKind.values)
                ChoiceChip(
                  key: Key('quota-tab-${kind.name}'),
                  label: Text(kind == QuotaKind.user ? 'Users' : 'Groups'),
                  selected: _kind == kind,
                  onSelected: (_) => setState(() => _kind = kind),
                ),
            ],
          ),
          const SizedBox(height: 12),
          ref
              .watch(quotaInventoryProvider(dataset))
              .when(
                skipLoadingOnRefresh: false,
                skipLoadingOnReload: false,
                loading: () => const LinearProgressIndicator(),
                error: (error, _) => QuotaReadError(
                  title: 'Could not load quotas',
                  error: error,
                  onRefresh: () =>
                      ref.invalidate(quotaInventoryProvider(dataset)),
                ),
                data: (inventory) => _QuotaEntries(
                  key: ValueKey((dataset, _kind)),
                  session: widget.session,
                  inventory: inventory,
                  kind: _kind,
                  canSet: widget.capability.canSet(_kind),
                ),
              ),
        ],
      ],
    );
  }
}

class _QuotaEntries extends ConsumerStatefulWidget {
  const _QuotaEntries({
    required this.session,
    required this.inventory,
    required this.kind,
    required this.canSet,
    super.key,
  });
  final AuthenticatedSession session;
  final QuotaInventory inventory;
  final QuotaKind kind;
  final bool canSet;

  @override
  ConsumerState<_QuotaEntries> createState() => _QuotaEntriesState();
}

class _QuotaEntriesState extends ConsumerState<_QuotaEntries> {
  var _search = '';
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(quotasControllerProvider);
    final entries = widget.inventory.entries
        .where((entry) => entry.kind == widget.kind)
        .toList();
    final visible = entries.where(
      (entry) =>
          '${entry.id} ${entry.name ?? ''}'.toLowerCase().contains(_search),
    );
    final enabled = widget.canSet && !state.locked;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!widget.canSet) ...[
          Text(
            '${widget.kind.label} quota changes are unavailable to this account.',
          ),
          const SizedBox(height: 12),
        ],
        TextField(
          key: const Key('quota-search'),
          decoration: const InputDecoration(
            labelText: 'Search name or numeric ID',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) => setState(() => _search = value.toLowerCase()),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton(
              key: const Key('quota-add'),
              onPressed: enabled ? () => _open() : null,
              child: Text('Add ${widget.kind.label.toLowerCase()} quota'),
            ),
            OutlinedButton(
              key: const Key('quota-refresh'),
              onPressed: state.busy
                  ? null
                  : () => ref.invalidate(
                      quotaInventoryProvider(widget.inventory.dataset),
                    ),
              child: const Text('Refresh quotas'),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '${entries.length} ${widget.kind.label.toLowerCase()} quota entries',
        ),
        if (visible.isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              entries.isEmpty
                  ? 'No ${widget.kind.label.toLowerCase()} quota entries were returned.'
                  : 'No identities match your search.',
            ),
          ),
        for (final entry in visible)
          Padding(
            padding: const EdgeInsets.only(top: 16),
            child: TdPanel(
              key: Key('quota-entry-${entry.kind.wire}-${entry.id}'),
              title: entry.name ?? '${entry.kind.label} ${entry.id}',
              description:
                  '${entry.kind.label} · ${quotaIdLabel(entry.kind)} ${entry.id}',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (entry.id == 0)
                    const Text('Root identity quotas are protected.'),
                  QuotaUsage(entry: entry, objects: false),
                  const SizedBox(height: 16),
                  QuotaUsage(entry: entry, objects: true),
                  const SizedBox(height: 16),
                  OutlinedButton(
                    key: Key('quota-edit-${entry.kind.wire}-${entry.id}'),
                    onPressed: enabled && entry.id != 0
                        ? () => _open(entry)
                        : null,
                    child: const Text('Edit limits'),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  void _open([QuotaEntry? entry]) => Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => QuotaEditorPage(
        session: widget.session,
        inventory: widget.inventory,
        kind: widget.kind,
        entry: entry,
      ),
    ),
  );
}

class QuotaUsage extends StatelessWidget {
  const QuotaUsage({required this.entry, required this.objects, super.key});
  final QuotaEntry entry;
  final bool objects;

  @override
  Widget build(BuildContext context) {
    final used = objects ? entry.usedObjects : entry.usedBytes;
    final limit = objects ? entry.objectLimit : entry.byteLimit;
    final measure = objects ? 'objects' : 'bytes';
    final label = objects ? 'Objects' : 'Bytes';
    final severity = used != null && limit > 0 && used >= limit
        ? used > limit
              ? context.tdTheme.statusCritical
              : context.tdTheme.statusWarning
        : context.tdTheme.actionPrimary;
    final usedLabel = used == null
        ? 'Unavailable'
        : quotaQuantity(used, objects: objects);
    final limitLabel = limit == 0
        ? 'Unlimited'
        : quotaQuantity(limit, objects: objects);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(label, style: TdTypography.titleSmall),
        const SizedBox(height: 4),
        Text('Used: $usedLabel'),
        Text('Limit: $limitLabel'),
        if (used != null && limit > 0) ...[
          const SizedBox(height: 8),
          Semantics(
            label:
                '${entry.kind.label} ${entry.id}, $measure: '
                '$usedLabel used, limit $limitLabel${used > limit ? ', over limit' : ''}.',
            child: ExcludeSemantics(
              child: LinearProgressIndicator(
                key: Key('quota-usage-${entry.kind.wire}-${entry.id}-$measure'),
                value: (used / limit).clamp(0.0, 1.0),
                minHeight: 6,
                color: severity,
              ),
            ),
          ),
          if (used >= limit)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                used > limit ? 'Over limit' : 'At limit',
                style: TextStyle(color: severity),
              ),
            ),
        ],
      ],
    );
  }
}

class QuotaOperationBanner extends ConsumerWidget {
  const QuotaOperationBanner({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(quotasControllerProvider);
    ref.watch(dashboardActiveSessionProvider);
    if (!state.busy && state.result == null) return const SizedBox.shrink();
    final controller = ref.read(quotasControllerProvider.notifier);
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TdPanel(
        title: state.busy
            ? 'Applying quota change'
            : state.unknown
            ? 'Outcome needs verification'
            : state.result?.outcome == QuotaOutcome.verified
            ? 'Quota change verified'
            : 'Change not applied',
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.server != null) Text('Original server: ${state.server}'),
            if (state.target != null) Text('Dataset: ${state.target}'),
            if (state.identity != null) Text('Identity: ${state.identity}'),
            const SizedBox(height: 8),
            if (state.busy)
              const LinearProgressIndicator()
            else
              Text(state.result!.message),
            if (state.unknown && !state.connectionCurrent) ...[
              const SizedBox(height: 12),
              const Text(
                'Reconnect to the original server and inspect this identity’s quota before acknowledging.',
              ),
              TextButton(
                key: const Key('quota-acknowledge-unknown'),
                onPressed: controller.canAcknowledge
                    ? controller.acknowledgeAfterReconnect
                    : null,
                child: const Text('I inspected the original quota'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class QuotaReadError extends StatelessWidget {
  const QuotaReadError({
    required this.title,
    required this.error,
    required this.onRefresh,
    super.key,
  });
  final String title;
  final Object error;
  final VoidCallback onRefresh;
  @override
  Widget build(BuildContext context) => TdPanel(
    title: title,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          error is QuotaException ? (error as QuotaException).userMessage : 'Quota details could not be read. Remote details were withheld.',
        ),
        const SizedBox(height: 12),
        OutlinedButton(
          key: const Key('quota-retry'),
          onPressed: onRefresh,
          child: const Text('Refresh'),
        ),
      ],
    ),
  );
}

String quotaIdLabel(QuotaKind kind) => kind == QuotaKind.user ? 'UID' : 'GID';

String quotaQuantity(int value, {required bool objects}) {
  if (objects) return '$value objects';
  const units = ['bytes', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  var size = value.toDouble(), unit = 0;
  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit++;
  }
  return unit == 0
      ? '$value bytes'
      : '${size.toStringAsFixed(1)} ${units[unit]} ($value bytes)';
}
