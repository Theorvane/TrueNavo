import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'notification_providers_controller.dart';
import 'notification_providers_review.dart';

class NotificationProvidersEditorDialog extends ConsumerStatefulWidget {
  const NotificationProvidersEditorDialog({
    required this.session,
    required this.inventory,
    required this.action,
    this.service,
    super.key,
  });
  final AuthenticatedSession session;
  final NotificationProvidersInventory inventory;
  final NotificationProvidersAction action;
  final NotificationProviderSnapshot? service;
  @override
  ConsumerState<NotificationProvidersEditorDialog> createState() =>
      _NotificationProvidersEditorDialogState();
}

class _NotificationProvidersEditorDialogState
    extends ConsumerState<NotificationProvidersEditorDialog> {
  final _name = TextEditingController();
  final _fields = <String, TextEditingController>{};
  late NotificationProviderType _provider;
  late AlertDeliveryLevel _level;
  bool _expired = false, _closing = false;
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    _provider = widget.service?.provider ?? NotificationProviderType.slack;
    _level = widget.service?.level ?? AlertDeliveryLevel.warning;
    _name.text = widget.service?.name ?? '';
    _initializeFields();
    final initial = WidgetsBinding.instance.lifecycleState;
    _expired = initial != null && initial != AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) _expire();
      },
    );
  }

  void _initializeFields() {
    for (final field in notificationProviderFields(_provider)) {
      _fields[field.key] = TextEditingController(
        text: field.initialValue is List ? '' : '${field.initialValue}',
      );
    }
  }

  void _clear() {
    _name.clear();
    for (final field in _fields.values) {
      field.clear();
    }
  }

  void _switch(NotificationProviderType value) {
    if (_provider == value) return;
    _clear();
    for (final field in _fields.values) {
      field.dispose();
    }
    _fields.clear();
    setState(() {
      _provider = value;
      _initializeFields();
    });
  }

  void _expire() {
    if (_expired || _closing || !mounted) return;
    ref.read(notificationProvidersControllerProvider.notifier).expireContext();
    setState(() {
      _expired = true;
      _clear();
    });
  }

  NotificationProvidersRequest _request() {
    final values = <String, Object?>{}, secrets = <String, String>{};
    for (final field in notificationProviderFields(_provider)) {
      final text = _fields[field.key]!.text;
      if (field.secret) {
        secrets[field.key] = text;
      } else {
        values[field.key] = switch (field.kind) {
          NotificationFieldKind.integer => int.tryParse(text) ?? 0,
          NotificationFieldKind.integerList =>
            text.isEmpty
                ? <int>[]
                : text
                      .split(',')
                      .map((s) => int.tryParse(s.trim()) ?? 0)
                      .toList(),
          _ => text,
        };
      }
    }
    return NotificationProvidersRequest(
      inventory: widget.inventory,
      action: widget.action,
      service: widget.service,
      settings: NotificationProviderSettings(
        provider: _provider,
        name: _name.text,
        level: _level,
        fields: values,
      ),
      credentials: NotificationProviderCredentials(
        provider: _provider,
        values: secrets,
      ),
    );
  }

  String? get _validation {
    final request = _request();
    try {
      return request.validationError;
    } finally {
      request.credentials!.dispose();
    }
  }

  void _finish(NotificationProvidersRequest? request) {
    _closing = true;
    _clear();
    Navigator.of(context).pop(request);
  }

  void _submit() {
    final request = _request();
    if (request.validationError != null) {
      request.credentials!.dispose();
      return;
    }
    _finish(request);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _clear();
    _name.dispose();
    for (final field in _fields.values) {
      field.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (ModalRoute.isCurrentOf(context) == false && !_closing && !_expired) {
      _expired = true;
      ref.read(notificationProvidersControllerProvider.notifier).abandonRoute();
      scheduleMicrotask(() {
        if (mounted) _clear();
      });
    }
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(notificationProvidersInventoryProvider, (_, next) {
      if (next.isLoading || !identical(widget.inventory, next.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(notificationProvidersInventoryProvider);
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
          key: const Key('provider-editor-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? notificationProvidersActionLabel(widget.action)
                    : 'Provider editor expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'All prior input was cleared. Reload and start a new review.',
                )
              else ...[
                const Text(
                  'This stores disabled configuration only. Every credential must be entered freshly; nothing is preserved implicitly or tested. Stored secrets never populate this form.',
                ),
                if (widget.action == NotificationProvidersAction.create) ...[
                  const SizedBox(height: 12),
                  const Text('Provider — changing this clears every input'),
                  for (final provider in NotificationProviderType.values)
                    Semantics(
                      checked: _provider == provider,
                      inMutuallyExclusiveGroup: true,
                      child: ListTile(
                        key: Key('provider-kind-${provider.name}'),
                        contentPadding: EdgeInsets.zero,
                        leading: Icon(
                          _provider == provider
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                        ),
                        title: Text(provider.label),
                        onTap: () => _switch(provider),
                      ),
                    ),
                ] else
                  Text(
                    'Fixed provider: ${_provider.label} — conversion is not supported',
                  ),
                TextField(
                  key: const Key('provider-name'),
                  controller: _name,
                  maxLength: 120,
                  minLines: 1,
                  maxLines: 3,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: 'Service name'),
                  onChanged: (_) => setState(() {}),
                ),
                for (final field in notificationProviderFields(_provider))
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: TextField(
                      key: Key('provider-field-${field.key}'),
                      controller: _fields[field.key],
                      obscureText: field.secret,
                      minLines: 1,
                      maxLines: field.secret ? 1 : 3,
                      maxLength: field.secret
                          ? 1024
                          : field.kind == NotificationFieldKind.integerList
                          ? 640
                          : 256,
                      autocorrect: false,
                      enableSuggestions: false,
                      enableIMEPersonalizedLearning: false,
                      autofillHints: const [],
                      keyboardType: field.secret
                          ? TextInputType.visiblePassword
                          : field.kind == NotificationFieldKind.integer
                          ? TextInputType.number
                          : TextInputType.text,
                      decoration: InputDecoration(labelText: field.label),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                if (_provider.unencrypted)
                  const Text(
                    'Unencrypted provider: enabling later can expose credentials and alert data. A separate risk consent will be required. InfluxDB port is fixed to 8086; SNMP supports v2c only.',
                  ),
                const SizedBox(height: 12),
                const Text('Minimum alert severity'),
                for (final level in AlertDeliveryLevel.values)
                  Semantics(
                    checked: _level == level,
                    inMutuallyExclusiveGroup: true,
                    child: ListTile(
                      key: Key('provider-level-${level.name}'),
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
                if (_validation != null) Text(_validation!),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('provider-editor-cancel'),
                    onPressed: () => _finish(null),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('provider-editor-review'),
                    onPressed: current && _validation == null ? _submit : null,
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
