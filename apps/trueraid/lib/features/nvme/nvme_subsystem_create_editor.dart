import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_create_coordinator.dart';

class NvmeSubsystemCreateEditor extends ConsumerStatefulWidget {
  const NvmeSubsystemCreateEditor({super.key});

  @override
  ConsumerState<NvmeSubsystemCreateEditor> createState() =>
      _NvmeSubsystemCreateEditorState();
}

class _NvmeSubsystemCreateEditorState
    extends ConsumerState<NvmeSubsystemCreateEditor> {
  final _name = TextEditingController();
  final _confirmation = TextEditingController();
  NvmeCreateReview? _review;
  NvmeSubsystemCreateCoordinator? _reviewCoordinator;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _name.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(NvmeSubsystemCreateCoordinator coordinator) async {
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
  }

  Future<void> _submit(
    NvmeSubsystemCreateCoordinator coordinator,
    NvmeCreateReview review,
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
    if (result.outcome == NvmeCreateOutcome.completed) {
      _name.clear();
      _confirmation.clear();
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(nvmeSubsystemCreateCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            identical(coordinator, _reviewCoordinator) &&
            _name.text == _review?.name
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Create an unbound NVMe-oF subsystem',
      description: 'Requests a subsystem without port, namespace or host mappings. Port and namespace absence are checked afterward; host mappings are not inspected. This does not test client access.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('nvme-subsystem-create-name'),
            controller: _name,
            enabled: enabled,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'New subsystem name',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          OutlinedButton(
            key: const Key('nvme-subsystem-create-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review unbound subsystem creation'),
          ),
          if (coordinator == null || !coordinator.available)
            const Text(
              'This server does not expose the required NVMe-oF methods.',
            ),
          if (coordinator?.locked == true)
            const Text(
              'An NVMe-oF change is in progress or unverified. Reconnect before retrying.',
            ),
          if (review != null && coordinator != null) ...[
            const Divider(),
            Text('Server: ${review.endpoint}'),
            Text('New subsystem: ${review.name}'),
            const Text(
              'Payload: name and allow_any_host=false only. No port, namespace or host mapping is submitted.',
            ),
            const Text(
              'The inventory is checked again before creation. Other administrators can still change the server concurrently.',
            ),
            TextField(
              key: const Key('nvme-subsystem-create-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('nvme-subsystem-create-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Create unbound subsystem'),
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
