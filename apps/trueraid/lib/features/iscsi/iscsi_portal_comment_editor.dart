import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_overview.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;
import 'iscsi_portal_comment_coordinator.dart';

class IscsiPortalCommentEditor extends ConsumerStatefulWidget {
  const IscsiPortalCommentEditor({required this.overview, super.key});
  final IscsiOverview overview;

  @override
  ConsumerState<IscsiPortalCommentEditor> createState() =>
      _IscsiPortalCommentEditorState();
}

class _IscsiPortalCommentEditorState
    extends ConsumerState<IscsiPortalCommentEditor> {
  final _comment = TextEditingController();
  final _confirmation = TextEditingController();
  int? _selectedId;
  IscsiPortalCommentReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant IscsiPortalCommentEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.overview, widget.overview)) {
      _selectedId = null;
      _review = null;
      _reviewSession = null;
      _comment.clear();
      _confirmation.clear();
    }
  }

  @override
  void dispose() {
    _comment.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(IscsiPortalCommentCoordinator coordinator) async {
    final id = _selectedId;
    if (id == null) {
      setState(() => _message = 'Select a portal.');
      return;
    }
    setState(() {
      _busy = true;
      _message = null;
      _review = null;
    });
    try {
      final review = await coordinator.prepare(id, _comment.text);
      if (!mounted) return;
      setState(() {
        _review = review;
        _reviewSession = ref.read(dashboardActiveSessionProvider);
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
    IscsiPortalCommentCoordinator coordinator,
    IscsiPortalCommentReview review,
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
    if (result.outcome == IscsiPortalCommentOutcome.completed) {
      ref.invalidate(iscsiOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiPortalCommentCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review = identical(session, _reviewSession) ? _review : null;
    final portals = widget.overview.portals;
    final selected = portals.any((portal) => portal.id == _selectedId)
        ? _selectedId
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Portal description',
      description: 'Edit only a portal comment. Listener addresses, ports and target access are never submitted by this form.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (portals.isEmpty) const Text('No portals configured.'),
          if (portals.isNotEmpty) ...[
            DropdownButtonFormField<int>(
              key: ObjectKey(widget.overview),
              initialValue: selected,
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
                  ? (id) {
                      final portal = portals.singleWhere(
                        (portal) => portal.id == id,
                      );
                      setState(() {
                        _selectedId = id;
                        _review = null;
                        _message = null;
                      });
                      _comment.text = portal.comment;
                      _confirmation.clear();
                    }
                  : null,
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('iscsi-portal-comment-value'),
              controller: _comment,
              enabled: enabled && selected != null,
              maxLength: 128,
              decoration: const InputDecoration(
                labelText: 'Description',
                border: OutlineInputBorder(),
              ),
            ),
            OutlinedButton(
              key: const Key('iscsi-portal-comment-review'),
              onPressed: enabled && selected != null
                  ? () => _prepare(coordinator)
                  : null,
              child: const Text('Review portal description change'),
            ),
          ],
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
            Text('Server: ${review.endpoint} · Portal #${review.portalId}'),
            Text(
              'Before: ${review.before.isEmpty ? '(empty)' : review.before}',
            ),
            Text(
              'After: ${review.proposed.isEmpty ? '(empty)' : review.proposed}',
            ),
            const Text(
              'The portal is reread before submission. Other administrators can still change it concurrently.',
            ),
            TextField(
              key: const Key('iscsi-portal-comment-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('iscsi-portal-comment-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Update portal description'),
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
