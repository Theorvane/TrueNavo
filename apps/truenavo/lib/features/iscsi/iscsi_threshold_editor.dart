import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_global_panel.dart';
import 'iscsi_threshold_coordinator.dart';

class IscsiThresholdEditor extends ConsumerStatefulWidget {
  const IscsiThresholdEditor({super.key});

  @override
  ConsumerState<IscsiThresholdEditor> createState() =>
      _IscsiThresholdEditorState();
}

class _IscsiThresholdEditorState extends ConsumerState<IscsiThresholdEditor> {
  final _value = TextEditingController();
  final _confirmation = TextEditingController();
  IscsiThresholdReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _value.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(IscsiThresholdCoordinator coordinator) async {
    final text = _value.text.trim();
    final proposed = text.toLowerCase() == 'off' ? null : int.tryParse(text);
    if (text.isEmpty || (proposed == null && text.toLowerCase() != 'off')) {
      setState(() => _message = 'Enter 1–99 or off.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _review = null;
    });
    try {
      final review = await coordinator.prepare(proposed);
      if (!mounted) return;
      setState(() {
        _review = review;
        _reviewSession = ref.read(dashboardActiveSessionProvider);
      });
    } on StateError catch (error) {
      if (mounted) setState(() => _message = error.message.toString());
    } on Object {
      if (mounted) {
        setState(() => _message = 'Preflight failed. Nothing was sent.');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    IscsiThresholdCoordinator coordinator,
    IscsiThresholdReview review,
  ) async {
    final confirmation = _confirmation.text;
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    final result = await coordinator.execute(review, confirmation);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = result.message;
    });
    if (result.outcome == IscsiThresholdOutcome.completed) {
      ref.invalidate(iscsiGlobalProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiThresholdCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review = identical(session, _reviewSession) ? _review : null;
    return TdPanel(
      title: 'Pool free-space alert threshold',
      description: 'A narrow iSCSI global-setting edit. Other iSCSI management is not available here.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Stop the iSCSI service and disconnect every client before preparing a change. This check is not atomic with other administrators.',
          ),
          const SizedBox(height: 12),
          TextField(
            key: const Key('iscsi-threshold-value'),
            controller: _value,
            enabled:
                !_busy &&
                coordinator != null &&
                coordinator.available &&
                !coordinator.locked,
            decoration: const InputDecoration(
              labelText: 'New threshold',
              hintText: '1–99 or off',
              border: OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 10),
          OutlinedButton(
            key: const Key('iscsi-threshold-review'),
            onPressed:
                _busy ||
                    coordinator == null ||
                    !coordinator.available ||
                    coordinator.locked
                ? null
                : () => _prepare(coordinator),
            child: const Text('Review change'),
          ),
          if (coordinator == null || !coordinator.available)
            const Text(
              'This server does not expose the required management methods.',
            ),
          if (coordinator?.locked == true)
            const Text(
              'Another change is in progress or its outcome is unverified. Reconnect before retrying.',
            ),
          if (review != null && coordinator != null) ...[
            const Divider(),
            Text('Server: ${review.endpoint}'),
            Text(
              'Threshold: ${review.before?.toString() ?? 'off'} → ${review.proposed?.toString() ?? 'off'}',
            ),
            const Text(
              'The service and sessions are checked again immediately before submission. External changes can still race with this update.',
            ),
            const SizedBox(height: 8),
            TextField(
              key: const Key('iscsi-threshold-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('iscsi-threshold-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Update threshold'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      coordinator.cancel(review);
                      setState(() => _review = null);
                    },
              child: const Text('Cancel'),
            ),
          ],
          if (_message != null) Text(_message!),
        ],
      ),
    );
  }
}
