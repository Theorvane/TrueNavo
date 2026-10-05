import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_overview.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;
import 'iscsi_portal_delete_coordinator.dart';

class IscsiPortalDeleteEditor extends ConsumerStatefulWidget {
  const IscsiPortalDeleteEditor({required this.overview, super.key});
  final IscsiOverview overview;

  @override
  ConsumerState<IscsiPortalDeleteEditor> createState() =>
      _IscsiPortalDeleteEditorState();
}

class _IscsiPortalDeleteEditorState
    extends ConsumerState<IscsiPortalDeleteEditor> {
  final _confirmation = TextEditingController();
  int? _selected;
  IscsiPortalDeleteReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant IscsiPortalDeleteEditor oldWidget) {
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
    IscsiPortalDeleteCoordinator coordinator,
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
    IscsiPortalDeleteCoordinator coordinator,
    IscsiPortalDeleteReview review,
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
    if (result.outcome == IscsiPortalDeleteOutcome.completed) {
      _selected = null;
      _confirmation.clear();
      ref.invalidate(iscsiOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiPortalDeleteCoordinatorProvider);
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
    final portals = widget.overview.portals;
    return TdPanel(
      title: 'Delete an unassigned portal',
      description: 'Only a portal not referenced by any target qualifies. Stop iSCSI and disconnect all clients first. Deletion does not remove targets or initiator groups.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<int>(
            key: const Key('iscsi-portal-delete-select'),
            isExpanded: true,
            initialValue: portals.any((portal) => portal.id == _selected)
                ? _selected
                : null,
            decoration: const InputDecoration(
              labelText: 'Portal',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final portal in portals)
                DropdownMenuItem(
                  value: portal.id,
                  child: Text('Portal #${portal.id}'),
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
            key: const Key('iscsi-portal-delete-review'),
            onPressed: enabled && _selected != null
                ? () => _prepare(coordinator, _selected!)
                : null,
            child: const Text('Review portal deletion'),
          ),
          if (coordinator == null || !coordinator.available)
            const Text(
              'This server does not expose the required portal methods.',
            ),
          if (coordinator?.locked == true)
            const Text(
              'An iSCSI change is in progress or unverified. Reconnect before retrying.',
            ),
          if (review != null && coordinator != null) ...[
            const Divider(),
            Text('Server: ${review.endpoint}'),
            Text('Portal #${review.id} · tag ${review.tag}'),
            Text('Listeners: ${review.listeners.join(', ')}'),
            Text(
              'Description: ${review.comment.isEmpty ? '(none)' : review.comment}',
            ),
            const Text(
              'Complete portal and target inventories, service and sessions are checked again before deletion. Other administrators can still change the server concurrently.',
            ),
            TextField(
              key: const Key('iscsi-portal-delete-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('iscsi-portal-delete-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Delete portal'),
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
