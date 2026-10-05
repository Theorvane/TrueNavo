import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'notification_providers_controller.dart';

String notificationProvidersActionLabel(NotificationProvidersAction action) =>
    switch (action) {
      NotificationProvidersAction.create => 'Create disabled provider',
      NotificationProvidersAction.replace => 'Replace disabled configuration',
      NotificationProvidersAction.enable => 'Enable provider',
      NotificationProvidersAction.disable => 'Disable provider',
      NotificationProvidersAction.delete => 'Delete disabled provider',
    };
const providerExternalWarning =
    'Enabling authorizes ongoing external disclosure of full formatted alerts and system identifiers to this reviewed destination. Cleared alerts may resolve external incidents. The app’s NAS certificate pin does not secure provider traffic; redirects, subscriptions and receiver ownership are not verified. Delivery, retries and backlog replay are not guaranteed.';
const providerNoRecallWarning =
    'Disabling or deleting can remove an important notification path. It cannot recall prior messages, stop in-flight work, resolve already-open incidents or globally mute independent notification services.';
String notificationProvidersImpact(NotificationProvidersAction action) =>
    switch (action) {
      NotificationProvidersAction.create => 'Creates a disabled row with the complete provider configuration and freshly entered credentials. This does not test or enable delivery.',
      NotificationProvidersAction.replace => 'Replaces every compiled setting and credential of this disabled provider. No omitted credential is preserved and the provider type cannot change. The full required envelope explicitly stays disabled.',
      NotificationProvidersAction.enable => providerExternalWarning,
      _ => providerNoRecallWarning,
    };

class NotificationProvidersReviewDialog extends ConsumerStatefulWidget {
  const NotificationProvidersReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final NotificationProvidersReview review;
  @override
  ConsumerState<NotificationProvidersReviewDialog> createState() =>
      _NotificationProvidersReviewDialogState();
}

class _NotificationProvidersReviewDialogState
    extends ConsumerState<NotificationProvidersReviewDialog> {
  final _target = TextEditingController();
  bool _unencrypted = false,
      _impact = false,
      _specific = false,
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
    ref.read(notificationProvidersControllerProvider.notifier).expireContext();
    setState(() {
      _expired = true;
      _unencrypted = false;
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
      ref.read(notificationProvidersControllerProvider.notifier).abandonRoute();
      scheduleMicrotask(() {
        if (mounted) _target.clear();
      });
    }
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(notificationProvidersInventoryProvider, (_, next) {
      if (next.isLoading ||
          !identical(widget.review.request.inventory, next.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(notificationProvidersInventoryProvider),
        state = ref.watch(notificationProvidersControllerProvider);
    final current =
        !_expired &&
        !_closing &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(inventory.asData?.value, widget.review.request.inventory) &&
        ref
            .read(notificationProvidersControllerProvider.notifier)
            .isReviewCurrent(widget.review);
    final action = widget.review.action;
    final specific = switch (action) {
      NotificationProvidersAction.enable => 'I independently checked this destination and authorize external alert disclosure and incident effects.',
      NotificationProvidersAction.disable ||
      NotificationProvidersAction.delete => 'I understand this cannot recall messages, resolve incidents or stop independent delivery.',
      _ => null,
    };
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('provider-review-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? 'Review ${notificationProvidersActionLabel(action).toLowerCase()}'
                    : 'Provider review expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous server details are hidden. Reload configuration and begin a new review.',
                )
              else ...[
                SelectableText(widget.review.endpoint),
                const SizedBox(height: 12),
                Text('Provider: ${widget.review.request.provider!.label}'),
                Text(
                  'Name: ${widget.review.request.service?.name ?? 'Not configured'} → ${widget.review.request.settings?.name ?? (action == NotificationProvidersAction.delete ? 'Removed' : widget.review.request.service!.name)}',
                ),
                Text(
                  'Threshold: ${(widget.review.request.settings?.level ?? widget.review.request.service!.level).name.toUpperCase()}',
                ),
                Text(
                  'Configured enabled after change: ${action == NotificationProvidersAction.enable}',
                ),
                const SizedBox(height: 12),
                const Text('Reviewed destination'),
                SelectableText(widget.review.destinationSummary),
                for (final field in widget.review.publicFields.entries)
                  Text('${field.key}: ${field.value}'),
                Text(
                  widget.review.request.credentials == null
                      ? 'Credentials preserved privately; values and secret URLs are never displayed.'
                      : 'Every credential is a new replacement. Values and secret URLs are never displayed.',
                ),
                const SizedBox(height: 12),
                Text(notificationProvidersImpact(action)),
                const SizedBox(height: 12),
                const Text(
                  'A configuration write may precede a later error. Configuration verification is not proof of notification delivery. No provider test, automatic retry or polling is offered.',
                ),
                if (widget.review.warnings.isNotEmpty)
                  ExpansionTile(
                    key: const Key('provider-review-details'),
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
                  key: const Key('provider-confirm-target'),
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
                  key: const Key('provider-confirm-impact'),
                  contentPadding: EdgeInsets.zero,
                  value: _impact,
                  onChanged: (value) =>
                      setState(() => _impact = value ?? false),
                  title: const Text(
                    'I accept this configuration change and its provider effects.',
                  ),
                ),
                if (specific != null)
                  CheckboxListTile(
                    key: const Key('provider-confirm-specific'),
                    contentPadding: EdgeInsets.zero,
                    value: _specific,
                    onChanged: (value) =>
                        setState(() => _specific = value ?? false),
                    title: Text(specific),
                  ),
              ],
              if (current &&
                  action == NotificationProvidersAction.enable &&
                  widget.review.unencrypted)
                CheckboxListTile(
                  key: const Key('provider-confirm-unencrypted'),
                  contentPadding: EdgeInsets.zero,
                  value: _unencrypted,
                  onChanged: (value) =>
                      setState(() => _unencrypted = value ?? false),
                  title: const Text(
                    'I explicitly accept sending credentials and alert data without encryption through this provider.',
                  ),
                ),
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('provider-review-cancel'),
                    onPressed: () => _finish(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('provider-confirm-submit'),
                    style: action == NotificationProvidersAction.delete
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
                            (action != NotificationProvidersAction.enable ||
                                !widget.review.unencrypted ||
                                _unencrypted) &&
                            _target.text == widget.review.target
                        ? () => _finish(true)
                        : null,
                    child: Text(notificationProvidersActionLabel(action)),
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
