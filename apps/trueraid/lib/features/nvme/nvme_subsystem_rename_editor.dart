import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_host_overview.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_rename_coordinator.dart';

class NvmeSubsystemRenameEditor extends ConsumerStatefulWidget {
  const NvmeSubsystemRenameEditor({super.key});

  @override
  ConsumerState<NvmeSubsystemRenameEditor> createState() =>
      _NvmeSubsystemRenameEditorState();
}

class _NvmeSubsystemRenameEditorState
    extends ConsumerState<NvmeSubsystemRenameEditor> {
  final _id = TextEditingController();
  final _name = TextEditingController();
  final _confirmation = TextEditingController();
  NvmeRenameReview? _review;
  NvmeSubsystemRenameCoordinator? _reviewCoordinator;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _id.dispose();
    _name.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _discardReview() {
    final review = _review;
    if (review != null) _reviewCoordinator?.cancel(review);
    _review = null;
    _reviewCoordinator = null;
    _reviewSession = null;
  }

  Future<void> _prepare(NvmeSubsystemRenameCoordinator coordinator) async {
    _discardReview();
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final id = int.tryParse(_id.text.trim());
      if (id == null || id <= 0) {
        throw StateError('Enter a positive subsystem ID. Nothing was sent.');
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

  Future<void> _submit(
    NvmeSubsystemRenameCoordinator coordinator,
    NvmeRenameReview review,
  ) async {
    final phrase = _confirmation.text;
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    final result = await coordinator.execute(review, phrase);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = result.message;
    });
    if (result.outcome == NvmeRenameOutcome.completed) {
      _id.clear();
      _name.clear();
      _confirmation.clear();
      ref.invalidate(nvmeOverviewProvider);
      ref.invalidate(nvmeHostOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(nvmeSubsystemRenameCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            identical(coordinator, _reviewCoordinator) &&
            _id.text.trim() == _review?.id.toString() &&
            _name.text == _review?.newName
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Rename an unbound NVMe-oF subsystem',
      description: 'Only a restricted subsystem with a returned NQN and no host, port or namespace association is eligible. The NQN is explicitly preserved.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('nvme-subsystem-rename-id'),
            controller: _id,
            enabled: enabled,
            keyboardType: TextInputType.number,
            maxLength: 12,
            decoration: const InputDecoration(
              labelText: 'Subsystem ID from explorer',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          TextField(
            key: const Key('nvme-subsystem-rename-name'),
            controller: _name,
            enabled: enabled,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'New display name',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          OutlinedButton(
            key: const Key('nvme-subsystem-rename-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review rename'),
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
            Text(
              'Subsystem #${review.id}: ${review.oldName} → ${review.newName}',
            ),
            Text('Preserved NQN: ${review.subnqn}'),
            const Text(
              'Only nvmet.subsys.update(id, {name, subnqn}) is submitted. No access policy, host, port or namespace mapping is sent.',
            ),
            const Text(
              'All returned dependencies are checked again. Sequential reads cannot exclude a concurrent administrator.',
            ),
            TextField(
              key: const Key('nvme-subsystem-rename-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('nvme-subsystem-rename-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Rename subsystem'),
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
