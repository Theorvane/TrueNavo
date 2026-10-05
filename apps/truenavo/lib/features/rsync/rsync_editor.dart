import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'rsync_controller.dart';

class RsyncEditor extends ConsumerStatefulWidget {
  const RsyncEditor({
    required this.session,
    required this.inventory,
    this.task,
    super.key,
  });
  final AuthenticatedSession session;
  final RsyncInventory inventory;
  final RsyncTask? task;
  @override
  ConsumerState<RsyncEditor> createState() => _RsyncEditorState();
}

class _RsyncEditorState extends ConsumerState<RsyncEditor> {
  final _description = TextEditingController(),
      _remote = TextEditingController(),
      _minute = TextEditingController(),
      _hour = TextEditingController(),
      _dom = TextEditingController(),
      _month = TextEditingController(),
      _dow = TextEditingController();
  String? _path, _user, _error;
  int? _connection;
  bool _times = true, _compress = true, _delay = true, _expired = false;
  late final AppLifecycleListener _lifecycle;
  List<TextEditingController> get _fields => [
    _description,
    _remote,
    _minute,
    _hour,
    _dom,
    _month,
    _dow,
  ];
  @override
  void initState() {
    super.initState();
    final s = widget.task?.settings;
    final cron =
        s?.cron ?? const PoolScrubCron(minute: '0', hour: '2', dow: '*');
    _description.text = s?.description ?? '';
    _remote.text = s?.remotePath ?? '';
    _path = s?.path;
    _user = s?.user;
    _connection = s?.connectionId;
    _times = s?.times ?? true;
    _compress = s?.compress ?? true;
    _delay = s?.delayUpdates ?? true;
    _minute.text = cron.minute;
    _hour.text = cron.hour;
    _dom.text = cron.dom;
    _month.text = cron.month;
    _dow.text = cron.dow;
    final initial = WidgetsBinding.instance.lifecycleState;
    _expired = initial != null && initial != AppLifecycleState.resumed;
    if (_expired) _clear();
    _lifecycle = AppLifecycleListener(
      onStateChange: (s) {
        if (s != AppLifecycleState.resumed) _expire();
      },
    );
  }

  void _clear() {
    for (final field in _fields) {
      field.clear();
    }
    _path = null;
    _user = null;
    _connection = null;
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
    final request = RsyncRequest(
      inventory: widget.inventory,
      action: widget.task == null ? RsyncAction.create : RsyncAction.update,
      task: widget.task,
      settings: RsyncSettings(
        path: _path ?? '',
        user: _user ?? '',
        connectionId: _connection ?? -1,
        remotePath: _remote.text,
        description: _description.text,
        times: _times,
        compress: _compress,
        delayUpdates: _delay,
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
      key: Key('rsync-$key'),
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
  Widget _choice<T>(
    String key,
    String label,
    T? value,
    List<DropdownMenuItem<T>> items,
    ValueChanged<T?> select,
  ) => Padding(
    padding: const EdgeInsets.only(top: 12),
    child: DropdownButtonFormField<T>(
      key: Key('rsync-$key'),
      initialValue: value,
      isExpanded: true,
      itemHeight: null,
      decoration: InputDecoration(labelText: label),
      items: items,
      onChanged: select,
    ),
  );
  Widget _toggle(
    String key,
    String label,
    bool value,
    ValueChanged<bool> change,
  ) => CheckboxListTile(
    key: Key('rsync-$key'),
    contentPadding: EdgeInsets.zero,
    title: Text(label),
    value: value,
    onChanged: (v) => setState(() => change(v == true)),
  );
  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(rsyncInventoryProvider, (_, b) {
      if (b.isLoading || !identical(widget.inventory, b.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(rsyncInventoryProvider);
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(widget.inventory, inventory.asData?.value);
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('rsync-editor-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                !current
                    ? 'Rsync editor expired'
                    : widget.task == null
                    ? 'Create disabled Rsync task'
                    : 'Edit disabled Rsync task',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Prior settings were discarded. Reload the current server and review again.',
                )
              else ...[
                Text(widget.inventory.endpoint),
                Text('Server timezone: ${widget.inventory.timezone}'),
                const Text(
                  'SSH · PUSH only. Save remains disabled; enabling scheduled transfers is a separate reviewed operation. No remote validation, SSH key scan or connection test.',
                ),
                _choice('dataset', 'Exact local dataset', _path, [
                  for (final d in widget.inventory.datasets.where(
                    (d) => d.blockedReason == null,
                  ))
                    DropdownMenuItem(value: d.path, child: Text(d.path)),
                ], (v) => setState(() => _path = v)),
                _choice('user', 'Local non-root user', _user, [
                  for (final u in widget.inventory.users)
                    DropdownMenuItem(
                      value: u.username,
                      child: Text('${u.username} · UID ${u.uid}'),
                    ),
                ], (v) => setState(() => _user = v)),
                _choice(
                  'connection',
                  'Existing pinned SSH connection',
                  _connection,
                  [
                    for (final c in widget.inventory.connections)
                      DropdownMenuItem(
                        value: c.id,
                        child: Text('${c.name} · ${c.destination}'),
                      ),
                  ],
                  (v) => setState(() => _connection = v),
                ),
                _field(
                  'remote-path',
                  'Dedicated remote directory (absolute)',
                  _remote,
                  max: 255,
                ),
                const Text(
                  'The source path is used exactly, with no added trailing slash. An existing destination directory receives the source directory. If the destination is absent, the resulting layout may differ. Remote existence and layout are not verified; destination files can be overwritten.',
                ),
                _field('description', 'Description', _description, max: 120),
                const Text(
                  'Cron uses server time, including daylight-saving behavior. Numeric values, lists, ranges and supported steps. Sunday is 0 or 7. When both day-of-month and weekday are restricted, either can match.',
                ),
                _field('minute', 'Minute (0–59)', _minute),
                _field('hour', 'Hour (0–23)', _hour),
                _field('dom', 'Day of month (1–31)', _dom),
                _field('month', 'Month (1–12)', _month),
                _field('dow', 'Day of week (0–7)', _dow),
                _toggle(
                  'times',
                  'Preserve file modification times',
                  _times,
                  (v) => _times = v,
                ),
                _toggle(
                  'compress',
                  'Compress transfer data',
                  _compress,
                  (v) => _compress = v,
                ),
                _toggle(
                  'delay',
                  'Delay replacement until transfer end',
                  _delay,
                  (v) => _delay = v,
                ),
                const Text(
                  'Recursive copy and fixed --one-file-system protection are required. Cross-device traversal is reduced, but same-device bind mounts are not fully excluded. Archive, deletion, preserved permissions/attributes and custom arguments are disabled. This is not a content or recoverability check.',
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
                    key: const Key('rsync-editor-cancel'),
                    onPressed: () => Navigator.pop(context),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('rsync-editor-review'),
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
