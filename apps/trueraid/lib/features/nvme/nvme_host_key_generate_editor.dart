import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_host_key_generate_coordinator.dart';

class NvmeHostKeyGenerateEditor extends ConsumerStatefulWidget {
  const NvmeHostKeyGenerateEditor({super.key});
  @override
  ConsumerState<NvmeHostKeyGenerateEditor> createState() => _GeneratorState();
}

class _GeneratorState extends ConsumerState<NvmeHostKeyGenerateEditor>
    with WidgetsBindingObserver {
  final _nqn = TextEditingController(), _phrase = TextEditingController();
  String _hash = 'SHA-256';
  String? _revealed, _message;
  bool _generation = false, _risks = false, _exposure = false, _busy = false;
  Object? _session;
  NvmeHostKeyGenerateCoordinator? _owner;
  Timer? _expiry;
  int _epoch = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  void _discard() {
    _epoch++;
    _expiry?.cancel();
    _expiry = null;
    _owner?.cancel();
    _owner = null;
    _revealed = null;
    _generation = _risks = _exposure = false;
    _phrase.clear();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed && mounted) {
      setState(() {
        _discard();
        _message = 'Key material discarded when the app left the foreground.';
      });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _discard();
    _nqn.dispose();
    _phrase.dispose();
    super.dispose();
  }

  Future<void> _generate(NvmeHostKeyGenerateCoordinator coordinator) async {
    final session = ref.read(dashboardActiveSessionProvider);
    final hash = _hash, nqn = _nqn.text.isEmpty ? null : _nqn.text;
    final phrase = _phrase.text, generation = _generation, risks = _risks;
    _discard();
    _owner = coordinator;
    final epoch = _epoch;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await coordinator.generate(
        hash: hash,
        nqn: nqn,
        generationConsent: generation,
        exposureRiskConsent: risks,
        phrase: phrase,
      );
      if (!mounted ||
          epoch != _epoch ||
          !identical(session, ref.read(dashboardActiveSessionProvider))) {
        return;
      }
      _expiry = Timer(const Duration(minutes: 5), () {
        if (mounted) {
          setState(() {
            _discard();
            _message = 'Transfer window expired; key material was discarded.';
          });
        }
      });
      setState(
        () => _message =
            'Generated key is hidden. No host was registered or changed.',
      );
    } on Object {
      if (mounted &&
          epoch == _epoch &&
          identical(session, ref.read(dashboardActiveSessionProvider))) {
        setState(() {
          _discard();
          _message = 'Key generation failed or was cancelled. No key is available; no automatic retry or host change was requested.';
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _reveal(NvmeHostKeyGenerateCoordinator coordinator) {
    try {
      final secret = coordinator.takeForTransfer(exposureConsent: _exposure);
      _expiry?.cancel();
      setState(() {
        _revealed = secret;
        _exposure = false;
      });
      _expiry = Timer(const Duration(seconds: 30), () {
        if (mounted) {
          setState(() {
            _discard();
            _message = 'One-time display ended. External copies cannot be erased by this app.';
          });
        }
      });
    } on Object {
      setState(() {
        _discard();
        _message = 'Key transfer is unavailable or expired.';
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    if (!identical(session, _session)) {
      _discard();
      _nqn.clear();
      _message = null;
      _session = session;
    }
    final coordinator = ref.watch(nvmeHostKeyGenerateCoordinatorProvider);
    if (_owner != null && !identical(_owner, coordinator)) {
      _discard();
      _message = null;
    }
    // Covered routes can stay mounted. Do not retain keys behind another page.
    if (ModalRoute.isCurrentOf(context) == false &&
        (_owner != null || _revealed != null || _busy)) {
      _discard();
      _message = 'Key material discarded when another page was opened.';
    }
    final available = coordinator?.available == true;
    final hasKey =
        identical(coordinator, _owner) && coordinator?.hasKey == true;
    final editable = available && !_busy && !hasKey && _revealed == null;
    void changed() => setState(() {
      _discard();
      _message = null;
    });
    return TdPanel(
      title: 'Generate a protected NVMe authentication key',
      description: 'Explicit server-side generation only. This does not save a host key, register an initiator, create associations or prove runtime authentication. No automatic generation, retries or clipboard writes.',
      child: Material(
        type: MaterialType.transparency,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('Connected server: ${session?.endpoint ?? 'unavailable'}'),
            if (!available)
              const Text(
                'Protected key generation is unavailable on this connection.',
              ),
            DropdownButtonFormField<String>(
              initialValue: _hash,
              isExpanded: true,
              decoration: const InputDecoration(
                labelText:
                    'DH-CHAP hash (checked against fresh server choices)',
              ),
              items: [
                for (final hash in ['SHA-256', 'SHA-384', 'SHA-512'])
                  DropdownMenuItem(value: hash, child: Text(hash)),
              ],
              onChanged: editable
                  ? (value) {
                      changed();
                      setState(() => _hash = value!);
                    }
                  : null,
            ),
            TextField(
              key: const Key('nvme-key-gen-nqn'),
              controller: _nqn,
              enabled: editable,
              maxLength: 223,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Optional transformation NQN (empty means unset)',
              ),
              onChanged: (_) => changed(),
            ),
            CheckboxListTile(
              key: const Key('nvme-key-gen-consent'),
              value: _generation,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'I request one server-generated key only; no host configuration will be saved.',
              ),
              onChanged: editable
                  ? (v) => setState(() => _generation = v ?? false)
                  : null,
            ),
            CheckboxListTile(
              key: const Key('nvme-key-gen-risks'),
              value: _risks,
              contentPadding: EdgeInsets.zero,
              title: const Text(
                'I understand memory wiping is best effort; validity and compatibility are not verified. Screenshots, selection copies and clipboard history may retain the key outside this app.',
              ),
              onChanged: editable
                  ? (v) => setState(() => _risks = v ?? false)
                  : null,
            ),
            TextField(
              key: const Key('nvme-key-gen-phrase'),
              controller: _phrase,
              enabled: editable,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                labelText: 'Type GENERATE NVME KEY',
              ),
              onChanged: (_) => setState(() {}),
            ),
            const SizedBox(height: 12),
            FilledButton(
              key: const Key('nvme-key-gen-submit'),
              onPressed:
                  editable &&
                      _generation &&
                      _risks &&
                      _phrase.text == 'GENERATE NVME KEY'
                  ? () => _generate(coordinator!)
                  : null,
              child: Text(_busy ? 'Generating…' : 'Generate one protected key'),
            ),
            if (hasKey) ...[
              const Text(
                'Key hidden. Transfer is single-use and expires within five minutes. No saved host configuration changed.',
              ),
              CheckboxListTile(
                key: const Key('nvme-key-gen-exposure'),
                value: _exposure,
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'I explicitly consent to display this secret for initiator transfer. Any copies remain my responsibility.',
                ),
                onChanged: (v) => setState(() => _exposure = v ?? false),
              ),
              OutlinedButton(
                key: const Key('nvme-key-gen-reveal'),
                onPressed: _exposure ? () => _reveal(coordinator!) : null,
                child: const Text('Reveal once for 30 seconds'),
              ),
            ],
            if (_revealed != null) ...[
              const Text(
                'Secret visible for at most 30 seconds. Manual selection copying is optional; clipboard contents are not cleared by this app.',
              ),
              SelectableText(_revealed!, key: const Key('nvme-key-gen-secret')),
            ],
            if (_owner != null || _busy || _revealed != null)
              TextButton(
                key: const Key('nvme-key-gen-discard'),
                onPressed: () => setState(() {
                  _discard();
                  _message = 'Key material discarded. An in-flight request cannot be recalled.';
                }),
                child: const Text('Discard key / cancel delivery'),
              ),
            if (_message != null) Text(_message!),
          ],
        ),
      ),
    );
  }
}
