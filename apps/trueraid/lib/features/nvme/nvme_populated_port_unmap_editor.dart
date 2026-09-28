import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_populated_port_unmap_coordinator.dart';
import 'nvme_overview.dart';

class NvmePopulatedPortUnmapEditor extends ConsumerStatefulWidget {
  const NvmePopulatedPortUnmapEditor({super.key});
  @override
  ConsumerState<NvmePopulatedPortUnmapEditor> createState() =>
      _PopulatedPortUnmapState();
}

class _PopulatedPortUnmapState
    extends ConsumerState<NvmePopulatedPortUnmapEditor> {
  final _id = TextEditingController(), _phrase = TextEditingController();
  NvmePopulatedPortUnmapReview? _review;
  NvmePopulatedPortUnmapCoordinator? _owner;
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

  Future<void> _prepare(NvmePopulatedPortUnmapCoordinator coordinator) async {
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
            ref.read(nvmePopulatedPortUnmapCoordinatorProvider),
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
          () => _message = 'Review failed. Select an exact single association on a disabled TCP/RDMA port and a restricted subsystem containing only disabled unlocked ZVOLs. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmePopulatedPortUnmapCoordinator coordinator,
    NvmePopulatedPortUnmapReview review,
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
        result.outcome == NvmePopulatedPortUnmapOutcome.completed) {
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final coordinator = ref.watch(nvmePopulatedPortUnmapCoordinatorProvider);
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
      title: 'Unlink a disabled NVMe port from a populated subsystem',
      description: 'Only a disabled TCP/RDMA port with exactly one restricted populated subsystem, no other subsystem ports and no host grants is supported. All residents must be disabled unlocked ZVOLs with valid unique NSIDs. Listener activity, client IO and runtime access are not attested.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('nvme-populated-port-unmap-id'),
            controller: _id,
            enabled: active,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Exact association database ID',
            ),
            onChanged: (_) => setState(_discard),
          ),
          OutlinedButton(
            key: const Key('nvme-populated-port-unmap-review'),
            onPressed: active && _targetId != null
                ? () => _prepare(coordinator!)
                : null,
            child: const Text('Review populated port unlink'),
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
              'Association #${review.mappingId}: disabled port #${review.port.id} ${review.port.transport}; subsystem #${review.target.id} ${review.target.name}; preserved NQN ${review.target.subnqn}',
            ),
            Text('Preserved namespaces: ${review.namespaces.length}'),
            for (final namespace in review.namespaces)
              Text(
                'Namespace #${namespace.id}, NSID ${namespace.nsid}: disabled unlocked ZVOL; unchanged',
              ),
            const Text(
              'Only the exact association ID is submitted for removal. No port, subsystem, namespace or backing storage is deleted. All other projected metadata must remain unchanged. Sequential reads cannot exclude concurrent or hidden backing changes. Review is single-use and expires in five minutes.',
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-populated-port-unmap-reload'),
                  value: _reload,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _reload = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I consent to removing only this saved association and reloading NVMe configuration. Port and resident namespaces remain configured disabled; backing storage is not deleted.',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-populated-port-unmap-limitations'),
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
                  key: const Key('nvme-populated-port-unmap-exposure'),
                  value: _exposure,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _exposure = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I understand unlinking changes advertised subsystem access and reload may disrupt clients. Disabled flags do not prove runtime quiescence. No initiator access or client IO test is performed; no compensating recreation is attempted.',
                  ),
                ),
              ],
            ),
            TextField(
              key: const Key('nvme-populated-port-unmap-phrase'),
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
              key: const Key('nvme-populated-port-unmap-submit'),
              onPressed:
                  active &&
                      _reload &&
                      _limitations &&
                      _exposure &&
                      _phrase.text == review.confirmation
                  ? () => _submit(coordinator!, review)
                  : null,
              child: const Text('Unlink saved association'),
            ),
            TextButton(
              key: const Key('nvme-populated-port-unmap-cancel'),
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
