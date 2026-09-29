import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_subsystem_attached_rename_coordinator.dart';
import 'nvme_overview.dart';
import 'nvme_subsystem_populated_rename_coordinator.dart'
    show isSupportedNvmeSubsystemDisplayName;

class NvmeSubsystemAttachedRenameEditor extends ConsumerStatefulWidget {
  const NvmeSubsystemAttachedRenameEditor({super.key});
  @override
  ConsumerState<NvmeSubsystemAttachedRenameEditor> createState() =>
      _AttachedRenameState();
}

class _AttachedRenameState
    extends ConsumerState<NvmeSubsystemAttachedRenameEditor> {
  final _id = TextEditingController(),
      _phrase = TextEditingController(),
      _name = TextEditingController();
  NvmeSubsystemAttachedRenameReview? _review;
  NvmeSubsystemAttachedRenameCoordinator? _owner;
  Object? _session, _reviewSession;
  List<NvmeSubsystemAttachedRenameCandidate>? _candidates;
  NvmeSubsystemAttachedRenameCoordinator? _candidateOwner;
  bool _busy = false,
      _reload = false,
      _limitations = false,
      _clientRisk = false;
  String? _message;
  int _epoch = 0;
  int? get _targetId => RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(_id.text)
      ? int.tryParse(_id.text)
      : null;
  String? get _desiredName =>
      isSupportedNvmeSubsystemDisplayName(_name.text) ? _name.text : null;

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
    _name.dispose();
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _loadCandidates(
    NvmeSubsystemAttachedRenameCoordinator coordinator,
  ) async {
    final session = ref.read(dashboardActiveSessionProvider);
    _discard();
    final epoch = _epoch;
    setState(() {
      _busy = true;
      _candidates = null;
      _candidateOwner = null;
      _id.clear();
      _name.clear();
      _message = null;
    });
    try {
      final candidates = await coordinator.loadCandidates();
      if (!mounted ||
          epoch != _epoch ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          !identical(
            coordinator,
            ref.read(nvmeSubsystemAttachedRenameCoordinatorProvider),
          )) {
        return;
      }
      setState(() {
        _candidates = candidates;
        _candidateOwner = coordinator;
      });
    } on Object {
      if (mounted &&
          epoch == _epoch &&
          identical(session, ref.read(dashboardActiveSessionProvider)) &&
          identical(
            coordinator,
            ref.read(nvmeSubsystemAttachedRenameCoordinatorProvider),
          )) {
        setState(
          () => _message = 'Rename target discovery failed. No configuration request was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepare(
    NvmeSubsystemAttachedRenameCoordinator coordinator,
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
        name: _desiredName ?? '',
      );
      if (!mounted ||
          epoch != _epoch ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          !identical(
            coordinator,
            ref.read(nvmeSubsystemAttachedRenameCoordinatorProvider),
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
          () => _message = 'Review failed. Select a restricted subsystem behind one disabled TCP/RDMA port with safe ZVOL residents, if any, and a different unused display name. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmeSubsystemAttachedRenameCoordinator coordinator,
    NvmeSubsystemAttachedRenameReview review,
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
        _candidates = null;
        _candidateOwner = null;
        _message = result.message;
      }
    });
    if (identical(session, ref.read(dashboardActiveSessionProvider)) &&
        result.outcome == NvmeSubsystemAttachedRenameOutcome.completed) {
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final coordinator = ref.watch(
      nvmeSubsystemAttachedRenameCoordinatorProvider,
    );
    if (!identical(session, _session)) {
      _discard();
      _id.clear();
      _name.clear();
      _candidates = null;
      _candidateOwner = null;
      _message = null;
      _session = session;
    }
    if (_owner != null && !identical(coordinator, _owner)) _discard();
    if (_candidateOwner != null && !identical(coordinator, _candidateOwner)) {
      _discard();
      _id.clear();
      _name.clear();
      _candidates = null;
      _candidateOwner = null;
      _message = null;
    }
    final active =
        !_busy &&
        coordinator?.available == true &&
        coordinator?.locked == false;
    final review = _review;
    final candidates = _candidates;
    final selected = candidates
        ?.where((c) => c.target.id == _targetId)
        .singleOrNull;
    return TdPanel(
      title: 'Rename a singly attached restricted NVMe subsystem',
      description: 'Only a restricted subsystem with one disabled TCP/RDMA port association and no host grant is supported. Residents, if any, must be disabled unlocked ZVOLs with valid unique NSIDs. Its NQN and all namespace and other settings remain unchanged; backing identity, runtime access and concurrent changes are not proven.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton(
            key: const Key('nvme-subsystem-attached-rename-discover'),
            onPressed: active ? () => _loadCandidates(coordinator!) : null,
            child: const Text('Load or refresh eligible rename targets'),
          ),
          if (candidates != null) ...[
            const Text(
              'Discovery is a public configuration snapshot, not proof of runtime safety. Selection only fills the database ID; review and submission independently reread the server. Only the display name changes; NQN and reviewed associations are preserved.',
            ),
            if (candidates.isEmpty)
              const Text('No eligible subsystem rename targets were found.'),
            if (candidates.isNotEmpty)
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Choose subsystem',
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    key: const Key('nvme-subsystem-attached-rename-choice'),
                    isExpanded: true,
                    value: selected?.target.id,
                    hint: const Text('Select a subsystem'),
                    items: [
                      for (final candidate in candidates)
                        DropdownMenuItem(
                          value: candidate.target.id,
                          child: Text(
                            '#${candidate.target.id} · ${candidate.target.name}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: active
                        ? (id) => setState(() {
                            _discard();
                            _id.text = id?.toString() ?? '';
                            _name.clear();
                            _message = null;
                          })
                        : null,
                  ),
                ),
              ),
            if (selected != null) ...[
              Text(
                'Current name: ${selected.target.name}; preserved NQN: ${selected.target.subnqn}; association #${selected.mapping.id}, disabled ${selected.port.transport} port #${selected.port.id}',
              ),
              Text(
                'Preserved namespaces (${selected.namespaces.length}): ${selected.namespaces.isEmpty ? 'none' : selected.namespaces.map((n) => '#${n.id} / NSID ${n.nsid}').join(', ')}',
              ),
            ],
          ],
          TextField(
            key: const Key('nvme-subsystem-attached-rename-id'),
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
            key: const Key('nvme-subsystem-attached-rename-new'),
            controller: _name,
            enabled: active,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 120,
            decoration: const InputDecoration(
              labelText: 'New display name (1–120 characters)',
            ),
            onChanged: (_) => setState(_discard),
          ),
          OutlinedButton(
            key: const Key('nvme-subsystem-attached-rename-review'),
            onPressed: active && _targetId != null && _desiredName != null
                ? () => _prepare(coordinator!)
                : null,
            child: const Text('Review attached subsystem rename'),
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
              'Subsystem #${review.target.id}: ${review.target.name}; Name ${review.target.name} → ${review.name}; preserved NQN ${review.target.subnqn}',
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
              'Only name and the explicitly preserved subnqn are submitted. Namespace settings, access policy, ANA, PI, queue ID and IEEE OUI settings must remain unchanged. Public topology is rechecked; sequential reads cannot exclude concurrent changes. Review is single-use and expires in five minutes.',
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-subsystem-attached-rename-reload'),
                  value: _reload,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _reload = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I consent to the display-name change and NVMe configuration reload. The NQN must remain unchanged; runtime access is not tested.',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-subsystem-attached-rename-limitations'),
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
                  key: const Key('nvme-subsystem-attached-rename-client'),
                  value: _clientRisk,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _clientRisk = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I understand reload may disrupt clients and dependent management labels may need updating. The saved disabled port and namespace flags and absent host grants do not prove runtime quiescence or isolation. NQN preservation does not attest actual initiator identity or compatibility.',
                  ),
                ),
              ],
            ),
            TextField(
              key: const Key('nvme-subsystem-attached-rename-phrase'),
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
              key: const Key('nvme-subsystem-attached-rename-submit'),
              onPressed:
                  active &&
                      _reload &&
                      _limitations &&
                      _clientRisk &&
                      _phrase.text == review.confirmation
                  ? () => _submit(coordinator!, review)
                  : null,
              child: const Text('Rename attached subsystem'),
            ),
            TextButton(
              key: const Key('nvme-subsystem-attached-rename-cancel'),
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
