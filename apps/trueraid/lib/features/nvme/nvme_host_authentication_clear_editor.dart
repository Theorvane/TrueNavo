import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_host_overview.dart';
import 'nvme_host_authentication_panel.dart';
import 'nvme_overview.dart';
import 'nvme_host_authentication_clear_coordinator.dart';

class NvmeHostAuthenticationClearEditor extends ConsumerStatefulWidget {
  const NvmeHostAuthenticationClearEditor({super.key});

  @override
  ConsumerState<NvmeHostAuthenticationClearEditor> createState() =>
      _NvmeHostAuthenticationClearEditorState();
}

class _NvmeHostAuthenticationClearEditorState
    extends ConsumerState<NvmeHostAuthenticationClearEditor> {
  final _id = TextEditingController();
  final _confirmation = TextEditingController();
  NvmeHostAuthenticationClearReview? _review;
  NvmeHostAuthenticationClearCoordinator? _reviewCoordinator;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;
  bool _acknowledgeCredentialLoss = false;

  @override
  void dispose() {
    _discardReview();
    _id.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(
    NvmeHostAuthenticationClearCoordinator coordinator,
  ) async {
    _discardReview();
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final id = int.tryParse(_id.text.trim());
      if (id == null || id <= 0) {
        throw StateError(
          'Enter a positive host database ID. Nothing was sent.',
        );
      }
      final review = await coordinator.prepare(id);
      if (!mounted) {
        coordinator.cancel(review);
        return;
      }
      setState(() {
        _review = review;
        _reviewCoordinator = coordinator;
        _reviewSession = ref.read(dashboardActiveSessionProvider);
        _confirmation.clear();
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

  void _discardReview() {
    final review = _review;
    if (review != null) _reviewCoordinator?.cancel(review);
    _review = null;
    _reviewCoordinator = null;
    _reviewSession = null;
    _acknowledgeCredentialLoss = false;
  }

  Future<void> _submit(
    NvmeHostAuthenticationClearCoordinator coordinator,
    NvmeHostAuthenticationClearReview review,
  ) async {
    final phrase = _confirmation.text;
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    final result = await coordinator.execute(
      review,
      phrase,
      acknowledgeCredentialLoss: _acknowledgeCredentialLoss,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = result.message;
    });
    if (result.outcome == NvmeHostAuthenticationClearOutcome.completed) {
      _id.clear();
      _confirmation.clear();
      ref.invalidate(nvmeOverviewProvider);
      ref.invalidate(nvmeHostOverviewProvider);
      ref.invalidate(nvmeHostAuthenticationProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(
      nvmeHostAuthenticationClearCoordinatorProvider,
    );
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            identical(coordinator, _reviewCoordinator) &&
            _id.text.trim() == _review?.id.toString()
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Clear unassociated NVMe-oF host authentication',
      description: 'Clears the current host key, controller key and DH group only for a host without subsystem mappings. NQN and saved hash are preserved. Removing these settings removes DH-CHAP requirements for future mappings. The app does not retain or restore old keys.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('nvme-host-auth-clear-id'),
            controller: _id,
            enabled: enabled,
            keyboardType: TextInputType.number,
            maxLength: 12,
            decoration: const InputDecoration(
              labelText: 'Host database ID from host inventory',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          OutlinedButton(
            key: const Key('nvme-host-auth-clear-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review authentication removal'),
          ),
          if (coordinator == null || !coordinator.available)
            const Text(
              'This server does not expose the required NVMe-oF methods and protected host inventory.',
            ),
          if (coordinator?.locked == true)
            const Text(
              'An NVMe-oF change is in progress or unverified. Reconnect before retrying.',
            ),
          if (review != null && coordinator != null) ...[
            const Divider(),
            Text('Server: ${review.endpoint}'),
            Text('Host #${review.id}: ${review.nqn}'),
            Text('Preserved hash: ${review.target.hash}'),
            Text(
              'Returned key flags: host ${review.target.hostKeyReturned}, controller ${review.target.controllerKeyReturned}; DH group ${review.target.group ?? "unset"}',
            ),
            const Text(
              'Payload: nvmet.host.update(host ID, {dhchap_key: null, dhchap_ctrl_key: null, dhchap_dhgroup: null}) only. NQN, saved hash and mappings are not submitted. The server reloads NVMe configuration.',
            ),
            const Text(
              'The inventory and public authentication metadata are checked again before submission. Returned flags may be redacted and cannot detect key rotations with the same flags. Other administrators can still change the server concurrently. This clears the current settings; old keys cannot be recovered through this app.',
            ),
            TextField(
              key: const Key('nvme-host-auth-clear-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-host-auth-clear-consent'),
                  value: _acknowledgeCredentialLoss,
                  onChanged: _busy
                      ? null
                      : (value) => setState(
                          () => _acknowledgeCredentialLoss = value == true,
                        ),
                ),
                const Expanded(
                  child: Text(
                    'I understand that current DH-CHAP credentials will be removed, cannot be restored by this app, and future subsystem mappings will not require these keys. Runtime authentication is not verified.',
                  ),
                ),
              ],
            ),
            FilledButton(
              key: const Key('nvme-host-auth-clear-submit'),
              onPressed: _busy || !_acknowledgeCredentialLoss
                  ? null
                  : () => _submit(coordinator, review),
              child: const Text('Clear host authentication'),
            ),
            TextButton(
              onPressed: _busy ? null : () => setState(_discardReview),
              child: const Text('Cancel'),
            ),
          ],
          if (_message != null) Text(_message!),
        ],
      ),
    );
  }
}
