import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_subsystem_attached_flags_coordinator.dart';
import 'nvme_overview.dart';

class NvmeSubsystemAttachedFlagsEditor extends ConsumerStatefulWidget {
  const NvmeSubsystemAttachedFlagsEditor({super.key});
  @override
  ConsumerState<NvmeSubsystemAttachedFlagsEditor> createState() =>
      _AttachedFlagsState();
}

class _AttachedFlagsState
    extends ConsumerState<NvmeSubsystemAttachedFlagsEditor> {
  final _id = TextEditingController(), _phrase = TextEditingController();
  NvmeAttachedSubsystemFlag _field = NvmeAttachedSubsystemFlag.ana;
  NvmeAttachedFlagChoice _choice = NvmeAttachedFlagChoice.on;
  NvmeSubsystemAttachedFlagsReview? _review;
  NvmeSubsystemAttachedFlagsCoordinator? _owner;
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
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _prepare(
    NvmeSubsystemAttachedFlagsCoordinator coordinator,
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
        field: _field,
        choice: _choice,
      );
      if (!mounted ||
          epoch != _epoch ||
          !identical(session, ref.read(dashboardActiveSessionProvider)) ||
          !identical(
            coordinator,
            ref.read(nvmeSubsystemAttachedFlagsCoordinatorProvider),
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
          () => _message = 'Review failed. Select a restricted subsystem behind one disabled TCP/RDMA port with safe ZVOL residents, if any, and a reported ANA or PI field with a different saved value. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmeSubsystemAttachedFlagsCoordinator coordinator,
    NvmeSubsystemAttachedFlagsReview review,
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
        result.outcome == NvmeSubsystemAttachedFlagsOutcome.completed) {
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final coordinator = ref.watch(
      nvmeSubsystemAttachedFlagsCoordinatorProvider,
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
      title: 'Set ANA or PI on a singly attached NVMe subsystem',
      description: 'Only a restricted subsystem with one disabled TCP/RDMA port association and no host grant is supported. Residents, if any, must be disabled unlocked ZVOLs with valid unique NSIDs. Its NQN and all namespace and other settings remain unchanged; ANA INHERIT and PI DEFAULT save explicit null. Effective defaults, path availability, protection integrity, backing identity and concurrent changes are not proven.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('nvme-subsystem-attached-flags-id'),
            controller: _id,
            enabled: active,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Exact subsystem database ID',
            ),
            onChanged: (_) => setState(_discard),
          ),
          DropdownButtonFormField<NvmeAttachedSubsystemFlag>(
            key: const Key('nvme-subsystem-attached-flags-field'),
            initialValue: _field,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Setting to change'),
            items: [
              for (final field in NvmeAttachedSubsystemFlag.values)
                DropdownMenuItem(
                  value: field,
                  child: Text('${field.label} setting'),
                ),
            ],
            onChanged: active
                ? (field) => setState(() {
                    _discard();
                    _field = field!;
                  })
                : null,
          ),
          DropdownButtonFormField<NvmeAttachedFlagChoice>(
            key: ValueKey(
              'nvme-subsystem-attached-flags-choice-${_field.name}',
            ),
            initialValue: _choice,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Requested saved value',
            ),
            items: [
              for (final choice in NvmeAttachedFlagChoice.values)
                DropdownMenuItem(
                  value: choice,
                  child: Text(_field.valueLabel(choice.wireValue)),
                ),
            ],
            onChanged: active
                ? (choice) => setState(() {
                    _discard();
                    _choice = choice!;
                  })
                : null,
          ),
          OutlinedButton(
            key: const Key('nvme-subsystem-attached-flags-review'),
            onPressed: active && _targetId != null
                ? () => _prepare(coordinator!)
                : null,
            child: const Text('Review attached subsystem setting'),
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
              'Subsystem #${review.target.id}: ${review.target.name}; ${review.field.label} ${review.field.valueLabel(review.field.value(review.target))} → ${review.field.valueLabel(review.choice.wireValue)}; preserved NQN ${review.target.subnqn}',
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
              'Only the selected ANA or PI field is submitted. Name, NQN, namespace settings, access policy, the unselected flag, queue ID and IEEE OUI settings must remain unchanged. Public topology is rechecked; sequential reads cannot exclude concurrent changes. Review is single-use and expires in five minutes.',
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-subsystem-attached-flags-reload'),
                  value: _reload,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _reload = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I consent to this saved setting change and NVMe configuration reload. The NQN must remain unchanged; effective defaults and runtime access are not tested.',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-subsystem-attached-flags-limitations'),
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
                  key: const Key('nvme-subsystem-attached-flags-client'),
                  value: _clientRisk,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _clientRisk = v == true),
                ),
                Expanded(
                  child: Text(
                    review.field == NvmeAttachedSubsystemFlag.ana
                        ? 'I understand ANA changes may affect discovery and multipath clients. Global inheritance and actual path availability are unverified; saved disabled flags and absent grants do not prove runtime isolation.'
                        : 'I understand PI changes may affect data integrity and backing or initiator compatibility. Actual protection integrity and effective defaults are unverified; saved disabled flags and absent grants do not prove runtime isolation.',
                  ),
                ),
              ],
            ),
            TextField(
              key: const Key('nvme-subsystem-attached-flags-phrase'),
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
              key: const Key('nvme-subsystem-attached-flags-submit'),
              onPressed:
                  active &&
                      _reload &&
                      _limitations &&
                      _clientRisk &&
                      _phrase.text == review.confirmation
                  ? () => _submit(coordinator!, review)
                  : null,
              child: const Text('Apply attached subsystem setting'),
            ),
            TextButton(
              key: const Key('nvme-subsystem-attached-flags-cancel'),
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
