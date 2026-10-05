import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'replication_controller.dart';

class ReplicationEditorDialog extends ConsumerStatefulWidget {
  const ReplicationEditorDialog({
    required this.session,
    required this.inventory,
    this.task,
    super.key,
  });
  final AuthenticatedSession session;
  final ReplicationInventory inventory;
  final ReplicationTask? task;
  @override
  ConsumerState<ReplicationEditorDialog> createState() =>
      _ReplicationEditorDialogState();
}

class _ReplicationEditorDialogState
    extends ConsumerState<ReplicationEditorDialog> {
  late final TextEditingController _name, _destination, _schema, _lifetime;
  String? _source;
  late String _retention, _unit;
  bool _enabled = true, _expired = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    final settings = widget.task?.settings;
    _name = TextEditingController(text: settings?.name ?? '');
    _destination = TextEditingController(text: settings?.destination ?? '');
    _schema = TextEditingController(
      text: settings?.namingSchema ?? 'auto-%Y-%m-%d_%H-%M',
    );
    _lifetime = TextEditingController(text: '${settings?.lifetimeValue ?? 2}');
    _source =
        widget.inventory.datasets.any(
          (dataset) => dataset.available && dataset.id == settings?.source,
        )
        ? settings?.source
        : null;
    _retention = settings?.retention ?? 'NONE';
    _unit = settings?.lifetimeUnit ?? 'WEEK';
    _enabled = settings?.enabled ?? true;
  }

  @override
  void dispose() {
    for (final controller in [_name, _destination, _schema, _lifetime]) {
      controller.dispose();
    }
    super.dispose();
  }

  void _expire() {
    if (_expired) return;
    setState(() {
      _expired = true;
      for (final controller in [_name, _destination, _schema, _lifetime]) {
        controller.clear();
      }
      _source = null;
      _error = null;
    });
  }

  void _submit() {
    final settings = ReplicationSettings(
      name: _name.text,
      source: _source ?? '',
      destination: _destination.text,
      namingSchema: _schema.text,
      retention: _retention,
      lifetimeValue: int.tryParse(_lifetime.text) ?? 0,
      lifetimeUnit: _unit,
      enabled: _enabled,
    );
    final request = ReplicationRequest(
      inventory: widget.inventory,
      action: widget.task == null
          ? ReplicationAction.create
          : ReplicationAction.update,
      task: widget.task,
      settings: settings,
    );
    final error = request.validationError;
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(settings);
  }

  @override
  Widget build(BuildContext context) {
    final currentSession = ref.watch(dashboardActiveSessionProvider);
    final inventory = ref.watch(replicationInventoryProvider);
    final locked = ref.watch(replicationControllerProvider).locked;
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (!identical(previous, next)) _expire();
    });
    ref.listen(replicationInventoryProvider, (_, next) {
      if (next.isLoading || !identical(next.asData?.value, widget.inventory)) {
        _expire();
      }
    });
    final current =
        !_expired &&
        identical(currentSession, widget.session) &&
        !inventory.isLoading &&
        identical(inventory.asData?.value, widget.inventory);
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 740),
        child: SingleChildScrollView(
          key: const Key('replication-editor-scroll'),
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          child: Padding(
            padding: const EdgeInsets.all(TdSpacing.component),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  current
                      ? (widget.task == null
                            ? 'Create local replication'
                            : 'Edit local replication')
                      : 'Editor is no longer current',
                  style: TdTypography.titleSmall,
                ),
                const SizedBox(height: TdSpacing.component),
                if (!current)
                  const Text(
                    'Previous server and dataset details are hidden. Close and reload. Nothing was saved.',
                  )
                else ...[
                  Text(widget.inventory.endpoint),
                  const Text(
                    'Single source · LOCAL PUSH · Manual · Non-recursive',
                  ),
                  if (widget.task != null && _source == null)
                    const Text(
                      'The original source is unavailable. Choose an available source explicitly; no replacement is selected automatically.',
                    ),
                  const SizedBox(height: TdSpacing.component),
                  TextField(
                    key: const Key('replication-name'),
                    controller: _name,
                    decoration: const InputDecoration(labelText: 'Task name'),
                  ),
                  const SizedBox(height: TdSpacing.related),
                  DropdownButtonFormField<String>(
                    key: const Key('replication-source'),
                    initialValue: _source,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Source dataset',
                    ),
                    hint: const Text('Choose a source'),
                    items: [
                      for (final dataset in widget.inventory.datasets.where(
                        (d) => d.available,
                      ))
                        DropdownMenuItem(
                          value: dataset.id,
                          child: Text(
                            dataset.id,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                    onChanged: (value) => setState(() => _source = value),
                  ),
                  const SizedBox(height: TdSpacing.related),
                  TextField(
                    key: const Key('replication-destination'),
                    controller: _destination,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Destination dataset',
                      helperText: 'Use an existing read-only dataset, or one new child below an available parent. Source and destination must be unrelated.',
                      helperMaxLines: 8,
                    ),
                  ),
                  const SizedBox(height: TdSpacing.related),
                  TextField(
                    key: const Key('replication-schema'),
                    controller: _schema,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Snapshot naming schema',
                      helperText: 'The source must have matching snapshots. Review checks the actual snapshot inventory.',
                      helperMaxLines: 5,
                    ),
                  ),
                  const SizedBox(height: TdSpacing.related),
                  DropdownButtonFormField<String>(
                    key: const Key('replication-retention'),
                    initialValue: _retention,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Destination retention',
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: 'NONE',
                        child: Text(
                          'NONE · Keep snapshots',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'SOURCE',
                        child: Text(
                          'SOURCE · Follow source',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      DropdownMenuItem(
                        value: 'CUSTOM',
                        child: Text(
                          'CUSTOM · Lifetime',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                    onChanged: (value) => setState(() => _retention = value!),
                  ),
                  if (_retention == 'CUSTOM') ...[
                    const SizedBox(height: TdSpacing.related),
                    TextField(
                      key: const Key('replication-lifetime'),
                      controller: _lifetime,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(
                        labelText: 'Lifetime (1–3650)',
                      ),
                    ),
                    const SizedBox(height: TdSpacing.related),
                    DropdownButtonFormField<String>(
                      key: const Key('replication-unit'),
                      initialValue: _unit,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Lifetime unit',
                      ),
                      items: [
                        for (final unit in snapshotScheduleLifetimeUnits)
                          DropdownMenuItem(value: unit, child: Text(unit)),
                      ],
                      onChanged: (value) => setState(() => _unit = value!),
                    ),
                  ],
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    key: const Key('replication-enabled'),
                    title: const Text('Enabled'),
                    subtitle: const Text(
                      'Still requires a separately reviewed manual run.',
                    ),
                    value: _enabled,
                    onChanged: (value) => setState(() => _enabled = value),
                  ),
                  const Text(
                    'SOURCE and CUSTOM retention can delete destination snapshots during a later run. Existing advanced options are never silently rewritten.',
                  ),
                  if (_error case final error?)
                    Padding(
                      padding: const EdgeInsets.only(top: TdSpacing.related),
                      child: Text(error),
                    ),
                ],
                const SizedBox(height: TdSpacing.component),
                Wrap(
                  alignment: WrapAlignment.end,
                  spacing: TdSpacing.related,
                  runSpacing: TdSpacing.related,
                  children: [
                    TextButton(
                      key: const Key('replication-editor-cancel'),
                      onPressed: () => Navigator.of(context).pop(),
                      child: Text(current ? 'Cancel' : 'Close'),
                    ),
                    FilledButton(
                      key: const Key('replication-editor-review'),
                      onPressed: current && !locked ? _submit : null,
                      child: const Text('Review settings'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
