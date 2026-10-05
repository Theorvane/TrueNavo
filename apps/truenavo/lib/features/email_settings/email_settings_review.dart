import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'email_settings_controller.dart';

String emailSecurityLabel(EmailSecurity security) => switch (security) {
  EmailSecurity.plain => 'Plain SMTP — insecure',
  EmailSecurity.tls => 'STARTTLS configured',
  EmailSecurity.ssl => 'Implicit TLS configured',
};
const emailSecurityWarning =
    'TLS/SSL in this TrueNAS SMTP path does not authenticate the SMTP server certificate or hostname. The app’s NAS certificate pin does not protect the SMTP connection. Confirm the destination and accept the risk of exposing message contents or authentication credentials.';
const emailQueueWarning =
    'Saving settings does not itself send a test. Previously queued messages can later retry using the newly saved SMTP server and From address. Their contents and recipients cannot be inspected here. The test’s queue=false setting neither inspects nor clears an existing mail queue. A settings write can succeed before later Gmail-client or alert-cleanup errors.';
const emailTestWarning =
    'This sends one fixed benign test message to the single explicit recipient, using saved configuration only. The server may authenticate to the saved SMTP destination. The recipient and SMTP infrastructure can see the From name/address, recipient, and a subject that automatically includes the TrueNAS product and NAS hostname/domain. No attachments, CC, custom content or configuration overrides are included. queue=false applies only to this new test. SMTP job success is not recipient delivery or inbox placement.';

class EmailSettingsDiff extends StatelessWidget {
  const EmailSettingsDiff({required this.request, super.key});
  final EmailSettingsRequest request;
  @override
  Widget build(BuildContext context) {
    final before = request.inventory.config.settings;
    if (request.action == EmailSettingsAction.test) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text('Saved SMTP: ${before.outgoingServer}:${before.port}'),
          Text(emailSecurityLabel(before.security)),
          Text('From: ${before.fromName} <${before.fromEmail}>'),
          Text('To: ${request.recipient}'),
          const Text(
            'Subject disclosure: TrueNAS product and NAS hostname/domain are added automatically.',
          ),
          const Text(
            'Fixed message · one recipient · no attachments · queue=false',
          ),
        ],
      );
    }
    final after = request.settings!;
    final values = <String, (String, String)>{
      'From address': (before.fromEmail, after.fromEmail),
      'From name': (before.fromName, after.fromName),
      'SMTP server': (before.outgoingServer, after.outgoingServer),
      'SMTP port': ('${before.port}', '${after.port}'),
      'Transport': (
        emailSecurityLabel(before.security),
        emailSecurityLabel(after.security),
      ),
      'SMTP authentication': ('${before.smtpAuth}', '${after.smtpAuth}'),
      'Username': (before.username, after.username),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (final entry in values.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text(
              '${entry.key}: ${entry.value.$1.isEmpty ? 'Empty' : entry.value.$1} → ${entry.value.$2.isEmpty ? 'Empty' : entry.value.$2}',
            ),
          ),
        Text(
          'Password action: ${switch (request.password.action) {
            EmailPasswordAction.keep => 'Kept private; not displayed or included again in this configuration patch',
            EmailPasswordAction.replace => 'Replace with new write-only input; its value is never shown in this review',
            EmailPasswordAction.clear => 'Explicitly clear the saved password',
          }}',
        ),
        if (request.password.action == EmailPasswordAction.keep &&
            before.outgoingServer != after.outgoingServer)
          const Text(
            'Keeping the password while changing the SMTP destination can send the retained credentials to the new server during later or previously queued email delivery.',
          ),
      ],
    );
  }
}

class EmailSettingsReviewDialog extends ConsumerStatefulWidget {
  const EmailSettingsReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final EmailSettingsReview review;
  @override
  ConsumerState<EmailSettingsReviewDialog> createState() =>
      _EmailSettingsReviewDialogState();
}

