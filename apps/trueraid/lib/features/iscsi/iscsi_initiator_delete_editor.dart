import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_initiator_delete_coordinator.dart';
import 'iscsi_overview.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;

class IscsiInitiatorDeleteEditor extends ConsumerStatefulWidget {
  const IscsiInitiatorDeleteEditor({required this.overview, super.key});
  final IscsiOverview overview;

  @override
  ConsumerState<IscsiInitiatorDeleteEditor> createState() =>
      _IscsiInitiatorDeleteEditorState();
}

class _IscsiInitiatorDeleteEditorState
    extends ConsumerState<IscsiInitiatorDeleteEditor> {
  final _confirmation = TextEditingController();
  int? _selected;
  IscsiInitiatorDeleteReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant IscsiInitiatorDeleteEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.overview, widget.overview)) {
      _selected = null;
      _review = null;
      _confirmation.clear();
    }
  }

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(
    IscsiInitiatorDeleteCoordinator coordinator,
    int id,
  ) async {
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    try {
      final review = await coordinator.prepare(id);
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
    IscsiInitiatorDeleteCoordinator coordinator,
    IscsiInitiatorDeleteReview review,
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
    if (result.outcome == IscsiInitiatorDeleteOutcome.completed) {
      _selected = null;
      _confirmation.clear();
      ref.invalidate(iscsiOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiInitiatorDeleteCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) && _selected == _review?.id
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    final groups = widget.overview.initiators;
    return TdPanel(
      title: 'Delete an unassigned initiator group',
      description: 'Only a group not referenced by any target qualifies. The iSCSI service must be stopped and have no active sessions. This does not remove targets, portals or extents.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<int>(
            key: const Key('iscsi-initiator-delete-select'),
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
          OutlinedButton(
            key: const Key('iscsi-initiator-delete-review'),
            onPressed: enabled && _selected != null
                ? () => _prepare(coordinator, _selected!)
                : null,
            child: const Text('Review initiator group deletion'),
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
            Text('Group #${review.id} · ${review.names.length} initiators'),
            Text(
              review.names.isEmpty
                  ? 'No initiator names'
                  : review.names.join('\n'),
            ),
            Text(
              'Description: ${review.comment.isEmpty ? '(none)' : review.comment}',
            ),
            const Text(
              'The complete group and target inventories, service and sessions are checked again before deletion. Other administrators can still change the server concurrently.',
            ),
            TextField(
              key: const Key('iscsi-initiator-delete-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('iscsi-initiator-delete-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Delete initiator group'),
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
