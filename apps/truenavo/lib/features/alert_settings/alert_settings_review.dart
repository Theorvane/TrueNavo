import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'alert_settings_controller.dart';

String alertSettingsActionLabel(AlertSettingsAction action) => switch (action) {
  AlertSettingsAction.createEmail => 'Create disabled email service',
  AlertSettingsAction.editEmail => 'Edit disabled email service',
  AlertSettingsAction.enableEmail => 'Enable email service',
  AlertSettingsAction.disableEmail => 'Disable email service',
  AlertSettingsAction.deleteEmail => 'Delete disabled email service',
};

const alertDeliveryWarning =
    'Enabling permits external delivery of formatted alert HTML, including TrueNAS product, hostname and potentially sensitive current, new and cleared alert details. The server uses saved SMTP settings and default mail queue retries. TLS/SSL does not guarantee SMTP certificate or hostname verification; the app’s NAS certificate pin does not protect SMTP. Delivery timing and backlog replay are not guaranteed.';
const alertNoRecallWarning =
    'Disabling or deleting removes a notification path, possibly the last enabled Mail service. It cannot recall queued or in-flight messages. This is not a global mute: independent default alert mail and other notification services can continue.';
String alertSettingsImpact(AlertSettingsAction action) => switch (action) {
  AlertSettingsAction.createEmail => 'The Mail service is created disabled with one explicit recipient. This does not send a test or enable delivery. A separate review is required to enable it.',
  AlertSettingsAction.editEmail => 'Only a disabled Mail service can be edited. The server requires its full verified name, recipient, threshold and disabled flag; unchanged fields are preserved. Saving does not test or enable delivery.',
  AlertSettingsAction.enableEmail => alertDeliveryWarning,
  AlertSettingsAction.disableEmail ||
  AlertSettingsAction.deleteEmail => alertNoRecallWarning,
};

class AlertSettingsDiff extends StatelessWidget {
  const AlertSettingsDiff({required this.request, super.key});
  final AlertSettingsRequest request;
  @override
  Widget build(BuildContext context) {
    final before = request.service, after = request.settings;
    final deleting = request.action == AlertSettingsAction.deleteEmail;
    final enabled = request.action == AlertSettingsAction.enableEmail;
    final values = <String, (String, String)>{
      'Name': (
        before?.name ?? 'Not configured',
        deleting ? 'Removed' : after?.name ?? before!.name,
      ),
      'Provider': (
        before?.type ?? 'Not configured',
        deleting ? 'Removed' : 'Mail',
      ),
      'Recipient': (
        before == null
            ? 'Not configured'
            : before.usesAdministratorFallback
            ? 'Administrator fallback (legacy)'
            : before.recipient ?? 'Unavailable',
        deleting
            ? 'Removed'
            : after?.recipient ??
                  (before!.usesAdministratorFallback
                      ? 'Administrator fallback (legacy)'
                      : before.recipient ?? 'Unavailable'),
      ),
      'Threshold': (
        before?.level.name.toUpperCase() ?? 'Not configured',
        deleting
            ? 'Removed'
            : (after?.level ?? before!.level).name.toUpperCase(),
      ),
      'Enabled': (
        '${before?.enabled ?? false}',
        deleting ? 'Removed' : '$enabled',
      ),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (before != null) Text('Configured service ID: ${before.id}'),
        for (final entry in values.entries)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: Text('${entry.key}: ${entry.value.$1} → ${entry.value.$2}'),
          ),
      ],
    );
  }
}

class AlertSettingsReviewDialog extends ConsumerStatefulWidget {
  const AlertSettingsReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final AlertSettingsReview review;
  @override
  ConsumerState<AlertSettingsReviewDialog> createState() =>
      _AlertSettingsReviewDialogState();
}

class _AlertSettingsReviewDialogState
    extends ConsumerState<AlertSettingsReviewDialog> {
  final _target = TextEditingController();
  bool _impact = false, _specific = false, _expired = false, _closing = false;
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
    ref.read(alertSettingsControllerProvider.notifier).expireContext();
    setState(() {
      _expired = true;
      _impact = false;
      _specific = false;
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
      _impact = false;
      _specific = false;
      ref.read(alertSettingsControllerProvider.notifier).abandonRoute();
      scheduleMicrotask(() {
        if (mounted) _target.clear();
      });
    }
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(alertSettingsInventoryProvider, (_, next) {
      if (next.isLoading ||
          !identical(widget.review.request.inventory, next.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(alertSettingsInventoryProvider),
        state = ref.watch(alertSettingsControllerProvider);
    final current =
        !_expired &&
        !_closing &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(inventory.asData?.value, widget.review.request.inventory) &&
        ref
            .read(alertSettingsControllerProvider.notifier)
            .isReviewCurrent(widget.review);
    final action = widget.review.action;
    final specific = switch (action) {
      AlertSettingsAction.enableEmail => 'I authorize sensitive alert delivery to this recipient and accept SMTP destination and queued-retry risks.',
      AlertSettingsAction.disableEmail || AlertSettingsAction.deleteEmail => 'I understand this cannot recall mail or stop independent alert delivery.',
      _ => null,
    };
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('alert-review-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? 'Review ${alertSettingsActionLabel(action).toLowerCase()}'
                    : 'Notification-service review expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous server details are hidden. Reload configuration and begin a new review.',
                )
              else ...[
                SelectableText(widget.review.endpoint),
                const SizedBox(height: 12),
                AlertSettingsDiff(request: widget.review.request),
                const SizedBox(height: 12),
                Text(alertSettingsImpact(action)),
                const SizedBox(height: 12),
                const Text(
                  'A configuration write may precede a later error. Configuration verification is not proof of notification delivery. No provider test, automatic retry or polling is offered.',
                ),
                if (widget.review.warnings.isNotEmpty)
                  ExpansionTile(
                    key: const Key('alert-review-details'),
                    tilePadding: EdgeInsets.zero,
                    title: const Text('Additional server/adapter details'),
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
                  'This single-use review expires after five minutes. Type the full target exactly.',
                ),
                SelectableText(widget.review.target),
                TextField(
                  key: const Key('alert-confirm-target'),
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
                  key: const Key('alert-confirm-impact'),
                  contentPadding: EdgeInsets.zero,
                  value: _impact,
                  onChanged: (value) =>
                      setState(() => _impact = value ?? false),
                  title: const Text(
                    'I accept this configuration change and its notification-service effects.',
                  ),
                ),
                if (specific != null)
                  CheckboxListTile(
                    key: const Key('alert-confirm-specific'),
                    contentPadding: EdgeInsets.zero,
                    value: _specific,
                    onChanged: (value) =>
                        setState(() => _specific = value ?? false),
                    title: Text(specific),
                  ),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('alert-review-cancel'),
                    onPressed: () => _finish(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('alert-confirm-submit'),
                    style: action == AlertSettingsAction.deleteEmail
                        ? FilledButton.styleFrom(
                            backgroundColor: Theme.of(context)
                                .colorScheme
                                .error,
                            foregroundColor: Theme.of(context)
                                .colorScheme
                                .onError,
                          )
                        : null,
                    onPressed:
                        current &&
                            !state.locked &&
                            _impact &&
                            (specific == null || _specific) &&
                            _target.text == widget.review.target
                        ? () => _finish(true)
                        : null,
                    child: Text(alertSettingsActionLabel(action)),
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
