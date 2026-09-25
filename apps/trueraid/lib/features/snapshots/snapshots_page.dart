import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'snapshots_controller.dart';
import 'snapshot_recovery_page.dart';

class SnapshotsPage extends ConsumerStatefulWidget {
  const SnapshotsPage({super.key});
  @override
  ConsumerState<SnapshotsPage> createState() => _SnapshotsPageState();
}

class _SnapshotsPageState extends ConsumerState<SnapshotsPage> {
  String? _dataset;
  var _prefix = '';
  var _page = 0;
  final _search = TextEditingController();
  String? _searchError;
  final _selectedForDeletion = <String, SnapshotEntry>{};
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final capabilities = ref
        .watch(snapshotsSessionProvider)
        ?.snapshotsCapabilities;
    final state = ref.watch(snapshotsControllerProvider);
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (identical(previous, next)) return;
      setState(() {
        _dataset = null;
        _prefix = '';
        _page = 0;
        _search.clear();
        _selectedForDeletion.clear();
      });
    });
    return Scaffold(
      appBar: AppBar(title: const Text('Snapshots')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            const Text('Filesystem history', style: TdTypography.titleLarge),
            const SizedBox(height: 8),
            Text(session?.endpoint ?? 'No authenticated server'),
            const SizedBox(height: 16),
            if (state.busy) const LinearProgressIndicator(),
            if (state.result != null) _SnapshotResultPanel(state: state),
            if (capabilities?.supported != true || session?.endpoint == null)
              TdPanel(
                title: 'Snapshot workspace unavailable',
                child: Text(
                  capabilities?.blockedReason ??
                      'Connect to a supported TrueNAS server.',
                ),
              )
            else
              ref
                  .watch(snapshotDatasetsProvider)
                  .when(
                    loading: () => const LinearProgressIndicator(),
                    error: (_, _) => TdPanel(
                      title: 'Filesystems unavailable',
                      child: OutlinedButton(
                        onPressed: () =>
                            ref.invalidate(snapshotDatasetsProvider),
                        child: const Text('Reload filesystems'),
                      ),
                    ),
                    data: (datasets) =>
                        _inventory(datasets, session!, capabilities!, state),
                  ),
            const SizedBox(height: 20),
            const Text(
              'Snapshots preserve filesystem state and initially share data blocks. They are not independent backups. Creation here does not coordinate running applications or virtual machines.',
            ),
            const SizedBox(height: 12),
            const Text(
              'Snapshot details provide guarded clone, latest-snapshot rollback and hold workflows. Descendant sets and selected deletion are explicit, bounded and non-atomic. Destructive recursive rollback, clone destruction and deferred deletion remain unavailable.',
            ),
          ],
        ),
      ),
    );
  }

  Widget _inventory(
    List<SnapshotDataset> datasets,
    AuthenticatedSession session,
    SnapshotsCapabilities capabilities,
    SnapshotsState state,
  ) {
    if (datasets.isEmpty) {
      return const Text('No filesystem datasets were returned.');
    }
    final selected =
        datasets.where((d) => d.id == _dataset).firstOrNull ?? datasets.first;
    final query = SnapshotQuery(
      dataset: selected.id,
      namePrefix: _prefix,
      page: _page,
    );
    final inventory = ref.watch(snapshotInventoryProvider(query));
    final enabled =
        !state.busy &&
        !state.unresolved &&
        !inventory.isLoading &&
        !ref.watch(snapshotDatasetsProvider).isLoading;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        DropdownButtonFormField<String>(
          key: ValueKey('snapshot-dataset-${selected.id}'),
          initialValue: selected.id,
          isExpanded: true,
          decoration: const InputDecoration(labelText: 'Filesystem'),
          items: [
            for (final dataset in datasets)
              DropdownMenuItem(
                value: dataset.id,
                child: Text(
                  dataset.id,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
          ],
          onChanged: enabled
              ? (value) => setState(() {
                  _dataset = value;
                  _page = 0;
                  _selectedForDeletion.clear();
                })
              : null,
        ),
        const SizedBox(height: 16),
        TextField(
          controller: _search,
          enabled: enabled,
          maxLength: 64,
          decoration: InputDecoration(
            labelText: 'Snapshot name prefix',
            hintText: 'For example: manual-',
            errorText: _searchError,
          ),
          onSubmitted: (_) => _applySearch(selected.id),
        ),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton(
              onPressed: enabled ? () => _applySearch(selected.id) : null,
              child: const Text('Search'),
            ),
            OutlinedButton(
              onPressed: enabled
                  ? () {
                      setState(_selectedForDeletion.clear);
                      ref.invalidate(snapshotInventoryProvider(query));
                    }
                  : null,
              child: const Text('Refresh snapshots'),
            ),
            FilledButton.icon(
              onPressed: enabled && selected.canCreate && capabilities.canCreate
                  ? () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => SnapshotCreatePage(
                          session: session,
                          dataset: selected,
                        ),
                      ),
                    )
                  : null,
              icon: const Icon(Icons.add),
              label: const Text('Create snapshot'),
            ),
            OutlinedButton(
              onPressed: enabled && selected.canCreate && capabilities.canCreate
                  ? () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => SnapshotRecoveryPage(
                          session: session,
                          kind: SnapshotRecoveryKind.recursiveCreate,
                          dataset: selected,
                        ),
                      ),
                    )
                  : null,
              child: const Text('Create descendant set'),
            ),
            OutlinedButton(
              key: const Key('snapshots-bulk-delete'),
              onPressed:
                  enabled &&
                      capabilities.canDelete &&
                      _selectedForDeletion.isNotEmpty
                  ? () => Navigator.of(context).push(
                      MaterialPageRoute<void>(
                        builder: (_) => SnapshotRecoveryPage(
                          session: session,
                          kind: SnapshotRecoveryKind.bulkDelete,
                          selected: List.unmodifiable(
                            _selectedForDeletion.values,
                          ),
                        ),
                      ),
                    )
                  : null,
              child: Text('Delete selected (${_selectedForDeletion.length})'),
            ),
          ],
        ),
        if (selected.blockedReason != null) Text(selected.blockedReason!),
        if (!capabilities.canCreate)
          const Text('This account cannot create snapshots.'),
        if (!capabilities.canDelete)
          const Text('This account cannot delete snapshots.'),
        const SizedBox(height: 16),
        inventory.when(
          loading: () => const LinearProgressIndicator(),
          error: (_, _) => const TdPanel(
            title: 'Snapshots unavailable',
            child: Text(
              'The filesystem inventory may have changed or required details were not returned. Refresh snapshots to try a new read.',
            ),
          ),
          data: (result) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'Page ${_page + 1} · ${result.entries.length} snapshots · names in alphabetical order',
              ),
              if (result.entries.isEmpty)
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 20),
                  child: Text('No snapshots match this filesystem and prefix.'),
                ),
              for (final snapshot in result.entries)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: TdPanel(
                    title: snapshot.name,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(snapshot.id),
                        Text('Created ${_shortUtc(snapshot.createdAt)}'),
                        Text(
                          'Used ${_binarySize(snapshot.usedBytes)} · referenced ${_binarySize(snapshot.referencedBytes)}',
                        ),
                        Text(_safetySummary(snapshot)),
                        Material(
                          type: MaterialType.transparency,
                          child: CheckboxListTile(
                            key: ValueKey('snapshot-select-${snapshot.id}'),
                            contentPadding: EdgeInsets.zero,
                            title: const Text('Select for exact deletion'),
                            value: identical(
                              _selectedForDeletion[snapshot.id],
                              snapshot,
                            ),
                            onChanged:
                                enabled &&
                                    capabilities.canDelete &&
                                    snapshot.canDelete
                                ? (checked) => setState(() {
                                    if (checked == true) {
                                      _selectedForDeletion[snapshot.id] =
                                          snapshot;
                                    } else {
                                      _selectedForDeletion.remove(snapshot.id);
                                    }
                                  })
                                : null,
                          ),
                        ),
                        if (snapshot.blockedReason != null)
                          Text(snapshot.blockedReason!),
                        TextButton(
                          onPressed: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => SnapshotDetailPage(
                                session: session,
                                snapshot: snapshot,
                              ),
                            ),
                          ),
                          child: const Text('View snapshot'),
                        ),
                      ],
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton(
                    onPressed: enabled && _page > 0
                        ? () => setState(() {
                            _page--;
                            _selectedForDeletion.clear();
                          })
                        : null,
                    child: const Text('Previous page'),
                  ),
                  OutlinedButton(
                    onPressed: enabled && result.hasMore && _page < 39
                        ? () => setState(() {
                            _page++;
                            _selectedForDeletion.clear();
                          })
                        : null,
                    child: const Text('Next page'),
                  ),
                ],
              ),
              if (result.hasMore && _page == 39)
                const Text(
                  'The 1000-name browsing limit was reached. Narrow the prefix to find more snapshots.',
                ),
              const Text(
                'Each page reads at most 25 snapshot details. Concurrent changes can shift page contents.',
              ),
            ],
          ),
        ),
      ],
    );
  }

  void _applySearch(String dataset) {
    final query = SnapshotQuery(dataset: dataset, namePrefix: _search.text);
    setState(() {
      _searchError = query.validationError;
      if (_searchError == null) {
        _prefix = _search.text;
        _page = 0;
        _selectedForDeletion.clear();
      }
    });
  }
}

