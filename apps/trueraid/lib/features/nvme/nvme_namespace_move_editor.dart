import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_namespace_move_coordinator.dart';
import 'nvme_overview.dart';

class NvmeNamespaceMoveEditor extends ConsumerStatefulWidget {
  const NvmeNamespaceMoveEditor({super.key});
  @override
  ConsumerState<NvmeNamespaceMoveEditor> createState() => _MoveState();
}

class _MoveState extends ConsumerState<NvmeNamespaceMoveEditor> {
  final _id = TextEditingController(),
      _phrase = TextEditingController(),
      _destination = TextEditingController();
  NvmeNamespaceMoveReview? _review;
  NvmeNamespaceMoveCoordinator? _owner;
  Object? _session, _reviewSession;
  bool _busy = false, _reload = false, _limitations = false;
  String? _message;
  int _epoch = 0;
  int? get _targetId => RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(_id.text)
      ? int.tryParse(_id.text)
      : null;
  int? get _destinationId {
    if (!RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(_destination.text)) return null;
    final value = int.tryParse(_destination.text);
    return value;
  }

  void _discard() {
    _epoch++;
    if (_review != null) _owner?.cancel(_review!);
    _review = null;
    _owner = null;
    _reviewSession = null;
    _reload = _limitations = false;
    _phrase.clear();
  }

  @override
  void dispose() {
    _discard();
    _id.dispose();
    _destination.dispose();
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _prepare(NvmeNamespaceMoveCoordinator coordinator) async {
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
        destinationId: _destinationId ?? 0,
      );
      if (!mounted ||
          epoch != _epoch ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          !identical(
            coordinator,
            ref.read(nvmeNamespaceMoveCoordinatorProvider),
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
          () => _message = 'Review failed. Select an isolated disabled unlocked ZVOL namespace and a different isolated destination with only disabled unlocked ZVOLs and no NSID collision. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmeNamespaceMoveCoordinator coordinator,
    NvmeNamespaceMoveReview review,
  ) async {
    final session = _reviewSession, phrase = _phrase.text;
    final reload = _reload, limitations = _limitations;
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
        result.outcome == NvmeNamespaceMoveOutcome.completed) {
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final coordinator = ref.watch(nvmeNamespaceMoveCoordinatorProvider);
    if (!identical(session, _session)) {
      _discard();
      _id.clear();
      _destination.clear();
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
      title: 'Move isolated disabled ZVOL namespace configuration',
      description: 'Saved configuration only, moving a disabled unlocked ZVOL namespace to a different restricted subsystem. The destination can be empty or contain only disabled unlocked ZVOLs with known unique NSIDs that do not collide with the moved NSID. Both subsystems must have distinct known NQNs and no host or port mappings. Backing paths, sizes and identifiers are not read or edited. Runtime client IO, backing identity and health are not proven.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('nvme-namespace-move-id'),
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
            key: const Key('nvme-namespace-move-new'),
            controller: _destination,
            enabled: active,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Exact isolated destination subsystem database ID',
            ),
            onChanged: (_) => setState(_discard),
          ),
          OutlinedButton(
            key: const Key('nvme-namespace-move-review'),
            onPressed: active && _targetId != null && _destinationId != null
                ? () => _prepare(coordinator!)
                : null,
            child: const Text('Review namespace subsystem assignment'),
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
              'Namespace #${review.target.id}, subsystem #${review.target.subsystemId}, NSID ${review.target.nsid}: subsystem #${review.source.id} → #${review.destination.id}',
            ),
            Text('Source: ${review.source.name} — ${review.source.subnqn}'),
            Text(
              'Destination: ${review.destination.name} — ${review.destination.subnqn}',
            ),
            Text(
              'Existing destination namespaces: ${review.destinationNamespaces.length}. All must remain unchanged; no NSID is reassigned.',
            ),
            for (final namespace in review.destinationNamespaces)
              Text(
                'Existing namespace #${namespace.id}, NSID ${namespace.nsid}: disabled unlocked ZVOL',
              ),
            const Text(
              'Only subsys_id is submitted; NSID and disabled state must remain unchanged. Public topology is rechecked; sequential reads cannot exclude concurrent changes or hidden backing drift. Review is single-use and expires in five minutes.',
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-namespace-move-reload'),
                  value: _reload,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _reload = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I consent to the subsystem assignment change and NVMe configuration reload. Initiator configuration may need updating; runtime access is not tested.',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-namespace-move-limitations'),
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
            TextField(
              key: const Key('nvme-namespace-move-phrase'),
              controller: _phrase,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
              ),
              onChanged: (_) => setState(() {}),
            ),
            FilledButton(
              key: const Key('nvme-namespace-move-submit'),
              onPressed:
                  active &&
                      _reload &&
                      _limitations &&
                      _phrase.text == review.confirmation
                  ? () => _submit(coordinator!, review)
                  : null,
              child: const Text('Apply namespace subsystem assignment'),
            ),
            TextButton(
              key: const Key('nvme-namespace-move-cancel'),
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
