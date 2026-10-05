import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'ssh_credentials_controller.dart';

final class SshCredentialEdit {
  const SshCredentialEdit(this.request, this.input);
  final SshCredentialRequest request;
  final SshCredentialWriteOnlyInput? input;
}

class SshCredentialsEditor extends ConsumerStatefulWidget {
  const SshCredentialsEditor({
    required this.session,
    required this.inventory,
    required this.action,
    this.credential,
    super.key,
  });
  final AuthenticatedSession session;
  final SshCredentialInventory inventory;
  final SshCredentialAction action;
  final SshCredentialEntry? credential;
  @override
  ConsumerState<SshCredentialsEditor> createState() =>
      _SshCredentialsEditorState();
}

class _SshCredentialsEditorState extends ConsumerState<SshCredentialsEditor> {
  final _name = TextEditingController(),
      _private = TextEditingController(),
      _public = TextEditingController(),
      _host = TextEditingController(),
      _port = TextEditingController(text: '22'),
      _username = TextEditingController(),
      _hostKeys = TextEditingController(),
      _timeout = TextEditingController(text: '10');
  int? _keyPair;
  bool _expired = false, _verified = false, _pasting = false;
  String? _error;
  late final AppLifecycleListener _lifecycle;
  List<TextEditingController> get _fields => [
    _name,
    _private,
    _public,
    _host,
    _port,
    _username,
    _hostKeys,
    _timeout,
  ];
  bool get _importing => widget.action == SshCredentialAction.importKeyPair;
  bool get _connection => widget.action == SshCredentialAction.createConnection;
  @override
  void initState() {
    super.initState();
    _name.text = widget.credential?.name ?? '';
    final state = WidgetsBinding.instance.lifecycleState;
    _expired = state != null && state != AppLifecycleState.resumed;
    if (_expired) {
      for (final field in _fields) {
        field.clear();
      }
    }
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) _expire();
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    for (final field in _fields) {
      field.clear();
      field.dispose();
    }
    super.dispose();
  }

  void _expire() {
    if (_expired) return;
    setState(() {
      _expired = true;
      _verified = false;
      _error = null;
      _keyPair = null;
      for (final field in _fields) {
        field.clear();
      }
    });
  }

  SshConnectionSettings get _settings => SshConnectionSettings(
    host: _host.text,
    port: int.tryParse(_port.text) ?? 0,
    username: _username.text,
    keyPairId: _keyPair ?? 0,
    remoteHostKey: _hostKeys.text,
    connectTimeout: int.tryParse(_timeout.text) ?? 0,
  );
  Future<void> _pastePrivate() async {
    if (_expired || _pasting) return;
    setState(() {
      _pasting = true;
      _private.clear();
      _error = null;
    });
    try {
      // Explicit user action only. Programmatic assignment preserves line breaks
      // that Flutter's obscured, single-line input formatter would otherwise strip.
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      if (!mounted || _expired) return;
      final inventory = ref.read(sshCredentialsInventoryProvider);
      if (!identical(
            widget.session,
            ref.read(dashboardActiveSessionProvider),
          ) ||
          inventory.isLoading ||
          !identical(widget.inventory, inventory.asData?.value)) {
        _expire();
        return;
      }
      final value = data?.text;
      setState(() {
        _private.clear();
        if (value == null || value.isEmpty || value.length > 65536) {
          _error = 'Copy one complete OpenSSH private-key block of at most 64 KiB, then paste explicitly.';
        } else {
          _private.text = value;
          _error = null;
        }
      });
    } on Object {
      if (mounted && !_expired) {
        setState(
          () =>
              _error = 'Clipboard access was unavailable. No key was imported.',
        );
      }
    } finally {
      if (mounted) setState(() => _pasting = false);
    }
  }

  void _submit() {
    final input = _importing
        ? SshCredentialWriteOnlyInput.keyPair(
            privateKey: _private.text,
            publicKey: _public.text.isEmpty ? null : _public.text,
          )
        : null;
    final request = SshCredentialRequest(
      inventory: widget.inventory,
      action: widget.action,
      credential: widget.credential,
      name: _name.text,
      connection: _connection ? _settings : null,
      hostKeyVerified: _connection && _verified,
    );
    final error = request.validationError ?? input?.validationError;
    if (error != null) {
      input?.dispose();
      setState(() => _error = error);
      return;
    }
    _private.clear();
    Navigator.pop(context, SshCredentialEdit(request, input));
  }

  Widget _field(
    String id,
    String label,
    TextEditingController controller, {
    bool secret = false,
    int lines = 1,
    int max = 1024,
    String? help,
    bool trust = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextField(
      key: Key('ssh-credential-$id'),
      controller: controller,
      obscureText: secret,
      readOnly: secret,
      minLines: 1,
      maxLines: lines,
      maxLength: max,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      keyboardType: secret
          ? TextInputType.visiblePassword
          : lines > 1
          ? TextInputType.multiline
          : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        helperText: help,
        helperMaxLines: 6,
      ),
      onChanged: (_) {
        if (trust) setState(() => _verified = false);
      },
      onTap: () => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && primaryFocus?.context != null) {
          Scrollable.ensureVisible(primaryFocus!.context!, alignment: .4);
        }
      }),
    ),
  );
  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(sshCredentialsInventoryProvider, (_, b) {
      if (b.isLoading || !identical(widget.inventory, b.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(sshCredentialsInventoryProvider);
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(widget.inventory, inventory.asData?.value);
    final fingerprints = _connection
        ? _settings.hostKeyFingerprints
        : const <String>[];
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: SingleChildScrollView(
          key: const Key('ssh-credential-editor-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current ? _title(widget.action) : 'SSH editor expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Prior settings and private-key input were discarded. Reload and review again.',
                )
              else ...[
                const SizedBox(height: 12),
                Text(widget.inventory.endpoint),
                _field('name', 'Credential name', _name, max: 255),
                if (_importing) ...[
                  const Text(
                    'Paste an unencrypted single-key OpenSSH container. Private material is write-only, cleared on submit, close, background or connection change. Cryptographic validation is performed by TrueNAS.',
                  ),
                  _field(
                    'private-key',
                    'Private OpenSSH key · write-only',
                    _private,
                    secret: true,
                    max: 65536,
                    help: 'Use the explicit paste button to preserve the complete multiline block. This app does not write to or clear your clipboard; manage its existing contents yourself.',
                  ),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      OutlinedButton.icon(
                        key: const Key('ssh-credential-paste-private'),
                        onPressed: _pasting ? null : _pastePrivate,
                        icon: const Icon(Icons.content_paste),
                        label: const Text('Paste private key'),
                      ),
                      TextButton(
                        key: const Key('ssh-credential-clear-private'),
                        onPressed: _pasting ? null : () => _private.clear(),
                        child: const Text('Clear private input'),
                      ),
                    ],
                  ),
                  _field(
                    'public-key',
                    'Optional matching public key',
                    _public,
                    lines: 3,
                    max: 16384,
                    help:
                        'Leave empty for the server to derive the public key.',
                  ),
                ],
                if (widget.action == SshCredentialAction.generateKeyPair)
                  const Text(
                    'Generate and store a new RSA keypair on TrueNAS after review. This performs server-side key generation and a separate save. Only its public key is returned to this screen. No remote SSH account is configured.',
                  ),
                if (widget.action == SshCredentialAction.rename)
                  const Text(
                    'Name-only update preserves existing attributes. TrueNAS can revalidate key material and reload replication task configuration; only unused credentials can be renamed here.',
                  ),
                if (_connection) ...[
                  const Text(
                    'Create a stored connection configuration, without making a network connection or installing keys. Verify the remote host keys through a separate trusted channel first.',
                  ),
                  _field(
                    'host',
                    'Remote hostname or IP',
                    _host,
                    max: 253,
                    trust: true,
                  ),
                  _field('port', 'SSH port', _port, max: 5, trust: true),
                  _field(
                    'username',
                    'Remote SSH account',
                    _username,
                    max: 64,
                    trust: true,
                  ),
                  const SizedBox(height: 12),
                  DropdownButtonFormField<int>(
                    key: const Key('ssh-credential-keypair'),
                    initialValue: _keyPair,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Existing keypair',
                    ),
                    hint: const Text('Choose a keypair'),
                    items: [
                      for (final key in widget.inventory.keyPairs)
                        DropdownMenuItem(
                          value: key.id,
                          child: Text('${key.name} · ID ${key.id}'),
                        ),
                    ],
                    onChanged: (value) => setState(() {
                      _keyPair = value;
                      _verified = false;
                    }),
                  ),
                  const Text(
                    'A public-key inventory does not prove that private material is present or remote authentication will work.',
                  ),
                  _field(
                    'host-keys',
                    'Independently verified host public keys',
                    _hostKeys,
                    lines: 3,
                    max: 1024,
                    trust: true,
                    help: 'One algorithm + base64 key per line, without hostname prefix. No automatic key scan or trust-on-first-use.',
                  ),
                  for (final fingerprint in fingerprints)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: SelectableText(fingerprint),
                    ),
                  _field(
                    'timeout',
                    'Connection timeout (seconds)',
                    _timeout,
                    max: 3,
                  ),
                  CheckboxListTile(
                    key: const Key('ssh-credential-host-verified'),
                    contentPadding: EdgeInsets.zero,
                    value: _verified,
                    onChanged: fingerprints.isEmpty
                        ? null
                        : (v) => setState(() => _verified = v == true),
                    title: const Text(
                      'I independently compared these fingerprints for this destination and account.',
                    ),
                  ),
                ],
                if (_error case final error?)
                  Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  TextButton(
                    key: const Key('ssh-credential-editor-cancel'),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('ssh-credential-editor-review'),
                    onPressed: current && !_pasting ? _submit : null,
                    child: const Text('Review change'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _title(SshCredentialAction action) => switch (action) {
  SshCredentialAction.importKeyPair => 'Import SSH keypair',
  SshCredentialAction.generateKeyPair => 'Generate & store SSH keypair',
  SshCredentialAction.createConnection => 'Create SSH connection configuration',
  SshCredentialAction.rename => 'Rename SSH credential',
  SshCredentialAction.delete => 'Delete SSH credential',
};
