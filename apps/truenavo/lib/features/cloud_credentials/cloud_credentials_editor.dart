import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'cloud_credentials_controller.dart';

final class CloudCredentialEdit {
  const CloudCredentialEdit(this.name, this.provider, this.input);
  final String name, provider;
  final CloudCredentialWriteOnlyInput? input;
}

class CloudCredentialsEditor extends ConsumerStatefulWidget {
  const CloudCredentialsEditor({
    required this.session,
    required this.inventory,
    required this.action,
    this.credential,
    super.key,
  });
  final AuthenticatedSession session;
  final CloudCredentialInventory inventory;
  final CloudCredentialAction action;
  final CloudCredentialEntry? credential;
  @override
  ConsumerState<CloudCredentialsEditor> createState() =>
      _CloudCredentialsEditorState();
}

class _CloudCredentialsEditorState
    extends ConsumerState<CloudCredentialsEditor> {
  final _name = TextEditingController(),
      _access = TextEditingController(),
      _secret = TextEditingController(),
      _endpoint = TextEditingController(),
      _region = TextEditingController(),
      _parts = TextEditingController(text: '10000'),
      _token = TextEditingController(),
      _clientId = TextEditingController(),
      _clientSecret = TextEditingController();
  String _provider = 'S3';
  String? _error;
  bool _skip = false, _v2 = false, _expired = false, _complete = false;
  late final AppLifecycleListener _lifecycle;
  List<TextEditingController> get _sensitive => [
    _access,
    _secret,
    _endpoint,
    _region,
    _parts,
    _token,
    _clientId,
    _clientSecret,
  ];
  bool get _rename => widget.action == CloudCredentialAction.rename;
  bool get _replace => widget.action == CloudCredentialAction.replace;
  @override
  void initState() {
    super.initState();
    _name.text = widget.credential?.name ?? '';
    _provider = widget.credential?.provider ?? 'S3';
    final initial = WidgetsBinding.instance.lifecycleState;
    _expired = initial != null && initial != AppLifecycleState.resumed;
    if (_expired) {
      _name.clear();
      for (final c in _sensitive) {
        c.clear();
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
    for (final c in [_name, ..._sensitive]) {
      c.clear();
      c.dispose();
    }
    super.dispose();
  }

  void _expire() {
    if (_expired) return;
    setState(() {
      _expired = true;
      _error = null;
      _complete = false;
      _name.clear();
      for (final c in _sensitive) {
        c.clear();
      }
    });
  }

  CloudCredentialWriteOnlyInput? _input() => _rename
      ? null
      : _provider == 'S3'
      ? CloudCredentialWriteOnlyInput.s3(
          accessKeyId: _access.text,
          secretAccessKey: _secret.text,
          endpoint: _endpoint.text,
          region: _region.text,
          skipRegion: _skip,
          signaturesV2: _v2,
          maxUploadParts: int.tryParse(_parts.text) ?? 0,
        )
      : CloudCredentialWriteOnlyInput.dropbox(
          token: _token.text,
          clientId: _clientId.text,
          clientSecret: _clientSecret.text,
        );
  void _submit() {
    final input = _input();
    final request = CloudCredentialRequest(
      inventory: widget.inventory,
      action: widget.action,
      credential: widget.credential,
      name: _name.text,
      provider: _provider,
    );
    final error = request.validationError ?? input?.validationError;
    if (error != null) {
      input?.dispose();
      setState(() => _error = error);
      return;
    }
    final edit = CloudCredentialEdit(_name.text, _provider, input);
    for (final c in _sensitive) {
      c.clear();
    }
    Navigator.of(context).pop(edit);
  }

  Widget _field(
    String id,
    String label,
    TextEditingController controller, {
    bool secret = false,
    String? help,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextField(
      key: Key('cloud-credential-$id'),
      controller: controller,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      keyboardType: secret ? TextInputType.visiblePassword : TextInputType.text,
      decoration: InputDecoration(
        labelText: label,
        helperText: help,
        helperMaxLines: 5,
      ),
      onTap: () {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted && primaryFocus?.context != null) {
            Scrollable.ensureVisible(primaryFocus!.context!, alignment: 0.4);
          }
        });
      },
    ),
  );
  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(cloudCredentialsInventoryProvider, (_, b) {
      if (b.isLoading || !identical(widget.inventory, b.asData?.value)) {
        _expire();
      }
    });
    final state = ref.watch(cloudCredentialsInventoryProvider);
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !state.isLoading &&
        identical(widget.inventory, state.asData?.value);
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 660),
        child: SingleChildScrollView(
          key: const Key('cloud-credential-editor-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? '${widget.action.name} cloud credential'
                    : 'Editor expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous account details and inputs were discarded. Reload on the current connection.',
                )
              else ...[
                const SizedBox(height: 8),
                Text(widget.inventory.endpoint),
                if (_replace)
                  const Text(
                    'Replace the ENTIRE provider record. Existing settings and secrets are not loaded. Re-enter every required value; blank optional fields explicitly clear prior values.',
                  ),
                if (!_replace) _field('name', 'Credential name', _name),
                if (widget.action == CloudCredentialAction.create)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: DropdownButtonFormField<String>(
                      initialValue: _provider,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Provider'),
                      items: const [
                        DropdownMenuItem(value: 'S3', child: Text('S3')),
                        DropdownMenuItem(
                          value: 'DROPBOX',
                          child: Text('Dropbox'),
                        ),
                      ],
                      onChanged: (value) {
                        if (value != null) {
                          setState(() {
                            _provider = value;
                            _complete = false;
                            _error = null;
                            for (final c in _sensitive) {
                              c.clear();
                            }
                            _parts.text = '10000';
                            _skip = false;
                            _v2 = false;
                          });
                        }
                      },
                    ),
                  ),
                if (!_rename) ...[
                  const Padding(
                    padding: EdgeInsets.only(top: 12),
                    child: Text(
                      'Write-only input · not saved on this device. No automatic cloud verification, OAuth sign-in or remote file listing.',
                    ),
                  ),
                  if (_provider == 'S3') ...[
                    _field(
                      'access-key',
                      'New access key ID',
                      _access,
                      secret: true,
                    ),
                    _field(
                      'secret-key',
                      'New secret access key',
                      _secret,
                      secret: true,
                    ),
                    _field(
                      'endpoint',
                      'HTTPS endpoint',
                      _endpoint,
                      help: 'Empty means AWS S3. No credentials, query, path or fragment.',
                    ),
                    _field(
                      'region',
                      'Region',
                      _region,
                      secret: true,
                      help: 'Empty is an explicit default; existing values are not preserved.',
                    ),
                    _field('parts', 'Maximum multipart parts', _parts),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _skip,
                      onChanged: (v) => setState(() => _skip = v ?? false),
                      title: const Text('Skip region validation'),
                    ),
                    CheckboxListTile(
                      contentPadding: EdgeInsets.zero,
                      value: _v2,
                      onChanged: (v) => setState(() => _v2 = v ?? false),
                      title: const Text('Use legacy signature version 2'),
                    ),
                  ] else ...[
                    _field(
                      'token',
                      'Already-issued OAuth token JSON',
                      _token,
                      secret: true,
                      help: 'Single-line bearer token JSON. OAuth authorization and token refresh are not performed by this screen.',
                    ),
                    _field(
                      'client-id',
                      'Custom client ID',
                      _clientId,
                      secret: true,
                    ),
                    _field(
                      'client-secret',
                      'Custom client secret',
                      _clientSecret,
                      secret: true,
                      help: 'Explicitly leave both custom client fields empty for provider defaults.',
                    ),
                  ],
                  CheckboxListTile(
                    key: const Key('cloud-credential-complete'),
                    contentPadding: EdgeInsets.zero,
                    value: _complete,
                    onChanged: (v) => setState(() => _complete = v ?? false),
                    title: const Text(
                      'These are the complete new provider values, including intentional blank optional fields.',
                    ),
                  ),
                ],
                if (_error != null)
                  Text(
                    _error!,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('cloud-credential-editor-review'),
                    onPressed: current && (_rename || _complete)
                        ? _submit
                        : null,
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
