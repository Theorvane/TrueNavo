import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_overview.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;
import 'iscsi_target_delete_coordinator.dart';

class IscsiTargetDeleteEditor extends ConsumerStatefulWidget {
  const IscsiTargetDeleteEditor({required this.overview, super.key});
  final IscsiOverview overview;

  @override
  ConsumerState<IscsiTargetDeleteEditor> createState() =>
      _IscsiTargetDeleteEditorState();
}

class _IscsiTargetDeleteEditorState
    extends ConsumerState<IscsiTargetDeleteEditor> {
  final _confirmation = TextEditingController();
  int? _selected;
  IscsiTargetDeleteReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(
    IscsiTargetDeleteCoordinator coordinator,
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
    IscsiTargetDeleteCoordinator coordinator,
    IscsiTargetDeleteReview review,
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
    if (result.outcome == IscsiTargetDeleteOutcome.completed) {
      _selected = null;
      _confirmation.clear();
      ref.invalidate(iscsiOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiTargetDeleteCoordinatorProvider);
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
    final options = widget.overview.targets;
    return TdPanel(
      title: 'Delete an unbound iSCSI target',
      description: 'Only an iSCSI-only target with no access groups, authorized networks or LUN mappings qualifies. The service must be stopped with no active sessions. This does not delete extents.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<int>(
            key: const Key('iscsi-target-delete-select'),
            initialValue: options.any((target) => target.id == _selected)
                ? _selected
                : null,
            decoration: const InputDecoration(
              labelText: 'Target to review',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final target in options)
                DropdownMenuItem(
                  value: target.id,
                  child: Text('#${target.id} ${target.name}'),
                ),
            ],
            onChanged: enabled
                ? (id) => setState(() {
                    _selected = id;
                    _review = null;
                  })
                : null,
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('iscsi-target-delete-review'),
            onPressed: enabled && _selected != null
                ? () => _prepare(coordinator, _selected!)
                : null,
            child: const Text('Review target deletion'),
          ),
          if (coordinator == null || !coordinator.available)
            const Text(
              'This server does not expose the required target methods.',
            ),
          if (coordinator?.locked == true)
            const Text(
              'An iSCSI change is in progress or unverified. Reconnect before retrying.',
            ),
          if (review != null && coordinator != null) ...[
            const Divider(),
            Text('Server: ${review.endpoint}'),
            Text('Target: #${review.id} ${review.name}'),
            const Text(
              'The app will submit force=false and delete_extents=false. It checks targets, LUN mappings, service and sessions again before submission. Other administrators can still change the server concurrently.',
            ),
            TextField(
              key: const Key('iscsi-target-delete-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('iscsi-target-delete-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Delete unbound target'),
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
