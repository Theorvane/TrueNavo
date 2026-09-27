import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_mapping_create_coordinator.dart';
import 'iscsi_overview.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;

class IscsiMappingRenumberEditor extends ConsumerStatefulWidget {
  const IscsiMappingRenumberEditor({
    required this.overview,
    this.bound = false,
    super.key,
  });
  final IscsiOverview overview;
  final bool bound;

  @override
  ConsumerState<IscsiMappingRenumberEditor> createState() =>
      _IscsiMappingRenumberEditorState();
}

class _IscsiMappingRenumberEditorState
    extends ConsumerState<IscsiMappingRenumberEditor> {
  final _confirmation = TextEditingController();
  int? _mapping, _proposed;
  IscsiMappingRenumberReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;
  String _key(String suffix) =>
      'iscsi-mapping-${widget.bound ? 'bound-' : ''}renumber-$suffix';

  @override
  void didUpdateWidget(covariant IscsiMappingRenumberEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.overview, widget.overview)) {
      _mapping = null;
      _proposed = null;
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
          ? await coordinator.prepareBoundRenumber(_mapping!, _proposed!)
          : await coordinator.prepareRenumber(_mapping!, _proposed!);
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
    IscsiMappingRenumberReview review,
  ) async {
    final phrase = _confirmation.text;
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    final result = widget.bound
        ? await coordinator.executeBoundRenumber(review, phrase)
        : await coordinator.executeRenumber(review, phrase);
    if (!mounted) return;
    setState(() {
      _busy = false;
      _message = result.message;
    });
    if (result.outcome == IscsiMappingCreateOutcome.completed) {
      _mapping = null;
      _proposed = null;
      _confirmation.clear();
      ref.invalidate(iscsiOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiMappingCreateCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final selected = widget.overview.mappings
        .where((mapping) => mapping.id == _mapping)
        .firstOrNull;
    final used = widget.overview.mappings
        .where((mapping) => mapping.targetId == selected?.targetId)
        .map((mapping) => mapping.lun)
        .toSet();
    final choices = selected != null && used.contains(0)
        ? [
            for (var lun = 1; lun <= 31; lun++)
              if (!used.contains(lun)) lun,
          ]
        : <int>[];
    final review =
        identical(session, _reviewSession) &&
            _mapping == _review?.mappingId &&
            _proposed == _review?.proposedLun &&
            widget.bound == _review?.bound
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        (widget.bound
            ? coordinator.boundRenumberAvailable
            : coordinator.renumberAvailable) &&
        !coordinator.locked;
    final options = widget.overview.mappings
        .where(
          (mapping) =>
              mapping.lun >= 1 &&
              mapping.lun <= 31 &&
              widget.overview.targetById(mapping.targetId)?.mode == 'iSCSI' &&
              (widget.bound
                  ? widget.overview
                            .targetById(mapping.targetId)!
                            .groups
                            .isNotEmpty &&
                        widget.overview
                                .targetById(mapping.targetId)!
                                .groups
                                .length <=
                            8 &&
                        widget.overview
                            .targetById(mapping.targetId)!
                            .groups
                            .every(
                              (group) =>
                                  group.authMethod == 'No CHAP' &&
                                  group.initiatorId != null,
                            )
                  : widget.overview
                            .targetById(mapping.targetId)
                            ?.groups
                            .isEmpty ==
                        true),
        )
        .toList();
    return TdPanel(
      title: widget.bound
          ? 'Change an access-bound additional LUN number'
          : 'Change an additional LUN number',
      description: widget.bound
          ? 'Moves one LUN 1–31 to a free number on the same target with 1–8 distinct explicit no-CHAP portal/initiator groups. LUN 0 and access settings remain unchanged. Stop iSCSI and disconnect clients first.'
          : 'Moves one LUN 1–31 to a free number on the same unbound iSCSI target. LUN 0, target and extent IDs remain unchanged. Stop iSCSI and disconnect clients first.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<int>(
            key: Key(_key('select')),
            isExpanded: true,
            initialValue: options.any((item) => item.id == _mapping)
                ? _mapping
                : null,
            decoration: const InputDecoration(
              labelText: 'Mapping to change',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final item in options)
                DropdownMenuItem(
                  value: item.id,
                  child: Text(
                    '#${item.id} ${widget.overview.targetById(item.targetId)?.name ?? '(missing target)'} · LUN ${item.lun}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: enabled
                ? (id) => setState(() {
                    _mapping = id;
                    final selected = widget.overview.mappings
                        .where((mapping) => mapping.id == id)
                        .firstOrNull;
                    final used = widget.overview.mappings
                        .where(
                          (mapping) => mapping.targetId == selected?.targetId,
                        )
                        .map((mapping) => mapping.lun)
                        .toSet();
                    _proposed = used.contains(0)
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
          DropdownButtonFormField<int>(
            key: Key(_key('lun')),
            initialValue: choices.contains(_proposed) ? _proposed : null,
            decoration: const InputDecoration(
              labelText: 'New LUN number',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final lun in choices)
                DropdownMenuItem(value: lun, child: Text('LUN $lun')),
            ],
            onChanged: enabled && choices.isNotEmpty
                ? (lun) => setState(() {
                    _proposed = lun;
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
                    _mapping != null &&
                    _proposed != null &&
                    choices.contains(_proposed)
                ? () => _prepare(coordinator)
                : null,
            child: const Text('Review LUN number change'),
          ),
          if (coordinator == null ||
              !(widget.bound
                  ? coordinator.boundRenumberAvailable
                  : coordinator.renumberAvailable))
            const Text(
              'This server does not expose the required LUN update methods.',
            ),
          if (coordinator?.locked == true)
            const Text(
              'An iSCSI change is in progress or unverified. Reconnect before retrying.',
            ),
          if (review != null && coordinator != null) ...[
            const Divider(),
            Text('Server: ${review.endpoint}'),
            Text(
              'Mapping #${review.mappingId}: LUN ${review.beforeLun} → ${review.proposedLun}',
            ),
            Text('Target #${review.targetId}: ${review.targetName}'),
            Text('Extent #${review.extentId}: ${review.extentName}'),
            for (var i = 0; i < review.accessGroups.length; i++)
              Text(
                '${review.accessGroups.length == 1 ? '' : 'Group ${i + 1}: '}Portal #${review.accessGroups[i].portalId} · initiator #${review.accessGroups[i].initiatorId}',
              ),
            const Text(
              'Only lunid is submitted. Complete inventories, service and sessions are rechecked; another administrator can still race these reads.',
            ),
            SelectableText(review.confirmation),
            TextField(
              key: Key(_key('confirmation')),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type the exact phrase above',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: Key(_key('submit')),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Change LUN number'),
            ),
            TextButton(
              onPressed: _busy
                  ? null
                  : () {
                      coordinator.cancelRenumber(review);
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
