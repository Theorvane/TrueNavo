import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'pool_maintenance_controller.dart';

class PoolMaintenanceEditor extends ConsumerStatefulWidget {
  const PoolMaintenanceEditor({
    required this.session,
    required this.inventory,
    required this.pool,
    this.schedule,
    super.key,
  });
  final AuthenticatedSession session;
  final PoolMaintenanceInventory inventory;
  final PoolMaintenancePool pool;
  final PoolScrubSchedule? schedule;
  @override
  ConsumerState<PoolMaintenanceEditor> createState() =>
      _PoolMaintenanceEditorState();
}

class _PoolMaintenanceEditorState extends ConsumerState<PoolMaintenanceEditor> {
  final _description = TextEditingController(),
      _threshold = TextEditingController(),
      _minute = TextEditingController(),
      _hour = TextEditingController(),
      _dom = TextEditingController(),
      _month = TextEditingController(),
      _dow = TextEditingController();
  bool _enabled = false, _expired = false;
  String? _error;
  late final AppLifecycleListener _lifecycle;
  List<TextEditingController> get _fields => [
    _description,
    _threshold,
    _minute,
    _hour,
    _dom,
    _month,
    _dow,
  ];
  @override
  void initState() {
    super.initState();
    final settings =
        widget.schedule?.settings ??
        const PoolScrubScheduleSettings(enabled: false);
    _description.text = settings.description;
    _threshold.text = '${settings.threshold}';
    _minute.text = settings.cron.minute;
    _hour.text = settings.cron.hour;
    _dom.text = settings.cron.dom;
    _month.text = settings.cron.month;
    _dow.text = settings.cron.dow;
    _enabled = settings.enabled;
    final initial = WidgetsBinding.instance.lifecycleState;
    _expired = initial != null && initial != AppLifecycleState.resumed;
    if (_expired) _clear();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) _expire();
      },
    );
  }

  void _clear() {
    for (final field in _fields) {
      field.clear();
    }
    _enabled = false;
    _error = null;
  }

  void _expire() {
    if (_expired) return;
    setState(() {
      _expired = true;
      _clear();
    });
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

  void _submit() {
    final request = PoolMaintenanceRequest(
      inventory: widget.inventory,
      action: widget.schedule == null
          ? PoolMaintenanceAction.createSchedule
          : PoolMaintenanceAction.updateSchedule,
      pool: widget.pool,
      schedule: widget.schedule,
      settings: PoolScrubScheduleSettings(
        threshold: int.tryParse(_threshold.text) ?? -1,
        description: _description.text,
        enabled: _enabled,
        cron: PoolScrubCron(
          minute: _minute.text,
          hour: _hour.text,
          dom: _dom.text,
          month: _month.text,
          dow: _dow.text,
        ),
      ),
    );
    if (request.validationError case final error?) {
      setState(() => _error = error);
      return;
    }
    Navigator.of(context).pop(request);
  }

  Widget _field(
    String key,
    String label,
    TextEditingController controller, {
    int max = 128,
  }) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: TextField(
      key: Key('pool-maintenance-$key'),
      controller: controller,
      maxLength: max,
      autocorrect: false,
      enableSuggestions: false,
      enableIMEPersonalizedLearning: false,
      decoration: InputDecoration(labelText: label),
      onTap: () => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && primaryFocus?.context != null) {
          Scrollable.ensureVisible(primaryFocus!.context!, alignment: .4);
        }
      }),
    ),
  );
  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(poolMaintenanceInventoryProvider, (_, b) {
      if (b.isLoading || !identical(widget.inventory, b.asData?.value)) {
        _expire();
      }
    });
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !ref.watch(poolMaintenanceInventoryProvider).isLoading &&
        identical(
          widget.inventory,
          ref.watch(poolMaintenanceInventoryProvider).asData?.value,
        );
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 700),
        child: SingleChildScrollView(
          key: const Key('pool-maintenance-editor-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                !current
                    ? 'Maintenance editor expired'
                    : widget.schedule == null
                    ? 'Create scrub schedule'
                    : 'Edit scrub schedule',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Prior settings were discarded. Reload the current server and review again.',
                )
              else ...[
                Text(widget.inventory.endpoint),
                Text(
                  'Pool ${widget.pool.id} · ${widget.pool.name} · GUID ${widget.pool.guid}',
                ),
                Text('Server timezone: ${widget.inventory.timezone}'),
                const Text(
                  'This configures future scrub eligibility, not an immediate scrub. The threshold is the minimum age in days since a prior scrub; cron alone does not predict the next run. Daylight-saving behavior follows the server.',
                ),
                _field('description', 'Description', _description, max: 200),
                _field(
                  'threshold',
                  'Threshold (days, 0–3650)',
                  _threshold,
                  max: 4,
                ),
                const Text(
                  'Numeric cron fields: values, lists, ranges or supported steps. Sunday is 0 or 7. When both day-of-month and weekday are restricted, either can match.',
                ),
                _field('minute', 'Minute (0–59)', _minute),
                _field('hour', 'Hour (0–23)', _hour),
                _field('dom', 'Day of month (1–31)', _dom),
                _field('month', 'Month (1–12)', _month),
                _field('dow', 'Day of week (0–7)', _dow),
                CheckboxListTile(
                  key: const Key('pool-maintenance-enabled'),
                  contentPadding: EdgeInsets.zero,
                  value: _enabled,
                  onChanged: (value) =>
                      setState(() => _enabled = value == true),
                  title: const Text('Enable future scheduled scrubs'),
                ),
                if (_error case final error?)
                  Text(
                    error,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.error,
                    ),
                  ),
              ],
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  TextButton(
                    key: const Key('pool-maintenance-editor-cancel'),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('pool-maintenance-editor-review'),
                    onPressed: current ? _submit : null,
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
