import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_mapping_create_coordinator.dart';
import 'iscsi_overview.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;

class IscsiMappingCreateEditor extends ConsumerStatefulWidget {
  const IscsiMappingCreateEditor({required this.overview, super.key});
  final IscsiOverview overview;

  @override
  ConsumerState<IscsiMappingCreateEditor> createState() =>
      _IscsiMappingCreateEditorState();
}

class _IscsiMappingCreateEditorState
    extends ConsumerState<IscsiMappingCreateEditor> {
  final _confirmation = TextEditingController();
  int? _target, _extent;
  IscsiMappingCreateReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant IscsiMappingCreateEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.overview, widget.overview)) {
      _target = null;
      _extent = null;
      _review = null;
      _confirmation.clear();
    }
  }

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(IscsiMappingCreateCoordinator coordinator) async {
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    try {
      final review = await coordinator.prepare(_target!, _extent!);
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
    IscsiMappingCreateCoordinator coordinator,
    IscsiMappingCreateReview review,
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
    if (result.outcome == IscsiMappingCreateOutcome.completed) {
      _target = null;
      _extent = null;
      _confirmation.clear();
      ref.invalidate(iscsiOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiMappingCreateCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            _target == _review?.targetId &&
            _extent == _review?.extentId
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    final mappedTargets = widget.overview.mappings
        .map((m) => m.targetId)
        .toSet();
    final mappedExtents = widget.overview.mappings
        .map((m) => m.extentId)
        .toSet();
    final targets = widget.overview.targets
        .where(
          (target) =>
              target.mode == 'iSCSI' &&
              target.groups.isEmpty &&
              !mappedTargets.contains(target.id),
        )
        .toList();
    final extents = widget.overview.extents
        .where(
          (extent) =>
              (extent.type == 'Disk' || extent.type == 'File') &&
              extent.enabled == true &&
              extent.locked == false &&
              !mappedExtents.contains(extent.id),
        )
        .toList();
    return TdPanel(
      title: 'Map an unused extent at LUN 0',
      description: 'One initial LUN on an unbound iSCSI-only target. The extent must be enabled, unlocked and unused. No portal or client access is configured here. Stop iSCSI and disconnect all clients first.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<int>(
            key: const Key('iscsi-mapping-create-target'),
            isExpanded: true,
            initialValue: targets.any((item) => item.id == _target)
                ? _target
                : null,
            decoration: const InputDecoration(
              labelText: 'Unbound target',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final item in targets)
                DropdownMenuItem(
                  value: item.id,
                  child: Text(
                    '#${item.id} ${item.name}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: enabled
                ? (id) => setState(() {
                    _target = id;
                    _review = null;
                    _message = null;
                  })
                : null,
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            key: const Key('iscsi-mapping-create-extent'),
            isExpanded: true,
            initialValue: extents.any((item) => item.id == _extent)
                ? _extent
                : null,
            decoration: const InputDecoration(
              labelText: 'Unused extent',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final item in extents)
                DropdownMenuItem(
                  value: item.id,
                  child: Text(
                    '#${item.id} ${item.name}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: enabled
                ? (id) => setState(() {
                    _extent = id;
                    _review = null;
                    _message = null;
                  })
                : null,
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('iscsi-mapping-create-review'),
            onPressed: enabled && _target != null && _extent != null
                ? () => _prepare(coordinator)
                : null,
            child: const Text('Review LUN 0 mapping'),
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
            Text('Target #${review.targetId}: ${review.targetName}'),
            Text('Extent #${review.extentId}: ${review.extentName}'),
            const Text(
              'Assign exact LUN 0. No target, extent or existing mapping is edited. Complete inventories, service and sessions are checked again; external administrators can still race these reads.',
            ),
            TextField(
              key: const Key('iscsi-mapping-create-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('iscsi-mapping-create-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Map LUN 0'),
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