class _SnapshotResultPanel extends ConsumerWidget {
  const _SnapshotResultPanel({required this.state});
  final SnapshotsState state;
  @override
  Widget build(BuildContext context, WidgetRef ref) => TdPanel(
    title: state.result!.outcome == SnapshotOperationOutcome.verified
        ? 'Snapshot operation verified'
        : state.unresolved
        ? 'Outcome unknown'
        : 'Operation not applied',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('${state.server ?? ''}\n${state.target ?? ''}'),
        Text(state.result!.message),
        if (state.unresolved)
          TextButton(
            onPressed:
                ref
                    .read(snapshotsControllerProvider.notifier)
                    .canAcknowledgeUnknown
                ? () => ref
                      .read(snapshotsControllerProvider.notifier)
                      .acknowledgeUnknown()
                : null,
            child: const Text('I inspected the outcome and reconnected'),
          ),
      ],
    ),
  );
}

class SnapshotCreatePage extends ConsumerStatefulWidget {
  const SnapshotCreatePage({
    required this.session,
    required this.dataset,
    super.key,
  });
  final AuthenticatedSession session;
  final SnapshotDataset dataset;
  @override
  ConsumerState<SnapshotCreatePage> createState() => _SnapshotCreatePageState();
}

class _SnapshotCreatePageState extends ConsumerState<SnapshotCreatePage> {
  final _name = TextEditingController();
  var _reviewed = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final current = identical(
      ref.watch(dashboardActiveSessionProvider),
      widget.session,
    );
    final state = ref.watch(snapshotsControllerProvider);
    final request = SnapshotCreateRequest(
      dataset: widget.dataset,
      name: _name.text,
    );
    final enabled = current && !state.busy && !state.unresolved;
    return Scaffold(
      appBar: AppBar(title: const Text('Create snapshot')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(widget.session.endpoint ?? 'Disconnected server'),
            const SizedBox(height: 12),
            Text(widget.dataset.id, style: TdTypography.titleLarge),
            const SizedBox(height: 16),
            TextField(
              controller: _name,
              enabled: enabled,
              maxLength: 64,
              decoration: InputDecoration(
                labelText: 'Snapshot name',
                errorText: _error,
              ),
              onChanged: (_) => setState(() {
                _reviewed = false;
                _error = null;
              }),
            ),
            const SizedBox(height: 12),
            const Text(
              'Only this filesystem will be captured. Child datasets are excluded. Applications and virtual machines are not paused or synchronized. Future changes can increase the space retained by this snapshot.',
            ),
            if (!current)
              const Text(
                'The connection changed. Return and reload the filesystem.',
              ),
            if (!_reviewed)
              OutlinedButton(
                onPressed: enabled
                    ? () => setState(() {
                        _error = request.validationError;
                        _reviewed = _error == null;
                      })
                    : null,
                child: const Text('Review creation'),
              ),
            if (_reviewed) ...[
              const SizedBox(height: 16),
              TdPanel(
                title: 'Review creation',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Server: ${widget.session.endpoint}'),
                    Text('Snapshot: ${request.id}'),
                    Text('Filesystem GUID: ${widget.dataset.guid}'),
                    const Text('One snapshot · no child datasets'),
                  ],
                ),
              ),
              FilledButton(
                onPressed: enabled
                    ? () async {
                        await ref
                            .read(snapshotsControllerProvider.notifier)
                            .create(
                              expectedSession: widget.session,
                              request: request,
                            );
                        if (context.mounted) Navigator.of(context).pop();
                      }
                    : null,
                child: Text(
                  state.busy ? 'Creating snapshot…' : 'Create this snapshot',
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class SnapshotDetailPage extends ConsumerStatefulWidget {
  const SnapshotDetailPage({
    required this.session,
    required this.snapshot,
    super.key,
  });
  final AuthenticatedSession session;
  final SnapshotEntry snapshot;
  @override
  ConsumerState<SnapshotDetailPage> createState() => _SnapshotDetailPageState();
}

class _SnapshotDetailPageState extends ConsumerState<SnapshotDetailPage> {
  final _confirmation = TextEditingController();
  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final snapshot = widget.snapshot;
    final current = identical(
      ref.watch(dashboardActiveSessionProvider),
      widget.session,
    );
    final state = ref.watch(snapshotsControllerProvider);
    final capability = ref
        .watch(snapshotsSessionProvider)
        ?.snapshotsCapabilities;
    final enabled =
        current &&
        !state.busy &&
        !state.unresolved &&
        capability?.canDelete == true &&
        snapshot.canDelete;
    final request = SnapshotDeleteRequest(
      snapshot: snapshot,
      confirmation: _confirmation.text,
    );
    return Scaffold(
      appBar: AppBar(title: const Text('Snapshot details')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            Text(widget.session.endpoint ?? 'Disconnected server'),
            const SizedBox(height: 16),
            Text(snapshot.id, style: TdTypography.titleLarge),
            const SizedBox(height: 16),
            Text('Filesystem: ${snapshot.dataset}'),
            Text('Created: ${snapshot.createdAt.toIso8601String()}'),
            Text('Creation time: ${snapshot.creationSeconds} Unix seconds'),
            Text('GUID: ${snapshot.guid}'),
            Text('Creation transaction group: ${snapshot.creationTxg}'),
            Text('Used: ${snapshot.usedBytes} bytes'),
            Text('Referenced: ${snapshot.referencedBytes} bytes'),
            Text(_safetySummary(snapshot)),
            if (snapshot.holds.isNotEmpty) ...[
              const Text('Hold tags:'),
              for (final entry in snapshot.holds.entries)
                Text('${entry.key}: ${entry.value} Unix seconds'),
            ],
            if (snapshot.clones.isNotEmpty) ...[
              const Text('Dependent clone filesystems:'),
              for (final clone in snapshot.clones) Text(clone),
            ],
            const SizedBox(height: 20),
            if (snapshot.blockedReason != null) Text(snapshot.blockedReason!),
            if (!current)
              const Text(
                'The connection changed. Return and reload snapshots.',
              ),
            if (capability?.canDelete != true)
              const Text('Deletion is unavailable to this account.'),
            TdPanel(
              title: 'Delete this snapshot',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'Deletion permanently removes this recovery point and cannot be undone. The active filesystem is retained. Only this exact snapshot is targeted; child snapshots are excluded. No holds are released and no deletion is deferred.',
                  ),
                  const SizedBox(height: 12),
                  Text('Type exactly: ${snapshot.id}'),
                  TextField(
                    controller: _confirmation,
                    enabled: enabled,
                    decoration: const InputDecoration(
                      labelText: 'Full snapshot identifier',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: enabled && request.validationError == null
                        ? () async {
                            await ref
                                .read(snapshotsControllerProvider.notifier)
                                .delete(
                                  expectedSession: widget.session,
                                  request: request,
                                );
                            if (context.mounted) Navigator.of(context).pop();
                          }
                        : null,
                    child: Text(
                      state.busy
                          ? 'Deleting snapshot…'
                          : 'Permanently delete snapshot',
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            const Text(
              'Holds, clone dependencies and immutable snapshot identity are rechecked immediately before deletion. Avoid concurrent snapshot changes in other clients.',
            ),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final kind in [
                  SnapshotRecoveryKind.clone,
                  SnapshotRecoveryKind.rollback,
                  SnapshotRecoveryKind.hold,
                  SnapshotRecoveryKind.release,
                ])
                  OutlinedButton(
                    key: ValueKey('snapshot-recovery-${kind.name}'),
                    onPressed:
                        current &&
                            !state.busy &&
                            !state.unresolved &&
                            (switch (kind) {
                                  SnapshotRecoveryKind.clone =>
                                    capability?.canClone,
                                  SnapshotRecoveryKind.rollback =>
                                    capability?.canRollback,
                                  SnapshotRecoveryKind.hold =>
                                    capability?.canHold,
                                  SnapshotRecoveryKind.release =>
                                    capability?.canRelease,
                                  _ => false,
                                }) ==
                                true
                        ? () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => SnapshotRecoveryPage(
                                session: widget.session,
                                kind: kind,
                                snapshot: snapshot,
                              ),
                            ),
                          )
                        : null,
                    child: Text(snapshotRecoveryTitle(kind)),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

String _binarySize(int bytes) {
  var value = bytes.toDouble();
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  var unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  final digits = value == value.truncateToDouble() ? 0 : 1;
  return '${value.toStringAsFixed(digits)} ${units[unit]}';
}

String _shortUtc(DateTime timestamp) =>
    '${timestamp.toUtc().toIso8601String().substring(0, 16).replaceFirst('T', ' ')} UTC';

String _safetySummary(SnapshotEntry snapshot) =>
    'Holds: ${snapshot.userReferences ?? 'unknown'} · clones: ${snapshot.clonesKnown ? snapshot.clones.length : 'unknown'} · '
    'deferred destruction: ${snapshot.deferredDestroy == null
        ? 'unknown'
        : snapshot.deferredDestroy!
        ? 'yes'
        : 'no'}';
