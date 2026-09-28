import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_subsystem_populated_pi_coordinator.dart';
import 'nvme_overview.dart';

class NvmeSubsystemPopulatedPiEditor extends ConsumerStatefulWidget {
  const NvmeSubsystemPopulatedPiEditor({super.key});
  @override
  ConsumerState<NvmeSubsystemPopulatedPiEditor> createState() =>
      _PopulatedPiState();
}

class _PopulatedPiState extends ConsumerState<NvmeSubsystemPopulatedPiEditor> {
  final _id = TextEditingController(), _phrase = TextEditingController();
  NvmePopulatedPiChoice _choice = NvmePopulatedPiChoice.on;
  NvmeSubsystemPopulatedPiReview? _review;
  NvmeSubsystemPopulatedPiCoordinator? _owner;
  Object? _session, _reviewSession;
  bool _busy = false, _reload = false, _limitations = false, _integrity = false;
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
    _reload = _limitations = _integrity = false;
    _phrase.clear();
  }

  @override
  void dispose() {
    _discard();
    _id.dispose();
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _prepare(NvmeSubsystemPopulatedPiCoordinator coordinator) async {
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
            ref.read(nvmeSubsystemPopulatedPiCoordinatorProvider),
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
          () => _message = 'Review failed. Select a populated restricted isolated subsystem with a reported PI field and a different saved PI setting. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmeSubsystemPopulatedPiCoordinator coordinator,
    NvmeSubsystemPopulatedPiReview review,
  ) async {
    final session = _reviewSession, phrase = _phrase.text;
    final reload = _reload, limitations = _limitations, integrity = _integrity;
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
      acknowledgeIntegrity: integrity,
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
        result.outcome == NvmeSubsystemPopulatedPiOutcome.completed) {
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final coordinator = ref.watch(nvmeSubsystemPopulatedPiCoordinatorProvider);
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
      title: 'Set saved PI on an isolated populated NVMe subsystem',
      description: 'Only a restricted subsystem containing disabled unlocked ZVOL namespaces with valid unique NSIDs and no host or port mappings is supported. Its NQN and all namespace and other settings remain unchanged. Default saves null; effective PI behavior, backing metadata format and initiator compatibility are not attested.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('nvme-subsystem-populated-pi-id'),
            controller: _id,
            enabled: active,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Exact subsystem database ID',
            ),
            onChanged: (_) => setState(_discard),
          ),
          DropdownButtonFormField<NvmePopulatedPiChoice>(
            key: const Key('nvme-subsystem-populated-pi-choice'),
            initialValue: _choice,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Requested saved PI setting',
            ),
            items: [
              for (final choice in NvmePopulatedPiChoice.values)
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
            key: const Key('nvme-subsystem-populated-pi-review'),
            onPressed: active && _targetId != null
                ? () => _prepare(coordinator!)
                : null,
            child: const Text('Review populated subsystem PI'),
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
              'Subsystem #${review.target.id}: ${review.target.name}; PI ${review.target.piEnable} → ${review.choice.label}; preserved NQN ${review.target.subnqn}',
            ),
            Text('Preserved namespaces: ${review.namespaces.length}'),
            for (final namespace in review.namespaces)
              Text(
                'Namespace #${namespace.id}, NSID ${namespace.nsid}: disabled unlocked ZVOL; unchanged',
              ),
            const Text(
              'Only pi_enable is submitted. Name, NQN, namespace settings, access policy, ANA, queue ID and IEEE OUI settings must remain unchanged. Public topology is rechecked; sequential reads cannot exclude concurrent changes. Review is single-use and expires in five minutes.',
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-subsystem-populated-pi-reload'),
                  value: _reload,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _reload = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I consent to the saved PI setting change and NVMe configuration reload. The NQN must remain unchanged; effective PI behavior and actual data integrity are not tested.',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-subsystem-populated-pi-limitations'),
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
                  key: const Key('nvme-subsystem-populated-pi-integrity'),
                  value: _integrity,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _integrity = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I understand PI changes can require compatible backing metadata and initiator settings. This review does not validate their compatibility, protection format or actual data integrity; disabled namespaces are not tested or enabled.',
                  ),
                ),
              ],
            ),
            TextField(
              key: const Key('nvme-subsystem-populated-pi-phrase'),
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
              key: const Key('nvme-subsystem-populated-pi-submit'),
              onPressed:
                  active &&
                      _reload &&
                      _limitations &&
                      _integrity &&
                      _phrase.text == review.confirmation
                  ? () => _submit(coordinator!, review)
                  : null,
              child: const Text('Apply saved PI'),
            ),
            TextButton(
              key: const Key('nvme-subsystem-populated-pi-cancel'),
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
