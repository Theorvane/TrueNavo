import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_host_overview.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_qid_coordinator.dart';

class NvmeSubsystemQidEditor extends ConsumerStatefulWidget {
  const NvmeSubsystemQidEditor({super.key});

  @override
  ConsumerState<NvmeSubsystemQidEditor> createState() =>
      _NvmeSubsystemQidEditorState();
}

class _NvmeSubsystemQidEditorState
    extends ConsumerState<NvmeSubsystemQidEditor> {
  final _id = TextEditingController();
  final _limit = TextEditingController();
  final _confirmation = TextEditingController();
  bool _useDefault = true;
  NvmeQidReview? _review;
  NvmeSubsystemQidCoordinator? _reviewCoordinator;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _id.dispose();
    _limit.dispose();
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

  Future<void> _prepare(NvmeSubsystemQidCoordinator coordinator) async {
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
      final rawLimit = _limit.text.trim();
      final parsedLimit = int.tryParse(rawLimit);
      if (!_useDefault &&
          (!RegExp(r'^[1-9][0-9]*$').hasMatch(rawLimit) ||
              parsedLimit == null ||
              parsedLimit > 2147483647)) {
        throw StateError(
          'Enter a queue-ID limit from 1 to 2147483647. Nothing was sent.',
        );
      }
      final review = await coordinator.prepare(
        id,
        NvmeQidChoice(_useDefault ? null : parsedLimit),
      );
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
    NvmeSubsystemQidCoordinator coordinator,
    NvmeQidReview review,
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
    if (result.outcome == NvmeQidOutcome.completed) {
      _id.clear();
      _limit.clear();
      _useDefault = true;
      _confirmation.clear();
      ref.invalidate(nvmeOverviewProvider);
      ref.invalidate(nvmeHostOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(nvmeSubsystemQidCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            identical(coordinator, _reviewCoordinator) &&
            _id.text.trim() == _review?.id.toString() &&
            _useDefault == (_review?.choice.wireValue == null) &&
            (_useDefault ||
                _limit.text.trim() == _review?.choice.wireValue?.toString())
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Set maximum queue IDs on an empty NVMe-oF subsystem',
      description: 'Changes only an unbound restricted subsystem with no returned host, port or namespace association. The saved limit may affect future client queues.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('nvme-subsystem-qid-id'),
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
          Row(
            children: [
              const Expanded(child: Text('Use server default')),
              Switch(
                key: const Key('nvme-subsystem-qid-default'),
                value: _useDefault,
                onChanged: enabled
                    ? (value) => setState(() {
                        _discardReview();
                        _useDefault = value;
                      })
                    : null,
              ),
            ],
          ),
          TextField(
            key: const Key('nvme-subsystem-qid-limit'),
            controller: _limit,
            enabled: enabled && !_useDefault,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Maximum queue IDs (1–2147483647)',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('nvme-subsystem-qid-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review queue-ID limit'),
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
            Text('Maximum queue IDs: ${review.oldLabel} → ${review.newLabel}'),
            const Text(
              'Only nvmet.subsys.update(id, {qid_max: selected value}) is submitted. No mapping or other subsystem field is sent.',
            ),
            const Text(
              'Dependencies are checked again before submission. Sequential reads cannot exclude a concurrent administrator.',
            ),
            TextField(
              key: const Key('nvme-subsystem-qid-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('nvme-subsystem-qid-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Set queue-ID limit'),
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
