import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_subsystem_populated_qid_coordinator.dart';
import 'nvme_overview.dart';

class NvmeSubsystemPopulatedQidEditor extends ConsumerStatefulWidget {
  const NvmeSubsystemPopulatedQidEditor({super.key});
  @override
  ConsumerState<NvmeSubsystemPopulatedQidEditor> createState() =>
      _PopulatedQidState();
}

class _PopulatedQidState
    extends ConsumerState<NvmeSubsystemPopulatedQidEditor> {
  final _id = TextEditingController(),
      _phrase = TextEditingController(),
      _limit = TextEditingController();
  bool _useDefault = true;
  NvmePopulatedQidChoice? get _choice {
    if (_useDefault) return const NvmePopulatedQidChoice(null);
    if (!RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(_limit.text)) return null;
    final value = int.tryParse(_limit.text);
    final choice = NvmePopulatedQidChoice(value);
    return value != null && choice.valid ? choice : null;
  }

  NvmeSubsystemPopulatedQidReview? _review;
  NvmeSubsystemPopulatedQidCoordinator? _owner;
  Object? _session, _reviewSession;
  bool _busy = false, _reload = false, _limitations = false;
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
    _reload = _limitations = false;
    _phrase.clear();
  }

  @override
  void dispose() {
    _discard();
    _id.dispose();
    _limit.dispose();
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _prepare(
    NvmeSubsystemPopulatedQidCoordinator coordinator,
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
        choice: _choice!,
      );
      if (!mounted ||
          epoch != _epoch ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          !identical(
            coordinator,
            ref.read(nvmeSubsystemPopulatedQidCoordinatorProvider),
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
          () => _message = 'Review failed. Select a populated restricted isolated subsystem with a reported QID field and a different saved QID setting. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmeSubsystemPopulatedQidCoordinator coordinator,
    NvmeSubsystemPopulatedQidReview review,
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
        result.outcome == NvmeSubsystemPopulatedQidOutcome.completed) {
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final coordinator = ref.watch(nvmeSubsystemPopulatedQidCoordinatorProvider);
    if (!identical(session, _session)) {
      _discard();
      _id.clear();
      _limit.clear();
      _useDefault = true;
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
      title: 'Set saved QID on an isolated populated NVMe subsystem',
      description: 'Only a restricted subsystem containing disabled unlocked ZVOL namespaces with valid unique NSIDs and no host or port mappings is supported. Its NQN and all namespace and other settings remain unchanged. Default saves null; explicit limits use the conservative 1–2147483647 range. Effective queue capacity, performance and initiator compatibility are not attested.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('nvme-subsystem-populated-qid-id'),
            controller: _id,
            enabled: active,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Exact subsystem database ID',
            ),
            onChanged: (_) => setState(_discard),
          ),
          Row(
            children: [
              const Expanded(child: Text('Use server default')),
              Switch(
                key: const Key('nvme-subsystem-populated-qid-default'),
                value: _useDefault,
                onChanged: active
                    ? (value) => setState(() {
                        _discard();
                        _useDefault = value;
                      })
                    : null,
              ),
            ],
          ),
          TextField(
            key: const Key('nvme-subsystem-populated-qid-limit'),
            controller: _limit,
            enabled: active && !_useDefault,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Maximum queue IDs (1–2147483647)',
            ),
            onChanged: (_) => setState(_discard),
          ),
          OutlinedButton(
            key: const Key('nvme-subsystem-populated-qid-review'),
            onPressed: active && _targetId != null && _choice != null
                ? () => _prepare(coordinator!)
                : null,
            child: const Text('Review populated subsystem QID'),
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
              'Subsystem #${review.target.id}: ${review.target.name}; QID ${review.target.qidMax} → ${review.choice.label}; preserved NQN ${review.target.subnqn}',
            ),
            Text('Preserved namespaces: ${review.namespaces.length}'),
            for (final namespace in review.namespaces)
              Text(
                'Namespace #${namespace.id}, NSID ${namespace.nsid}: disabled unlocked ZVOL; unchanged',
              ),
            const Text(
              'Only qid_max is submitted. Name, NQN, namespace settings, access policy, ANA, PI and IEEE OUI settings must remain unchanged. Public topology is rechecked; sequential reads cannot exclude concurrent changes. Review is single-use and expires in five minutes.',
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-subsystem-populated-qid-reload'),
                  value: _reload,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _reload = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I consent to the saved QID setting change and NVMe configuration reload. The NQN must remain unchanged; effective queue capacity, performance and client compatibility are not tested.',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-subsystem-populated-qid-limitations'),
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
              key: const Key('nvme-subsystem-populated-qid-phrase'),
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
              key: const Key('nvme-subsystem-populated-qid-submit'),
              onPressed:
                  active &&
                      _reload &&
                      _limitations &&
                      _phrase.text == review.confirmation
                  ? () => _submit(coordinator!, review)
                  : null,
              child: const Text('Apply saved QID'),
            ),
            TextButton(
              key: const Key('nvme-subsystem-populated-qid-cancel'),
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
