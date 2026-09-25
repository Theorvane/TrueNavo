import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'snapshots_controller.dart';

class SnapshotRecoveryPage extends ConsumerStatefulWidget {
  const SnapshotRecoveryPage({
    required this.session,
    required this.kind,
    this.snapshot,
    this.dataset,
    this.selected = const [],
    super.key,
  });
  final AuthenticatedSession session;
  final SnapshotRecoveryKind kind;
  final SnapshotEntry? snapshot;
  final SnapshotDataset? dataset;
  final List<SnapshotEntry> selected;
  @override
  ConsumerState<SnapshotRecoveryPage> createState() =>
      _SnapshotRecoveryPageState();
}

class _SnapshotRecoveryPageState extends ConsumerState<SnapshotRecoveryPage> {
  final _name = TextEditingController();
  final _confirmation = TextEditingController();
  SnapshotDataset? _parent;
  SnapshotRecoveryReview? _review;
  bool _loading = false, _loss = false, _targets = false, _submitted = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  bool get _current =>
      identical(widget.session, ref.read(dashboardActiveSessionProvider));
  SnapshotRecoveryPlan _plan() => switch (widget.kind) {
    SnapshotRecoveryKind.clone => SnapshotRecoveryPlan.clone(
      snapshot: widget.snapshot!,
      parent: _parent!,
      newName: _name.text,
    ),
    SnapshotRecoveryKind.rollback => SnapshotRecoveryPlan.rollback(
      widget.snapshot!,
    ),
    SnapshotRecoveryKind.hold => SnapshotRecoveryPlan.hold(widget.snapshot!),
    SnapshotRecoveryKind.release => SnapshotRecoveryPlan.release(
      widget.snapshot!,
    ),
    SnapshotRecoveryKind.recursiveCreate =>
      SnapshotRecoveryPlan.recursiveCreate(
        dataset: widget.dataset!,
        name: _name.text,
      ),
    SnapshotRecoveryKind.bulkDelete => SnapshotRecoveryPlan.bulkDelete(
      widget.selected,
    ),
  };

