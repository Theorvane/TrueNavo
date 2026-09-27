import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'iscsi_overview.dart';
import 'iscsi_page.dart' show iscsiOverviewProvider;
import 'iscsi_target_access_coordinator.dart';

class IscsiTargetAccessEditor extends ConsumerStatefulWidget {
  const IscsiTargetAccessEditor({required this.overview, super.key});
  final IscsiOverview overview;

  @override
  ConsumerState<IscsiTargetAccessEditor> createState() =>
      _IscsiTargetAccessEditorState();
}

class _IscsiTargetAccessEditorState
    extends ConsumerState<IscsiTargetAccessEditor> {
  final _confirmation = TextEditingController();
  int? _target, _portal, _initiator;
  IscsiTargetAccessReview? _review;
  Object? _reviewSession;
  String? _message;
  bool _busy = false;

  @override
  void didUpdateWidget(covariant IscsiTargetAccessEditor oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.overview, widget.overview)) {
      _target = null;
      _portal = null;
      _initiator = null;
      _review = null;
      _confirmation.clear();
    }
  }

  @override
  void dispose() {
    _confirmation.dispose();
    super.dispose();
  }

  Future<void> _prepare(IscsiTargetAccessCoordinator coordinator) async {
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    try {
      final review = await coordinator.prepare(_target!, _portal!, _initiator!);
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
    IscsiTargetAccessCoordinator coordinator,
    IscsiTargetAccessReview review,
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
    if (result.outcome == IscsiTargetAccessOutcome.completed) {
      _target = null;
      _portal = null;
      _initiator = null;
      _confirmation.clear();
      ref.invalidate(iscsiOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(iscsiTargetAccessCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    final review =
        identical(session, _reviewSession) &&
            _target == _review?.targetId &&
            _portal == _review?.portalId &&
            _initiator == _review?.initiatorId
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    final mapped = widget.overview.mappings
        .map((item) => item.targetId)
        .toSet();
    final targets = widget.overview.targets.where(
      (item) =>
          item.mode == 'iSCSI' &&
          item.groups.isEmpty &&
          !mapped.contains(item.id),
    );
    final portals = widget.overview.portals.where(
      (item) =>
          item.listeners.length == 1 &&
          item.listeners.single.ip != '0.0.0.0' &&
          !item.listeners.single.ip.contains(':'),
    );
    final initiators = widget.overview.initiators.where(
      (item) => item.names.isNotEmpty && !item.names.contains('ALL'),
    );
    return TdPanel(
      title: 'Attach a portal and initiator to an unbound target',
      description: 'For a target with no access groups, authorized networks or LUNs. Only one explicit portal and initiator group are attached, without CHAP or a LUN. Stop iSCSI and disconnect clients first.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          DropdownButtonFormField<int>(
            key: const Key('iscsi-access-target'),
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
                ? (value) => setState(() {
                    _target = value;
                    _review = null;
                    _message = null;
                  })
                : null,
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            key: const Key('iscsi-access-portal'),
            isExpanded: true,
            initialValue: portals.any((item) => item.id == _portal)
                ? _portal
                : null,
            decoration: const InputDecoration(
              labelText: 'Portal',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final item in portals)
                DropdownMenuItem(
                  value: item.id,
                  child: Text(
                    '#${item.id} ${item.listeners.single.ip}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: enabled
                ? (value) => setState(() {
                    _portal = value;
                    _review = null;
                    _message = null;
                  })
                : null,
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<int>(
            key: const Key('iscsi-access-initiator'),
            isExpanded: true,
            initialValue: initiators.any((item) => item.id == _initiator)
                ? _initiator
                : null,
            decoration: const InputDecoration(
              labelText: 'Explicit initiator group',
              border: OutlineInputBorder(),
            ),
            items: [
              for (final item in initiators)
                DropdownMenuItem(
                  value: item.id,
                  child: Text(
                    '#${item.id} ${item.names.join(', ')}',
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: enabled
                ? (value) => setState(() {
                    _initiator = value;
                    _review = null;
                    _message = null;
                  })
                : null,
          ),
          const SizedBox(height: 8),
          OutlinedButton(
            key: const Key('iscsi-access-review'),
            onPressed:
                enabled &&
                    _target != null &&
                    _portal != null &&
                    _initiator != null
                ? () => _prepare(coordinator)
                : null,
            child: const Text('Review target access association'),
          ),
          if (coordinator == null || !coordinator.available)
            const Text(
              'This server does not expose the required iSCSI methods.',
            ),
          if (coordinator?.locked == true)
            const Text(
              'An iSCSI change is in progress or unverified. Reconnect before retrying.',
            ),
          if (review != null && coordinator != null) ...[
            const Divider(),
            Text('Server: ${review.endpoint}'),
            Text('Target #${review.targetId}: ${review.targetName}'),
            Text('Portal #${review.portalId}: ${review.portalIp}'),
            Text(
              'Initiator #${review.initiatorId}: ${review.initiatorNames.join(', ')}',
            ),
            const Text(
              'No CHAP, authorized networks or LUN is submitted. Complete inventories and stopped service are checked again; concurrent administrators can still race these reads.',
            ),
            TextField(
              key: const Key('iscsi-access-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('iscsi-access-submit'),
              onPressed: _busy ? null : () => _submit(coordinator, review),
              child: const Text('Attach portal and initiator'),
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
