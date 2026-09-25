import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'email_settings_controller.dart';
import 'email_settings_review.dart';

class EmailSettingsEditorDialog extends ConsumerStatefulWidget {
  const EmailSettingsEditorDialog({
    required this.session,
    required this.inventory,
    required this.action,
    super.key,
  });
  final AuthenticatedSession session;
  final EmailSettingsInventory inventory;
  final EmailSettingsAction action;
  @override
  ConsumerState<EmailSettingsEditorDialog> createState() =>
      _EmailSettingsEditorDialogState();
}

class _EmailSettingsEditorDialogState
    extends ConsumerState<EmailSettingsEditorDialog> {
  late final TextEditingController _from, _name, _host, _port, _username;
  final _password = TextEditingController(),
      _recipient = TextEditingController();
  late EmailSecurity _security;
  late bool _auth;
  EmailPasswordAction _passwordAction = EmailPasswordAction.keep;
  bool _expired = false, _closing = false;
  String? _error;
  late final AppLifecycleListener _lifecycle;
  bool get _test => widget.action == EmailSettingsAction.test;
  @override
  void initState() {
    super.initState();
    final settings = widget.inventory.config.settings;
    _from = TextEditingController(text: settings.fromEmail);
    _name = TextEditingController(text: settings.fromName);
    _host = TextEditingController(text: settings.outgoingServer);
    _port = TextEditingController(text: '${settings.port}');
    _username = TextEditingController(text: settings.username);
    _security = settings.security;
    _auth = settings.smtpAuth;
    final initial = WidgetsBinding.instance.lifecycleState;
    _expired = initial != null && initial != AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) _expire();
      },
    );
  }

  List<TextEditingController> get _fields => [
    _from,
    _name,
    _host,
    _port,
    _username,
    _password,
    _recipient,
  ];
  void _expire() {
    if (_expired || _closing || !mounted) return;
    ref.read(emailSettingsControllerProvider.notifier).expireContext();
    setState(() {
      _expired = true;
      _error = null;
      for (final field in _fields) {
        field.clear();
      }
    });
  }

  EmailSmtpSettings get _settings => EmailSmtpSettings(
    fromEmail: _from.text,
    fromName: _name.text,
    outgoingServer: _host.text,
    port: int.tryParse(_port.text) ?? 0,
    security: _security,
    smtpAuth: _auth,
    username: _username.text,
  );
  EmailPasswordChange get _safePasswordChoice =>
      _passwordAction == EmailPasswordAction.clear
      ? const EmailPasswordChange.clear()
      : const EmailPasswordChange.keep();
  String? get _validation {
    if (_test) {
      return EmailSettingsRequest(
        inventory: widget.inventory,
        action: widget.action,
        recipient: _recipient.text,
      ).validationError;
    }
    if (_settings.validationError != null) return _settings.validationError;
    if (_passwordAction == EmailPasswordAction.replace) {
      if (_password.text.isEmpty ||
          _password.text.length > 1024 ||
          _password.text.codeUnits.any((c) => c < 0x20 || c > 0x7e)) {
        return 'New passwords must contain 1–1024 printable ASCII characters, with no line breaks or control characters.';
      }
      if (!_auth) {
        return 'Disable authentication only with an explicit saved-password clear; do not store an unused replacement.';
      }
      return widget.inventory.blockedReason;
    }
    return EmailSettingsRequest(
      inventory: widget.inventory,
      action: widget.action,
      settings: _settings,
      password: _safePasswordChoice,
    ).validationError;
  }

  void _finish(EmailSettingsRequest? request) {
    _password.clear();
    _closing = true;
    Navigator.of(context).pop(request);
  }

  void _submit() {
    EmailPasswordChange? password;
    try {
      password = !_test && _passwordAction == EmailPasswordAction.replace
          ? EmailPasswordChange.replace(_password.text)
          : _safePasswordChoice;
      final request = EmailSettingsRequest(
        inventory: widget.inventory,
        action: widget.action,
        settings: _test ? null : _settings,
        password: _test ? const EmailPasswordChange.keep() : password,
        recipient: _test ? _recipient.text : null,
      );
      final error = request.validationError ?? password.validationError;
      if (error != null) {
        password.dispose();
        _password.clear();
        setState(() => _error = error);
        return;
      }
      _finish(request);
    } on Object {
      password?.dispose();
      _password.clear();
      setState(
        () => _error = 'The email input could not be accepted safely. New password input was discarded; check the fields again.',
      );
    }
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

  Widget _field(
    String key,
    String label,
    TextEditingController controller, {
    bool secret = false,
    bool number = false,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextField(
      key: Key(key),
      controller: controller,
      obscureText: secret,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      autofillHints: const [],
      minLines: 1,
      maxLines: secret ? 1 : 3,
      maxLength: secret ? 1024 : 320,
      keyboardType: secret
          ? TextInputType.visiblePassword
          : number
          ? TextInputType.number
          : TextInputType.text,
      decoration: InputDecoration(labelText: label),
      onChanged: (_) => setState(() => _error = null),
    ),
  );
  @override
  Widget build(BuildContext context) {
    if (ModalRoute.isCurrentOf(context) == false && !_closing && !_expired) {
      _expired = true;
      ref.read(emailSettingsControllerProvider.notifier).abandonRoute();
      // Authorization expires synchronously; clear every editing buffer after
      // this build so EditableText is not notified during its teardown.
      scheduleMicrotask(() {
        if (!mounted) return;
        for (final field in _fields) {
          field.clear();
        }
      });
    }
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(emailSettingsInventoryProvider, (_, next) {
      if (next.isLoading || !identical(widget.inventory, next.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(emailSettingsInventoryProvider);
    final current =
        !_expired &&
        !_closing &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(inventory.asData?.value, widget.inventory);
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('email-editor-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? _test
                          ? 'One test-email recipient'
                          : 'Edit SMTP configuration'
                    : 'Email editor expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous values are hidden and new password input was cleared. Reload configuration before editing again.',
                )
              else ...[
                Text(widget.session.endpoint!),
                if (_test) ...[
                  const Text(
                    'Use saved settings only. No settings are changed by this test; no custom subject, body, attachments or extra recipients can be entered.',
                  ),
                  _field(
                    'email-recipient',
                    'One recipient email address',
                    _recipient,
                  ),
                  Text(
                    'Saved From: ${widget.inventory.config.settings.fromName} <${widget.inventory.config.settings.fromEmail}>',
                  ),
                  const Text(
                    'The generated subject discloses the NAS hostname/domain and product name. Review and explicit transmission consent follow.',
                  ),
                ] else ...[
                  _field('email-from', 'From email address', _from),
                  _field('email-from-name', 'From display name', _name),
                  _field(
                    'email-host',
                    'SMTP hostname or IP address (no URL)',
                    _host,
                  ),
                  _field('email-port', 'SMTP port', _port, number: true),
                  const SizedBox(height: 12),
                  const Text('SMTP transport'),
                  if (_security == EmailSecurity.plain)
                    const Text(
                      'Saved transport is PLAIN. Choose TLS or SSL explicitly before saving.',
                    ),
                  for (final security in [EmailSecurity.tls, EmailSecurity.ssl])
                    Semantics(
                      checked: _security == security,
                      inMutuallyExclusiveGroup: true,
                      child: ListTile(
                        key: Key('email-security-${security.name}'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(emailSecurityLabel(security)),
                        trailing: Icon(
                          _security == security
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                        ),
                        onTap: () => setState(() {
                          _security = security;
                          _error = null;
                        }),
                      ),
                    ),
                  const Text(
                    'TLS/SSL configures encryption, not validated SMTP server identity. The app’s NAS certificate pin does not cover this connection.',
                  ),
                  CheckboxListTile(
                    key: const Key('email-auth'),
                    contentPadding: EdgeInsets.zero,
                    value: _auth,
                    onChanged: (value) => setState(() {
                      _auth = value ?? false;
                      _error = null;
                    }),
                    title: const Text('SMTP authentication'),
                  ),
                  _field('email-username', 'SMTP username', _username),
                  const Text(
                    'Saved password values are never loaded into this editor. Keep is not a masked placeholder. Disabling authentication while a password exists requires explicit Clear.',
                  ),
                  const Text('Saved password action'),
                  for (final action in EmailPasswordAction.values)
                    Semantics(
                      checked: _passwordAction == action,
                      inMutuallyExclusiveGroup: true,
                      child: ListTile(
                        key: Key('email-password-${action.name}'),
                        contentPadding: EdgeInsets.zero,
                        title: Text(switch (action) {
                          EmailPasswordAction.keep => 'Keep saved password',
                          EmailPasswordAction.replace =>
                            'Replace with new password',
                          EmailPasswordAction.clear => 'Clear saved password',
                        }),
                        trailing: Icon(
                          _passwordAction == action
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                        ),
                        onTap: () => setState(() {
                          _passwordAction = action;
                          _password.clear();
                          _error = null;
                        }),
                      ),
                    ),
                  if (_passwordAction == EmailPasswordAction.replace)
                    _field(
                      'email-new-password',
                      'New write-only SMTP password',
                      _password,
                      secret: true,
                    ),
                  if (_passwordAction == EmailPasswordAction.clear)
                    const Text(
                      'Clear deletes the saved password. It is not a request to keep an existing masked value. A separate confirmation is required in review.',
                    ),
                  const Text(
                    'New password input is cleared at handoff, cancellation, backgrounding or connection changes. In-memory clearing is best effort; the app never stores it in provider state or displays it in the review.',
                  ),
                ],
                if (_error ?? _validation case final String error)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 12),
                    child: Text(
                      error,
                      key: const Key('email-editor-validation'),
                    ),
                  ),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('email-editor-cancel'),
                    onPressed: () => _finish(null),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('email-editor-review'),
                    onPressed: current && _validation == null ? _submit : null,
                    child: const Text('Review — nothing sent yet'),
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
