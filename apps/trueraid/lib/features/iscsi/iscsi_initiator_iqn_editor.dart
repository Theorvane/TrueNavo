import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_initiator_iqn_coordinator.dart';
import 'iscsi_overview.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;

class IscsiInitiatorIqnEditor extends ConsumerStatefulWidget {
  const IscsiInitiatorIqnEditor({required this.overview, super.key});
  final IscsiOverview overview;

  @override
  ConsumerState<IscsiInitiatorIqnEditor> createState() =>
      _IscsiInitiatorIqnEditorState();
}

class _IscsiInitiatorIqnEditorState
    extends ConsumerState<IscsiInitiatorIqnEditor> {
  final _iqn = TextEditingController();
  final _confirmation = TextEditingController();
  int? _selected;
  IscsiInitiatorIqnReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant IscsiInitiatorIqnEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.overview, widget.overview)) {
      _selected = null;
      _review = null;
      _confirmation.clear();
    }
  }

  @override
  void dispose() {
    _iqn.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(IscsiInitiatorIqnCoordinator coordinator) async {
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    try {
      final review = await coordinator.prepare(_selected!, _iqn.text);
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
    IscsiInitiatorIqnCoordinator coordinator,
    IscsiInitiatorIqnReview review,
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
    if (result.outcome == IscsiInitiatorIqnOutcome.completed) {
      _selected = null;
      _iqn.clear();
      _confirmation.clear();
      ref.invalidate(iscsiOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiInitiatorIqnCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            _selected == _review?.id &&
            _iqn.text == _review?.proposed
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    final groups = widget.overview.initiators;
    return TdPanel(
      title: 'Replace an unassigned initiator IQN',
      description: 'Only a group with one explicit IQN and no target references qualifies. Stop iSCSI and disconnect all clients first. This does not change target assignments.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<int>(
            key: const Key('iscsi-initiator-iqn-select'),
            isExpanded: true,
            initialValue: groups.any((group) => group.id == _selected)
                ? _selected
                : null,
            decoration: const InputDecoration(
              labelText: 'Initiator group',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final group in groups)
                DropdownMenuItem(
                  value: group.id,
                  child: Text(
                    '#${group.id} ${group.names.isEmpty ? '(empty)' : group.names.first}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: enabled
                ? (id) => setState(() {
                    _selected = id;
                    _review = null;
                    _message = null;
                  })
                : null,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('iscsi-initiator-iqn-new'),
            controller: _iqn,
            enabled: enabled,
            maxLength: 223,
            decoration: const InputDecoration(
              labelText: 'New lowercase IQN',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() {
              _review = null;
              _message = null;
            }),
          ),
          OutlinedButton(
            key: const Key('iscsi-initiator-iqn-review'),
            onPressed: enabled && _selected != null
                ? () => _prepare(coordinator)
                : null,
            child: const Text('Review IQN replacement'),
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
            Text('Group #${review.id}: ${review.before} → ${review.proposed}'),
            Text(
              'Description unchanged: ${review.comment.isEmpty ? '(none)' : review.comment}',
            ),
            const Text(
              'Complete initiator and target inventories, service and sessions are checked again before submission. Other administrators can still change the server concurrently.',
            ),
            TextField(
              key: const Key('iscsi-initiator-iqn-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('iscsi-initiator-iqn-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Replace IQN'),
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
