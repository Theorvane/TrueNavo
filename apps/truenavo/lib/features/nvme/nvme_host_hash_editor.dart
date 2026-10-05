import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_host_overview.dart';
import 'nvme_host_authentication_panel.dart';
import 'nvme_overview.dart';
import 'nvme_host_hash_coordinator.dart';

class NvmeHostHashEditor extends ConsumerStatefulWidget {
  const NvmeHostHashEditor({super.key});

  @override
  ConsumerState<NvmeHostHashEditor> createState() => _NvmeHostHashEditorState();
}

class _NvmeHostHashEditorState extends ConsumerState<NvmeHostHashEditor> {
  String? _hash;
  final _id = TextEditingController();
  final _confirmation = TextEditingController();
  NvmeHostHashReview? _review;
  NvmeHostHashCoordinator? _reviewCoordinator;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;
  bool _acknowledgeHashChange = false;

  @override
  void dispose() {
    _discardReview();
    _id.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(NvmeHostHashCoordinator coordinator) async {
    _discardReview();
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final id = int.tryParse(_id.text.trim());
      if (id == null || id <= 0) {
        throw StateError(
          'Enter a positive host database ID. Nothing was sent.',
        );
      }
      final review = await coordinator.prepare(id, _hash ?? '');
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
    _acknowledgeHashChange = false;
  }

  Future<void> _submit(
    NvmeHostHashCoordinator coordinator,
    NvmeHostHashReview review,
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
      acknowledgeHashChange: _acknowledgeHashChange,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = result.message;
    });
    if (result.outcome == NvmeHostHashOutcome.completed) {
      _id.clear();
      _hash = null;
      _confirmation.clear();
      ref.invalidate(nvmeOverviewProvider);
      ref.invalidate(nvmeHostOverviewProvider);
      ref.invalidate(nvmeHostAuthenticationProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(nvmeHostHashCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            identical(coordinator, _reviewCoordinator) &&
            _hash == _review?.hash &&
            _id.text.trim() == _review?.id.toString()
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Change unassociated NVMe-oF host hash',
      description: 'Changes only the saved DH-CHAP hash setting of a host without subsystem mappings, keys or a DH group. The known client options below are validated against fresh server choices at review and submission. This does not configure authentication.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('nvme-host-hash-id'),
            controller: _id,
            enabled: enabled,
            keyboardType: TextInputType.number,
            maxLength: 12,
            decoration: const InputDecoration(
              labelText: 'Host database ID from host inventory',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          DropdownButtonFormField<String>(
            key: ValueKey('nvme-host-hash-choice-$_hash'),
            initialValue: _hash,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'New saved DH-CHAP hash',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final hash in const ['SHA-256', 'SHA-384', 'SHA-512'])
                DropdownMenuItem(value: hash, child: Text(hash)),
            ],
            onChanged: enabled
                ? (value) => setState(() {
                    _discardReview();
                    _hash = value;
                  })
                : null,
          ),
          OutlinedButton(
            key: const Key('nvme-host-hash-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review host hash change'),
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
            Text('Host #${review.id}: ${review.nqn}'),
            Text('Saved hash: ${review.oldHash} → ${review.hash}'),
            const Text(
              'Payload: nvmet.host.update(host ID, {dhchap_hash: new hash}) only. No NQN, key, DH group or mapping fields are submitted. The server reloads NVMe configuration.',
            ),
            const Text(
              'The inventory, unset keys and DH group, and server choices are checked again before submission. Other administrators can still change the server concurrently.',
            ),
            TextField(
              key: const Key('nvme-host-hash-confirmation'),
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
                  key: const Key('nvme-host-hash-consent'),
                  value: _acknowledgeHashChange,
                  onChanged: _busy
                      ? null
                      : (value) => setState(
                          () => _acknowledgeHashChange = value == true,
                        ),
                ),
                const Expanded(
                  child: Text(
                    'I understand that this changes only a saved hash setting, reloads NVMe configuration, and does not configure or verify authentication.',
                  ),
                ),
              ],
            ),
            FilledButton(
              key: const Key('nvme-host-hash-submit'),
              onPressed: _busy || !_acknowledgeHashChange
                  ? null
                  : () => _submit(coordinator, review),
              child: const Text('Change host hash'),
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
