import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'cloud_sync_controller.dart';

Future<void> reviewCloudSyncChange({
  required BuildContext context,
  required WidgetRef ref,
  required AuthenticatedSession session,
  required CloudSyncRequest request,
}) async {
  bool current() =>
      identical(session, ref.read(dashboardActiveSessionProvider)) &&
      !ref.read(cloudSyncInventoryProvider).isLoading &&
      identical(
        request.inventory,
        ref.read(cloudSyncInventoryProvider).asData?.value,
      );
  if (!current() ||
      request.validationError != null ||
      ref.read(cloudSyncControllerProvider).locked) {
    return;
  }
  final api = ref.read(cloudSyncSessionProvider);
  if (api == null) return;
  var expired = false;
  final sessionWatch = ref.listenManual(dashboardActiveSessionProvider, (a, b) {
    if (!identical(a, b)) expired = true;
  });
  final inventoryWatch = ref.listenManual(cloudSyncInventoryProvider, (_, b) {
    if (b.isLoading || !identical(request.inventory, b.asData?.value)) {
      expired = true;
    }
  });
  try {
    final review = await api.reviewCloudSync(request);
    if (!context.mounted || expired || !current()) return;
    if (!identical(review.request, request) ||
        review.endpoint != session.endpoint) {
      throw StateError('Mismatching review');
    }
    final confirmed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => CloudSyncReviewDialog(session: session, review: review),
    );
    if (!context.mounted || confirmed != true || expired || !current()) return;
    await ref
        .read(cloudSyncControllerProvider.notifier)
        .execute(
          expectedSession: session,
          review: review,
          confirmation: review.target,
        );
  } finally {
    sessionWatch.close();
    inventoryWatch.close();
  }
}

class CloudSyncReviewDialog extends ConsumerStatefulWidget {
  const CloudSyncReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final CloudSyncReview review;
  @override
  ConsumerState<CloudSyncReviewDialog> createState() =>
      _CloudSyncReviewDialogState();
}

class _CloudSyncReviewDialogState extends ConsumerState<CloudSyncReviewDialog> {
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
    final session = ref.watch(dashboardActiveSessionProvider),
        inventory = ref.watch(cloudSyncInventoryProvider),
        locked = ref.watch(cloudSyncControllerProvider).locked;
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(cloudSyncInventoryProvider, (_, b) {
      if (b.isLoading ||
          !identical(widget.review.request.inventory, b.asData?.value)) {
        _expire();
      }
    });
    final current =
        !_expired &&
        identical(session, widget.session) &&
        !inventory.isLoading &&
        identical(widget.review.request.inventory, inventory.asData?.value);
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('cloud-sync-review-scroll'),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  current
                      ? 'Review ${widget.review.action.name}'
                      : 'Review expired',
                  style: Theme.of(context).textTheme.titleLarge,
                ),
                if (!current)
                  const Text(
                    'Previous server and destination details are hidden. Reload and review again.',
                  )
                else ...[
                  SelectableText(widget.review.endpoint),
                  SelectableText(widget.review.target),
                  for (final warning in widget.review.warnings)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(warning),
                    ),
                  const SizedBox(height: 16),
                  TextField(
                    key: const Key('cloud-sync-confirm-target'),
                    controller: _confirmation,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Type the exact target',
                      helperText: 'Case-sensitive; no trimming.',
                      helperMaxLines: 2,
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  CheckboxListTile(
                    key: const Key('cloud-sync-confirm-impact'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    value: _acknowledged,
                    onChanged: (v) =>
                        setState(() => _acknowledged = v ?? false),
                    title: const Text(
                      'I understand these effects and verified the prerequisites.',
                    ),
                  ),
                ],
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.of(context).pop(false),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      key: const Key('cloud-sync-confirm-submit'),
                      onPressed:
                          current &&
                              !locked &&
                              _acknowledged &&
                              _confirmation.text == widget.review.target
                          ? () => Navigator.of(context).pop(true)
                          : null,
                      child: const Text('Confirm once'),
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
