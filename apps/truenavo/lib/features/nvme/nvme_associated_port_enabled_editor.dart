import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_associated_port_enabled_coordinator.dart';
import 'nvme_overview.dart';

class NvmeAssociatedPortEnabledEditor extends ConsumerStatefulWidget {
  const NvmeAssociatedPortEnabledEditor({super.key});
  @override
  ConsumerState<NvmeAssociatedPortEnabledEditor> createState() =>
      _AssociatedPortEnabledState();
}

class _AssociatedPortEnabledState
    extends ConsumerState<NvmeAssociatedPortEnabledEditor> {
  final _id = TextEditingController(), _phrase = TextEditingController();
  NvmeAssociatedPortChoice _choice = NvmeAssociatedPortChoice.on;
  NvmeAssociatedPortEnabledReview? _review;
  NvmeAssociatedPortEnabledCoordinator? _owner;
  Object? _session, _reviewSession;
  bool _busy = false, _reload = false, _limitations = false, _exposure = false;
  String? _message;
  int _epoch = 0;
  int? get _targetId => RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(_id.text)
      ? int.tryParse(_id.text)
      : null;
  void _discard() {
    _epoch++;
    if (_review != null) _owner?.cancel(_review!);
    _review = null;
    _owner = null;
    _reviewSession = null;
    _reload = _limitations = _exposure = false;
    _phrase.clear();
  }

  @override
  void dispose() {
    _discard();
    _id.dispose();
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _prepare(
    NvmeAssociatedPortEnabledCoordinator coordinator,
  ) async {
    final session = ref.read(dashboardActiveSessionProvider);
    _discard();
    final epoch = _epoch;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final review = await coordinator.prepare(_targetId ?? 0, choice: _choice);
      if (!mounted ||
          epoch != _epoch ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          !identical(
            coordinator,
            ref.read(nvmeAssociatedPortEnabledCoordinatorProvider),
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
          () => _message = 'Review failed. Select a singly associated TCP/RDMA port on a restricted subsystem containing only disabled unlocked ZVOLs and a different saved enabled setting. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmeAssociatedPortEnabledCoordinator coordinator,
    NvmeAssociatedPortEnabledReview review,
  ) async {
    final session = _reviewSession, phrase = _phrase.text;
    final reload = _reload, limitations = _limitations, exposure = _exposure;
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
      acknowledgeExposure: exposure,
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
        result.outcome == NvmeAssociatedPortEnabledOutcome.completed) {
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final coordinator = ref.watch(nvmeAssociatedPortEnabledCoordinatorProvider);
    if (!identical(session, _session)) {
      _discard();
      _id.clear();
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
      title: 'Set saved enabled flag on an associated NVMe port',
      description: 'Only a TCP/RDMA port with exactly one restricted populated subsystem, no other subsystem ports and no host grants is supported. All residents must be disabled unlocked ZVOLs with valid unique NSIDs. Listener activity, client IO and runtime access are not attested.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('nvme-associated-port-enabled-id'),
            controller: _id,
            enabled: active,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Exact port database ID',
            ),
            onChanged: (_) => setState(_discard),
          ),
          DropdownButtonFormField<NvmeAssociatedPortChoice>(
            key: const Key('nvme-associated-port-enabled-choice'),
            initialValue: _choice,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Requested saved enabled setting',
            ),
            items: [
              for (final choice in NvmeAssociatedPortChoice.values)
                DropdownMenuItem(value: choice, child: Text(choice.label)),
            ],
            onChanged: active
                ? (choice) => setState(() {
                    _discard();
                    _choice = choice!;
                  })
                : null,
          ),
          OutlinedButton(
            key: const Key('nvme-associated-port-enabled-review'),
            onPressed: active && _targetId != null
                ? () => _prepare(coordinator!)
                : null,
            child: const Text('Review associated port enabled setting'),
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
              'Port #${review.port.id} ${review.port.transport}: enabled ${review.port.enabled} → ${review.choice.label}; subsystem #${review.target.id} ${review.target.name}; preserved NQN ${review.target.subnqn}',
            ),
            Text('Preserved namespaces: ${review.namespaces.length}'),
            for (final namespace in review.namespaces)
              Text(
                'Namespace #${namespace.id}, NSID ${namespace.nsid}: disabled unlocked ZVOL; unchanged',
              ),
            const Text(
              'Only enabled is submitted. Associations, NQN, residents and other projected settings must remain unchanged. Sequential public reads cannot exclude concurrent changes or hidden backing changes. Review is single-use and expires in five minutes.',
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-associated-port-enabled-reload'),
                  value: _reload,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _reload = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I consent to the saved port enabled setting and NVMe configuration reload. This is not proof of the actual listener state or client IO.',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-associated-port-enabled-limitations'),
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
                  key: const Key('nvme-associated-port-enabled-exposure'),
                  value: _exposure,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _exposure = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I understand enabling may expose a network listener and disabling or reload may disrupt clients. Disabled namespaces and absent saved host grants do not prove runtime isolation or quiescence. No connectivity or initiator compatibility test is performed.',
                  ),
                ),
              ],
            ),
            TextField(
              key: const Key('nvme-associated-port-enabled-phrase'),
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
              key: const Key('nvme-associated-port-enabled-submit'),
              onPressed:
                  active &&
                      _reload &&
                      _limitations &&
                      _exposure &&
                      _phrase.text == review.confirmation
                  ? () => _submit(coordinator!, review)
                  : null,
              child: const Text('Apply saved enabled setting'),
            ),
            TextButton(
              key: const Key('nvme-associated-port-enabled-cancel'),
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
