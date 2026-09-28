import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_subsystem_populated_oui_coordinator.dart';
import 'nvme_overview.dart';

class NvmeSubsystemPopulatedOuiEditor extends ConsumerStatefulWidget {
  const NvmeSubsystemPopulatedOuiEditor({super.key});
  @override
  ConsumerState<NvmeSubsystemPopulatedOuiEditor> createState() =>
      _PopulatedOuiState();
}

class _PopulatedOuiState
    extends ConsumerState<NvmeSubsystemPopulatedOuiEditor> {
  final _id = TextEditingController(),
      _phrase = TextEditingController(),
      _oui = TextEditingController();
  bool _useDefault = true;
  NvmePopulatedOuiChoice? get _choice {
    final choice = NvmePopulatedOuiChoice(_useDefault ? null : _oui.text);
    return choice.valid ? choice : null;
  }

  NvmeSubsystemPopulatedOuiReview? _review;
  NvmeSubsystemPopulatedOuiCoordinator? _owner;
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
    _oui.dispose();
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _prepare(
    NvmeSubsystemPopulatedOuiCoordinator coordinator,
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
            ref.read(nvmeSubsystemPopulatedOuiCoordinatorProvider),
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
          () => _message = 'Review failed. Select a populated restricted isolated subsystem with a reported OUI field and a different saved OUI setting. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmeSubsystemPopulatedOuiCoordinator coordinator,
    NvmeSubsystemPopulatedOuiReview review,
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
        result.outcome == NvmeSubsystemPopulatedOuiOutcome.completed) {
      ref.invalidate(nvmeOverviewProvider);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final coordinator = ref.watch(nvmeSubsystemPopulatedOuiCoordinatorProvider);
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
      title: 'Set saved OUI on an isolated populated NVMe subsystem',
      description: 'Only a restricted subsystem containing disabled unlocked ZVOL namespaces with valid unique NSIDs and no host or port mappings is supported. Its NQN and all namespace and other settings remain unchanged. The current OUI must be null or colon-delimited hex. Default saves null; explicit OUI uses the conservative uppercase AA:BB:CC hex form. Registered OUI ownership, actual device identity and initiator compatibility are not attested.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const Key('nvme-subsystem-populated-oui-id'),
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
                key: const Key('nvme-subsystem-populated-oui-default'),
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
            key: const Key('nvme-subsystem-populated-oui-value'),
            controller: _oui,
            enabled: active && !_useDefault,
            keyboardType: TextInputType.text,
            autocorrect: false,
            enableSuggestions: false,
            maxLength: 8,
            decoration: const InputDecoration(
              labelText: 'IEEE OUI (AA:BB:CC uppercase hex)',
            ),
            onChanged: (_) => setState(_discard),
          ),
          OutlinedButton(
            key: const Key('nvme-subsystem-populated-oui-review'),
            onPressed: active && _targetId != null && _choice != null
                ? () => _prepare(coordinator!)
                : null,
            child: const Text('Review populated subsystem OUI'),
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
            Text('Preserved namespaces: ${review.namespaces.length}'),
            for (final namespace in review.namespaces)
              Text(
                'Namespace #${namespace.id}, NSID ${namespace.nsid}: disabled unlocked ZVOL; unchanged',
              ),
            const Text(
              'Only ieee_oui is submitted. Name, NQN, namespace settings, access policy, ANA, PI and maximum queue-ID settings must remain unchanged. Public topology is rechecked; sequential reads cannot exclude concurrent changes. Review is single-use and expires in five minutes.',
            ),
            Row(
              children: [
                Checkbox(
                  key: const Key('nvme-subsystem-populated-oui-reload'),
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
                  key: const Key('nvme-subsystem-populated-oui-limitations'),
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
              key: const Key('nvme-subsystem-populated-oui-phrase'),
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
              key: const Key('nvme-subsystem-populated-oui-submit'),
              onPressed:
                  active &&
                      _reload &&
                      _limitations &&
                      _phrase.text == review.confirmation
                  ? () => _submit(coordinator!, review)
                  : null,
              child: const Text('Apply saved OUI'),
            ),
            TextButton(
              key: const Key('nvme-subsystem-populated-oui-cancel'),
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
