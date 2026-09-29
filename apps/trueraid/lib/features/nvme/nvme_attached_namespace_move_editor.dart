import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_attached_namespace_move_coordinator.dart';
import 'nvme_overview.dart';

class NvmeAttachedNamespaceMoveEditor extends ConsumerStatefulWidget {
  const NvmeAttachedNamespaceMoveEditor({super.key});
  @override
  ConsumerState<NvmeAttachedNamespaceMoveEditor> createState() => _MoveState();
}

class _MoveState extends ConsumerState<NvmeAttachedNamespaceMoveEditor> {
  final _id = TextEditingController(),
      _phrase = TextEditingController(),
      _destinationId = TextEditingController();
  NvmeAttachedNamespaceMoveReview? _review;
  NvmeAttachedNamespaceMoveCoordinator? _owner;
  Object? _session, _reviewSession;
  bool _busy = false,
      _reload = false,
      _limitations = false,
      _identityRisk = false;
  String? _message;
  int _epoch = 0;
  int? get _targetId => RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(_id.text)
      ? int.tryParse(_id.text)
      : null;
  int? get _desiredDestination {
    if (!RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(_destinationId.text)) {
      return null;
    }
    final value = int.tryParse(_destinationId.text);
    return value != null && value > 0 ? value : null;
  }

  void _discard() {
    _epoch++;
    if (_review != null) _owner?.cancel(_review!);
    _review = null;
    _owner = null;
    _reviewSession = null;
    _reload = _limitations = _identityRisk = false;
    _phrase.clear();
  }

