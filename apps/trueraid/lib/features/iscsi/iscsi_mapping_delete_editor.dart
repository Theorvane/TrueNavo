import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_mapping_delete_coordinator.dart';
import 'iscsi_overview.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;

class IscsiMappingDeleteEditor extends ConsumerStatefulWidget {
  const IscsiMappingDeleteEditor({required this.overview, super.key});
  final IscsiOverview overview;

  @override
  ConsumerState<IscsiMappingDeleteEditor> createState() =>
      _IscsiMappingDeleteEditorState();
}

class _IscsiMappingDeleteEditorState
    extends ConsumerState<IscsiMappingDeleteEditor> {
  final _confirmation = TextEditingController();
  int? _selected;
  IscsiMappingDeleteReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant IscsiMappingDeleteEditor oldWidget) {
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

  Future<void> _prepare(IscsiMappingDeleteCoordinator coordinator) async {
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    try {
      final review = await coordinator.prepare(_selected!);
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
    IscsiMappingDeleteCoordinator coordinator,
    IscsiMappingDeleteReview review,
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
    if (result.outcome == IscsiMappingDeleteOutcome.completed) {
      _selected = null;
      _confirmation.clear();
      ref.invalidate(iscsiOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiMappingDeleteCoordinatorProvider);
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
    final mappings = widget.overview.mappings;
    return TdPanel(
      title: 'Remove a target–extent LUN mapping',
      description: 'Unmaps only one association from an iSCSI-only target. It does not delete the target or backing extent. Stop iSCSI and disconnect all clients first.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<int>(
            key: const Key('iscsi-mapping-delete-select'),
            isExpanded: true,
            initialValue: mappings.any((mapping) => mapping.id == _selected)
                ? _selected
                : null,
            decoration: const InputDecoration(
              labelText: 'LUN mapping',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final mapping in mappings)
                DropdownMenuItem(
                  value: mapping.id,
                  child: Text(
                    '#${mapping.id} ${widget.overview.targetById(mapping.targetId)?.name ?? '(missing target)'} → ${widget.overview.extentById(mapping.extentId)?.name ?? '(missing extent)'} · LUN ${mapping.lun}',
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
            key: const Key('iscsi-mapping-delete-review'),
            onPressed: enabled && _selected != null
                ? () => _prepare(coordinator)
                : null,
            child: const Text('Review LUN unmap'),
          ),
          if (coordinator == null || !coordinator.available)
            const Text(
              'This server does not expose the required LUN mapping methods.',
            ),
          if (coordinator?.locked == true)
            const Text(
              'An iSCSI change is in progress or unverified. Reconnect before retrying.',
            ),
          if (review != null && coordinator != null) ...[
            const Divider(),
            Text('Server: ${review.endpoint}'),
            Text('Mapping #${review.id}, LUN ${review.lun}'),
            Text('Target #${review.targetId}: ${review.targetName}'),
            Text('Extent #${review.extentId}: ${review.extentName}'),
            const Text(
              'Only this association is removed with force=false. Target, extent, mapping, service and session inventories are checked again. Concurrent server changes are still possible.',
            ),
            TextField(
              key: const Key('iscsi-mapping-delete-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('iscsi-mapping-delete-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Unmap LUN'),
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
