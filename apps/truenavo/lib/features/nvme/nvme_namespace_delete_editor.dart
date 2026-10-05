import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_overview.dart';
import 'nvme_namespace_delete_coordinator.dart';

class NvmeNamespaceDeleteEditor extends ConsumerStatefulWidget {
  const NvmeNamespaceDeleteEditor({super.key});

  @override
  ConsumerState<NvmeNamespaceDeleteEditor> createState() =>
      _NvmeNamespaceDeleteEditorState();
}

class _NvmeNamespaceDeleteEditorState
    extends ConsumerState<NvmeNamespaceDeleteEditor> {
  final _id = TextEditingController();
  final _confirmation = TextEditingController();
  NvmeNamespaceDeleteReview? _review;
  NvmeNamespaceDeleteCoordinator? _reviewCoordinator;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;
  bool _acknowledgeLoss = false;

  @override
  void dispose() {
    _id.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  void _discardReview() {
    final review = _review;
    if (review != null) _reviewCoordinator?.cancel(review);
    _review = null;
    _reviewCoordinator = null;
    _reviewSession = null;
    _acknowledgeLoss = false;
  }

  Future<void> _prepare(NvmeNamespaceDeleteCoordinator coordinator) async {
    _discardReview();
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final id = int.tryParse(_id.text.trim());
      if (id == null || id <= 0) {
        throw StateError('Enter a positive namespace ID. Nothing was sent.');
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
        _acknowledgeLoss = false;
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
    NvmeNamespaceDeleteCoordinator coordinator,
    NvmeNamespaceDeleteReview review,
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
      acknowledgeConfigurationLoss: _acknowledgeLoss,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = result.message;
    });
    if (result.outcome == NvmeNamespaceDeleteOutcome.completed) {
      _id.clear();
      _confirmation.clear();
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(nvmeNamespaceDeleteCoordinatorProvider);
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
      title: 'Remove disabled NVMe-oF namespace configuration',
      description: 'Removes only an unlocked disabled namespace configuration in a restricted subsystem without port or host mappings. Backing-file removal is never requested. The configuration may need to be recreated; backing integrity and concurrent administration are not verified.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('nvme-namespace-delete-id'),
            controller: _id,
            enabled: enabled,
            keyboardType: TextInputType.number,
            maxLength: 12,
            decoration: const InputDecoration(
              labelText: 'Namespace database ID from topology (not NSID)',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          OutlinedButton(
            key: const Key('nvme-namespace-delete-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review namespace configuration removal'),
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
              'Namespace #${review.id}: ${review.deviceType}, subsystem #${review.subsystemId}, NSID ${review.nsid}',
            ),
            const Text(
              'Only nvmet.namespace.delete(namespace database ID, {remove: false}) is submitted. No backing file, zvol or dataset removal is requested.',
            ),
            const Text(
              'All returned configuration is checked again. Sequential reads cannot exclude a concurrent administrator.',
            ),
            TextField(
              key: const Key('nvme-namespace-delete-confirmation'),
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
                  key: const Key('nvme-namespace-delete-consent'),
                  value: _acknowledgeLoss,
                  onChanged: _busy
                      ? null
                      : (value) =>
                            setState(() => _acknowledgeLoss = value == true),
                ),
                const Expanded(
                  child: Text(
                    'I understand this removes namespace configuration and may require recreation. Backing-file removal is not requested.',
                  ),
                ),
              ],
            ),
            FilledButton(
              key: const Key('nvme-namespace-delete-submit'),
              onPressed: _busy || !_acknowledgeLoss
                  ? null
                  : () => _submit(coordinator, review),
              child: const Text('Remove namespace configuration'),
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
