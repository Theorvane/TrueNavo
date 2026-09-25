import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'alerts_controller.dart';

/// The same identity/lifecycle boundary protects both read-only details and review.
class AlertsDialog extends ConsumerStatefulWidget {
  const AlertsDialog({
    required this.session,
    required this.inventory,
    required this.alert,
    this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final AlertInventory inventory;
  final AlertSnapshot alert;
  final AlertReview? review;
  @override
  ConsumerState<AlertsDialog> createState() => _AlertsDialogState();
}

class _AlertsDialogState extends ConsumerState<AlertsDialog> {
  final _confirmation = TextEditingController();
  late final AppLifecycleListener _lifecycle;
  bool _expired = false, _ack = false;
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
    _confirmation.clear();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(alertsInventoryProvider, (_, b) {
      if (b.isLoading || !identical(widget.inventory, b.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(alertsInventoryProvider),
        review = widget.review;
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(widget.inventory, inventory.asData?.value);
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('alerts-dialog-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? review == null
                          ? 'Alert details'
                          : 'Review ${review.action.name}'
                    : 'Alert view expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous alert details are hidden. Reload and review on the current connection.',
                )
              else ...[
                SelectableText(widget.inventory.endpoint),
                const SizedBox(height: 12),
                Text(
                  widget.alert.title,
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                Text(
                  '${widget.alert.level} · ${widget.alert.dismissed ? 'Dismissed' : 'Active'} · ${widget.alert.category}',
                ),
                Text('Source: ${widget.alert.sourceLabel}'),
                Text('Node: ${widget.alert.node}'),
                SelectableText('UUID: ${widget.alert.id}'),
                Text(
                  'First seen (UTC): ${widget.alert.firstSeen.toUtc().toIso8601String()}',
                ),
                Text(
                  'Last occurrence (UTC): ${widget.alert.lastSeen.toUtc().toIso8601String()}',
                ),
                const SizedBox(height: 12),
                Text(widget.alert.summary),
                for (final entry in widget.alert.metrics.entries)
                  Text('${entry.key}: ${entry.value}'),
                const Padding(
                  padding: EdgeInsets.only(top: 12),
                  child: Text(
                    'Raw messages, HTML, arguments, keys and mail details are withheld. These coded descriptions do not identify or diagnose the affected resource.',
                  ),
                ),
                if (widget.alert.blockedReason case final reason?) Text(reason),
                if (review != null) ...[
                  for (final warning in review.warnings)
                    Padding(
                      padding: const EdgeInsets.only(top: 12),
                      child: Text(warning),
                    ),
                  const SizedBox(height: 12),
                  SelectableText(review.target),
                  TextField(
                    key: const Key('alerts-confirm-target'),
                    controller: _confirmation,
                    autocorrect: false,
                    enableSuggestions: false,
                    enableIMEPersonalizedLearning: false,
                    decoration: const InputDecoration(
                      labelText: 'Type the exact target',
                      helperText: 'Case-sensitive; no trimming.',
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  CheckboxListTile(
                    key: const Key('alerts-confirm-impact'),
                    contentPadding: EdgeInsets.zero,
                    value: _ack,
                    onChanged: (v) => setState(() => _ack = v ?? false),
                    title: const Text(
                      'I inspected this alert and understand that changing its visibility does not resolve it.',
                    ),
                  ),
                ],
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text(review == null ? 'Close' : 'Cancel'),
                  ),
                  if (review != null)
                    FilledButton(
                      key: const Key('alerts-confirm-submit'),
                      onPressed:
                          current &&
                              !ref.watch(alertsControllerProvider).locked &&
                              _ack &&
                              _confirmation.text == review.target
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
