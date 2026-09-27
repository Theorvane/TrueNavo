import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_mapping_create_coordinator.dart';
import 'iscsi_overview.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;

class IscsiMappingCreateEditor extends ConsumerStatefulWidget {
  const IscsiMappingCreateEditor({
    required this.overview,
    this.bound = false,
    super.key,
  });
  final IscsiOverview overview;
  final bool bound;

  @override
  ConsumerState<IscsiMappingCreateEditor> createState() =>
      _IscsiMappingCreateEditorState();
}

class _IscsiMappingCreateEditorState
    extends ConsumerState<IscsiMappingCreateEditor> {
  final _confirmation = TextEditingController();
  int? _target, _extent, _lun;
  IscsiMappingCreateReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;
  String _key(String suffix) =>
      'iscsi-mapping-${widget.bound ? 'bound-' : ''}create-$suffix';

  @override
  void didUpdateWidget(covariant IscsiMappingCreateEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.overview, widget.overview) ||
        oldWidget.bound != widget.bound) {
      _target = null;
      _extent = null;
      _lun = null;
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
      final review = widget.bound
          ? await coordinator.prepareBound(_target!, _extent!, lun: _lun!)
          : await coordinator.prepare(_target!, _extent!, lun: _lun!);
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
    final result = widget.bound
        ? await coordinator.executeBound(review, phrase)
        : await coordinator.execute(review, phrase);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = result.message;
    });
    if (result.outcome == IscsiMappingCreateOutcome.completed) {
      _target = null;
      _extent = null;
      _lun = null;
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
            _extent == _review?.extentId &&
            _lun == _review?.lun &&
            widget.bound == _review?.bound
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        (widget.bound ? coordinator.boundAvailable : coordinator.available) &&
        !coordinator.locked;
    final mappedExtents = widget.overview.mappings
        .map((m) => m.extentId)
        .toSet();
    final targetMappings = widget.overview.mappings
        .where((mapping) => mapping.targetId == _target)
        .toList();
    final usedLuns = targetMappings.map((mapping) => mapping.lun).toSet();
    final lunChoices = targetMappings.isEmpty
        ? const <int>[0]
        : usedLuns.contains(0) && usedLuns.length == targetMappings.length
        ? [
            for (var lun = 1; lun <= 31; lun++)
              if (!usedLuns.contains(lun)) lun,
          ]
        : <int>[];
    final targets = widget.overview.targets
        .where(
          (target) =>
              target.mode == 'iSCSI' &&
              (widget.bound
                  ? target.groups.length == 1 &&
                        target.groups.single.authMethod == 'No CHAP'
                  : target.groups.isEmpty),
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
      title: widget.bound
          ? 'Map an unused extent to an access-bound target'
          : 'Map an unused extent to a LUN',
      description: widget.bound
          ? 'First mapping uses LUN 0; subsequent mappings use a free LUN 1–31. The iSCSI-only target must have exactly one explicit no-CHAP portal/initiator group and no authorized networks. The access group and extent backing stay unchanged. Stop iSCSI and disconnect all clients first.'
          : 'First mapping uses LUN 0; subsequent mappings use a free LUN 1–31. Only an unbound iSCSI-only target and enabled, unlocked, unused extent qualify. Stop iSCSI and disconnect all clients first.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<int>(
            key: Key(_key('target')),
            isExpanded: true,
            initialValue: targets.any((item) => item.id == _target)
                ? _target
                : null,
            decoration: InputDecoration(
              labelText: widget.bound
                  ? 'Access-bound target'
                  : 'Unbound target',
              border: const OutlineInputBorder(),
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
                    final used = widget.overview.mappings
                        .where((mapping) => mapping.targetId == id)
                        .map((mapping) => mapping.lun)
                        .toSet();
                    _lun = used.isEmpty
                        ? 0
                        : used.contains(0)
                        ? [
                            for (var lun = 1; lun <= 31; lun++)
                              if (!used.contains(lun)) lun,
                          ].firstOrNull
                        : null;
                    _review = null;
                    _message = null;
                  })
                : null,
          ),
          const SizedBox(height: 8),
          KeyedSubtree(
            key: ValueKey(('lun', _target, widget.bound)),
            child: DropdownButtonFormField<int>(
              key: Key(_key('lun')),
              initialValue: lunChoices.contains(_lun) ? _lun : null,
              decoration: const InputDecoration(
                labelText: 'LUN number',
                border: OutlineInputBorder(),
              ),
              items: [
                for (final lun in lunChoices)
                  DropdownMenuItem(value: lun, child: Text('LUN $lun')),
              ],
              onChanged: enabled && _target != null && lunChoices.isNotEmpty
                  ? (lun) => setState(() {
                      _lun = lun;
                      _review = null;
                      _message = null;
                    })
                  : null,
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            key: Key(_key('extent')),
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
            key: Key(_key('review')),
            onPressed:
                enabled &&
                    _target != null &&
                    _extent != null &&
                    _lun != null &&
                    lunChoices.contains(_lun)
                ? () => _prepare(coordinator)
                : null,
            child: const Text('Review LUN mapping'),
          ),
          if (coordinator == null ||
              !(widget.bound
                  ? coordinator.boundAvailable
                  : coordinator.available))
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
            if (review.bound)
              Text(
                'Access group: portal #${review.portalId} · initiator #${review.initiatorId} · no CHAP',
              ),
            Text('Extent #${review.extentId}: ${review.extentName}'),
            Text(
              'Assign exact LUN ${review.lun}. No target, extent or existing mapping is edited. Complete inventories, service and sessions are checked again; external administrators can still race these reads.',
            ),
            TextField(
              key: Key(_key('confirmation')),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: Key(_key('submit')),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Map LUN'),
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
