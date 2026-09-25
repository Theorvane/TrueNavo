import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'alert_settings_controller.dart';
import 'alert_settings_review.dart';

class AlertSettingsEditorDialog extends ConsumerStatefulWidget {
  const AlertSettingsEditorDialog({
    required this.session,
    required this.inventory,
    required this.action,
    this.service,
    super.key,
  });
  final AuthenticatedSession session;
  final AlertSettingsInventory inventory;
  final AlertSettingsAction action;
  final AlertServiceSnapshot? service;
  @override
  ConsumerState<AlertSettingsEditorDialog> createState() =>
      _AlertSettingsEditorDialogState();
}

class _AlertSettingsEditorDialogState
    extends ConsumerState<AlertSettingsEditorDialog> {
  late final TextEditingController _name, _recipient;
  late AlertDeliveryLevel _level;
  bool _expired = false, _closing = false;
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    _name = TextEditingController(text: widget.service?.name ?? '');
    _recipient = TextEditingController(text: widget.service?.recipient ?? '');
    _level = widget.service?.level ?? AlertDeliveryLevel.warning;
    final initial = WidgetsBinding.instance.lifecycleState;
    _expired = initial != null && initial != AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) _expire();
      },
    );
  }

  void _clear() {
    _name.clear();
    _recipient.clear();
  }

  void _expire() {
    if (_expired || _closing || !mounted) return;
    ref.read(alertSettingsControllerProvider.notifier).expireContext();
    setState(() {
      _expired = true;
      _clear();
    });
  }

  AlertSettingsRequest get _request => AlertSettingsRequest(
    inventory: widget.inventory,
    action: widget.action,
    service: widget.service,
    settings: EmailAlertServiceSettings(
      name: _name.text,
      recipient: _recipient.text,
      level: _level,
    ),
  );
  void _finish(AlertSettingsRequest? request) {
    _closing = true;
    _clear();
    Navigator.of(context).pop(request);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _clear();
    _name.dispose();
    _recipient.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (ModalRoute.isCurrentOf(context) == false && !_closing && !_expired) {
      _expired = true;
      ref.read(alertSettingsControllerProvider.notifier).abandonRoute();
      scheduleMicrotask(() {
        if (mounted) _clear();
      });
    }
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(alertSettingsInventoryProvider, (_, next) {
      if (next.isLoading || !identical(widget.inventory, next.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(alertSettingsInventoryProvider);
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
          key: const Key('alert-editor-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? alertSettingsActionLabel(widget.action)
                    : 'Notification-service editor expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous server fields were cleared. Reload configuration and begin again.',
                )
              else ...[
                Text(alertSettingsImpact(widget.action)),
                const SizedBox(height: 12),
                for (final field in [
                  (key: 'alert-name', label: 'Service name', controller: _name),
                  (
                    key: 'alert-recipient',
                    label: 'Single explicit recipient',
                    controller: _recipient,
                  ),
                ])
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextField(
                      key: Key(field.key),
                      controller: field.controller,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      autofillHints: const [],
                      minLines: 1,
                      maxLines: 3,
                      maxLength: 120,
                      decoration: InputDecoration(labelText: field.label),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                const Text(
                  'Blank recipients can target all local full administrators in legacy services. New or edited services require one explicit mailbox; no automatic fallback or provider test is used.',
                ),
                const SizedBox(height: 12),
                const Text('Minimum alert severity'),
                for (final level in AlertDeliveryLevel.values)
                  Semantics(
                    checked: _level == level,
                    inMutuallyExclusiveGroup: true,
                    child: ListTile(
                      key: Key('alert-level-${level.name}'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        _level == level
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text(level.name.toUpperCase()),
                      onTap: () => setState(() => _level = level),
                    ),
                  ),
                if (_request.validationError != null)
                  Text(_request.validationError!),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('alert-editor-cancel'),
                    onPressed: () => _finish(null),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('alert-editor-review'),
                    onPressed: current && _request.validationError == null
                        ? () => _finish(_request)
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
