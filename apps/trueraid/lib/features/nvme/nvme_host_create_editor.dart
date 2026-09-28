import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_host_overview.dart';
import 'nvme_host_authentication_panel.dart';
import 'nvme_overview.dart';
import 'nvme_host_create_coordinator.dart';

class NvmeHostCreateEditor extends ConsumerStatefulWidget {
  const NvmeHostCreateEditor({super.key});

  @override
  ConsumerState<NvmeHostCreateEditor> createState() =>
      _NvmeHostCreateEditorState();
}

class _NvmeHostCreateEditorState extends ConsumerState<NvmeHostCreateEditor> {
  final _name = TextEditingController();
  final _confirmation = TextEditingController();
  NvmeHostCreateReview? _review;
  NvmeHostCreateCoordinator? _reviewCoordinator;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;
  bool _acknowledgeNoDhchap = false;

  @override
  void dispose() {
    _discardReview();
    _name.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(NvmeHostCreateCoordinator coordinator) async {
    _discardReview();
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final review = await coordinator.prepare(_name.text);
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

  void _discardReview() {
    final review = _review;
    if (review != null) _reviewCoordinator?.cancel(review);
    _review = null;
    _reviewCoordinator = null;
    _reviewSession = null;
    _acknowledgeNoDhchap = false;
  }

  Future<void> _submit(
    NvmeHostCreateCoordinator coordinator,
    NvmeHostCreateReview review,
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
      acknowledgeNoDhchap: _acknowledgeNoDhchap,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = result.message;
    });
    if (result.outcome == NvmeHostCreateOutcome.completed) {
      _name.clear();
      _confirmation.clear();
      ref.invalidate(nvmeOverviewProvider);
      ref.invalidate(nvmeHostOverviewProvider);
      ref.invalidate(nvmeHostAuthenticationProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(nvmeHostCreateCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            identical(coordinator, _reviewCoordinator) &&
            _name.text == _review?.nqn
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Register an unassociated NVMe-oF host',
      description: 'Registers an initiator NQN only, without DH-CHAP keys or subsystem mappings. NQN is an identity string, not proof of authentication. Association and credential setup remain separate.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('nvme-host-create-name'),
            controller: _name,
            enabled: enabled,
            maxLength: 223,
            decoration: const InputDecoration(
              labelText: 'Exact initiator host NQN',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          OutlinedButton(
            key: const Key('nvme-host-create-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review unassociated host registration'),
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
            Text('Host NQN: ${review.nqn}'),
            const Text(
              'Payload: hostnqn and explicit null DH-CHAP keys/group only. No subsystem association is submitted. Creating the host reloads NVMe configuration on the server.',
            ),
            const Text(
              'The inventory is checked again before creation. Other administrators can still change the server concurrently.',
            ),
            TextField(
              key: const Key('nvme-host-create-confirmation'),
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
                  key: const Key('nvme-host-create-consent'),
                  value: _acknowledgeNoDhchap,
                  onChanged: _busy
                      ? null
                      : (value) => setState(
                          () => _acknowledgeNoDhchap = value == true,
                        ),
                ),
                const Expanded(
                  child: Text(
                    'I understand that DH-CHAP authentication is not configured and this does not grant or verify client access.',
                  ),
                ),
              ],
            ),
            FilledButton(
              key: const Key('nvme-host-create-submit'),
              onPressed: _busy || !_acknowledgeNoDhchap
                  ? null
                  : () => _submit(coordinator, review),
              child: const Text('Register unassociated host'),
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