  Future<void> _loadReview() async {
    if (!_current || _loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final api = widget.session.repository as AuthenticatedSnapshotsSession;
      final review = await api.reviewSnapshotRecovery(_plan());
      if (!mounted || !_current) return;
      setState(() {
        _review = review;
        _loss = false;
        _targets = false;
        _confirmation.clear();
      });
    } on Object {
      if (mounted && _current) {
        setState(
          () => _error = 'Recovery review could not be verified. No change was sent. Return and refresh the inventory if it changed.',
        );
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final current = identical(
      widget.session,
      ref.watch(dashboardActiveSessionProvider),
    );
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (!identical(widget.session, next)) {
        _name.clear();
        _confirmation.clear();
        _review = null;
        _parent = null;
        _error = null;
      }
    });
    final operation = ref.watch(snapshotsControllerProvider);
    final capabilities = ref
        .watch(snapshotsSessionProvider)
        ?.snapshotsCapabilities;
    final allowed =
        (switch (widget.kind) {
          SnapshotRecoveryKind.clone => capabilities?.canClone,
          SnapshotRecoveryKind.rollback => capabilities?.canRollback,
          SnapshotRecoveryKind.hold => capabilities?.canHold,
          SnapshotRecoveryKind.release => capabilities?.canRelease,
          SnapshotRecoveryKind.recursiveCreate => capabilities?.canCreate,
          SnapshotRecoveryKind.bulkDelete => capabilities?.canDelete,
        }) ==
        true;
    final enabled =
        current &&
        allowed &&
        !_loading &&
        !_submitted &&
        !operation.busy &&
        !operation.unresolved;
    final review = _review;
    final request = review == null
        ? null
        : SnapshotRecoveryRequest(
            review: review,
            confirmation: _confirmation.text,
            acknowledgeDataLoss: _loss,
          );
    return Scaffold(
      appBar: AppBar(title: Text(snapshotRecoveryTitle(widget.kind))),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(20),
          children: [
            if (!current)
              const TdPanel(
                title: 'Connection changed',
                child: Text(
                  'The old review is hidden. Reopen recovery for the current authenticated server.',
                ),
              )
            else ...[
              Text(widget.session.endpoint ?? '', style: TdTypography.metadata),
              if (!allowed)
                const Text('This operation is unavailable to this account.'),
              const SizedBox(height: 12),
              if (widget.snapshot != null)
                Text(widget.snapshot!.id, style: TdTypography.titleLarge),
              if (widget.dataset != null)
                Text(widget.dataset!.id, style: TdTypography.titleLarge),
              if (_submitted)
                TdPanel(
                  title: operation.unresolved
                      ? 'Outcome unknown'
                      : 'Recovery request finished',
                  child: Text(
                    operation.result?.message ??
                        'Inspect the operation status before another change.',
                  ),
                )
              else ...[
                if (review == null) ...[
                  if (widget.kind == SnapshotRecoveryKind.clone)
                    ref
                        .watch(snapshotDatasetsProvider)
                        .when(
                          loading: () => const LinearProgressIndicator(),
                          error: (_, _) => const Text(
                            'Destination parents unavailable. Return and reload filesystems.',
                          ),
                          data: (datasets) =>
                              DropdownButtonFormField<SnapshotDataset>(
                                key: const Key('recovery-clone-parent'),
                                initialValue: _parent,
                                isExpanded: true,
                                decoration: const InputDecoration(
                                  labelText: 'Existing destination parent',
                                ),
                                items: [
                                  for (final d in datasets.where(
                                    (d) => d.canCreate,
                                  ))
                                    DropdownMenuItem(
                                      value: d,
                                      child: Text(
                                        d.id,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                ],
                                onChanged: enabled
                                    ? (value) => setState(() => _parent = value)
                                    : null,
                              ),
                        ),
                  if ({
                    SnapshotRecoveryKind.clone,
                    SnapshotRecoveryKind.recursiveCreate,
                  }.contains(widget.kind))
                    TextField(
                      key: const Key('recovery-name'),
                      controller: _name,
                      enabled: enabled,
                      maxLength: 64,
                      decoration: InputDecoration(
                        labelText: widget.kind == SnapshotRecoveryKind.clone
                            ? 'New clone filesystem name'
                            : 'Snapshot set name',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  if (widget.kind == SnapshotRecoveryKind.bulkDelete) ...[
                    const Text(
                      'Only the explicitly selected snapshots will be reviewed:',
                    ),
                    for (final snapshot in widget.selected) Text(snapshot.id),
                  ],
                  const SizedBox(height: 16),
                  FilledButton(
                    key: const Key('recovery-review'),
                    onPressed:
                        enabled &&
                            (widget.kind != SnapshotRecoveryKind.clone ||
                                _parent != null && _name.text.isNotEmpty) &&
                            (widget.kind !=
                                    SnapshotRecoveryKind.recursiveCreate ||
                                _name.text.isNotEmpty)
                        ? _loadReview
                        : null,
                    child: const Text('Load exact impact review'),
                  ),
                ],
                if (_loading) const LinearProgressIndicator(),
                if (_error != null) Text(_error!),
                if (review != null) ...[
                  const SizedBox(height: 16),
                  TdPanel(
                    title: 'Exact recovery impact',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('Target: ${review.plan.target}'),
                        for (final warning in review.warnings)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(warning),
                          ),
                        const SizedBox(height: 12),
                        for (final dataset in review.datasets)
                          Text(
                            'Filesystem ${dataset.id}\nGUID ${dataset.guid} · created ${dataset.creationSeconds}'
                            '${widget.kind == SnapshotRecoveryKind.recursiveCreate ? '\nCreate ${dataset.id}@${review.plan.name}' : ''}',
                          ),
                        for (final snapshot in review.snapshots)
                          Padding(
                            padding: const EdgeInsets.only(top: 12),
                            child: Text(
                              '${snapshot.id}\nGUID ${snapshot.guid} · TXG ${snapshot.creationTxg}\nHolds ${snapshot.userReferences ?? 'unknown'}: ${snapshot.holds.keys.join(', ')}\nClones: ${snapshot.clonesKnown ? snapshot.clones.join(', ') : 'unknown'}',
                            ),
                          ),
                        if (widget.kind == SnapshotRecoveryKind.rollback) ...[
                          const SizedBox(height: 12),
                          Text(
                            'Newer snapshots: ${review.newerSnapshots.length}',
                          ),
                          for (final newer in review.newerSnapshots)
                            Text(
                              '${newer.id}\nGUID ${newer.guid} · TXG ${newer.creationTxg}\nHolds ${newer.userReferences ?? 'unknown'} · clones ${newer.clones.join(', ')}',
                            ),
                          const Text(
                            'Bookmarks: inventory unavailable through the public API. None selected for destruction.',
                          ),
                          const Text(
                            'Destroy newer snapshots/bookmarks: OFF\nDestroy clones: OFF\nForce unmount: OFF\nRollback children: OFF',
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (!review.canApply)
                    TdPanel(
                      title: 'This impact cannot be applied safely',
                      child: Text(review.blockedReason!),
                    )
                  else ...[
                    CheckboxListTile(
                      key: const Key('recovery-authorize-targets'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'I authorize exactly all listed targets and understand this operation is not an independent backup.',
                      ),
                      value: _targets,
                      onChanged: enabled
                          ? (value) => setState(() => _targets = value == true)
                          : null,
                    ),
                    if (review.requiresLossAcknowledgement)
                      CheckboxListTile(
                        key: const Key('recovery-acknowledge-loss'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          widget.kind == SnapshotRecoveryKind.release
                              ? 'I understand releasing this hold permits later deletion by retention tasks.'
                              : 'I understand the reviewed data or recovery points can be permanently lost; no automatic backup or undo is created.',
                        ),
                        value: _loss,
                        onChanged: enabled
                            ? (value) => setState(() => _loss = value == true)
                            : null,
                      ),
                    Text('Type exactly: ${review.plan.target}'),
                    TextField(
                      key: const Key('recovery-confirmation'),
                      controller: _confirmation,
                      enabled: enabled,
                      decoration: const InputDecoration(
                        labelText: 'Exact reviewed target',
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 12),
                    FilledButton(
                      key: const Key('recovery-apply'),
                      onPressed:
                          enabled &&
                              _targets &&
                              request?.validationError == null
                          ? () async {
                              if (!_current) return;
                              await ref
                                  .read(snapshotsControllerProvider.notifier)
                                  .recover(
                                    expectedSession: widget.session,
                                    request: request!,
                                  );
                              if (mounted && _current) {
                                setState(() {
                                  _submitted = true;
                                  _review = null;
                                  _confirmation.clear();
                                });
                              }
                            }
                          : null,
                      child: Text(
                        operation.busy
                            ? 'Applying…'
                            : 'Apply reviewed recovery',
                      ),
                    ),
                  ],
                  if (!operation.busy)
                    TextButton(
                      onPressed: enabled
                          ? () => setState(() {
                              _review = null;
                              _targets = false;
                              _loss = false;
                              _confirmation.clear();
                            })
                          : null,
                      child: const Text('Discard review'),
                    ),
                ],
              ],
            ],
          ],
        ),
      ),
    );
  }
}

String snapshotRecoveryTitle(SnapshotRecoveryKind kind) => switch (kind) {
  SnapshotRecoveryKind.clone => 'Clone snapshot',
  SnapshotRecoveryKind.rollback => 'Rollback filesystem',
  SnapshotRecoveryKind.hold => 'Protect snapshot with hold',
  SnapshotRecoveryKind.release => 'Release snapshot hold',
  SnapshotRecoveryKind.recursiveCreate => 'Create descendant snapshot set',
  SnapshotRecoveryKind.bulkDelete => 'Delete selected snapshots',
};
