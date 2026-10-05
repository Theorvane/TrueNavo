import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_subsystem_populated_rename_coordinator.dart';
import 'nvme_overview.dart';

class NvmeSubsystemPopulatedRenameEditor extends ConsumerStatefulWidget {
  const NvmeSubsystemPopulatedRenameEditor({super.key});
  @override
  ConsumerState<NvmeSubsystemPopulatedRenameEditor> createState() =>
      _PopulatedRenameState();
}

class _PopulatedRenameState
    extends ConsumerState<NvmeSubsystemPopulatedRenameEditor> {
  final _id = TextEditingController(),
      _phrase = TextEditingController(),
      _name = TextEditingController();
  NvmeSubsystemPopulatedRenameReview? _review;
  NvmeSubsystemPopulatedRenameCoordinator? _owner;
  Object? _session, _reviewSession;
  bool _busy = false, _reload = false, _limitations = false;
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
    _reload = _limitations = false;
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

  Future<void> _prepare(
    NvmeSubsystemPopulatedRenameCoordinator coordinator,
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
            ref.read(nvmeSubsystemPopulatedRenameCoordinatorProvider),
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
          () => _message = 'Review failed. Select a populated restricted isolated subsystem and a different unused display name. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmeSubsystemPopulatedRenameCoordinator coordinator,
    NvmeSubsystemPopulatedRenameReview review,
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
        result.outcome == NvmeSubsystemPopulatedRenameOutcome.completed) {
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final coordinator = ref.watch(
      nvmeSubsystemPopulatedRenameCoordinatorProvider,
    );
    if (!identical(session, _session)) {
      _discard();
      _id.clear();
      _name.clear();
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
      title: 'Rename an isolated populated NVMe subsystem',
      description: 'Only a restricted subsystem containing disabled unlocked ZVOL namespaces with valid unique NSIDs and no host or port mappings is supported. Its NQN and all namespace and other settings remain unchanged; backing identity, runtime access and concurrent changes are not proven.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('nvme-subsystem-populated-rename-id'),
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
            key: const Key('nvme-subsystem-populated-rename-new'),
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
            key: const Key('nvme-subsystem-populated-rename-review'),
            onPressed: active && _targetId != null && _desiredName != null
                ? () => _prepare(coordinator!)
                : null,
            child: const Text('Review populated subsystem rename'),
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
                  key: const Key('nvme-subsystem-populated-rename-reload'),
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
                  key: const Key('nvme-subsystem-populated-rename-limitations'),
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
              key: const Key('nvme-subsystem-populated-rename-phrase'),
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
              key: const Key('nvme-subsystem-populated-rename-submit'),
              onPressed:
                  active &&
                      _reload &&
                      _limitations &&
                      _phrase.text == review.confirmation
                  ? () => _submit(coordinator!, review)
                  : null,
              child: const Text('Rename populated subsystem'),
            ),
            TextButton(
              key: const Key('nvme-subsystem-populated-rename-cancel'),
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
