import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_host_overview.dart';
import 'nvme_overview.dart';
import 'nvme_host_rename_coordinator.dart';

class NvmeHostRenameEditor extends ConsumerStatefulWidget {
  const NvmeHostRenameEditor({super.key});

  @override
  ConsumerState<NvmeHostRenameEditor> createState() =>
      _NvmeHostRenameEditorState();
}

class _NvmeHostRenameEditorState extends ConsumerState<NvmeHostRenameEditor> {
  final _name = TextEditingController();
  final _id = TextEditingController();
  final _confirmation = TextEditingController();
  NvmeHostRenameReview? _review;
  NvmeHostRenameCoordinator? _reviewCoordinator;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;
  bool _acknowledgeIdentityChange = false;

  @override
  void dispose() {
    _discardReview();
    _id.dispose();
    _name.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(NvmeHostRenameCoordinator coordinator) async {
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
      final review = await coordinator.prepare(id, _name.text);
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
    _acknowledgeIdentityChange = false;
  }

  Future<void> _submit(
    NvmeHostRenameCoordinator coordinator,
    NvmeHostRenameReview review,
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
      acknowledgeIdentityChange: _acknowledgeIdentityChange,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = result.message;
    });
    if (result.outcome == NvmeHostRenameOutcome.completed) {
      _id.clear();
      _name.clear();
      _confirmation.clear();
      ref.invalidate(nvmeOverviewProvider);
      ref.invalidate(nvmeHostOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(nvmeHostRenameCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            identical(coordinator, _reviewCoordinator) &&
            _name.text == _review?.nqn &&
            _id.text.trim() == _review?.id.toString()
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Change unassociated NVMe-oF host NQN',
      description: 'Changes only the NQN of a host without subsystem mappings or configured DH-CHAP keys. Existing initiators may need reconfiguration. Authentication and live client access are not verified.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('nvme-host-rename-id'),
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
          TextField(
            key: const Key('nvme-host-rename-name'),
            controller: _name,
            enabled: enabled,
            maxLength: 223,
            decoration: const InputDecoration(
              labelText: 'New exact initiator host NQN',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          OutlinedButton(
            key: const Key('nvme-host-rename-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review host NQN change'),
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
            Text('Host #${review.id}: ${review.oldNqn} → ${review.nqn}'),
            const Text(
              'Payload: nvmet.host.update(host ID, {hostnqn: new NQN}) only. No authentication or mapping fields are submitted. The server reloads NVMe configuration.',
            ),
            const Text(
              'The inventory and unset authentication keys are checked again before changing the NQN. Other administrators can still change the server concurrently.',
            ),
            TextField(
              key: const Key('nvme-host-rename-confirmation'),
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
                  key: const Key('nvme-host-rename-consent'),
                  value: _acknowledgeIdentityChange,
                  onChanged: _busy
                      ? null
                      : (value) => setState(
                          () => _acknowledgeIdentityChange = value == true,
                        ),
                ),
                const Expanded(
                  child: Text(
                    'I understand that the initiator NQN changes and existing initiators may need reconfiguration. Authentication is not configured or verified.',
                  ),
                ),
              ],
            ),
            FilledButton(
              key: const Key('nvme-host-rename-submit'),
              onPressed: _busy || !_acknowledgeIdentityChange
                  ? null
                  : () => _submit(coordinator, review),
              child: const Text('Change host NQN'),
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
