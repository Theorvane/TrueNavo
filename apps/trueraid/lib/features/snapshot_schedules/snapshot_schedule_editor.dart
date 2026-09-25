import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'snapshot_calendar_editor.dart';
import 'snapshot_schedule_review.dart';
import 'snapshot_schedules_controller.dart';
import 'snapshot_schedules_page.dart';

class SnapshotScheduleEditorPage extends ConsumerStatefulWidget {
  const SnapshotScheduleEditorPage({
    required this.session,
    required this.inventory,
    this.task,
    super.key,
  });
  final AuthenticatedSession session;
  final SnapshotScheduleInventory inventory;
  final SnapshotScheduleTask? task;
  @override
  ConsumerState<SnapshotScheduleEditorPage> createState() =>
      _SnapshotScheduleEditorPageState();
}

class _SnapshotScheduleEditorPageState
    extends ConsumerState<SnapshotScheduleEditorPage> {
  late final _initial =
      widget.task?.settings ??
      SnapshotScheduleSettings(
        dataset:
            widget.inventory.datasets
                .where((dataset) => dataset.available)
                .firstOrNull
                ?.id ??
            '',
      );
  late String _dataset = _initial.dataset;
  late bool _recursive = _initial.recursive,
      _enabled = _initial.enabled,
      _allowEmpty = _initial.allowEmpty;
  late List<String> _exclude = [..._initial.exclude];
  late final _lifetime = TextEditingController(
    text: '${_initial.lifetimeValue}',
  );
  late String _unit = _initial.lifetimeUnit;
  late final _naming = TextEditingController(text: _initial.namingSchema);
  late SnapshotCalendarValue _calendar = scheduleCalendar(_initial.cron);
  late String _begin = _initial.cron.begin, _end = _initial.cron.end;
  bool _reviewing = false;
  bool _reviewReady = false;
  String? _error;
  @override
  void dispose() {
    _lifetime.dispose();
    _naming.dispose();
    super.dispose();
  }

  Future<void> _review() async {
    if (_reviewing ||
        !identical(widget.session, ref.read(dashboardActiveSessionProvider))) {
      return;
    }
    if (!_calendar.supported) {
      setState(
        () => _error = 'Explicitly replace the unsupported calendar rule or manage it in TrueNAS. No rule was converted.',
      );
      return;
    }
    final lifetime = int.tryParse(_lifetime.text);
    if (lifetime == null) {
      setState(() => _error = 'Enter an integer retention duration.');
      return;
    }
    final settings = SnapshotScheduleSettings(
      dataset: _dataset,
      recursive: _recursive,
      exclude: _exclude,
      lifetimeValue: lifetime,
      lifetimeUnit: _unit,
      enabled: _enabled,
      namingSchema: _naming.text,
      allowEmpty: _allowEmpty,
      cron: SnapshotScheduleCron(
        minute: _calendar.minute,
        hour: _calendar.hour,
        dom: _calendar.dayOfMonth,
        month: _calendar.month,
        dow: _calendar.dayOfWeek,
        begin: _begin,
        end: _end,
      ),
    );
    final request = SnapshotScheduleRequest(
      inventory: widget.inventory,
      task: widget.task,
      settings: settings,
      action: widget.task == null
          ? SnapshotScheduleAction.create
          : SnapshotScheduleAction.update,
    );
    final invalid = request.validationError;
    if (invalid != null) {
      setState(() => _error = invalid);
      return;
    }
    setState(() {
      _error = null;
      _reviewing = true;
      _reviewReady = false;
    });
    try {
      await reviewSnapshotScheduleChange(
        context: context,
        ref: ref,
        session: widget.session,
        inventory: widget.inventory,
        request: request,
        onReviewReady: () {
          if (mounted) setState(() => _reviewReady = true);
        },
      );
    } on Object {
      if (mounted &&
          identical(widget.session, ref.read(dashboardActiveSessionProvider))) {
        setState(
          () => _error = 'The draft could not be reviewed. Reload the schedule and try again. Nothing was sent.',
        );
      }
    } finally {
      if (mounted) setState(() => _reviewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sessionCurrent = identical(
      widget.session,
      ref.watch(dashboardActiveSessionProvider),
    );
    final state = ref.watch(snapshotSchedulesControllerProvider);
    final currentInventory = ref.watch(snapshotSchedulesInventoryProvider);
    final inventoryCurrent =
        !currentInventory.isLoading &&
        identical(currentInventory.asData?.value, widget.inventory);
    if (!sessionCurrent || !inventoryCurrent) {
      return Scaffold(
        appBar: AppBar(title: const Text('Snapshot schedule')),
        body: SnapshotSchedulesWorkspace(
          children: [
            const SnapshotSchedulesOperationBanner(),
            TdPanel(
              title: sessionCurrent
                  ? 'Inventory changed'
                  : 'Connection changed',
              child: const Text(
                'The previous draft and dataset details are hidden. Return to schedules, reload, and open a fresh editor. No previous draft is replayed.',
              ),
            ),
          ],
        ),
      );
    }
    final caps = ref
        .watch(snapshotSchedulesSessionProvider)!
        .snapshotSchedulesCapabilities;
    final canWrite = widget.task == null
        ? caps.canCreate
        : caps.canUpdate && widget.task!.editable;
    final enabled = canWrite && !state.locked && !_reviewing;
    final datasets = widget.inventory.datasets;
    final descendants = datasets
        .where((dataset) => dataset.id.startsWith('$_dataset/'))
        .toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(
          widget.task == null
              ? 'Create snapshot schedule'
              : 'Edit task #${widget.task!.id}',
        ),
      ),
      body: SnapshotSchedulesWorkspace(
        children: [
          Text(widget.session.endpoint!, style: TdTypography.label),
          Text('Times use ${widget.inventory.timezone} on the server.'),
          const SizedBox(height: TdSpacing.component),
          const SnapshotSchedulesOperationBanner(),
          if (!canWrite)
            TdPanel(
              title: 'Read-only schedule',
              child: Text(
                widget.task?.blockedReason ??
                    'The required schedule mutation capability is unavailable.',
              ),
            ),
          TdPanel(
            title: 'Dataset & scope',
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  DropdownButtonFormField<String>(
                    key: ValueKey('schedule-dataset-$_dataset'),
                    initialValue:
                        datasets.any((dataset) => dataset.id == _dataset)
                        ? _dataset
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Exact dataset',
                    ),
                    items: [
                      for (final dataset in datasets)
                        DropdownMenuItem(
                          value: dataset.id,
                          enabled: dataset.available,
                          child: Text('${dataset.id} · ${dataset.kind}'),
                        ),
                    ],
                    onChanged: enabled
                        ? (value) {
                            if (value != null) {
                              setState(() {
                                _dataset = value;
                                _error = null;
                              });
                            }
                          }
                        : null,
                  ),
                  CheckboxListTile(
                    key: const Key('schedule-recursive'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Include descendant datasets'),
                    subtitle: const Text(
                      'Recursion may include future descendants. Exclusions are explicit below.',
                    ),
                    value: _recursive,
                    onChanged: enabled
                        ? (value) => setState(() => _recursive = value ?? false)
                        : null,
                  ),
                  if (_recursive || _exclude.isNotEmpty) ...[
                    const Text(
                      'Excluded descendant datasets',
                      style: TdTypography.label,
                    ),
                    if (!_recursive && _exclude.isNotEmpty)
                      const Text(
                        'Exclusions remain in this draft. Remove them explicitly or keep recursion enabled before review.',
                      ),
                    if (descendants.isEmpty && _exclude.isEmpty)
                      const Text(
                        'No current descendants are available to exclude.',
                      ),
                    for (final id in {
                      ..._exclude,
                      ...descendants.map((dataset) => dataset.id),
                    })
                      CheckboxListTile(
                        key: ValueKey('schedule-exclude-$id'),
                        contentPadding: EdgeInsets.zero,
                        controlAffinity: ListTileControlAffinity.leading,
                        title: Text(id),
                        value: _exclude.contains(id),
                        onChanged: enabled
                            ? (value) => setState(() {
                                if (value == true) {
                                  _exclude = [..._exclude, id];
                                } else {
                                  _exclude = _exclude
                                      .where((item) => item != id)
                                      .toList();
                                }
                              })
                            : null,
                      ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(height: TdSpacing.component),
          TdPanel(
            child: SnapshotCalendarEditor(
              value: _calendar,
              enabled: enabled,
              onChanged: (calendar) => setState(() {
                _calendar = calendar;
                _error = null;
              }),
            ),
          ),
          const SizedBox(height: TdSpacing.component),
          TdPanel(
            title: 'Daily execution window',
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text(
                  'The calendar rule is also constrained to this inclusive server-local time window. Begin must be earlier than end; use 00:00–23:59 for all day. Equal or overnight windows are unavailable here. The end is not a completion deadline.',
                ),
                const SizedBox(height: TdSpacing.related),
                Wrap(
                  spacing: TdSpacing.related,
                  runSpacing: TdSpacing.related,
                  children: [
                    _TimeSelector(
                      label: 'Begin',
                      value: _begin,
                      enabled: enabled,
                      onChanged: (value) => setState(() => _begin = value),
                    ),
                    _TimeSelector(
                      label: 'End',
                      value: _end,
                      enabled: enabled,
                      onChanged: (value) => setState(() => _end = value),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: TdSpacing.component),
          TdPanel(
            title: 'Retention & naming',
            child: Material(
              type: MaterialType.transparency,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  TextField(
                    key: const Key('schedule-lifetime'),
                    controller: _lifetime,
                    enabled: enabled,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Retention duration',
                    ),
                  ),
                  const SizedBox(height: TdSpacing.component),
                  DropdownButtonFormField<String>(
                    key: ValueKey('schedule-lifetime-unit-$_unit'),
                    initialValue:
                        const [
                          'HOUR',
                          'DAY',
                          'WEEK',
                          'MONTH',
                          'YEAR',
                        ].contains(_unit)
                        ? _unit
                        : null,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Retention unit',
                    ),
                    items: [
                      for (final unit in const [
                        'HOUR',
                        'DAY',
                        'WEEK',
                        'MONTH',
                        'YEAR',
                      ])
                        DropdownMenuItem(
                          value: unit,
                          child: Text(unit.toLowerCase()),
                        ),
                    ],
                    onChanged: enabled
                        ? (value) {
                            if (value != null) setState(() => _unit = value);
                          }
                        : null,
                  ),
                  const SizedBox(height: TdSpacing.component),
                  TextField(
                    key: const Key('schedule-naming'),
                    controller: _naming,
                    enabled: enabled,
                    autocorrect: false,
                    enableSuggestions: false,
                    decoration: const InputDecoration(
                      labelText: 'Snapshot naming schema',
                      helperText: 'A server-validated timestamp pattern, for example auto-%Y-%m-%d_%H-%M.',
                      helperMaxLines: 4,
                    ),
                  ),
                  const SizedBox(height: TdSpacing.related),
                  const Text(
                    'Shorter retention, naming-pattern overlap, scope changes, or deleting a task can change existing snapshots’ future expiry. The server review describes the affected set; no private retention-fixation job is launched.',
                  ),
                  CheckboxListTile(
                    key: const Key('schedule-allow-empty'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Allow empty snapshots'),
                    value: _allowEmpty,
                    onChanged: enabled
                        ? (value) =>
                              setState(() => _allowEmpty = value ?? false)
                        : null,
                  ),
                  CheckboxListTile(
                    key: const Key('schedule-enabled'),
                    contentPadding: EdgeInsets.zero,
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('Enable automatic scheduling'),
                    value: _enabled,
                    subtitle: const Text(
                      'Running now is a separate reviewed action.',
                    ),
                    onChanged: enabled
                        ? (value) => setState(() => _enabled = value ?? false)
                        : null,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: TdSpacing.component),
          if (_reviewing && !_reviewReady) const LinearProgressIndicator(),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(bottom: TdSpacing.related),
              child: Text(
                _error!,
                key: const Key('schedule-validation-error'),
                style: TextStyle(color: context.tdTheme.statusCritical),
              ),
            ),
          FilledButton.icon(
            key: const Key('schedule-review-draft'),
            onPressed: enabled ? _review : null,
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('Review schedule'),
          ),
        ],
      ),
    );
  }
}

class _TimeSelector extends StatelessWidget {
  const _TimeSelector({
    required this.label,
    required this.value,
    required this.enabled,
    required this.onChanged,
  });
  final String label, value;
  final bool enabled;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => OutlinedButton.icon(
    key: ValueKey('schedule-window-${label.toLowerCase()}'),
    onPressed: enabled
        ? () async {
            final parts = value.split(':');
            final hour = parts.length == 2 ? int.tryParse(parts[0]) : null;
            final minute = parts.length == 2 ? int.tryParse(parts[1]) : null;
            final valid =
                hour != null &&
                minute != null &&
                hour >= 0 &&
                hour < 24 &&
                minute >= 0 &&
                minute < 60;
            final selected = await showTimePicker(
              context: context,
              initialTime: valid
                  ? TimeOfDay(hour: hour, minute: minute)
                  : const TimeOfDay(hour: 0, minute: 0),
              builder: (context, child) => MediaQuery(
                data: MediaQuery.of(context)
                    .copyWith(alwaysUse24HourFormat: true),
                child: child!,
              ),
            );
            if (context.mounted && selected != null) {
              onChanged(
                '${selected.hour.toString().padLeft(2, '0')}:${selected.minute.toString().padLeft(2, '0')}',
              );
            }
          }
        : null,
    icon: const Icon(Icons.schedule_rounded),
    label: Text('$label $value'),
  );
}
