import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_subsystem_attached_nqn_coordinator.dart';
import 'nvme_subsystem_nqn_coordinator.dart' show isSupportedNvmeSubsystemNqn;
import 'nvme_overview.dart';

class NvmeSubsystemAttachedNqnEditor extends ConsumerStatefulWidget {
  const NvmeSubsystemAttachedNqnEditor({super.key});
  @override
  ConsumerState<NvmeSubsystemAttachedNqnEditor> createState() =>
      _AttachedNqnState();
}

class _AttachedNqnState extends ConsumerState<NvmeSubsystemAttachedNqnEditor> {
  final _id = TextEditingController(),
      _phrase = TextEditingController(),
      _nqn = TextEditingController();
  NvmeSubsystemAttachedNqnReview? _review;
  NvmeSubsystemAttachedNqnCoordinator? _owner;
  Object? _session, _reviewSession;
  bool _busy = false,
      _reload = false,
      _limitations = false,
      _clientRisk = false;
  String? _message;
  int _epoch = 0;
  int? get _targetId => RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(_id.text)
      ? int.tryParse(_id.text)
      : null;
  String? get _desiredNqn =>
      isSupportedNvmeSubsystemNqn(_nqn.text) ? _nqn.text : null;

  void _discard() {
    _epoch++;
    if (_review != null) _owner?.cancel(_review!);
    _review = null;
    _owner = null;
    _reviewSession = null;
    _reload = _limitations = _clientRisk = false;
    _phrase.clear();
  }

  @override
  void dispose() {
    _discard();
    _id.dispose();
    _nqn.dispose();
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _prepare(NvmeSubsystemAttachedNqnCoordinator coordinator) async {
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
        nqn: _desiredNqn ?? '',
      );
      if (!mounted ||
          epoch != _epoch ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          !identical(
            coordinator,
            ref.read(nvmeSubsystemAttachedNqnCoordinatorProvider),
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
          () => _message = 'Review failed. Select a restricted subsystem with one disabled TCP/RDMA association, no host grant, safe ZVOL residents and complete unique public NQNs, and a different unused supported NQN. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmeSubsystemAttachedNqnCoordinator coordinator,
    NvmeSubsystemAttachedNqnReview review,
  ) async {
    final session = _reviewSession, phrase = _phrase.text;
    final reload = _reload,
        limitations = _limitations,
        clientRisk = _clientRisk;
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
      acknowledgeClientRisk: clientRisk,
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
        result.outcome == NvmeSubsystemAttachedNqnOutcome.completed) {
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final coordinator = ref.watch(nvmeSubsystemAttachedNqnCoordinatorProvider);
    if (!identical(session, _session)) {
      _discard();
      _id.clear();
      _nqn.clear();
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
      title: 'Change NQN on a singly attached NVMe subsystem',
      description: 'The subsystem must be empty or contain only disabled unlocked ZVOL namespaces with known unique NSIDs, and have restricted access with one disabled TCP/RDMA association and no host grant. The port must not be shared. All public subsystem NQNs must be known and unique. Names and namespace settings remain unchanged. NQN identity changes can require initiator reconfiguration; backing identity, runtime access and concurrent changes are not proven.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('nvme-subsystem-attached-nqn-id'),
            controller: _id,
            enabled: active,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Exact subsystem database ID',
            ),
            onChanged: (_) => setState(_discard),
          ),
          TextField(
            key: const Key('nvme-subsystem-attached-nqn-new'),
            controller: _nqn,
            enabled: active,
            minLines: 1,
            maxLines: 3,
            keyboardType: TextInputType.text,
            textInputAction: TextInputAction.done,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 223,
            maxLengthEnforcement: MaxLengthEnforcement.none,
            decoration: const InputDecoration(
              labelText: 'Explicit dated ASCII NQN (11–223 characters)',
            ),
            onChanged: (_) => setState(_discard),
          ),
          OutlinedButton(
            key: const Key('nvme-subsystem-attached-nqn-review'),
            onPressed: active && _targetId != null && _desiredNqn != null
                ? () => _prepare(coordinator!)
                : null,
            child: const Text('Review subsystem NQN'),
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
              'Subsystem #${review.target.id}: ${review.target.name}; NQN ${review.target.subnqn} → ${review.nqn}',
            ),
            Text(
              'Preserved association #${review.mapping.id}, disabled ${review.port.transport} port #${review.port.id}',
            ),
            Text('Preserved namespaces: ${review.namespaces.length}'),
            for (final namespace in review.namespaces)
              Text(
                'Namespace #${namespace.id}, NSID ${namespace.nsid}: disabled unlocked ZVOL; unchanged',
              ),
            const Text(
              'Only subnqn is submitted; name, access policy, ANA, PI, queue ID and IEEE OUI settings must remain unchanged. Public topology is rechecked; sequential reads cannot exclude concurrent changes. Review is single-use and expires in five minutes.',
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-subsystem-attached-nqn-reload'),
                  value: _reload,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _reload = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I consent to the NQN identity change and NVMe configuration reload. Initiator configuration may need updating; runtime access is not tested.',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-subsystem-attached-nqn-limitations'),
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
                  key: const Key('nvme-subsystem-attached-nqn-client'),
                  value: _clientRisk,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _clientRisk = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I understand NQN changes may break initiator discovery, access and external client configuration. I am responsible for updating clients. Saved disabled flags and absent host grants do not prove runtime quiescence or isolation.',
                  ),
                ),
              ],
            ),
            const Text('Confirmation phrase (copy or type exactly):'),
            SelectableText(
              review.confirmation,
              key: const Key('nvme-subsystem-attached-nqn-confirmation'),
            ),
            TextField(
              key: const Key('nvme-subsystem-attached-nqn-phrase'),
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
              key: const Key('nvme-subsystem-attached-nqn-submit'),
              onPressed:
                  active &&
                      _reload &&
                      _limitations &&
                      _clientRisk &&
                      _phrase.text == review.confirmation
                  ? () => _submit(coordinator!, review)
                  : null,
              child: const Text('Apply subsystem NQN'),
            ),
            TextButton(
              key: const Key('nvme-subsystem-attached-nqn-cancel'),
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
