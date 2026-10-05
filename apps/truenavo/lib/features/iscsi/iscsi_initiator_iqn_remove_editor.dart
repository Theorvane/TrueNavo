import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_initiator_iqn_coordinator.dart';
import 'iscsi_overview.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;

class IscsiInitiatorIqnRemoveEditor extends ConsumerStatefulWidget {
  const IscsiInitiatorIqnRemoveEditor({required this.overview, super.key});
  final IscsiOverview overview;

  @override
  ConsumerState<IscsiInitiatorIqnRemoveEditor> createState() =>
      _IscsiInitiatorIqnRemoveEditorState();
}

class _IscsiInitiatorIqnRemoveEditorState
    extends ConsumerState<IscsiInitiatorIqnRemoveEditor> {
  final _confirmation = TextEditingController();
  int? _selected;
  String? _iqn;
  IscsiInitiatorIqnRemoveReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant IscsiInitiatorIqnRemoveEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.overview, widget.overview)) {
      _selected = null;
      _iqn = null;
      _review = null;
      _confirmation.clear();
    }
  }

  @override
  void dispose() {
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
      final review = await coordinator.prepareRemove(_selected!, _iqn!);
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
    IscsiInitiatorIqnRemoveReview review,
  ) async {
    final phrase = _confirmation.text;
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    final result = await coordinator.executeRemove(review, phrase);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = result.message;
    });
    if (result.outcome == IscsiInitiatorIqnOutcome.completed) {
      _selected = null;
      _iqn = null;
      _confirmation.clear();
      ref.invalidate(iscsiOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiInitiatorIqnCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final groups = widget.overview.initiators;
    final selectedGroup = groups
        .where((group) => group.id == _selected)
        .firstOrNull;
    final names = selectedGroup?.names ?? const <String>[];
    final review =
        identical(session, _reviewSession) &&
            _selected == _review?.id &&
            _iqn == _review?.removed
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Remove one initiator IQN',
      description: 'Only an unassigned group with at least two explicit IQNs qualifies. The remaining IQNs and description stay unchanged. Stop iSCSI and disconnect all clients first.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<int>(
            key: const Key('iscsi-initiator-iqn-remove-select'),
            isExpanded: true,
            initialValue: selectedGroup?.id,
            decoration: const InputDecoration(
              labelText: 'Initiator group',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final group in groups)
                DropdownMenuItem(
                  value: group.id,
                  child: Text(
                    '#${group.id} (${group.names.length} IQNs)',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: enabled
                ? (id) => setState(() {
                    _selected = id;
                    _iqn = null;
                    _review = null;
                    _message = null;
                  })
                : null,
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            key: const Key('iscsi-initiator-iqn-remove-name'),
            isExpanded: true,
            initialValue: names.contains(_iqn) ? _iqn : null,
            decoration: const InputDecoration(
              labelText: 'IQN to remove',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final name in names)
                DropdownMenuItem(
                  value: name,
                  child: Text(name, overflow: TextOverflow.ellipsis),
                ),
            ],
            onChanged: enabled && names.length >= 2
                ? (name) => setState(() {
                    _iqn = name;
                    _review = null;
                    _message = null;
                  })
                : null,
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('iscsi-initiator-iqn-remove-review'),
            onPressed: enabled && _selected != null && _iqn != null
                ? () => _prepare(coordinator)
                : null,
            child: const Text('Review IQN removal'),
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
            Text('Group #${review.id}: remove ${review.removed}'),
            for (final name in review.before)
              if (name != review.removed) Text('Preserve: $name'),
            Text(
              'Description unchanged: ${review.comment.isEmpty ? '(none)' : review.comment}',
            ),
            const Text(
              'Complete inventories, service and sessions are rechecked before submission. Concurrent server changes are still possible.',
            ),
            TextField(
              key: const Key('iscsi-initiator-iqn-remove-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('iscsi-initiator-iqn-remove-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Remove IQN'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      coordinator.cancelRemove(review);
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
