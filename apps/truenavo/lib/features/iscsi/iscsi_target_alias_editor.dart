import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_overview.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;
import 'iscsi_target_alias_coordinator.dart';

class IscsiTargetAliasEditor extends ConsumerStatefulWidget {
  const IscsiTargetAliasEditor({required this.overview, super.key});
  final IscsiOverview overview;

  @override
  ConsumerState<IscsiTargetAliasEditor> createState() =>
      _IscsiTargetAliasEditorState();
}

class _IscsiTargetAliasEditorState
    extends ConsumerState<IscsiTargetAliasEditor> {
  final _alias = TextEditingController();
  final _confirmation = TextEditingController();
  int? _selected;
  bool _clear = false;
  IscsiTargetAliasReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant IscsiTargetAliasEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.overview, widget.overview)) {
      _selected = null;
      _review = null;
      _clear = false;
      _alias.clear();
      _confirmation.clear();
    }
  }

  @override
  void dispose() {
    _alias.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(IscsiTargetAliasCoordinator coordinator, int id) async {
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    try {
      final review = await coordinator.prepare(id, _clear ? null : _alias.text);
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
    IscsiTargetAliasCoordinator coordinator,
    IscsiTargetAliasReview review,
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
    if (result.outcome == IscsiTargetAliasOutcome.completed) {
      _selected = null;
      _alias.clear();
      _confirmation.clear();
      _clear = false;
      ref.invalidate(iscsiOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiTargetAliasCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final proposed = _clear ? null : _alias.text;
    final review =
        identical(session, _reviewSession) &&
            _selected == _review?.id &&
            proposed == _review?.proposed
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    final targets = widget.overview.targets;
    return TdPanel(
      title: 'Edit an unbound iSCSI target alias',
      description: 'The alias is a separate optional label; the target name is not changed. Only a target with no access groups, networks or LUN mappings qualifies, while the service is stopped with no active sessions.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<int>(
            key: const Key('iscsi-target-alias-select'),
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
                    _alias.clear();
                    _clear = false;
                  })
                : null,
          ),
          const SizedBox(height: 8),
          TextField(
            key: const Key('iscsi-target-alias-value'),
            controller: _alias,
            enabled: enabled && _selected != null && !_clear,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'New alias',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(() => _review = null),
          ),
          Row(
            children: [
              Checkbox(
                key: const Key('iscsi-target-alias-clear'),
                value: _clear,
                onChanged: enabled && _selected != null
                    ? (value) => setState(() {
                        _clear = value == true;
                        _review = null;
                      })
                    : null,
              ),
              const Expanded(child: Text('Clear the alias (send null)')),
            ],
          ),
          OutlinedButton(
            key: const Key('iscsi-target-alias-review'),
            onPressed: enabled && _selected != null
                ? () => _prepare(coordinator, _selected!)
                : null,
            child: const Text('Review alias change'),
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
            Text('Before: ${review.before ?? '(none)'}'),
            Text('After: ${review.proposed ?? '(none)'}'),
            const Text(
              'Only alias is submitted. Target and LUN configuration, service and sessions are checked again; another administrator can still change the server concurrently.',
            ),
            TextField(
              key: const Key('iscsi-target-alias-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('iscsi-target-alias-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Update alias'),
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
