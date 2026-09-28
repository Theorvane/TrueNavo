import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_host_key_replace_coordinator.dart';
import 'nvme_host_authentication_panel.dart';
import 'nvme_host_overview.dart';
import 'nvme_overview.dart';

class NvmeHostKeyReplaceEditor extends ConsumerStatefulWidget {
  const NvmeHostKeyReplaceEditor({super.key});
  @override
  ConsumerState<NvmeHostKeyReplaceEditor> createState() =>
      _NvmeHostKeyReplaceEditorState();
}

class _NvmeHostKeyReplaceEditorState
    extends ConsumerState<NvmeHostKeyReplaceEditor> {
  final _hostId = TextEditingController();
  final _hostKey = TextEditingController();
  final _controllerKey = TextEditingController();
  final _confirmation = TextEditingController();
  String _hash = 'SHA-256';
  String? _group, _message;
  Object? _shownSession, _reviewSession;
  NvmeHostKeyReplaceReview? _review;
  NvmeHostKeyReplaceCoordinator? _reviewCoordinator;
  bool _busy = false, _limitations = false, _noAssociation = false;
  int _secretEpoch = 0;
  bool _credentialLoss = false;
  int? get _id => RegExp(r'^[1-9][0-9]{0,9}$').hasMatch(_hostId.text)
      ? int.tryParse(_hostId.text)
      : null;

  void _discardReview() {
    final review = _review;
    if (review != null) _reviewCoordinator?.cancel(review);
    _review = null;
    _reviewCoordinator = null;
    _reviewSession = null;
    _limitations = false;
    _credentialLoss = false;
    _noAssociation = false;
    _confirmation.clear();
  }

  void _clearInputs() {
    _hostKey.clear();
    _controllerKey.clear();
    // Replace EditableText state as well, dropping its undo/editing history.
    _secretEpoch++;
  }

  @override
  void dispose() {
    _discardReview();
    _clearInputs();
    _hostId.dispose();
    _hostKey.dispose();
    _controllerKey.dispose();
    _confirmation.dispose();
    super.dispose();
  }

  bool _current(Object? session, NvmeHostKeyReplaceCoordinator coordinator) =>
      mounted &&
      identical(ref.read(dashboardActiveSessionProvider), session) &&
      identical(ref.read(nvmeHostKeyReplaceCoordinatorProvider), coordinator);

  Future<void> _prepare(NvmeHostKeyReplaceCoordinator coordinator) async {
    final session = ref.read(dashboardActiveSessionProvider);
    _discardReview();
    setState(() {
      _busy = true;
      _message = null;
    });
    NvmeHostKeyDraft? draft;
    var transferred = false;
    try {
      try {
        draft = NvmeHostKeyDraft.import(
          hostKey: _hostKey.text,
          controllerKey: _controllerKey.text.isEmpty
              ? null
              : _controllerKey.text,
        );
      } finally {
        _clearInputs();
      }
      final review = await coordinator.prepare(
        _id ?? 0,
        hash: _hash,
        group: _group,
        keys: draft,
      );
      transferred = true;
      if (!_current(session, coordinator)) {
        coordinator.cancel(review);
        return;
      }
      setState(() {
        _review = review;
        _reviewCoordinator = coordinator;
        _reviewSession = session;
      });
    } on Object {
      if (_current(session, coordinator)) {
        setState(
          () => _message = 'Imported-key review failed. Check the canonical DHHC-1:01/02/03 keys, exact host ID, advertised algorithms and unassociated inventory. Nothing was sent; re-enter keys.',
        );
      }
    } finally {
      if (!transferred) draft?.dispose();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit(
    NvmeHostKeyReplaceCoordinator coordinator,
    NvmeHostKeyReplaceReview review,
  ) async {
    final session = _reviewSession;
    final phrase = _confirmation.text;
    final limitations = _limitations,
        noAssociation = _noAssociation,
        credentialLoss = _credentialLoss;
    setState(() {
      _busy = true;
      _review = null;
      _message = null;
    });
    final result = await coordinator.execute(
      review,
      phrase,
      acknowledgeKeyLimitations: limitations,
      acknowledgeNoAssociation: noAssociation,
      acknowledgeCredentialLoss: credentialLoss,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      _discardReview();
    });
    if (!_current(session, coordinator)) return;
    setState(() => _message = result.message);
    if (result.outcome == NvmeHostKeyReplaceOutcome.completed) {
      _hostId.clear();
      ref.invalidate(nvmeOverviewProvider);
      ref.invalidate(nvmeHostOverviewProvider);
      ref.invalidate(nvmeHostAuthenticationProvider);
    }
  }

  Widget _secret(
    TextEditingController controller,
    String id,
    String label,
    bool enabled,
  ) => KeyedSubtree(
    key: ValueKey('$id-$_secretEpoch'),
    child: TextField(
      key: Key(id),
      controller: controller,
      enabled: enabled,
      obscureText: true,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      autofillHints: const [],
      maxLength: 120,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      onChanged: (_) => setState(_discardReview),
    ),
  );
  Widget _consent(
    String id,
    String label,
    bool value,
    ValueChanged<bool?> onChanged,
  ) => Row(
    children: [
      Checkbox(key: Key(id), value: value, onChanged: _busy ? null : onChanged),
      Expanded(child: Text(label)),
    ],
  );
  @override
  Widget build(BuildContext context) {
    final coordinator = ref.watch(nvmeHostKeyReplaceCoordinatorProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    if (!identical(session, _shownSession)) {
      _shownSession = session;
      _discardReview();
      _clearInputs();
      _message = null;
    }
    final review =
        identical(session, _reviewSession) &&
            identical(coordinator, _reviewCoordinator) &&
            _review?.hasKeys == true &&
            _id == _review?.id &&
            _hash == _review?.hash &&
            _group == _review?.group
        ? _review
        : null;
    final enabled =
        !_busy &&
        coordinator != null &&
        coordinator.available &&
        !coordinator.locked;
    return TdPanel(
      title: 'Replace DH-CHAP keys for an unassociated NVMe-oF host',
      description: 'Replaces both host/controller key settings of an existing unassociated host while preserving NQN. An empty controller key explicitly removes it. No mapping or key generation. Old keys are not shown, saved or restored by the app.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('nvme-key-replace-id'),
            controller: _hostId,
            enabled: enabled,
            maxLength: 10,
            decoration: const InputDecoration(
              labelText: 'Exact existing host ID',
              border: OutlineInputBorder(),
            ),
            onChanged: (_) => setState(_discardReview),
          ),
          _secret(
            _hostKey,
            'nvme-key-replace-host-key',
            'Imported host DH-CHAP key',
            enabled,
          ),
          _secret(
            _controllerKey,
            'nvme-key-replace-controller-key',
            'Optional controller DH-CHAP key',
            enabled,
          ),
          DropdownButtonFormField<String>(
            key: const Key('nvme-key-replace-hash'),
            isExpanded: true,
            initialValue: _hash,
            decoration: const InputDecoration(
              labelText: 'Hash (server support checked before submission)',
            ),
            items: [
              for (final hash in ['SHA-256', 'SHA-384', 'SHA-512'])
                DropdownMenuItem(
                  value: hash,
                  child: Text(
                    hash,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: enabled
                ? (value) => setState(() {
                    _discardReview();
                    _hash = value!;
                  })
                : null,
          ),
          DropdownButtonFormField<String>(
            key: const Key('nvme-key-replace-group'),
            isExpanded: true,
            initialValue: _group ?? 'NONE',
            decoration: const InputDecoration(
              labelText: 'DH group (server support checked before submission)',
            ),
            items: [
              const DropdownMenuItem(value: 'NONE', child: Text('None')),
              for (final group in [
                '2048-BIT',
                '3072-BIT',
                '4096-BIT',
                '6144-BIT',
                '8192-BIT',
              ])
                DropdownMenuItem(
                  value: group,
                  child: Text(
                    group,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
            ],
            onChanged: enabled
                ? (value) => setState(() {
                    _discardReview();
                    _group = value == 'NONE' ? null : value;
                  })
                : null,
          ),
          OutlinedButton(
            key: const Key('nvme-key-replace-review'),
            onPressed: enabled ? () => _prepare(coordinator) : null,
            child: const Text('Review imported-key replacement'),
          ),
          if (coordinator == null || !coordinator.available)
            const Text(
              'Protected key replacement is unavailable on this server.',
            ),
          if (coordinator?.locked == true)
            const Text(
              'An NVMe change is in progress or unverified. Reconnect before retrying.',
            ),
          if (review != null && coordinator != null) ...[
            const Divider(),
            Text('Server: ${review.endpoint}'),
            Text('Host ID: ${review.id} · NQN: ${review.nqn}'),
            Text(
              'Previous returned settings: hash ${review.previous.hash} · DH group ${review.previous.group ?? "None"} · Host key ${review.previous.hostKeyReturned ? "present" : "not returned"} · Controller key ${review.previous.controllerKeyReturned ? "present" : "not returned"}',
            ),
            Text('Hash: ${review.hash} · DH group: ${review.group ?? "None"}'),
            Text(
              'Host key: supplied · Controller key: ${review.hasControllerKey ? "supplied" : "not supplied"}',
            ),
            const Text(
              'Key inputs were cleared. Cancel to discard this single-use five-minute review. Server choices and full public topology will be checked again; concurrent administrators cannot be excluded.',
            ),
            _consent(
              'nvme-key-replace-limitations',
              'I understand that imported keys will be stored on the NAS. Structural validation does not verify CRC, entropy, derivation or initiator compatibility. Owned buffers are best-effort wiped, but Dart strings and transport copies cannot be guaranteed zeroized.',
              _limitations,
              (v) => setState(() => _limitations = v == true),
            ),
            _consent(
              'nvme-key-replace-no-association',
              'I understand that replacement reloads NVMe configuration but creates no subsystem association. Runtime authentication, client activity and access are not verified; returned fields can be redacted and sequential checks cannot exclude concurrent administration.',
              _noAssociation,
              (v) => setState(() => _noAssociation = v == true),
            ),
            _consent(
              'nvme-key-replace-credential-loss',
              'I understand that both key settings and the reviewed algorithms will replace the old values. The old keys cannot be recovered or rolled back by this app. Initiator configuration may need to change before future access.',
              _credentialLoss,
              (v) => setState(() => _credentialLoss = v == true),
            ),
            TextField(
              key: const Key('nvme-key-replace-confirmation'),
              controller: _confirmation,
              enabled: !_busy,
              decoration: InputDecoration(
                labelText: 'Type ${review.confirmation}',
                border: const OutlineInputBorder(),
              ),
            ),
            FilledButton(
              key: const Key('nvme-key-replace-submit'),
              onPressed:
                  enabled && _limitations && _noAssociation && _credentialLoss
                  ? () => _submit(coordinator, review)
                  : null,
              child: const Text('Replace host authentication keys'),
            ),
            TextButton(
              key: const Key('nvme-key-replace-cancel'),
              onPressed: _busy
                  ? null
                  : () => setState(() {
                      _discardReview();
                      _clearInputs();
                    }),
              child: const Text('Cancel'),
            ),
          ],
          if (_message != null) Text(_message!),
        ],
      ),
    );
  }
}
