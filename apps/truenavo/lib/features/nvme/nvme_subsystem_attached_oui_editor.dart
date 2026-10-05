import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_subsystem_attached_oui_coordinator.dart';
import 'nvme_overview.dart';

class NvmeSubsystemAttachedOuiEditor extends ConsumerStatefulWidget {
  const NvmeSubsystemAttachedOuiEditor({super.key});
  @override
  ConsumerState<NvmeSubsystemAttachedOuiEditor> createState() =>
      _AttachedOuiState();
}

class _AttachedOuiState extends ConsumerState<NvmeSubsystemAttachedOuiEditor> {
  final _id = TextEditingController(),
      _phrase = TextEditingController(),
      _oui = TextEditingController();
  bool _useDefault = true;
  NvmeAttachedOuiChoice? get _choice {
    if (_useDefault) return const NvmeAttachedOuiChoice(null);
    final choice = NvmeAttachedOuiChoice(_oui.text);
    return choice.valid ? choice : null;
  }

  NvmeSubsystemAttachedOuiReview? _review;
  NvmeSubsystemAttachedOuiCoordinator? _owner;
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
    _oui.dispose();
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _prepare(NvmeSubsystemAttachedOuiCoordinator coordinator) async {
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
            ref.read(nvmeSubsystemAttachedOuiCoordinatorProvider),
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
          () => _message = 'Review failed. Select a restricted subsystem with one disabled TCP/RDMA association, no host grant and safe ZVOL residents, if any, with a reported OUI field and a different saved OUI setting. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmeSubsystemAttachedOuiCoordinator coordinator,
    NvmeSubsystemAttachedOuiReview review,
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
        result.outcome == NvmeSubsystemAttachedOuiOutcome.completed) {
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final coordinator = ref.watch(nvmeSubsystemAttachedOuiCoordinatorProvider);
    if (!identical(session, _session)) {
      _discard();
      _id.clear();
      _oui.clear();
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
      title: 'Set saved OUI on a singly attached NVMe subsystem',
      description: 'Only a restricted subsystem with one disabled TCP/RDMA association and no host grant is supported. Residents, if any, must be disabled unlocked unique-NSID ZVOLs. Its NQN and all namespace and other settings remain unchanged. Default saves null; explicit values use uppercase colon-hex (AA:BB:CC). Registered OUI ownership, actual device identity and initiator compatibility are not attested.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('nvme-subsystem-attached-oui-id'),
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
                key: const Key('nvme-subsystem-attached-oui-default'),
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
            key: const Key('nvme-subsystem-attached-oui-value'),
            controller: _oui,
            enabled: active && !_useDefault,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 32,
            decoration: const InputDecoration(labelText: 'IEEE OUI (AA:BB:CC)'),
            onChanged: (_) => setState(_discard),
          ),
          OutlinedButton(
            key: const Key('nvme-subsystem-attached-oui-review'),
            onPressed: active && _targetId != null && _choice != null
                ? () => _prepare(coordinator!)
                : null,
            child: const Text('Review attached subsystem OUI'),
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
              'Subsystem #${review.target.id}: ${review.target.name}; OUI ${review.target.ieeeOui} → ${review.choice.label}; preserved NQN ${review.target.subnqn}',
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
              'Only ieee_oui is submitted. Name, NQN, namespace settings, access policy, ANA, PI and queue-ID settings must remain unchanged. Public topology is rechecked; sequential reads cannot exclude concurrent changes. Review is single-use and expires in five minutes.',
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-subsystem-attached-oui-reload'),
                  value: _reload,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _reload = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I consent to the saved OUI setting change and NVMe configuration reload. The NQN must remain unchanged; registered OUI ownership, actual device identity and client compatibility are not tested.',
                  ),
                ),
              ],
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-subsystem-attached-oui-limitations'),
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
                  key: const Key('nvme-subsystem-attached-oui-client'),
                  value: _clientRisk,
                  onChanged: _busy
                      ? null
                      : (v) => setState(() => _clientRisk = v == true),
                ),
                const Expanded(
                  child: Text(
                    'I understand OUI changes and reload may affect initiator identity and compatibility. I am responsible for using an appropriate registered identifier. Saved disabled flags and absent host grants do not prove runtime quiescence or isolation. Registered OUI ownership and actual device identity are unverified.',
                  ),
                ),
              ],
            ),
            const Text('Confirmation phrase (copy or type exactly):'),
            SelectableText(
              review.confirmation,
              key: const Key('nvme-subsystem-attached-oui-confirmation'),
            ),
            TextField(
              key: const Key('nvme-subsystem-attached-oui-phrase'),
              controller: _phrase,
              enabled: !_busy,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Exact confirmation phrase',
              ),
              onChanged: (_) => setState(() {}),
            ),
            FilledButton(
              key: const Key('nvme-subsystem-attached-oui-submit'),
              onPressed:
                  active &&
                      _reload &&
                      _limitations &&
                      _clientRisk &&
                      _phrase.text == review.confirmation
                  ? () => _submit(coordinator!, review)
                  : null,
              child: const Text('Apply saved OUI'),
            ),
            TextButton(
              key: const Key('nvme-subsystem-attached-oui-cancel'),
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
