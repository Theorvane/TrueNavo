import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_host_overview.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_ana_coordinator.dart';

class NvmeSubsystemAnaEditor extends ConsumerStatefulWidget {
  const NvmeSubsystemAnaEditor({super.key});

  @override
  ConsumerState<NvmeSubsystemAnaEditor> createState() =>
      _NvmeSubsystemAnaEditorState();
}

class _NvmeSubsystemAnaEditorState
    extends ConsumerState<NvmeSubsystemAnaEditor> {
  final _id = TextEditingController();
  final _confirmation = TextEditingController();
  NvmeAnaChoice _choice = NvmeAnaChoice.inherit;
  NvmeAnaReview? _review;
  NvmeSubsystemAnaCoordinator? _reviewCoordinator;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

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
  }

  Future<void> _prepare(NvmeSubsystemAnaCoordinator coordinator) async {
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
      final review = await coordinator.prepare(id, _choice);
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
    NvmeSubsystemAnaCoordinator coordinator,
    NvmeAnaReview review,
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
    if (result.outcome == NvmeAnaOutcome.completed) {
      _id.clear();
      _confirmation.clear();
      ref.invalidate(nvmeOverviewProvider);
      ref.invalidate(nvmeHostOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(nvmeSubsystemAnaCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            identical(coordinator, _reviewCoordinator) &&
            _id.text.trim() == _review?.id.toString() &&
            _choice == _review?.choice
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Set ANA on an empty NVMe-oF subsystem',
      description: 'Changes only an unbound restricted subsystem with no returned host, port or namespace association. ANA can affect path behavior if this configuration is later exposed.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('nvme-subsystem-ana-id'),
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
          DropdownButtonFormField<NvmeAnaChoice>(
            key: const Key('nvme-subsystem-ana-choice'),
            isExpanded: true,
            initialValue: _choice,
            decoration: const InputDecoration(
              labelText: 'ANA configuration',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: NvmeAnaChoice.inherit,
                child: Text('Inherit global setting'),
              ),
              DropdownMenuItem(
                value: NvmeAnaChoice.on,
                child: Text('Override: on'),
              ),
              DropdownMenuItem(
                value: NvmeAnaChoice.off,
                child: Text('Override: off'),
              ),
            ],
            onChanged: enabled
                ? (value) {
                    if (value != null) {
                      setState(() {
                        _discardReview();
                        _choice = value;
                      });
                    }
                  }
                : null,
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('nvme-subsystem-ana-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review ANA change'),
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
            Text('Subsystem #${review.id}: ${review.name}'),
            Text('NQN: ${review.subnqn}'),
            Text('ANA: ${review.oldLabel} → ${review.newLabel}'),
            const Text(
              'Only nvmet.subsys.update(id, {ana: selected value}) is submitted. No mapping or other subsystem field is sent.',
            ),
            const Text(
              'Dependencies are checked again before submission. Sequential reads cannot exclude a concurrent administrator.',
            ),
            TextField(
              key: const Key('nvme-subsystem-ana-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('nvme-subsystem-ana-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Set ANA'),
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
