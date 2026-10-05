import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_attached_namespace_nsid_coordinator.dart';
import 'nvme_overview.dart';

class NvmeAttachedNamespaceNsidEditor extends ConsumerStatefulWidget {
  const NvmeAttachedNamespaceNsidEditor({super.key});
  @override
  ConsumerState<NvmeAttachedNamespaceNsidEditor> createState() => _NsidState();
}

class _NsidState extends ConsumerState<NvmeAttachedNamespaceNsidEditor> {
  final _id = TextEditingController(),
      _phrase = TextEditingController(),
      _nsid = TextEditingController();
  NvmeAttachedNamespaceNsidReview? _review;
  NvmeAttachedNamespaceNsidCoordinator? _owner;
  Object? _session, _reviewSession;
  List<NvmeAttachedNamespaceNsidCandidate>? _candidates;
  NvmeAttachedNamespaceNsidCoordinator? _candidateOwner;
  bool _busy = false,
      _reload = false,
      _limitations = false,
      _identityRisk = false;
  String? _message;
  int _epoch = 0;
  int? get _targetId => RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(_id.text)
      ? int.tryParse(_id.text)
      : null;
  int? get _desiredNsid {
    if (!RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(_nsid.text)) return null;
    final value = int.tryParse(_nsid.text);
    return value != null && value < 4294967295 ? value : null;
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
    _nsid.dispose();
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _loadCandidates(
    NvmeAttachedNamespaceNsidCoordinator coordinator,
  ) async {
    final session = ref.read(dashboardActiveSessionProvider);
    _discard();
    final epoch = _epoch;
    setState(() {
      _busy = true;
      _candidates = null;
      _candidateOwner = null;
      _id.clear();
      _nsid.clear();
      _message = null;
    });
    try {
      final candidates = await coordinator.loadCandidates();
      if (!mounted ||
          epoch != _epoch ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          !identical(
            coordinator,
            ref.read(nvmeAttachedNamespaceNsidCoordinatorProvider),
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
            ref.read(nvmeAttachedNamespaceNsidCoordinatorProvider),
          )) {
        setState(
          () => _message = 'NSID target discovery failed. No configuration request was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _prepare(
    NvmeAttachedNamespaceNsidCoordinator coordinator,
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
        nsid: _desiredNsid ?? 0,
      );
      if (!mounted ||
          epoch != _epoch ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          !identical(
            coordinator,
            ref.read(nvmeAttachedNamespaceNsidCoordinatorProvider),
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
          () => _message = 'Review failed. Select a singly attached disabled unlocked ZVOL namespace and a different saved NSID. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmeAttachedNamespaceNsidCoordinator coordinator,
    NvmeAttachedNamespaceNsidReview review,
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
        _candidates = null;
        _candidateOwner = null;
        _message = result.message;
      }
    });
    if (identical(session, ref.read(dashboardActiveSessionProvider)) &&
        result.outcome == NvmeAttachedNamespaceNsidOutcome.completed) {
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final coordinator = ref.watch(nvmeAttachedNamespaceNsidCoordinatorProvider);
    if (!identical(session, _session)) {
      _discard();
      _id.clear();
      _nsid.clear();
      _candidates = null;
      _candidateOwner = null;
      _message = null;
      _session = session;
    }
    if (_owner != null && !identical(coordinator, _owner)) _discard();
    if (_candidateOwner != null && !identical(coordinator, _candidateOwner)) {
      _discard();
      _id.clear();
      _nsid.clear();
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
      title: 'Change singly attached disabled ZVOL namespace NSID',
      description: 'Only a disabled unlocked ZVOL in a restricted subsystem behind one disabled TCP/RDMA port, with no other port mapping or host grant and safe disabled residents, is supported. NSIDs must remain unique. No port, enablement or backing change is submitted.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          OutlinedButton(
            key: const Key('nvme-attached-namespace-nsid-discover'),
            onPressed: active ? () => _loadCandidates(coordinator!) : null,
            child: const Text('Load or refresh eligible NSID targets'),
          ),
          if (candidates != null) ...[
            const Text(
              'Discovery and free NSID suggestions are public snapshot hints, not runtime safety or reservations. Review and submission independently reread the server. Only an explicit NSID is submitted; automatic assignment is not used.',
            ),
            if (candidates.isEmpty)
              const Text('No eligible namespace NSID targets were found.'),
            if (candidates.isNotEmpty)
              InputDecorator(
                decoration: const InputDecoration(
                  labelText: 'Choose namespace',
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<int>(
                    key: const Key('nvme-attached-namespace-nsid-choice'),
                    isExpanded: true,
                    value: selected?.target.id,
                    hint: const Text('Select a namespace'),
                    items: [
                      for (final candidate in candidates)
                        DropdownMenuItem(
                          value: candidate.target.id,
                          child: Text(
                            '#${candidate.target.id} · NSID ${candidate.target.nsid} · ${candidate.subsystem.name}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: active
                        ? (id) => setState(() {
                            _discard();
                            _id.text = id?.toString() ?? '';
                            _nsid.clear();
                            _message = null;
                          })
                        : null,
                  ),
                ),
              ),
            if (selected != null) ...[
              Text(
                'Subsystem #${selected.subsystem.id}: ${selected.subsystem.name} — ${selected.subsystem.subnqn}; association #${selected.mapping.id}, disabled ${selected.port.transport} port #${selected.port.id}; used NSIDs: ${selected.usedNsids.join(', ')}',
              ),
              OutlinedButton(
                key: const Key('nvme-attached-namespace-nsid-suggestion'),
                onPressed: active
                    ? () => setState(() {
                        _discard();
                        _nsid.text = selected.suggestedNsid.toString();
                        _message = null;
                      })
                    : null,
                child: Text(
                  'Use suggested free NSID ${selected.suggestedNsid}',
                ),
              ),
            ],
          ],
          TextField(
            key: const Key('nvme-attached-namespace-nsid-id'),
            controller: _id,
            enabled: active,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Exact namespace database ID (not NSID)',
            ),
            onChanged: (_) => setState(() {
              _discard();
              _nsid.clear();
            }),
          ),
          TextField(
            key: const Key('nvme-attached-namespace-nsid-new'),
            controller: _nsid,
            enabled: active,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'New NSID (1–4294967294; no automatic assignment)',
            ),
            onChanged: (_) => setState(_discard),
          ),
          OutlinedButton(
            key: const Key('nvme-attached-namespace-nsid-review'),
            onPressed: active && _targetId != null && _desiredNsid != null
                ? () => _prepare(coordinator!)
                : null,
            child: const Text('Review saved namespace NSID'),
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
              'Namespace #${review.target.id}, subsystem #${review.target.subsystemId}, NSID ${review.target.nsid}: ${review.target.nsid} → ${review.nsid}',
            ),
            Text(
              'Preserved association #${review.mapping.id}, disabled port #${review.port.id} ${review.port.transport}; subsystem ${review.subsystem.name}; NQN ${review.subsystem.subnqn}',
            ),
            Text(
              'Unchanged neighboring namespaces: ${review.residents.length}',
            ),
            for (final resident in review.residents)
              Text(
                'Namespace #${resident.id}, NSID ${resident.nsid}: disabled unlocked ZVOL; unchanged',
              ),
            const Text(
              'Only nsid is submitted. Public topology is rechecked; sequential reads cannot exclude concurrent changes or hidden backing drift. Review is single-use and expires in five minutes.',
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-attached-namespace-nsid-reload'),
                  value: _reload,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _reload = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I consent to the saved NSID change and NVMe configuration reload. Initiator configuration may need updating; runtime access is not tested.',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-attached-namespace-nsid-limitations'),
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
                  key: const Key('nvme-attached-namespace-nsid-identity'),
                  value: _identityRisk,
                  onChanged: _busy
                      ? null
                      : (value) =>
                            setState(() => _identityRisk = value == true),
                ),
                const Expanded(
                  child: Text(
                    'I understand NSID changes alter initiator namespace identity and reload may disrupt clients. Disabled saved flags do not prove runtime quiescence or isolation; initiator compatibility and discovery are not tested.',
                  ),
                ),
              ],
            ),
            TextField(
              key: const Key('nvme-attached-namespace-nsid-phrase'),
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
              key: const Key('nvme-attached-namespace-nsid-submit'),
              onPressed:
                  active &&
                      _reload &&
                      _limitations &&
                      _identityRisk &&
                      _phrase.text == review.confirmation
                  ? () => _submit(coordinator!, review)
                  : null,
              child: const Text('Apply saved namespace NSID'),
            ),
            TextButton(
              key: const Key('nvme-attached-namespace-nsid-cancel'),
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
