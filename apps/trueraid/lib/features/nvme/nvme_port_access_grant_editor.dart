import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_host_overview.dart';
import 'nvme_overview.dart';
import 'nvme_port_access_grant_coordinator.dart';

class NvmePortAccessGrantEditor extends ConsumerStatefulWidget {
  const NvmePortAccessGrantEditor({super.key});

  @override
  ConsumerState<NvmePortAccessGrantEditor> createState() =>
      _NvmePortAccessGrantEditorState();
}

class _NvmePortAccessGrantEditorState
    extends ConsumerState<NvmePortAccessGrantEditor> {
  final _portId = TextEditingController();
  final _subsystemId = TextEditingController();
  final _confirmation = TextEditingController();
  NvmePortGrantReview? _review;
  NvmePortAccessGrantCoordinator? _reviewCoordinator;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _portId.dispose();
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

  Future<void> _prepare(NvmePortAccessGrantCoordinator coordinator) async {
    _discardReview();
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final portId = int.tryParse(_portId.text.trim());
      final subsystemId = int.tryParse(_subsystemId.text.trim());
      if (portId == null ||
          portId <= 0 ||
          subsystemId == null ||
          subsystemId <= 0) {
        throw StateError(
          'Enter positive port and subsystem IDs. Nothing was sent.',
        );
      }
      final review = await coordinator.prepare(portId, subsystemId);
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
    NvmePortAccessGrantCoordinator coordinator,
    NvmePortGrantReview review,
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
    if (result.outcome == NvmePortGrantOutcome.completed) {
      _portId.clear();
      _subsystemId.clear();
      _confirmation.clear();
      ref.invalidate(nvmeOverviewProvider);
      ref.invalidate(nvmeHostOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(nvmePortAccessGrantCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            identical(coordinator, _reviewCoordinator) &&
            _portId.text.trim() == _review?.portId.toString() &&
            _subsystemId.text.trim() == _review?.subsystemId.toString()
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Map disabled NVMe-oF port',
      description: 'Associates an unused disabled port only with an empty restricted subsystem. A concurrent administrator could still enable the port or attach storage.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('nvme-port-grant-port-id'),
            controller: _portId,
            enabled: enabled,
            keyboardType: TextInputType.number,
            maxLength: 12,
            decoration: const InputDecoration(
              labelText: 'Unused disabled port ID',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          TextField(
            key: const Key('nvme-port-grant-subsystem-id'),
            controller: _subsystemId,
            enabled: enabled,
            keyboardType: TextInputType.number,
            maxLength: 12,
            decoration: const InputDecoration(
              labelText: 'Empty restricted subsystem ID',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          OutlinedButton(
            key: const Key('nvme-port-grant-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review port mapping'),
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
            Text('Disabled port #${review.portId}: ${review.transport}'),
            Text('Subsystem #${review.subsystemId}: ${review.subsystemName}'),
            Text('Subsystem NQN: ${review.subnqn}'),
            const Text(
              'Only nvmet.port_subsys.create({port_id, subsys_id}) is submitted. No backing device, host grant, credential or port enablement is submitted.',
            ),
            const Text(
              'A concurrent administrator can attach storage or enable this port between sequential checks. Client reachability cannot be proven here.',
            ),
            TextField(
              key: const Key('nvme-port-grant-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('nvme-port-grant-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Map disabled port'),
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
