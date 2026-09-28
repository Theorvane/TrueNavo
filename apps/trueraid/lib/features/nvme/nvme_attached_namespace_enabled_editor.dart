import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_attached_namespace_enabled_coordinator.dart';
import 'nvme_overview.dart';

class NvmeAttachedNamespaceEnabledEditor extends ConsumerStatefulWidget {
  const NvmeAttachedNamespaceEnabledEditor({super.key});
  @override
  ConsumerState<NvmeAttachedNamespaceEnabledEditor> createState() =>
      _EnabledState();
}

class _EnabledState extends ConsumerState<NvmeAttachedNamespaceEnabledEditor> {
  final _id = TextEditingController(), _phrase = TextEditingController();
  NvmeAttachedNamespaceEnabledReview? _review;
  NvmeAttachedNamespaceEnabledCoordinator? _owner;
  Object? _session, _reviewSession;
  bool _enabled = true,
      _busy = false,
      _reload = false,
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
    _reload = _limitations = _exposureRisk = false;
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
    NvmeAttachedNamespaceEnabledCoordinator coordinator,
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
        enabled: _enabled,
      );
      if (!mounted ||
          epoch != _epoch ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          !identical(
            coordinator,
            ref.read(nvmeAttachedNamespaceEnabledCoordinatorProvider),
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
          () => _message = 'Review failed. Select a singly attached unlocked ZVOL namespace behind a disabled port and a different saved enabled setting. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmeAttachedNamespaceEnabledCoordinator coordinator,
    NvmeAttachedNamespaceEnabledReview review,
  ) async {
    final session = _reviewSession, phrase = _phrase.text;
    final reload = _reload,
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
      acknowledgeReload: reload,
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
        result.outcome == NvmeAttachedNamespaceEnabledOutcome.completed) {
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final coordinator = ref.watch(
      nvmeAttachedNamespaceEnabledCoordinatorProvider,
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
      title: 'Change singly attached ZVOL namespace enabled setting',
      description: 'Saved enabled flag only for an unlocked ZVOL in a restricted subsystem behind one disabled TCP/RDMA port, with no other port mapping or host grant and disabled unlocked ZVOL neighbors with valid unique NSIDs. The port stays disabled. Runtime isolation, client compatibility and backing ownership or health are not proven.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('nvme-attached-namespace-enabled-id'),
            controller: _id,
            enabled: active,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Exact namespace database ID (not NSID)',
            ),
            onChanged: (_) => setState(_discard),
          ),
          DropdownButtonFormField<bool>(
            key: const Key('nvme-attached-namespace-enabled-value'),
            initialValue: _enabled,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Requested saved enabled setting',
            ),
            items: const [
              DropdownMenuItem(value: true, child: Text('Enabled')),
              DropdownMenuItem(value: false, child: Text('Disabled')),
            ],
            onChanged: active
                ? (value) => setState(() {
                    _discard();
                    _enabled = value!;
                  })
                : null,
          ),
          OutlinedButton(
            key: const Key('nvme-attached-namespace-enabled-review'),
            onPressed: active && _targetId != null
                ? () => _prepare(coordinator!)
                : null,
            child: const Text('Review saved namespace enabled setting'),
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
              'Namespace #${review.target.id}, subsystem #${review.target.subsystemId}, NSID ${review.target.nsid}: ${review.target.enabled} → ${review.enabled}',
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
              'Only enabled is submitted. Public topology is rechecked; sequential reads cannot exclude concurrent changes or hidden backing drift. Review is single-use and expires in five minutes.',
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-attached-namespace-enabled-reload'),
                  value: _reload,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _reload = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I consent to the saved enabled setting change and NVMe configuration reload. No port enablement is requested; runtime access is not tested.',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-attached-namespace-enabled-limitations'),
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
                  key: const Key('nvme-attached-namespace-enabled-exposure'),
                  value: _exposureRisk,
                  onChanged: _busy
                      ? null
                      : (value) =>
                            setState(() => _exposureRisk = value == true),
                ),
                const Expanded(
                  child: Text(
                    'I understand enabling a namespace may allow future client access if a port or host grant is later enabled, while disabling and reload may disrupt clients. Saved disabled port flags and absent host grants do not prove runtime isolation or quiescence; backing and initiator compatibility are unverified.',
                  ),
                ),
              ],
            ),
            TextField(
              key: const Key('nvme-attached-namespace-enabled-phrase'),
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
              key: const Key('nvme-attached-namespace-enabled-submit'),
              onPressed:
                  active &&
                      _reload &&
                      _limitations &&
                      _exposureRisk &&
                      _phrase.text == review.confirmation
                  ? () => _submit(coordinator!, review)
                  : null,
              child: const Text('Apply saved namespace enabled setting'),
            ),
            TextButton(
              key: const Key('nvme-attached-namespace-enabled-cancel'),
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