  @override
  void dispose() {
    _discard();
    _id.dispose();
    _destinationId.dispose();
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _prepare(
    NvmeAttachedNamespaceMoveCoordinator coordinator,
  ) async {
    final session = ref.read(dashboardActiveSessionProvider);
    _discard();
    final epoch = _epoch;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final review = await coordinator.prepare(
        _targetId ?? 0,
        destinationId: _desiredDestination ?? 0,
      );
      if (!mounted ||
          epoch != _epoch ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          !identical(
            coordinator,
            ref.read(nvmeAttachedNamespaceMoveCoordinatorProvider),
          )) {
        coordinator.cancel(review);
        return;
      }
      setState(() {
        _review = review;
        _owner = coordinator;
        _reviewSession = session;
      });
    } on Object {
      if (mounted &&
          epoch == _epoch &&
          identical(session, ref.read(dashboardActiveSessionProvider))) {
        setState(
          () => _message = 'Review failed. Select a singly attached disabled unlocked ZVOL namespace and a different restricted isolated destination with safe disabled unlocked unique-NSID ZVOL residents. Nothing is enabled or removed. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmeAttachedNamespaceMoveCoordinator coordinator,
    NvmeAttachedNamespaceMoveReview review,
  ) async {
    final session = _reviewSession, phrase = _phrase.text;
    final reload = _reload,
        limitations = _limitations,
        identityRisk = _identityRisk;
    _review = null;
    setState(() {
      _busy = true;
      _message = null;
    });
    final result = await coordinator.execute(
      review,
      phrase,
      acknowledgeReload: reload,
      acknowledgeLimitations: limitations,
      acknowledgeIdentityRisk: identityRisk,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (identical(session, ref.read(dashboardActiveSessionProvider))) {
        _discard();
        _message = result.message;
      }
    });
    if (identical(session, ref.read(dashboardActiveSessionProvider)) &&
        result.outcome == NvmeAttachedNamespaceMoveOutcome.completed) {
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final coordinator = ref.watch(nvmeAttachedNamespaceMoveCoordinatorProvider);
    if (!identical(session, _session)) {
      _discard();
      _id.clear();
      _destinationId.clear();
      _message = null;
      _session = session;
    }
    if (_owner != null && !identical(coordinator, _owner)) _discard();
    final active =
        !_busy &&
        coordinator?.available == true &&
        coordinator?.locked == false;
    final review = _review;
    return TdPanel(
      title: 'Move a singly attached disabled ZVOL to an isolated subsystem',
      description: 'Only a disabled unlocked ZVOL in a restricted subsystem behind one disabled TCP/RDMA port, with no other port mapping or host grant and safe disabled residents, is supported. The different destination must be restricted and have no port or host mapping and only safe disabled unlocked ZVOL residents with noncolliding NSIDs. Known public subsystem NQNs must be unique. Only the saved subsystem assignment changes; NSID, port, enablement and backing fields remain unchanged.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('nvme-attached-namespace-move-id'),
            controller: _id,
            enabled: active,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Exact namespace database ID (not NSID)',
            ),
            onChanged: (_) => setState(_discard),
          ),
          TextField(
            key: const Key('nvme-attached-namespace-move-new'),
            controller: _destinationId,
            enabled: active,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Exact isolated destination subsystem database ID',
            ),
            onChanged: (_) => setState(_discard),
          ),
          OutlinedButton(
            key: const Key('nvme-attached-namespace-move-review'),
            onPressed:
                active && _targetId != null && _desiredDestination != null
                ? () => _prepare(coordinator!)
                : null,
            child: const Text('Review attached namespace move'),
          ),
          if (coordinator?.available != true)
            const Text(
              'Required methods and protected host inventory are unavailable.',
            ),
          if (coordinator?.locked == true)
            const Text(
              'An operation is in progress or an NVMe change is unverified. Reconnect before editing.',
            ),
          if (review != null) ...[
            Text('Server: ${review.endpoint}'),
            Text(
              'Namespace #${review.target.id}, preserved NSID ${review.target.nsid}; subsystem #${review.source.id} NQN ${review.source.subnqn} → #${review.destination.id} NQN ${review.destination.subnqn}',
            ),
            Text(
              'Preserved association #${review.mapping.id}, disabled port #${review.port.id} ${review.port.transport}; subsystem ${review.source.name}; NQN ${review.source.subnqn}',
            ),
            Text(
              'Unchanged neighboring namespaces: ${review.sourceNamespaces.length}',
            ),
            for (final resident in review.sourceNamespaces)
              Text(
                'Namespace #${resident.id}, NSID ${resident.nsid}: disabled unlocked ZVOL; unchanged',
              ),
            Text(
              'Unchanged destination residents: ${review.destinationNamespaces.length}',
            ),
            for (final resident in review.destinationNamespaces)
              Text(
                'Destination namespace #${resident.id}, NSID ${resident.nsid}: disabled unlocked ZVOL; unchanged',
              ),
            const Text(
              'Only subsys_id is submitted. Public topology is rechecked; sequential reads cannot exclude concurrent changes or hidden backing drift. Review is single-use and expires in five minutes.',
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-attached-namespace-move-reload'),
                  value: _reload,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _reload = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I consent to the saved subsystem assignment change and NVMe configuration reload. Initiator configuration may need updating; runtime access is not tested.',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-attached-namespace-move-limitations'),
                  value: _limitations,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _limitations = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I understand backing identity, ownership and health are unverified and concurrent administrators are not excluded. No retry or rollback is attempted for an uncertain result.',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-attached-namespace-move-identity'),
                  value: _identityRisk,
                  onChanged: _busy
                      ? null
                      : (value) =>
                            setState(() => _identityRisk = value == true),
                ),
                const Expanded(
                  child: Text(
                    'I understand moving a namespace changes its subsystem NQN context and may disrupt initiator discovery or access. The original disabled port association remains unchanged; no port or namespace is enabled. Disabled saved flags do not prove runtime quiescence or isolation; initiator compatibility and discovery are not tested.',
                  ),
                ),
              ],
            ),
            const Text('Confirmation phrase (copy or type exactly):'),
            SelectableText(
              review.confirmation,
              key: const Key('nvme-attached-namespace-move-confirmation'),
            ),
            TextField(
              key: const Key('nvme-attached-namespace-move-phrase'),
              controller: _phrase,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Exact confirmation phrase',
              ),
              onChanged: (_) => setState(() {}),
            ),
            FilledButton(
              key: const Key('nvme-attached-namespace-move-submit'),
              onPressed:
                  active &&
                      _reload &&
                      _limitations &&
                      _identityRisk &&
                      _phrase.text == review.confirmation
                  ? () => _submit(coordinator!, review)
                  : null,
              child: const Text('Apply saved namespace move'),
            ),
            TextButton(
              key: const Key('nvme-attached-namespace-move-cancel'),
              onPressed: _busy ? null : () => setState(_discard),
              child: const Text('Cancel review'),
            ),
          ],
          if (_message != null) Text(_message!),
        ],
      ),
    );
  }
}
