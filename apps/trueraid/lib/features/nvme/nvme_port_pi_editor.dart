import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_overview.dart';
import 'nvme_port_pi_coordinator.dart';

class NvmePortPiEditor extends ConsumerStatefulWidget {
  const NvmePortPiEditor({super.key});

  @override
  ConsumerState<NvmePortPiEditor> createState() => _NvmePortPiEditorState();
}

class _NvmePortPiEditorState extends ConsumerState<NvmePortPiEditor> {
  final _id = TextEditingController();
  final _confirmation = TextEditingController();
  NvmePortPiChoice _choice = NvmePortPiChoice.serverDefault;
  NvmePortPiReview? _review;
  NvmePortPiCoordinator? _reviewCoordinator;
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

  Future<void> _prepare(NvmePortPiCoordinator coordinator) async {
    _discardReview();
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final id = int.tryParse(_id.text.trim());
      if (id == null || id <= 0) {
        throw StateError('Enter a positive port ID. Nothing was sent.');
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
    NvmePortPiCoordinator coordinator,
    NvmePortPiReview review,
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
    if (result.outcome == NvmePortPiOutcome.completed) {
      _id.clear();
      _confirmation.clear();
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(nvmePortPiCoordinatorProvider);
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
      title: 'Set PI on an unassociated disabled NVMe-oF port',
      description: 'Changes only PI on a disabled port with no returned subsystem associations. Saved PI configuration does not verify data protection; concurrent administration cannot be excluded.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('nvme-port-pi-id'),
            controller: _id,
            enabled: enabled,
            keyboardType: TextInputType.number,
            maxLength: 12,
            decoration: const InputDecoration(
              labelText: 'Disabled port ID from topology',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          DropdownButtonFormField<NvmePortPiChoice>(
            key: const Key('nvme-port-pi-choice'),
            isExpanded: true,
            initialValue: _choice,
            decoration: const InputDecoration(
              labelText: 'Port protection information',
              border: OutlineInputBorder(),
            ),
            items: const [
              DropdownMenuItem(
                value: NvmePortPiChoice.serverDefault,
                child: Text('Server default'),
              ),
              DropdownMenuItem(value: NvmePortPiChoice.on, child: Text('On')),
              DropdownMenuItem(value: NvmePortPiChoice.off, child: Text('Off')),
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
            key: const Key('nvme-port-pi-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review port PI'),
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
            Text('Disabled port #${review.id}: ${review.transport}'),
            Text('Port PI: ${review.oldLabel} → ${review.newLabel}'),
            const Text(
              'Only nvmet.port.update(port ID, {pi_enable: selected value}) is submitted. A port with any returned subsystem association is rejected.',
            ),
            const Text(
              'All returned configuration is checked again. Sequential reads cannot exclude a concurrent administrator.',
            ),
            TextField(
              key: const Key('nvme-port-pi-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('nvme-port-pi-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Set port PI'),
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