class _EmailSettingsReviewDialogState
    extends ConsumerState<EmailSettingsReviewDialog> {
  final _target = TextEditingController();
  bool _contact = false,
      _impact = false,
      _clear = false,
      _expired = false,
      _closing = false;
  late final AppLifecycleListener _lifecycle;
  late final Timer _expiry;
  @override
  void initState() {
    super.initState();
    final initial = WidgetsBinding.instance.lifecycleState;
    _expired = initial != null && initial != AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) _expire();
      },
    );
    _expiry = Timer(const Duration(minutes: 5), _expire);
  }

  void _expire() {
    if (_expired || _closing || !mounted) return;
    ref.read(emailSettingsControllerProvider.notifier).expireContext();
    setState(() {
      _expired = true;
      _contact = false;
      _impact = false;
      _clear = false;
      _target.clear();
    });
  }

  void _finish(bool value) {
    _closing = true;
    Navigator.of(context).pop(value);
  }

  @override
  void dispose() {
    _expiry.cancel();
    _lifecycle.dispose();
    _target.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (ModalRoute.isCurrentOf(context) == false && !_closing && !_expired) {
      _expired = true;
      ref.read(emailSettingsControllerProvider.notifier).abandonRoute();
    }
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(emailSettingsInventoryProvider, (_, next) {
      if (next.isLoading ||
          !identical(widget.review.request.inventory, next.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(emailSettingsInventoryProvider),
        state = ref.watch(emailSettingsControllerProvider);
    final current =
        !_expired &&
        !_closing &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(inventory.asData?.value, widget.review.request.inventory) &&
        ref
            .read(emailSettingsControllerProvider.notifier)
            .isReviewCurrent(widget.review);
    final test = widget.review.action == EmailSettingsAction.test,
        clear =
            widget.review.request.password.action == EmailPasswordAction.clear;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('email-review-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? test
                          ? 'Review one test email'
                          : 'Review SMTP configuration'
                    : 'Email review expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous server details are hidden and new password input is discarded. Reload configuration and review again.',
                )
              else ...[
                SelectableText(widget.review.endpoint),
                const SizedBox(height: 12),
                EmailSettingsDiff(request: widget.review.request),
                const SizedBox(height: 12),
                const Text(emailSecurityWarning),
                const SizedBox(height: 12),
                Text(test ? emailTestWarning : emailQueueWarning),
                if (widget.review.warnings.isNotEmpty)
                  ExpansionTile(
                    key: const Key('email-review-details'),
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Additional server / adapter details'),
                    expandedCrossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      for (final warning in widget.review.warnings)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(warning),
                        ),
                    ],
                  ),
                const SizedBox(height: 12),
                const Text(
                  'This single-use review expires after five minutes. Type the full target exactly. Nothing is retried or resent automatically.',
                ),
                SelectableText(widget.review.target),
                TextField(
                  key: const Key('email-confirm-target'),
                  controller: _target,
                  minLines: 1,
                  maxLines: 8,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Exact confirmation target',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                CheckboxListTile(
                  key: const Key('email-confirm-contact'),
                  contentPadding: EdgeInsets.zero,
                  value: _contact,
                  onChanged: (value) =>
                      setState(() => _contact = value ?? false),
                  title: const Text(
                    'I approve this SMTP destination and accept credential exposure risks.',
                  ),
                ),
                CheckboxListTile(
                  key: const Key('email-confirm-impact'),
                  contentPadding: EdgeInsets.zero,
                  value: _impact,
                  onChanged: (value) =>
                      setState(() => _impact = value ?? false),
                  title: Text(
                    test
                        ? 'I authorize one message and its sender, recipient and NAS-name disclosure.'
                        : 'I accept settings side effects and changes to previously queued mail.',
                  ),
                ),
                if (clear)
                  CheckboxListTile(
                    key: const Key('email-confirm-clear'),
                    contentPadding: EdgeInsets.zero,
                    value: _clear,
                    onChanged: (value) =>
                        setState(() => _clear = value ?? false),
                    title: const Text(
                      'I explicitly authorize deleting the saved SMTP password.',
                    ),
                  ),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('email-review-cancel'),
                    onPressed: () => _finish(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('email-confirm-submit'),
                    onPressed:
                        current &&
                            !state.locked &&
                            _contact &&
                            _impact &&
                            (!clear || _clear) &&
                            _target.text == widget.review.target
                        ? () => _finish(true)
                        : null,
                    child: Text(
                      test
                          ? 'Send one test using saved settings'
                          : 'Save reviewed SMTP settings once',
                    ),
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
