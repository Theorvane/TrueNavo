import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'disks_controller.dart';

class DisksReviewDialog extends ConsumerStatefulWidget {
  const DisksReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final DiskReview review;
  @override
  ConsumerState<DisksReviewDialog> createState() => _DisksReviewDialogState();
}

class _DisksReviewDialogState extends ConsumerState<DisksReviewDialog> {
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

  void _expire() {
    if (_expired) return;
    setState(() {
      _expired = true;
      _ack = false;
      _confirmation.clear();
    });
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(disksInventoryProvider, (_, b) {
      if (b.isLoading ||
          !identical(widget.review.request.inventory, b.asData?.value)) {
        _expire();
      }
    });
    final data = ref.watch(disksInventoryProvider);
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !data.isLoading &&
        identical(widget.review.request.inventory, data.asData?.value);
    final disk = widget.review.request.disk,
        next = widget.review.request.settings;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('disks-review-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current ? 'Review disk settings' : 'Review expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              const SizedBox(height: 12),
              if (!current)
                const Text(
                  'Previous server details are hidden. Reload and review again.',
                )
              else ...[
                SelectableText(widget.review.endpoint),
                SelectableText(widget.review.target),
                Text('Disk: ${disk.name} · Serial: ${disk.serial}'),
                Text(
                  'Pool: ${disk.pool ?? 'No recorded pool'} · Boot disk: ${disk.bootDisk ? 'Yes' : 'No'}',
                ),
                const SizedBox(height: 12),
                _change('Description', disk.description, next.description),
                _change('HDD standby', disk.hddStandby, next.hddStandby),
                _change(
                  'Advanced power management',
                  disk.advancedPowerManagement,
                  next.advancedPowerManagement,
                ),
                for (final warning in widget.review.warnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(warning),
                  ),
                const SizedBox(height: 16),
                TextField(
                  key: const Key('disk-confirm-target'),
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
                  key: const Key('disk-confirm-impact'),
                  contentPadding: EdgeInsets.zero,
                  value: _ack,
                  onChanged: (v) => setState(() => _ack = v ?? false),
                  title: const Text(
                    'I verified this disk and understand the access-latency and power-policy effects.',
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
                    key: const Key('disk-confirm-submit'),
                    onPressed:
                        current &&
                            !ref.watch(disksControllerProvider).locked &&
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

  Widget _change(String label, String before, String after) => Padding(
    padding: const EdgeInsets.only(bottom: 12),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w600)),
        Text('Before: ${before.isEmpty ? '(empty)' : before}'),
        Text('After: ${after.isEmpty ? '(empty)' : after}'),
      ],
    ),
  );
}
