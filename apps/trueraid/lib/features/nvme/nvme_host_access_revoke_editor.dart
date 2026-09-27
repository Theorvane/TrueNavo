import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_host_overview.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_delete_coordinator.dart';

class NvmeHostAccessRevokeEditor extends ConsumerStatefulWidget {
  const NvmeHostAccessRevokeEditor({super.key});

  @override
  ConsumerState<NvmeHostAccessRevokeEditor> createState() =>
      _NvmeHostAccessRevokeEditorState();
}

class _NvmeHostAccessRevokeEditorState
    extends ConsumerState<NvmeHostAccessRevokeEditor> {
  final _mappingId = TextEditingController();
  final _confirmation = TextEditingController();
  NvmeHostRevokeReview? _review;
  NvmeHostAccessRevokeCoordinator? _reviewCoordinator;
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

  Future<void> _prepare(NvmeHostAccessRevokeCoordinator coordinator) async {
    _discardReview();
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final id = int.tryParse(_mappingId.text.trim());
      if (id == null || id <= 0) {
        throw StateError('Enter a positive association ID. Nothing was sent.');
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
    NvmeHostAccessRevokeCoordinator coordinator,
    NvmeHostRevokeReview review,
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
    if (result.outcome == NvmeHostRevokeOutcome.completed) {
      _mappingId.clear();
      _confirmation.clear();
      ref.invalidate(nvmeOverviewProvider);
      ref.invalidate(nvmeHostOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(nvmeHostAccessRevokeCoordinatorProvider);
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
      title: 'Revoke NVMe-oF host access',
      description: 'Removes one saved host association from a restricted subsystem. This can disconnect an active client; the app cannot verify live sessions.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('nvme-host-revoke-id'),
            controller: _mappingId,
            enabled: enabled,
            keyboardType: TextInputType.number,
            maxLength: 12,
            decoration: const InputDecoration(
              labelText: 'Association ID from host explorer',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          OutlinedButton(
            key: const Key('nvme-host-revoke-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review host access removal'),
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
            Text('Association #${review.mappingId}'),
            Text('Host #${review.hostId}: ${review.hostNqn}'),
            Text('Subsystem #${review.subsystemId}: ${review.subsystemName}'),
            const Text(
              'Only nvmet.host_subsys.delete(association ID) is submitted. Removing this grant can disconnect clients. This does not delete the host or subsystem.',
            ),
            const Text(
              'All returned configuration is checked again. Sequential reads cannot exclude a concurrent administrator.',
            ),
            TextField(
              key: const Key('nvme-host-revoke-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('nvme-host-revoke-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Revoke host access'),
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
