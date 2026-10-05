import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../admin/admin_schema_form.dart';
import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'apps_controller.dart';
import 'apps_page.dart';

/// Only reviewed, explicitly selected scalar leaves can be changed. The page
/// never receives the stored raw configuration or existing secret values.
class AppConfigPage extends ConsumerStatefulWidget {
  const AppConfigPage({required this.session, required this.app, super.key});
  final AuthenticatedSession session;
  final InstalledApp app;

  @override
  ConsumerState<AppConfigPage> createState() => _AppConfigPageState();
}

class _AppConfigPageState extends ConsumerState<AppConfigPage> {
  AppConfigReview? _boundReview;
  final _selected = <String>{};
  final _forms = <String, GlobalKey<AdminSchemaFormState>>{};
  final _parameters = <String, List<AdminParameter>>{};
  String _search = '';
  String? _error;
  bool _reviewing = false;
  bool _submitted = false;

  void _clear() {
    _selected.clear();
    _forms.clear();
    _parameters.clear();
    _boundReview = null;
    _error = null;
  }

  @override
  Widget build(BuildContext context) {
    final current = identical(
      widget.session,
      ref.watch(dashboardActiveSessionProvider),
    );
    ref.listen(dashboardActiveSessionProvider, (_, next) {
      if (!identical(widget.session, next)) {
        for (final form in _forms.values) {
          form.currentState?.clearSensitiveValues();
        }
        _clear();
      }
    });
    final operation = ref.watch(appsControllerProvider);
    final enabled =
        current &&
        !_reviewing &&
        !_submitted &&
        !operation.locked &&
        widget.session.availableMethodNames.contains('app.update');
    return Scaffold(
      appBar: AppBar(title: const Text('Application settings')),
      body: SafeArea(
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 900),
            child: ListView(
              padding: const EdgeInsets.all(20),
              children: [
                if (!current)
                  const TdPanel(
                    title: 'Connection changed',
                    child: Text(
                      'Return to the application inventory and reopen settings for the current authenticated server. No old configuration is shown.',
                    ),
                  )
                else ...[
                  Text(widget.app.name, style: TdTypography.titleLarge),
                  const SizedBox(height: 8),
                  Text(
                    '${widget.session.endpoint}\nInstalled version · ${widget.app.version}',
                  ),
                  const SizedBox(height: 20),
                  const AppsOperationBanner(),
                  if (_submitted)
                    TdPanel(
                      title: 'This review has been used',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'The operation status above tracks the result. Return to the inventory and reload settings before making another change. No action is automatically repeated.',
                          ),
                          const SizedBox(height: 12),
                          OutlinedButton(
                            onPressed: () => Navigator.of(context).pop(),
                            child: const Text('Return to applications'),
                          ),
                        ],
                      ),
                    )
                  else
                    ref
                        .watch(appConfigReviewProvider(widget.app))
                        .when(
                          loading: () => const LinearProgressIndicator(),
                          error: (_, _) => TdPanel(
                            title: 'Settings unavailable',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'The current configuration could not be loaded safely. No change was sent. If another operation changed this application, return and reload the inventory.',
                                ),
                                const SizedBox(height: 12),
                                TextButton(
                                  onPressed: _reviewing
                                      ? null
                                      : () => ref.invalidate(
                                          appConfigReviewProvider(widget.app),
                                        ),
                                  child: const Text('Retry read'),
                                ),
                              ],
                            ),
                          ),
                          data: (review) => _editor(review, enabled: enabled),
                        ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _editor(AppConfigReview review, {required bool enabled}) {
    if (!identical(review, _boundReview)) {
      _clear();
      _boundReview = review;
    }
    final schema = review.schema;
    final visible = schema.fields.where(
      (field) =>
          _selected.contains(field.id) ||
          '${field.label} ${field.path.join(' ')}'.toLowerCase().contains(
            _search,
          ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TdPanel(
          title: 'Change only what you select',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Existing secrets stay hidden. Select the settings you want to change, then compare before applying.',
              ),
              Material(
                type: MaterialType.transparency,
                child: ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Safety and compatibility'),
                  childrenPadding: const EdgeInsets.only(bottom: 12),
                  expandedCrossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      'This client preserves unselected settings and stored secrets in the submitted configuration and does not fill installation defaults. TrueNAS still validates the complete configuration; unexpected readback stays unverified. Lists, storage, permissions, protected values and conditional selectors need dedicated editors and remain locked.',
                    ),
                    for (final warning in review.warnings)
                      Padding(
                        padding: const EdgeInsets.only(top: 8),
                        child: Text(warning),
                      ),
                  ],
                ),
              ),
              if (!widget.session.availableMethodNames.contains('app.update'))
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'This account does not advertise application updates. Settings are view-only.',
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        if (!schema.supported)
          TdPanel(
            title: 'Configuration changes unavailable',
            child: Text(
              schema.blockedReason ?? 'This application needs a specialized configuration workflow.',
            ),
          ),
        const SizedBox(height: 16),
        TextField(
          key: const Key('app-config-search'),
          enabled: !_reviewing,
          decoration: const InputDecoration(
            labelText: 'Find a setting',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (value) =>
              setState(() => _search = value.trim().toLowerCase()),
        ),
        const SizedBox(height: 16),
        Text(
          '${_selected.length} selected changes · ${schema.fields.length} settings',
          style: TdTypography.metadata,
        ),
        const SizedBox(height: 12),
        if (visible.isEmpty) const Text('No settings match this search.'),
        for (final field in visible)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _field(field, enabled: enabled && schema.supported),
          ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 12),
            child: Text(_error!),
          ),
        FilledButton.icon(
          key: const Key('app-config-review'),
          onPressed: enabled && schema.supported && _selected.isNotEmpty
              ? () => _review(review)
              : null,
          icon: const Icon(Icons.fact_check_outlined),
          label: const Text('Review configuration changes'),
        ),
      ],
    );
  }

  Widget _field(AppConfigField field, {required bool enabled}) {
    final selected = _selected.contains(field.id);
    final changeable = field.editable && !field.secret;
    return TdPanel(
      title: field.label,
      description: field.path.join(' › '),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Current · ${_currentText(field)}'),
          if (field.blockedReason != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(field.blockedReason!),
            ),
          if (changeable) ...[
            Material(
              type: MaterialType.transparency,
              child: CheckboxListTile(
                key: ValueKey('app-config-select-${field.id}'),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                title: const Text('Change this setting'),
                value: selected,
                onChanged: enabled
                    ? (checked) => setState(() {
                        _error = null;
                        if (checked == true) {
                          _selected.add(field.id);
                          _forms[field.id] = GlobalKey<AdminSchemaFormState>();
                          _parameters[field.id] = [
                            AdminParameter(
                              name: 'new_value',
                              schema: AdminSchema.fromJson({
                                ...field.schema.raw,
                                if (field.present)
                                  'default': field.currentValue,
                              }),
                              required: true,
                            ),
                          ];
                        } else {
                          _selected.remove(field.id);
                          _forms.remove(field.id);
                          _parameters.remove(field.id);
                        }
                      })
                    : null,
              ),
            ),
            if (selected)
              AdminSchemaForm(
                key: _forms[field.id],
                parameters: _parameters[field.id]!,
                enabled: enabled,
              ),
          ] else ...[
            const SizedBox(height: 8),
            const Wrap(
              spacing: 8,
              children: [
                Icon(Icons.lock_outline, size: 18),
                Text('Preserved · not editable here'),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _review(AppConfigReview review) async {
    final patches = <AppConfigPatch>[];
    final lines = <String>[];
    var characters = 0;
    for (final field in review.schema.fields.where(
      (field) => _selected.contains(field.id),
    )) {
      final values = _forms[field.id]?.currentState?.validateAndBuild();
      if (values == null || values.length != 1) {
        setState(
          () => _error =
              'Check every selected field before review. No change was sent.',
        );
        return;
      }
      patches.add(AppConfigPatch(fieldId: field.id, value: values.single));
      final line =
          '${field.path.join(' › ')}\n${_currentText(field)} → ${jsonEncode(values.single)}';
      characters += line.length;
      if (characters > 16000 || lines.length >= 64) {
        setState(
          () => _error = 'This change exceeds the review limit. Select fewer settings. No change was sent.',
        );
        return;
      }
      lines.add(line);
    }
    final error = review.schema.validatePatches(patches);
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _reviewing = true;
      _error = null;
    });
    var confirmed = false;
    try {
      confirmed = await confirmAppOperation(
        context,
        title: 'Confirm configuration changes',
        expectedSession: widget.session,
        endpoint: widget.session.endpoint!,
        target: widget.app.name,
        warning:
            'Updating settings can recreate application resources and interrupt connected users. '
            'Only the selected changes below are requested. Unchanged settings and secrets are preserved in the submitted values. '
            'TrueNAS validates the full configuration; unexpected readback stays unverified. '
            'No configuration backup or rollback is created. Avoid concurrent edits in other clients.',
        reviewLines: lines,
      );
    } finally {
      if (mounted) setState(() => _reviewing = false);
    }
    if (!confirmed ||
        !mounted ||
        !identical(widget.session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    setState(() {
      _submitted = true;
      _clear();
    });
    await ref
        .read(appsControllerProvider.notifier)
        .updateConfiguration(
          widget.session,
          AppConfigUpdateRequest(review: review, patches: patches),
        );
  }

  String _currentText(AppConfigField field) => field.secret
      ? '[protected value]'
      : !field.present
      ? '[not configured]'
      : !field.valueVisible
      ? '[value retained; not displayed]'
      : field.schema.type == 'object' || field.schema.type == 'array'
      ? '[managed structure]'
      : jsonEncode(field.currentValue);
}
