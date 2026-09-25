import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'system_power_controller.dart';
import 'system_power_identity.dart';

class SystemPowerReviewDialog extends ConsumerStatefulWidget {
  const SystemPowerReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final SystemPowerReview review;
  @override
  ConsumerState<SystemPowerReviewDialog> createState() =>
      _SystemPowerReviewDialogState();
}

class _SystemPowerReviewDialogState
    extends ConsumerState<SystemPowerReviewDialog> {
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
    ref.listen(systemPowerInventoryProvider, (_, next) {
      if (next.isLoading ||
          !identical(widget.review.request.inventory, next.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(systemPowerInventoryProvider);
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(widget.review.request.inventory, inventory.asData?.value);
    final locked = ref.watch(systemPowerControllerProvider).locked;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('power-review-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? 'Review: ${systemPowerLabel(widget.review.action)}'
                    : 'Power review expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous server details and confirmation are hidden. Reload and review again.',
                )
              else ...[
                SelectableText(widget.review.endpoint),
                const SizedBox(height: 12),
                SystemPowerIdentity(inventory: widget.review.request.inventory),
                const SizedBox(height: 12),
                Text('Audit reason: ${widget.review.request.reason}'),
                for (final warning in widget.review.warnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(warning),
                  ),
                const SizedBox(height: 12),
                const Text(
                  'Type the full action and public host identity below. Job acceptance or a lost connection will not be treated as completion.',
                ),
                SelectableText(widget.review.target),
                TextField(
                  key: const Key('power-confirm-target'),
                  controller: _confirmation,
                  autocorrect: false,
                  enableSuggestions: false,
                  minLines: 1,
                  maxLines: 4,
                  decoration: const InputDecoration(
                    labelText: 'Exact confirmation target',
                    helperText: 'Case-sensitive; no trimming.',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const Text(
                  'I have arranged client downtime and independent server access. All services will be interrupted. I will inspect the original server before reconnecting or making another change.',
                ),
                CheckboxListTile(
                  key: const Key('power-confirm-impact'),
                  contentPadding: EdgeInsets.zero,
                  value: _ack,
                  onChanged: (value) => setState(() => _ack = value ?? false),
                  title: const Text('I accept this downtime and access plan.'),
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
                    key: const Key('power-confirm-submit'),
                    onPressed:
                        current &&
                            !locked &&
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
