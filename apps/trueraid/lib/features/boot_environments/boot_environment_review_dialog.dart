import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';

/// A review belongs to the exact connection that supplied its target.
/// Losing that connection discards the visible confirmation form.
class BootEnvironmentReviewDialog extends ConsumerStatefulWidget {
  const BootEnvironmentReviewDialog({
    required this.session,
    required this.title,
    required this.target,
    required this.details,
    required this.confirmLabel,
    this.acknowledgement,
    super.key,
  });

  final AuthenticatedSession session;
  final String title, target, confirmLabel;
  final List<String> details;
  final String? acknowledgement;

  @override
  ConsumerState<BootEnvironmentReviewDialog> createState() =>
      _BootEnvironmentReviewDialogState();
}

class _BootEnvironmentReviewDialogState
    extends ConsumerState<BootEnvironmentReviewDialog> {
  final _confirmation = TextEditingController();
  var _acknowledged = false;
  var _expired = false;

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!identical(widget.session, ref.watch(dashboardActiveSessionProvider))) {
      _expired = true;
      _confirmation.clear();
      _acknowledged = false;
    }
    final current = !_expired;
    return Dialog(
      insetPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: SingleChildScrollView(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current ? widget.title : 'Connection changed',
                style: TdTypography.titleMedium,
              ),
              const SizedBox(height: 16),
              if (!current || widget.session.endpoint == null) ...[
                const Text(
                  'This review has expired. Close it and load boot environments '
                  'from the current server before reviewing another change.',
                ),
                const SizedBox(height: 16),
                OutlinedButton(
                  key: const Key('boot-review-close'),
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Close'),
                ),
              ] else ...[
                Text('Server: ${widget.session.endpoint}'),
                const SizedBox(height: 8),
                Text('Exact target: ${widget.target}'),
                const SizedBox(height: 16),
                for (final detail in widget.details)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: Text(detail),
                  ),
                TextField(
                  key: const Key('boot-review-confirmation'),
                  controller: _confirmation,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Type the exact target name',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                if (widget.acknowledgement != null) ...[
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    key: const Key('boot-review-acknowledge'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text(widget.acknowledgement!),
                    value: _acknowledged,
                    onChanged: (value) =>
                        setState(() => _acknowledged = value == true),
                  ),
                ],
                const SizedBox(height: 20),
                FilledButton(
                  key: const Key('boot-review-confirm'),
                  onPressed:
                      _confirmation.text == widget.target &&
                          (widget.acknowledgement == null || _acknowledged)
                      ? () => Navigator.of(context).pop(true)
                      : null,
                  child: Text(widget.confirmLabel, textAlign: TextAlign.center),
                ),
                const SizedBox(height: 8),
                OutlinedButton(
                  key: const Key('boot-review-cancel'),
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Cancel'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}
