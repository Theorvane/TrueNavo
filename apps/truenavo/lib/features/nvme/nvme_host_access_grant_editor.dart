import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_host_access_grant_coordinator.dart';
import 'nvme_host_overview.dart';
import 'nvme_overview.dart';

class NvmeHostAccessGrantEditor extends ConsumerStatefulWidget {
  const NvmeHostAccessGrantEditor({super.key});

  @override
  ConsumerState<NvmeHostAccessGrantEditor> createState() =>
      _NvmeHostAccessGrantEditorState();
}

class _NvmeHostAccessGrantEditorState
    extends ConsumerState<NvmeHostAccessGrantEditor> {
  final _hostId = TextEditingController();
  final _subsystemId = TextEditingController();
  final _confirmation = TextEditingController();
  NvmeHostGrantReview? _review;
  NvmeHostAccessGrantCoordinator? _reviewCoordinator;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _hostId.dispose();
    _subsystemId.dispose();
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

  Future<void> _prepare(NvmeHostAccessGrantCoordinator coordinator) async {
    _discardReview();
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final hostId = int.tryParse(_hostId.text.trim());
      final subsystemId = int.tryParse(_subsystemId.text.trim());
      if (hostId == null ||
          hostId <= 0 ||
          subsystemId == null ||
          subsystemId <= 0) {
        throw StateError(
          'Enter positive host and subsystem IDs. Nothing was sent.',
        );
      }
      final review = await coordinator.prepare(hostId, subsystemId);
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
    NvmeHostAccessGrantCoordinator coordinator,
    NvmeHostGrantReview review,
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
    if (result.outcome == NvmeHostGrantOutcome.completed) {
      _hostId.clear();
      _subsystemId.clear();
      _confirmation.clear();
      ref.invalidate(nvmeOverviewProvider);
      ref.invalidate(nvmeHostOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(nvmeHostAccessGrantCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            identical(coordinator, _reviewCoordinator) &&
            _hostId.text.trim() == _review?.hostId.toString() &&
            _subsystemId.text.trim() == _review?.subsystemId.toString()
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Grant NVMe-oF host access',
      description: 'Associates an existing host only with a restricted subsystem that has no returned port or namespace. A concurrent administrator could still expose it; coordinate before editing.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('nvme-host-grant-host-id'),
            controller: _hostId,
            enabled: enabled,
            keyboardType: TextInputType.number,
            maxLength: 12,
            decoration: const InputDecoration(
              labelText: 'Existing host ID from host explorer',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          TextField(
            key: const Key('nvme-host-grant-subsystem-id'),
            controller: _subsystemId,
            enabled: enabled,
            keyboardType: TextInputType.number,
            maxLength: 12,
            decoration: const InputDecoration(
              labelText: 'Restricted subsystem ID',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          OutlinedButton(
            key: const Key('nvme-host-grant-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review host grant'),
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
            Text('Host #${review.hostId}: ${review.hostNqn}'),
            Text('Subsystem #${review.subsystemId}: ${review.subsystemName}'),
            Text('Subsystem NQN: ${review.subnqn}'),
            const Text(
              'Only nvmet.host_subsys.create({host_id, subsys_id}) is submitted. No key or storage mapping is submitted.',
            ),
            const Text(
              'Adding a grant may permit access if another administrator attaches storage and a port. Sequential reads cannot exclude that race.',
            ),
            TextField(
              key: const Key('nvme-host-grant-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('nvme-host-grant-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Grant host access'),
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
