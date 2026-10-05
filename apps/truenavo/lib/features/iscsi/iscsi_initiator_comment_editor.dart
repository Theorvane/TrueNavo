import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_initiator_comment_coordinator.dart';
import 'iscsi_overview.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;

class IscsiInitiatorCommentEditor extends ConsumerStatefulWidget {
  const IscsiInitiatorCommentEditor({required this.overview, super.key});
  final IscsiOverview overview;

  @override
  ConsumerState<IscsiInitiatorCommentEditor> createState() =>
      _IscsiInitiatorCommentEditorState();
}

class _IscsiInitiatorCommentEditorState
    extends ConsumerState<IscsiInitiatorCommentEditor> {
  final _comment = TextEditingController();
  final _confirmation = TextEditingController();
  int? _selectedId;
  IscsiCommentReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant IscsiInitiatorCommentEditor oldWidget) {
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

  Future<void> _prepare(IscsiInitiatorCommentCoordinator coordinator) async {
    final id = _selectedId;
    if (id == null) {
      setState(() => _message = 'Select an initiator group.');
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
    IscsiInitiatorCommentCoordinator coordinator,
    IscsiCommentReview review,
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
    if (result.outcome == IscsiCommentOutcome.completed) {
      ref.invalidate(iscsiOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiInitiatorCommentCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review = identical(session, _reviewSession) ? _review : null;
    final groups = widget.overview.initiators;
    final selected = groups.any((group) => group.id == _selectedId)
        ? _selectedId
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Initiator group description',
      description: 'Edit only a group comment. Allowed initiator names are never submitted by this form.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (groups.isEmpty) const Text('No initiator groups configured.'),
          if (groups.isNotEmpty) ...[
            DropdownButtonFormField<int>(
              key: ObjectKey(widget.overview),
              initialValue: selected,
              decoration: const InputDecoration(
                labelText: 'Initiator group',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final group in groups)
                  DropdownMenuItem(
                    value: group.id,
                    child: Text('Group #${group.id}'),
                  ),
              ],
              onChanged: enabled
                  ? (id) {
                      final group = groups.singleWhere(
                        (group) => group.id == id,
                      );
                      setState(() {
                        _selectedId = id;
                        _review = null;
                        _message = null;
                      });
                      _comment.text = group.comment;
                      _confirmation.clear();
                    }
                  : null,
            ),
            const SizedBox(height: 10),
            TextField(
              key: const Key('iscsi-comment-value'),
              controller: _comment,
              enabled: enabled && selected != null,
              maxLength: 128,
              decoration: const InputDecoration(
                labelText: 'Description',
                border: OutlineInputBorder(),
              ),
            ),
            OutlinedButton(
              key: const Key('iscsi-comment-review'),
              onPressed: enabled && selected != null
                  ? () => _prepare(coordinator)
                  : null,
              child: const Text('Review description change'),
            ),
          ],
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
            Text('Server: ${review.endpoint} · Group #${review.groupId}'),
            Text(
              'Before: ${review.before.isEmpty ? '(empty)' : review.before}',
            ),
            Text(
              'After: ${review.proposed.isEmpty ? '(empty)' : review.proposed}',
            ),
            const Text(
              'The group is reread before submission. Other administrators can still change it concurrently.',
            ),
            TextField(
              key: const Key('iscsi-comment-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('iscsi-comment-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Update description'),
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
