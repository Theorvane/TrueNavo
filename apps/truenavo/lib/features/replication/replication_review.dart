import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'replication_controller.dart';

List<String> replicationImpact(ReplicationAction action) => switch (action) {
  ReplicationAction.run => const [
    'Running sends matching snapshots to the destination. Receiving may roll back destination changes and retention may delete destination snapshots. Verify the destination is dedicated to this task.',
    'The destination is made read-only. This workflow never allows replication from scratch or automatically retries a submission.',
  ],
  ReplicationAction.delete => const [
    'This removes the task configuration, not its existing snapshots or destination dataset. Future replication protection stops.',
  ],
  ReplicationAction.disable => const [
    'Disabling prevents this task from being run here. Existing destination data is not removed.',
  ],
  ReplicationAction.enable => const [
    'Enabling makes this manual task available for a separately reviewed run. No run is started now.',
  ],
  _ => const [
    'This saves a local, single-source, non-recursive, manual PUSH task. It does not start a replication run.',
    'A later run can roll back the destination and delete destination snapshots according to retention. No automatic schedule, property replication, encryption or SSH credentials are configured here.',
  ],
};

Future<void> reviewReplicationChange({
  required BuildContext context,
  required WidgetRef ref,
  required AuthenticatedSession session,
  required ReplicationRequest request,
}) async {
  bool current() =>
      identical(session, ref.read(dashboardActiveSessionProvider)) &&
      !ref.read(replicationInventoryProvider).isLoading &&
      identical(
        request.inventory,
        ref.read(replicationInventoryProvider).asData?.value,
      );
  if (!current() ||
      request.validationError != null ||
      ref.read(replicationControllerProvider).locked) {
    return;
  }
  final api = ref.read(replicationSessionProvider);
  if (api == null) return;
  var expired = false;
  final connection = ref.listenManual(dashboardActiveSessionProvider, (
    previous,
    next,
  ) {
    if (!identical(previous, next)) expired = true;
  });
  final inventory = ref.listenManual(replicationInventoryProvider, (_, next) {
    if (next.isLoading || !identical(next.asData?.value, request.inventory)) {
      expired = true;
    }
  });
  try {
    final review = await api.reviewReplication(request);
    if (!context.mounted || expired || !current()) return;
    if (review.endpoint != session.endpoint ||
        !identical(review.request, request)) {
      throw StateError('The review does not match the exact request.');
    }
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => ReplicationReviewDialog(session: session, review: review),
    );
    if (!context.mounted || confirmed != true || expired || !current()) return;
    await ref
        .read(replicationControllerProvider.notifier)
        .execute(
          expectedSession: session,
          review: review,
          confirmation: review.target,
        );
  } finally {
    connection.close();
    inventory.close();
  }
}

class ReplicationReviewDialog extends ConsumerStatefulWidget {
  const ReplicationReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final ReplicationReview review;
  @override
  ConsumerState<ReplicationReviewDialog> createState() =>
      _ReplicationReviewDialogState();
}

class _ReplicationReviewDialogState
    extends ConsumerState<ReplicationReviewDialog> {
  final _confirmation = TextEditingController();
  bool _acknowledged = false, _expired = false;
  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  void _expire() {
    if (_expired) return;
    setState(() {
      _expired = true;
      _confirmation.clear();
      _acknowledged = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(replicationInventoryProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final locked = ref.watch(replicationControllerProvider).locked;
    final review = widget.review, settings = review.request.effectiveSettings!;
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    ref.listen(replicationInventoryProvider, (_, next) {
      if (next.isLoading ||
          !identical(next.asData?.value, review.request.inventory)) {
        _expire();
      }
    });
    final current =
        !_expired &&
        identical(widget.session, session) &&
        !inventory.isLoading &&
        identical(review.request.inventory, inventory.asData?.value);
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 740),
        child: SingleChildScrollView(
          key: const Key('replication-review-scroll'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Padding(
            padding: const EdgeInsets.all(TdSpacing.component),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  current
                      ? 'Review ${review.action.name}'
                      : 'Review is no longer current',
                  style: TdTypography.titleSmall,
                ),
                const SizedBox(height: TdSpacing.component),
                if (!current)
                  const Text(
                    'Previous server and dataset details are hidden. Close this review and reload. Nothing was sent.',
                  )
                else ...[
                  const Text(
                    'Authenticated endpoint',
                    style: TdTypography.label,
                  ),
                  SelectableText(review.endpoint),
                  const Text('Exact target', style: TdTypography.label),
                  SelectableText(review.target),
                  Text('Source: ${settings.source}'),
                  Text('Destination: ${settings.destination}'),
                  const Text(
                    'Direction: PUSH · Transport: LOCAL · Manual · Non-recursive',
                  ),
                  Text('Snapshot naming schema: ${settings.namingSchema}'),
                  Text(
                    'Destination retention: ${settings.retention}${settings.retention == 'CUSTOM' ? ' · ${settings.lifetimeValue} ${settings.lifetimeUnit}' : ''}',
                  ),
                  Text('Enabled: ${settings.enabled ? 'Yes' : 'No'}'),
                  Text(
                    'Source snapshots (total): ${review.sourceSnapshots} · Destination snapshots (total): ${review.destinationSnapshots}',
                  ),
                  const Text(
                    'Totals are not eligible transfer or deletion counts.',
                  ),
                  Text(
                    review.createsDestination
                        ? 'A later receive can create the destination dataset.'
                        : 'The destination dataset already exists.',
                  ),
                  const SizedBox(height: TdSpacing.component),
                  for (final warning in [
                    ...replicationImpact(review.action),
                    ...review.warnings,
                  ])
                    Padding(
                      padding: const EdgeInsets.only(bottom: TdSpacing.related),
                      child: Text(warning),
                    ),
                  TextField(
                    key: const Key('replication-confirm-target'),
                    controller: _confirmation,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Type the exact target shown above',
                      helperText:
                          'Case-sensitive. No trimming or approximation.',
                      helperMaxLines: 3,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  CheckboxListTile(
                    key: const Key('replication-confirm-impact'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _acknowledged,
                    onChanged: (value) =>
                        setState(() => _acknowledged = value ?? false),
                    title: const Text(
                      'I reviewed the exact server and destination and understand rollback and retention effects.',
                    ),
                  ),
                ],
                const SizedBox(height: TdSpacing.component),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: TdSpacing.related,
                  runSpacing: TdSpacing.related,
                  children: [
                    TextButton(
                      key: const Key('replication-confirm-cancel'),
                      onPressed: () => Navigator.of(context).pop(false),
                      child: Text(current ? 'Cancel' : 'Close'),
                    ),
                    FilledButton(
                      key: const Key('replication-confirm-submit'),
                      onPressed:
                          current &&
                              !locked &&
                              _acknowledged &&
                              _confirmation.text == review.target
                          ? () => Navigator.of(context).pop(true)
                          : null,
                      child: const Text('Submit once'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
