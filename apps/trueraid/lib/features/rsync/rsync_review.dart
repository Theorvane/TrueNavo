import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'rsync_controller.dart';
import 'rsync_labels.dart';
import 'rsync_settings_summary.dart';

class RsyncReviewDialog extends ConsumerStatefulWidget {
  const RsyncReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final RsyncReview review;
  @override
  ConsumerState<RsyncReviewDialog> createState() => _RsyncReviewDialogState();
}

class _RsyncReviewDialogState extends ConsumerState<RsyncReviewDialog> {
  final _confirmation = TextEditingController();
  bool _ack = false, _expired = false;
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    final initial = WidgetsBinding.instance.lifecycleState;
    _expired = initial != null && initial != AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) _expire();
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _expire() {
    if (_expired) return;
    setState(() {
      _expired = true;
      _ack = false;
      _confirmation.clear();
    });
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(rsyncInventoryProvider, (_, b) {
      if (b.isLoading ||
          !identical(widget.review.request.inventory, b.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(rsyncInventoryProvider);
    final state = ref.watch(rsyncControllerProvider);
    final allowed = !state.locked;
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(widget.review.request.inventory, inventory.asData?.value);
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('rsync-review-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? 'Review: ${rsyncActionLabel(widget.review.action)}'
                    : 'Review expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'The previous server details are hidden. Reload and review again.',
                )
              else ...[
                SelectableText(widget.review.endpoint),
                SelectableText(widget.review.target),
                RsyncSettingsSummary(request: widget.review.request),
                for (final warning in widget.review.warnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(warning),
                  ),
                TextField(
                  key: const Key('rsync-confirm-target'),
                  controller: _confirmation,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Type the exact target',
                    helperText: 'Case-sensitive; no trimming.',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                CheckboxListTile(
                  key: const Key('rsync-confirm-impact'),
                  contentPadding: EdgeInsets.zero,
                  value: _ack,
                  onChanged: (v) => setState(() => _ack = v ?? false),
                  title: const Text(
                    'I understand this operation can affect destination files and future scheduled transfers. Disabling or deleting a task does not stop a transfer.',
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
                    key: const Key('rsync-confirm-submit'),
                    onPressed:
                        current &&
                            allowed &&
                            _ack &&
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
    );
  }
}
