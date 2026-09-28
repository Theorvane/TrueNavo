import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_associated_port_tuning_coordinator.dart';
import 'nvme_overview.dart';

class NvmeAssociatedPortTuningEditor extends ConsumerStatefulWidget {
  const NvmeAssociatedPortTuningEditor({super.key});
  @override
  ConsumerState<NvmeAssociatedPortTuningEditor> createState() =>
      _AssociatedPortTuningState();
}

class _AssociatedPortTuningState
    extends ConsumerState<NvmeAssociatedPortTuningEditor> {
  final _id = TextEditingController(), _phrase = TextEditingController();
  final _value = TextEditingController();
  NvmeAssociatedPortField _field = NvmeAssociatedPortField.pi;
  String _pi = 'ON';
  bool _useDefault = true;
  NvmeAssociatedPortChoice? get _choice {
    if (_field == NvmeAssociatedPortField.pi) {
      return NvmeAssociatedPortChoice(
        _field,
        _pi == 'DEFAULT' ? null : _pi == 'ON',
      );
    }
    if (_useDefault) return NvmeAssociatedPortChoice(_field, null);
    if (!RegExp(r'^(0|[1-9][0-9]{0,9})$').hasMatch(_value.text)) return null;
    final value = int.tryParse(_value.text);
    final choice = NvmeAssociatedPortChoice(_field, value);
    return value != null && choice.valid ? choice : null;
  }

  NvmeAssociatedPortTuningReview? _review;
  NvmeAssociatedPortTuningCoordinator? _owner;
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
    _value.dispose();
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _prepare(NvmeAssociatedPortTuningCoordinator coordinator) async {
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
            ref.read(nvmeAssociatedPortTuningCoordinatorProvider),
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
          () => _message = 'Review failed. Select a singly associated TCP/RDMA port on a restricted subsystem containing only disabled unlocked ZVOLs with a reported field and a different saved tuning setting. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmeAssociatedPortTuningCoordinator coordinator,
    NvmeAssociatedPortTuningReview review,
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
        result.outcome == NvmeAssociatedPortTuningOutcome.completed) {
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final coordinator = ref.watch(nvmeAssociatedPortTuningCoordinatorProvider);
    if (!identical(session, _session)) {
      _discard();
      _id.clear();
      _value.clear();
      _useDefault = true;
      _pi = 'ON';
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
      title: 'Tune one saved setting on an associated disabled NVMe port',
      description: 'Only a disabled TCP/RDMA port with exactly one restricted populated subsystem, no other subsystem ports and no host grants is supported. All residents must be disabled unlocked ZVOLs with valid unique NSIDs. Listener activity, client IO and runtime access are not attested.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('nvme-associated-port-tuning-id'),
            controller: _id,
            enabled: active,
            keyboardType: TextInputType.number,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Exact port database ID',
            ),
            onChanged: (_) => setState(_discard),
          ),
          DropdownButtonFormField<NvmeAssociatedPortField>(
            key: const Key('nvme-associated-port-tuning-field'),
            initialValue: _field,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Single saved setting',
            ),
            items: [
              for (final field in NvmeAssociatedPortField.values)
                DropdownMenuItem(value: field, child: Text(field.label)),
            ],
            onChanged: active
                ? (field) => setState(() {
                    _discard();
                    _field = field!;
                    _value.clear();
                    _useDefault = true;
                  })
                : null,
          ),
          if (_field == NvmeAssociatedPortField.pi)
            DropdownButtonFormField<String>(
              key: const Key('nvme-associated-port-tuning-pi'),
              initialValue: _pi,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText: 'Requested saved PI',
              ),
              items: [
                for (final value in ['DEFAULT', 'ON', 'OFF'])
                  DropdownMenuItem(value: value, child: Text(value)),
              ],
              onChanged: active
                  ? (value) => setState(() {
                      _discard();
                      _pi = value!;
                    })
                  : null,
            )
          else ...[
            Row(
              children: [
                const Expanded(child: Text('Use server default')),
                Switch(
                  key: const Key('nvme-associated-port-tuning-default'),
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
              key: const Key('nvme-associated-port-tuning-value'),
              controller: _value,
              enabled: active && !_useDefault,
              keyboardType: TextInputType.number,
              maxLength: 10,
              decoration: InputDecoration(
                labelText: _field == NvmeAssociatedPortField.inline
                    ? 'Inline size: 0–2147483647'
                    : 'Queue size: 1–2147483647',
              ),
              onChanged: (_) => setState(_discard),
            ),
          ],
          OutlinedButton(
            key: const Key('nvme-associated-port-tuning-review'),
            onPressed: active && _targetId != null && _choice != null
                ? () => _prepare(coordinator!)
                : null,
            child: const Text('Review associated port tuning'),
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
              'Disabled port #${review.port.id} ${review.port.transport}: ${review.choice.field.label} ${nvmePortTuningToken(review.choice.field.value(review.port))} → ${review.choice.label}; subsystem #${review.target.id} ${review.target.name}; preserved NQN ${review.target.subnqn}',
            ),
            Text('Preserved namespaces: ${review.namespaces.length}'),
            for (final namespace in review.namespaces)
              Text(
                'Namespace #${namespace.id}, NSID ${namespace.nsid}: disabled unlocked ZVOL; unchanged',
              ),
            const Text(
              'Only the selected saved tuning field is submitted. Default saves null, not a tested effective value. Disabled flags, associations, NQN, residents and other projected settings must remain unchanged. Sequential reads cannot exclude concurrent or hidden address/backing changes. Review is single-use and expires in five minutes.',
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-associated-port-tuning-reload'),
                  value: _reload,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _reload = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I consent to changing only the selected saved tuning field and NVMe configuration reload. The port and all resident namespaces remain configured disabled.',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-associated-port-tuning-limitations'),
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
                  key: const Key('nvme-associated-port-tuning-exposure'),
                  value: _exposure,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _exposure = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I understand tuning changes may require compatible initiator and backing metadata settings and reload may disrupt clients. Actual PI integrity, hardware suitability, effective capacity, performance and client quiescence are not validated.',
                  ),
                ),
              ],
            ),
            TextField(
              key: const Key('nvme-associated-port-tuning-phrase'),
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
              key: const Key('nvme-associated-port-tuning-submit'),
              onPressed:
                  active &&
                      _reload &&
                      _limitations &&
                      _exposure &&
                      _phrase.text == review.confirmation
                  ? () => _submit(coordinator!, review)
                  : null,
              child: const Text('Apply one saved tuning setting'),
            ),
            TextButton(
              key: const Key('nvme-associated-port-tuning-cancel'),
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
