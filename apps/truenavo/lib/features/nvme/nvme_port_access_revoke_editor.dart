import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_host_overview.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_delete_coordinator.dart';

class NvmePortAccessRevokeEditor extends ConsumerStatefulWidget {
  const NvmePortAccessRevokeEditor({super.key});

  @override
  ConsumerState<NvmePortAccessRevokeEditor> createState() =>
      _NvmePortAccessRevokeEditorState();
}

class _NvmePortAccessRevokeEditorState
    extends ConsumerState<NvmePortAccessRevokeEditor> {
  final _mappingId = TextEditingController();
  final _confirmation = TextEditingController();
  NvmePortRevokeReview? _review;
  NvmePortAccessRevokeCoordinator? _reviewCoordinator;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _mappingId.dispose();
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

  Future<void> _prepare(NvmePortAccessRevokeCoordinator coordinator) async {
    _discardReview();
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final id = int.tryParse(_mappingId.text.trim());
      if (id == null || id <= 0) {
        throw StateError(
          'Enter a positive port association ID. Nothing was sent.',
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

  Future<void> _submit(
    NvmePortAccessRevokeCoordinator coordinator,
    NvmePortRevokeReview review,
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
    if (result.outcome == NvmePortRevokeOutcome.completed) {
      _mappingId.clear();
      _confirmation.clear();
      ref.invalidate(nvmeOverviewProvider);
      ref.invalidate(nvmeHostOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(nvmePortAccessRevokeCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            identical(coordinator, _reviewCoordinator) &&
            _mappingId.text.trim() == _review?.mappingId.toString()
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Unmap NVMe-oF port access',
      description: 'Removes one saved port–subsystem association. Active clients may disconnect; other port mappings may still expose the subsystem.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('nvme-port-revoke-id'),
            controller: _mappingId,
            enabled: enabled,
            keyboardType: TextInputType.number,
            maxLength: 12,
            decoration: const InputDecoration(
              labelText: 'Port association ID from topology',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          OutlinedButton(
            key: const Key('nvme-port-revoke-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review port unmapping'),
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
              'Association #${review.mappingId}: port #${review.portId} (${review.transport})',
            ),
            Text('Subsystem #${review.subsystemId}: ${review.subsystemName}'),
            Text('Subsystem NQN: ${review.subnqn}'),
            Text(
              '${review.namespaceCount} returned namespaces · ${review.otherPortCount} other port associations',
            ),
            const Text(
              'Only nvmet.port_subsys.delete(association ID) is submitted. This can interrupt active clients; live sessions are not checked.',
            ),
            const Text(
              'All returned configuration is checked again. Sequential reads cannot exclude a concurrent administrator.',
            ),
            TextField(
              key: const Key('nvme-port-revoke-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('nvme-port-revoke-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Unmap port'),
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
