import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_initiator_create_coordinator.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;

class IscsiInitiatorCreateEditor extends ConsumerStatefulWidget {
  const IscsiInitiatorCreateEditor({super.key});

  @override
  ConsumerState<IscsiInitiatorCreateEditor> createState() =>
      _IscsiInitiatorCreateEditorState();
}

class _IscsiInitiatorCreateEditorState
    extends ConsumerState<IscsiInitiatorCreateEditor> {
  final _iqn = TextEditingController();
  final _comment = TextEditingController();
  final _confirmation = TextEditingController();
  IscsiInitiatorCreateReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _iqn.dispose();
    _comment.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(IscsiInitiatorCreateCoordinator coordinator) async {
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    try {
      final review = await coordinator.prepare(_iqn.text, _comment.text);
      if (!mounted) return;
      setState(() {
        _review = review;
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
    IscsiInitiatorCreateCoordinator coordinator,
    IscsiInitiatorCreateReview review,
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
    if (result.outcome == IscsiInitiatorCreateOutcome.completed) {
      _iqn.clear();
      _comment.clear();
      _confirmation.clear();
      ref.invalidate(iscsiOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiInitiatorCreateCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            _iqn.text == _review?.iqn &&
            _comment.text == _review?.comment
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Create an unassigned initiator group',
      description: 'Creates one explicit IQN group with an optional description. No wildcard, IP address or target association is submitted. The iSCSI service must be stopped with no active sessions.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('iscsi-initiator-create-iqn'),
            controller: _iqn,
            enabled: enabled,
            maxLength: 223,
            decoration: const InputDecoration(
              labelText: 'Initiator IQN',
              hintText: 'iqn.2026-01.example.com:host',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() => _review = null),
          ),
          TextField(
            key: const Key('iscsi-initiator-create-comment'),
            controller: _comment,
            enabled: enabled,
            maxLength: 128,
            decoration: const InputDecoration(
              labelText: 'Description (optional)',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() => _review = null),
          ),
          OutlinedButton(
            key: const Key('iscsi-initiator-create-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review initiator group creation'),
          ),
          if (coordinator == null || !coordinator.available)
            const Text(
              'This server does not expose the required initiator methods.',
            ),
          if (coordinator?.locked == true)
            const Text(
              'An iSCSI change is in progress or unverified. Reconnect before retrying.',
            ),
          if (review != null && coordinator != null) ...[
            const Divider(),
            Text('Server: ${review.endpoint}'),
            Text('IQN: ${review.iqn}'),
            Text(
              'Description: ${review.comment.isEmpty ? '(none)' : review.comment}',
            ),
            const Text(
              'The group is not assigned to a target. Initiator and target inventories, service and sessions are checked again before submission. Other administrators can still change the server concurrently.',
            ),
            TextField(
              key: const Key('iscsi-initiator-create-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('iscsi-initiator-create-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Create initiator group'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      coordinator.cancel(review);
                      setState(() => _review = null);
                    },
              child: const Text('Cancel'),
            ),
          ],
          if (_message != null) Text(_message!),
        ],
      ),
    );
  }
}
