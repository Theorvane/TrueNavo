import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_populated_port_mapping_coordinator.dart';
import 'nvme_overview.dart';

class NvmePopulatedPortMappingEditor extends ConsumerStatefulWidget {
  const NvmePopulatedPortMappingEditor({super.key});
  @override
  ConsumerState<NvmePopulatedPortMappingEditor> createState() =>
      _PopulatedPortMappingState();
}

class _PopulatedPortMappingState
    extends ConsumerState<NvmePopulatedPortMappingEditor> {
  final _id = TextEditingController(),
      _phrase = TextEditingController(),
      _portId = TextEditingController();
  NvmePopulatedPortMappingReview? _review;
  NvmePopulatedPortMappingCoordinator? _owner;
  Object? _session, _reviewSession;
  bool _busy = false, _reload = false, _limitations = false, _exposure = false;
  String? _message;
  int _epoch = 0;
  int? get _targetId => RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(_id.text)
      ? int.tryParse(_id.text)
      : null;
  int? get _selectedPortId =>
      RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(_portId.text)
      ? int.tryParse(_portId.text)
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
    _portId.dispose();
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _prepare(NvmePopulatedPortMappingCoordinator coordinator) async {
    final session = ref.read(dashboardActiveSessionProvider);
    _discard();
    final epoch = _epoch;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      final review = await coordinator.prepare(
        _selectedPortId ?? 0,
        _targetId ?? 0,
      );
      if (!mounted ||
          epoch != _epoch ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          !identical(
            coordinator,
            ref.read(nvmePopulatedPortMappingCoordinatorProvider),
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
          () => _message = 'Review failed. Select a populated restricted isolated subsystem and an unused disabled TCP/RDMA port. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmePopulatedPortMappingCoordinator coordinator,
    NvmePopulatedPortMappingReview review,
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
        result.outcome == NvmePopulatedPortMappingOutcome.completed) {
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final coordinator = ref.watch(nvmePopulatedPortMappingCoordinatorProvider);
    if (!identical(session, _session)) {
      _discard();
      _id.clear();
      _portId.clear();
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
      title: 'Map a disabled port to a populated NVMe subsystem',
      description: 'Associates an unused disabled TCP/RDMA port with a restricted subsystem containing only disabled unlocked ZVOLs with known unique NSIDs and no host or port mappings. Only the association is created. No port or namespace is enabled and no host is granted access. Sequential observations do not prove runtime isolation or backing health.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('nvme-populated-port-mapping-id'),
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
            key: const Key('nvme-populated-port-mapping-port-id'),
            controller: _portId,
            enabled: active,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Unused disabled TCP/RDMA port ID',
            ),
            onChanged: (_) => setState(_discard),
          ),
          OutlinedButton(
            key: const Key('nvme-populated-port-mapping-review'),
            onPressed: active && _targetId != null && _selectedPortId != null
                ? () => _prepare(coordinator!)
                : null,
            child: const Text('Review populated port mapping'),
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
            Text('Disabled port #${review.port.id}: ${review.port.transport}'),
            Text(
              'Subsystem #${review.target.id}: ${review.target.name}; preserved NQN ${review.target.subnqn}',
            ),
            Text('Preserved namespaces: ${review.namespaces.length}'),
            for (final namespace in review.namespaces)
              Text(
                'Namespace #${namespace.id}, NSID ${namespace.nsid}: disabled unlocked ZVOL; unchanged',
              ),
            const Text(
              'Only port_id and subsys_id are sent to create one association. Subsystem settings, port flags and settings, namespace IDs/NSIDs and flags, host grants and all other public rows must remain unchanged. Public topology is rechecked; sequential reads cannot exclude concurrent changes. Review is single-use and expires in five minutes.',
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-populated-port-mapping-reload'),
                  value: _reload,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _reload = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I consent to creating the saved port-subsystem association and NVMe configuration reload. The port and namespaces must remain configured disabled and no host grant is requested.',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-populated-port-mapping-limitations'),
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
                  key: const Key('nvme-populated-port-mapping-exposure'),
                  value: _exposure,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _exposure = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I understand later port or namespace enablement or host access changes can expose storage. Concurrent administrators and runtime access cannot be excluded by sequential public reads; this operation does not test reachability or client access.',
                  ),
                ),
              ],
            ),
            TextField(
              key: const Key('nvme-populated-port-mapping-phrase'),
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
              key: const Key('nvme-populated-port-mapping-submit'),
              onPressed:
                  active &&
                      _reload &&
                      _limitations &&
                      _exposure &&
                      _phrase.text == review.confirmation
                  ? () => _submit(coordinator!, review)
                  : null,
              child: const Text('Create saved port association'),
            ),
            TextButton(
              key: const Key('nvme-populated-port-mapping-cancel'),
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
