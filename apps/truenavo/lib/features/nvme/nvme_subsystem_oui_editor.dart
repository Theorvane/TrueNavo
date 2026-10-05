import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_host_overview.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_oui_coordinator.dart';

class NvmeSubsystemOuiEditor extends ConsumerStatefulWidget {
  const NvmeSubsystemOuiEditor({super.key});

  @override
  ConsumerState<NvmeSubsystemOuiEditor> createState() =>
      _NvmeSubsystemOuiEditorState();
}

class _NvmeSubsystemOuiEditorState
    extends ConsumerState<NvmeSubsystemOuiEditor> {
  final _id = TextEditingController();
  final _oui = TextEditingController();
  final _confirmation = TextEditingController();
  bool _useDefault = true;
  NvmeOuiReview? _review;
  NvmeSubsystemOuiCoordinator? _reviewCoordinator;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _id.dispose();
    _oui.dispose();
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

  Future<void> _prepare(NvmeSubsystemOuiCoordinator coordinator) async {
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
      final choice = NvmeOuiChoice(_useDefault ? null : _oui.text);
      if (!choice.valid) {
        throw StateError(
          'Enter 1–32 letters, digits, dots, underscores, colons or hyphens. Nothing was sent.',
        );
      }
      final review = await coordinator.prepare(id, choice);
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
    NvmeSubsystemOuiCoordinator coordinator,
    NvmeOuiReview review,
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
    if (result.outcome == NvmeOuiOutcome.completed) {
      _id.clear();
      _oui.clear();
      _useDefault = true;
      _confirmation.clear();
      ref.invalidate(nvmeOverviewProvider);
      ref.invalidate(nvmeHostOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(nvmeSubsystemOuiCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            identical(coordinator, _reviewCoordinator) &&
            _id.text.trim() == _review?.id.toString() &&
            _useDefault == (_review?.choice.wireValue == null) &&
            (_useDefault || _oui.text == _review?.choice.wireValue)
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Set IEEE OUI on an empty NVMe-oF subsystem',
      description: 'Changes only an unbound restricted subsystem with no returned host, port or namespace association. This editor supports a conservative 1–32 character ASCII subset of the server string field.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('nvme-subsystem-oui-id'),
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
                key: const Key('nvme-subsystem-oui-default'),
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
            key: const Key('nvme-subsystem-oui-value'),
            controller: _oui,
            enabled: enabled && !_useDefault,
            maxLength: 32,
            decoration: const InputDecoration(
              labelText: 'IEEE OUI (safe ASCII, 1–32 characters)',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('nvme-subsystem-oui-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review IEEE OUI'),
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
            Text('IEEE OUI: ${review.oldLabel} → ${review.newLabel}'),
            const Text(
              'Only nvmet.subsys.update(id, {ieee_oui: selected value}) is submitted. No mapping or other subsystem field is sent.',
            ),
            const Text(
              'Dependencies are checked again before submission. Sequential reads cannot exclude a concurrent administrator.',
            ),
            TextField(
              key: const Key('nvme-subsystem-oui-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('nvme-subsystem-oui-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Set IEEE OUI'),
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
