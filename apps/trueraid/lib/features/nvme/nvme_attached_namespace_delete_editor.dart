import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_attached_namespace_delete_coordinator.dart';
import 'nvme_overview.dart';

class NvmeAttachedNamespaceDeleteEditor extends ConsumerStatefulWidget {
  const NvmeAttachedNamespaceDeleteEditor({super.key});
  @override
  ConsumerState<NvmeAttachedNamespaceDeleteEditor> createState() =>
      _DeleteState();
}

class _DeleteState extends ConsumerState<NvmeAttachedNamespaceDeleteEditor> {
  final _id = TextEditingController(), _phrase = TextEditingController();
  NvmeAttachedNamespaceDeleteReview? _review;
  NvmeAttachedNamespaceDeleteCoordinator? _owner;
  Object? _session, _reviewSession;
  bool _busy = false,
      _configurationLoss = false,
      _limitations = false,
      _exposureRisk = false;
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
    _configurationLoss = _limitations = _exposureRisk = false;
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
    NvmeAttachedNamespaceDeleteCoordinator coordinator,
  ) async {
    final session = ref.read(dashboardActiveSessionProvider);
    _discard();
    final epoch = _epoch;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final review = await coordinator.prepare(_targetId ?? 0);
      if (!mounted ||
          epoch != _epoch ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          !identical(
            coordinator,
            ref.read(nvmeAttachedNamespaceDeleteCoordinatorProvider),
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
          () => _message = 'Review failed. Select a singly attached disabled unlocked ZVOL namespace behind a disabled port. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmeAttachedNamespaceDeleteCoordinator coordinator,
    NvmeAttachedNamespaceDeleteReview review,
  ) async {
    final session = _reviewSession, phrase = _phrase.text;
    final configurationLoss = _configurationLoss,
        limitations = _limitations,
        exposureRisk = _exposureRisk;
    _review = null;
    setState(() {
      _busy = true;
      _message = null;
    });
    final result = await coordinator.execute(
      review,
      phrase,
      acknowledgeConfigurationLoss: configurationLoss,
      acknowledgeLimitations: limitations,
      acknowledgeExposureRisk: exposureRisk,
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
        result.outcome == NvmeAttachedNamespaceDeleteOutcome.completed) {
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final coordinator = ref.watch(
      nvmeAttachedNamespaceDeleteCoordinatorProvider,
    );
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
      title: 'Remove singly attached disabled ZVOL namespace configuration',
      description: 'Configuration removal only for a disabled unlocked ZVOL behind one disabled TCP/RDMA port in a restricted subsystem without other port mappings or host grants. All residents must be disabled unlocked ZVOLs with valid unique NSIDs. Backing storage and port association deletion are not requested; actual client access and backing integrity are unverified.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('nvme-attached-namespace-delete-id'),
            controller: _id,
            enabled: active,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Exact namespace database ID (not NSID)',
            ),
            onChanged: (_) => setState(_discard),
          ),
          OutlinedButton(
            key: const Key('nvme-attached-namespace-delete-review'),
            onPressed: active && _targetId != null
                ? () => _prepare(coordinator!)
                : null,
            child: const Text(
              'Review attached namespace configuration removal',
            ),
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
              'Namespace #${review.target.id}, subsystem #${review.target.subsystemId}, NSID ${review.target.nsid}: disabled unlocked ZVOL; remove configuration only',
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
              'Only namespace.delete(id, {remove: false}) is submitted. The association stays. Public topology is rechecked; sequential reads cannot exclude concurrent changes or hidden backing drift. Review is single-use and expires in five minutes.',
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-attached-namespace-delete-loss'),
                  value: _configurationLoss,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _configurationLoss = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I consent to namespace configuration loss and NVMe reload. The namespace may need to be recreated. Backing storage deletion is not requested; no automatic recreation or rollback is attempted.',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-attached-namespace-delete-limitations'),
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
                  key: const Key('nvme-attached-namespace-delete-exposure'),
                  value: _exposureRisk,
                  onChanged: _busy
                      ? null
                      : (value) =>
                            setState(() => _exposureRisk = value == true),
                ),
                const Expanded(
                  child: Text(
                    'I understand namespace removal and reload may disrupt clients or require initiator rediscovery. The saved disabled port and namespace flags and absent host grants do not prove runtime quiescence or access revocation. The existing port association and neighbors are retained.',
                  ),
                ),
              ],
            ),
            TextField(
              key: const Key('nvme-attached-namespace-delete-phrase'),
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
              key: const Key('nvme-attached-namespace-delete-submit'),
              onPressed:
                  active &&
                      _configurationLoss &&
                      _limitations &&
                      _exposureRisk &&
                      _phrase.text == review.confirmation
                  ? () => _submit(coordinator!, review)
                  : null,
              child: const Text('Remove attached namespace configuration'),
            ),
            TextButton(
              key: const Key('nvme-attached-namespace-delete-cancel'),
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
