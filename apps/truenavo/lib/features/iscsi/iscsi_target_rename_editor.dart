import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_overview.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;
import 'iscsi_target_rename_coordinator.dart';

class IscsiTargetRenameEditor extends ConsumerStatefulWidget {
  const IscsiTargetRenameEditor({required this.overview, super.key});
  final IscsiOverview overview;

  @override
  ConsumerState<IscsiTargetRenameEditor> createState() =>
      _IscsiTargetRenameEditorState();
}

class _IscsiTargetRenameEditorState
    extends ConsumerState<IscsiTargetRenameEditor> {
  final _name = TextEditingController();
  final _confirmation = TextEditingController();
  int? _selected;
  IscsiTargetRenameReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant IscsiTargetRenameEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.overview, widget.overview)) {
      _selected = null;
      _review = null;
      _name.clear();
      _confirmation.clear();
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(
    IscsiTargetRenameCoordinator coordinator,
    int id,
  ) async {
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    try {
      final review = await coordinator.prepare(id, _name.text);
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
    IscsiTargetRenameCoordinator coordinator,
    IscsiTargetRenameReview review,
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
    if (result.outcome == IscsiTargetRenameOutcome.completed) {
      _selected = null;
      _name.clear();
      _confirmation.clear();
      ref.invalidate(iscsiOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiTargetRenameCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            _selected == _review?.id &&
            _name.text == _review?.newName
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    final targets = widget.overview.targets;
    return TdPanel(
      title: 'Rename an unbound iSCSI target',
      description: 'Only an iSCSI-only target with no access groups, authorized networks or LUN mappings qualifies. The service must be stopped with no active sessions. Clients may need to rediscover the new name.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<int>(
            key: const Key('iscsi-target-rename-select'),
            isExpanded: true,
            initialValue: targets.any((target) => target.id == _selected)
                ? _selected
                : null,
            decoration: const InputDecoration(
              labelText: 'Target',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final target in targets)
                DropdownMenuItem(
                  value: target.id,
                  child: Text(
                    '#${target.id} ${target.name}',
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
            key: const Key('iscsi-target-rename-name'),
            controller: _name,
            maxLength: 120,
            enabled: enabled && _selected != null,
            decoration: const InputDecoration(
              labelText: 'New target name',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() => _review = null),
          ),
          OutlinedButton(
            key: const Key('iscsi-target-rename-review'),
            onPressed: enabled && _selected != null
                ? () => _prepare(coordinator, _selected!)
                : null,
            child: const Text('Review target rename'),
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
            Text('Target #${review.id}: ${review.oldName} → ${review.newName}'),
            const Text(
              'Only the name field is submitted. The target, LUN mappings, service and sessions are checked again before submission; other administrators can still change the server concurrently.',
            ),
            TextField(
              key: const Key('iscsi-target-rename-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('iscsi-target-rename-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Rename target'),
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
