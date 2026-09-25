import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'cron_tasks_controller.dart';

class CronTasksPage extends ConsumerStatefulWidget {
  const CronTasksPage({super.key});
  @override
  ConsumerState<CronTasksPage> createState() => _CronTasksPageState();
}

class _CronTasksPageState extends ConsumerState<CronTasksPage> {
  late final CronTasksController _controller;
  bool _working = false, _ownModal = false, _abandoned = false;
  String _filter = '';
  int _limit = 30;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(cronTasksControllerProvider.notifier);
  }

  @override
  void dispose() {
    _controller.abandonRoute();
    super.dispose();
  }

  bool get _routeCurrent =>
      mounted && ModalRoute.of(context)?.isCurrent == true;
  Future<T?> _modal<T>(WidgetBuilder builder) async {
    setState(() => _ownModal = true);
    final route = DialogRoute<T>(
      context: context,
      builder: builder,
      barrierDismissible: false,
    );
    try {
      final value = await Navigator.of(context).push(route);
      await route.completed;
      return value;
    } finally {
      if (mounted) setState(() => _ownModal = false);
    }
  }

  Future<void> _change(
    AuthenticatedSession session,
    CronTasksInventory inventory,
    CronTasksAction action, [
    CronTaskSnapshot? task,
  ]) async {
    if (_working) return;
    setState(() => _working = true);
    var expired = false;
    CronTasksRequest? request;
    final lifecycle = AppLifecycleListener(
      onStateChange: (s) {
        if (s != AppLifecycleState.resumed) expired = true;
      },
    );
    final sessions = ref.listenManual(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) expired = true;
    });
    final inventories = ref.listenManual(cronTasksInventoryProvider, (_, b) {
      if (b.isLoading || !identical(inventory, b.asData?.value)) expired = true;
    });
    bool current() =>
        _routeCurrent &&
        !expired &&
        identical(session, ref.read(dashboardActiveSessionProvider)) &&
        !ref.read(cronTasksInventoryProvider).isLoading &&
        identical(
          inventory,
          ref.read(cronTasksInventoryProvider).asData?.value,
        );
    try {
      if (!current()) return;
      if (action == CronTasksAction.create || action == CronTasksAction.edit) {
        request = await _modal<CronTasksRequest>(
          (_) =>
              _CronEditor(session: session, inventory: inventory, task: task),
        );
      } else {
        request = CronTasksRequest(
          inventory: inventory,
          action: action,
          task: task,
        );
      }
      if (request == null || !current()) {
        _controller.expireContext();
        return;
      }
      final review = await _controller.review(
        expectedSession: session,
        request: request,
        isRouteCurrent: () => _routeCurrent,
      );
      if (!current()) {
        _controller.expireContext();
        return;
      }
      if (review == null) return;
      final confirmed = await _modal<bool>(
        (_) => _CronReview(session: session, review: review),
      );
      if (confirmed != true || !current()) {
        _controller.expireContext();
        return;
      }
      await _controller.execute(
        expectedSession: session,
        review: review,
        confirmation: review.target,
        configurationImpactAccepted: true,
        executionImpactAccepted: true,
        commandRiskAccepted: true,
        disclosureAccepted: true,
        isRouteCurrent: () => _routeCurrent,
      );
    } finally {
      request?.command?.dispose();
      lifecycle.dispose();
      sessions.close();
      inventories.close();
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (ModalRoute.isCurrentOf(context) == false && !_ownModal && !_abandoned) {
      _abandoned = true;
      _controller.abandonRoute();
    } else if (ModalRoute.isCurrentOf(context) == true) {
      _abandoned = false;
    }
    final session = ref.watch(dashboardActiveSessionProvider),
        api = ref.watch(cronTasksSessionProvider),
        state = ref.watch(cronTasksControllerProvider),
        inventory = ref.watch(cronTasksInventoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('Scheduled cron tasks')),
      body: SafeArea(
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            const Text(
              'Explicit scheduling, protected commands',
              style: TdTypography.titleMedium,
            ),
            const SizedBox(height: 8),
            const Text(
              'Configured task counts, not executions, next-run predictions or successful outcomes. Stored commands are withheld because they may contain secrets. No Run now, shell, command test or job-log viewer is offered.',
            ),
            const SizedBox(height: 16),
            if (state.message != null)
              TdPanel(
                title: state.unresolved
                    ? 'Inspect the original server'
                    : state.status == CronTasksStatus.completed
                    ? 'Configuration verified'
                    : 'Cron status',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(state.message!),
                    if (state.server != null)
                      Text('Original server: ${state.server}'),
                    if (state.unresolved) ...[
                      const Text(
                        'Writes remain locked. Reconnect manually to the original endpoint, verify the same host, then independently inspect task configuration and any running commands or downstream effects. No retry or command cancellation is performed.',
                      ),
                      OutlinedButton(
                        key: const Key('cron-verify'),
                        onPressed: _controller.canVerifyReconnectedServer
                            ? _controller.verifyReconnectedServer
                            : null,
                        child: const Text(
                          'Verify reconnected original host once',
                        ),
                      ),
                      if (state.verificationMessage != null)
                        Text(state.verificationMessage!),
                      OutlinedButton(
                        key: const Key('cron-acknowledge'),
                        onPressed: _controller.canAcknowledge
                            ? _controller.acknowledgeAfterReconnect
                            : null,
                        child: const Text(
                          'I inspected the original tasks and effects; release app lock',
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            if (!state.locked) ...[
              if (api == null || !api.cronTasksCapabilities.supported)
                Text(
                  api?.cronTasksCapabilities.blockedReason ??
                      'Connect to inspect cron tasks.',
                ),
              inventory.when(
                loading: () => const Padding(
                  padding: EdgeInsets.all(24),
                  child: Center(child: CircularProgressIndicator()),
                ),
                error: (_, _) => const TdPanel(
                  title: 'Cron tasks unavailable',
                  child: Text(
                    'Safe task headers, local identities or readiness could not be verified. No change was submitted. Remote and command details are withheld.',
                  ),
                ),
                data: (i) {
                  final matching = i.tasks
                      .where(
                        (t) =>
                            '${t.id} ${t.settings.description} ${t.settings.user}'
                                .toLowerCase()
                                .contains(_filter.toLowerCase()),
                      )
                      .toList();
                  final enabled = i.tasks.where((t) => t.enabled).length,
                      exposed = i.tasks
                          .where(
                            (t) =>
                                !t.settings.hideStdout ||
                                !t.settings.hideStderr,
                          )
                          .length;
                  bool allowed(CronTasksAction a) =>
                      session != null &&
                      api?.cronTasksCapabilities.allows(a) == true &&
                      i.blockedReason == null &&
                      !_working &&
                      !state.busy;
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      TdPanel(
                        title: 'Configured schedules only',
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Wrap(
                              spacing: 20,
                              runSpacing: 12,
                              crossAxisAlignment: WrapCrossAlignment.center,
                              children: [
                                Semantics(
                                  label:
                                      '$enabled enabled of ${i.tasks.length} configured cron tasks',
                                  child: ExcludeSemantics(
                                    child: SizedBox(
                                      width: 110,
                                      height: 110,
                                      child: CustomPaint(
                                        key: const Key('cron-task-ring'),
                                        painter: _CronRing(
                                          enabled,
                                          i.tasks.length,
                                          Theme.of(context).colorScheme.primary,
                                          Theme.of(context)
                                              .colorScheme
                                              .outlineVariant,
                                        ),
                                        child: Center(
                                          child: Padding(
                                            padding: const EdgeInsets.all(20),
                                            child: FittedBox(
                                              child: Text(
                                                '${i.tasks.length}',
                                                style:
                                                    TdTypography.metricMedium,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                Text(
                                  '$enabled enabled\n${i.tasks.length - enabled} disabled',
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '$exposed tasks allow stdout or stderr output',
                            ),
                            if (i.tasks.isNotEmpty)
                              ExcludeSemantics(
                                child: LinearProgressIndicator(
                                  value: exposed / i.tasks.length,
                                  minHeight: 8,
                                ),
                              ),
                            Text('Server timezone: ${i.timezone}'),
                            Text(
                              '${i.users.length} verified unlocked local account choices',
                            ),
                            const Text(
                              'Output suppression does not hide command text in all failures, prevent command effects or guarantee email privacy.',
                            ),
                          ],
                        ),
                      ),
                      if (i.blockedReason != null)
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          child: Text(i.blockedReason!),
                        ),
                      FilledButton(
                        key: const Key('cron-create'),
                        onPressed:
                            allowed(CronTasksAction.create) &&
                                i.tasks.length < 256 &&
                                i.users.isNotEmpty
                            ? () => _change(session!, i, CronTasksAction.create)
                            : null,
                        child: const Text('Create disabled cron task'),
                      ),
                      TextField(
                        key: const Key('cron-filter'),
                        decoration: const InputDecoration(
                          labelText:
                              'Filter task description, ID or local user',
                        ),
                        onChanged: (v) => setState(() {
                          _filter = v;
                          _limit = 30;
                        }),
                      ),
                      const SizedBox(height: 12),
                      if (i.tasks.isEmpty)
                        const Text(
                          'No configured cron tasks. Create a disabled draft to begin; nothing executes automatically from this page.',
                        ),
                      if (i.tasks.isNotEmpty && matching.isEmpty)
                        const Text('No tasks match this filter.'),
                      for (final task in matching.take(_limit))
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: TdPanel(
                            title: task.settings.description.isEmpty
                                ? 'Task #${task.id}'
                                : task.settings.description,
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  'Task #${task.id} · ${task.enabled ? 'enabled' : 'disabled'}',
                                ),
                                Text('Local account: ${task.settings.user}'),
                                Text(
                                  'Schedule: ${task.settings.schedule.expression}',
                                ),
                                const Text('Stored command: withheld'),
                                Text(
                                  'Suppress stdout: ${task.settings.hideStdout} · stderr: ${task.settings.hideStderr}',
                                ),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    if (!task.enabled)
                                      OutlinedButton(
                                        key: Key('cron-edit-${task.id}'),
                                        onPressed: allowed(CronTasksAction.edit)
                                            ? () => _change(
                                                session!,
                                                i,
                                                CronTasksAction.edit,
                                                task,
                                              )
                                            : null,
                                        child: const Text('Edit disabled task'),
                                      ),
                                    OutlinedButton(
                                      key: Key(
                                        'cron-${task.enabled ? 'disable' : 'enable'}-${task.id}',
                                      ),
                                      onPressed:
                                          allowed(
                                                task.enabled
                                                    ? CronTasksAction.disable
                                                    : CronTasksAction.enable,
                                              ) &&
                                              CronTasksRequest(
                                                    inventory: i,
                                                    action: task.enabled
                                                        ? CronTasksAction
                                                              .disable
                                                        : CronTasksAction
                                                              .enable,
                                                    task: task,
                                                  ).validationError ==
                                                  null
                                          ? () => _change(
                                              session!,
                                              i,
                                              task.enabled
                                                  ? CronTasksAction.disable
                                                  : CronTasksAction.enable,
                                              task,
                                            )
                                          : null,
                                      child: Text(
                                        task.enabled
                                            ? 'Disable task'
                                            : 'Enable task',
                                      ),
                                    ),
                                    if (task.enabled)
                                      OutlinedButton(
                                        key: Key('cron-run-${task.id}'),
                                        onPressed:
                                            allowed(CronTasksAction.run) &&
                                                CronTasksRequest(
                                                      inventory: i,
                                                      action:
                                                          CronTasksAction.run,
                                                      task: task,
                                                    ).validationError ==
                                                    null
                                            ? () => _change(
                                                session!,
                                                i,
                                                CronTasksAction.run,
                                                task,
                                              )
                                            : null,
                                        child: const Text('Run once now'),
                                      ),

                                    if (!task.enabled)
                                      OutlinedButton(
                                        key: Key('cron-delete-${task.id}'),
                                        onPressed:
                                            allowed(CronTasksAction.delete)
                                            ? () => _change(
                                                session!,
                                                i,
                                                CronTasksAction.delete,
                                                task,
                                              )
                                            : null,
                                        child: const Text(
                                          'Delete disabled task',
                                        ),
                                      ),
                                  ],
                                ),
                              ],
                            ),
                          ),
                        ),
                      if (matching.length > _limit)
                        TextButton(
                          onPressed: () => setState(() => _limit += 30),
                          child: Text(
                            'Show more (${matching.length - _limit} remaining)',
                          ),
                        ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 12),
              OutlinedButton(
                key: const Key('cron-reload'),
                onPressed: !_working && !state.busy
                    ? _controller.refreshConfiguration
                    : null,
                child: const Text('Read fresh cron configuration'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CronRing extends CustomPainter {
  const _CronRing(this.enabled, this.total, this.color, this.track);
  final int enabled, total;
  final Color color, track;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero),
        radius = math.min(size.width, size.height) / 2 - 7;
    final p = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12
      ..color = track;
    canvas.drawCircle(center, radius, p);
    if (total > 0 && enabled > 0) {
      p.color = color;
      canvas.drawArc(
        Rect.fromCircle(center: center, radius: radius),
        -math.pi / 2,
        math.pi * 2 * enabled / total,
        false,
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_CronRing old) =>
      old.enabled != enabled ||
      old.total != total ||
      old.color != color ||
      old.track != track;
}

class _CronEditor extends ConsumerStatefulWidget {
  const _CronEditor({
    required this.session,
    required this.inventory,
    this.task,
  });
  final AuthenticatedSession session;
  final CronTasksInventory inventory;
  final CronTaskSnapshot? task;
  @override
  ConsumerState<_CronEditor> createState() => _CronEditorState();
}

class _CronEditorState extends ConsumerState<_CronEditor> {
  late final TextEditingController _description,
      _minute,
      _hour,
      _dom,
      _month,
      _dow;
  final _command = TextEditingController(),
      _userFilter = TextEditingController();
  String _user = '';
  bool _replace = false,
      _stdout = true,
      _stderr = true,
      _expired = false,
      _closing = false;
  late final AppLifecycleListener _lifecycle;
  List<TextEditingController> get _buffers => [
    _description,
    _minute,
    _hour,
    _dom,
    _month,
    _dow,
    _command,
    _userFilter,
  ];
  @override
  void initState() {
    super.initState();
    final s = widget.task?.settings,
        cron = s?.schedule ?? const CronTaskSchedule();
    _user = s?.user ?? '';
    _description = TextEditingController(text: s?.description ?? '');
    _minute = TextEditingController(text: cron.minute);
    _hour = TextEditingController(text: cron.hour);
    _dom = TextEditingController(text: cron.dom);
    _month = TextEditingController(text: cron.month);
    _dow = TextEditingController(text: cron.dow);
    _stdout = s?.hideStdout ?? true;
    _stderr = s?.hideStderr ?? true;
    _replace = widget.task == null;
    _lifecycle = AppLifecycleListener(
      onStateChange: (s) {
        if (s != AppLifecycleState.resumed) _expire();
      },
    );
  }

  void _clear() {
    for (final c in _buffers) {
      c.clear();
    }
    _user = '';
    _replace = false;
  }

  void _expire() {
    if (!mounted || _expired || _closing) return;
    setState(() {
      _expired = true;
      _clear();
    });
    ref.read(cronTasksControllerProvider.notifier).expireContext();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _clear();
    for (final c in _buffers) {
      c.dispose();
    }
    super.dispose();
  }

  CronTaskSettings get _settings => CronTaskSettings(
    user: _user,
    description: _description.text,
    schedule: CronTaskSchedule(
      minute: _minute.text,
      hour: _hour.text,
      dom: _dom.text,
      month: _month.text,
      dow: _dow.text,
    ),
    hideStdout: _stdout,
    hideStderr: _stderr,
  );
  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(cronTasksInventoryProvider, (_, v) {
      if (v.isLoading || !identical(widget.inventory, v.asData?.value)) {
        _expire();
      }
    });
    if (ModalRoute.isCurrentOf(context) == false && !_closing && !_expired) {
      _expired = true;
      _clear();
      ref.read(cronTasksControllerProvider.notifier).abandonRoute();
    }
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        identical(
          widget.inventory,
          ref.watch(cronTasksInventoryProvider).asData?.value,
        );
    final effective = _settings;
    final error =
        effective.validationError ??
        (!widget.inventory.users.any((u) => u.username == _user)
            ? 'Choose a verified local account.'
            : _replace
            ? CronTaskCommand.validationErrorFor(_command.text)
            : CronTasksRequest(
                inventory: widget.inventory,
                action: CronTasksAction.edit,
                task: widget.task,
                settings: effective,
              ).validationError);
    final users = widget.inventory.users
        .where(
          (u) =>
              u.username.toLowerCase().contains(_userFilter.text.toLowerCase()),
        )
        .take(30)
        .toList();
    void preset(CronTaskSchedule s) {
      setState(() {
        _minute.text = s.minute;
        _hour.text = s.hour;
        _dom.text = s.dom;
        _month.text = s.month;
        _dow.text = s.dow;
      });
    }

    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('cron-editor-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? (widget.task == null
                          ? 'Create disabled cron task'
                          : 'Edit disabled cron task')
                    : 'Cron draft expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'The foreground, connection or route changed. Draft buffers were cleared; close and reload.',
                )
              else ...[
                const Text(
                  'This saves a disabled task. Commands are arbitrary shell programs; root has appliance-wide privileges. Existing command text is never read into this editor. Do not place secrets in descriptions.',
                ),
                TextField(
                  key: const Key('cron-description'),
                  controller: _description,
                  maxLength: 200,
                  decoration: const InputDecoration(
                    labelText: 'Description (visible in lists)',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                Text(
                  'Selected local account: ${_user.isEmpty ? 'choose explicitly' : _user}',
                ),
                TextField(
                  key: const Key('cron-user-filter'),
                  controller: _userFilter,
                  decoration: const InputDecoration(
                    labelText: 'Filter verified local users',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    for (final u in users)
                      ChoiceChip(
                        key: Key('cron-user-${u.id}'),
                        label: Text('${u.username} · UID ${u.uid}'),
                        selected: _user == u.username,
                        onSelected: (_) => setState(() => _user = u.username),
                      ),
                  ],
                ),
                if (users.isEmpty) const Text('No verified local users match.'),
                if (widget.inventory.users.length > 30)
                  const Text('At most 30 choices shown; filter by username.'),
                const SizedBox(height: 12),
                Text('Five-field schedule in ${widget.inventory.timezone}'),
                const Text(
                  'Minute / hour / day of month / month / weekday. Numeric syntax only; restrict either calendar day or weekday, not both. No guaranteed next-run preview.',
                ),
                Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  children: [
                    ActionChip(
                      key: const Key('cron-preset-hourly'),
                      label: const Text('Hourly'),
                      onPressed: () =>
                          preset(const CronTaskSchedule(hour: '*')),
                    ),
                    ActionChip(
                      key: const Key('cron-preset-daily'),
                      label: const Text('Daily 02:00'),
                      onPressed: () => preset(const CronTaskSchedule()),
                    ),
                    ActionChip(
                      key: const Key('cron-preset-weekly'),
                      label: const Text('Sunday 02:00'),
                      onPressed: () => preset(const CronTaskSchedule(dow: '0')),
                    ),
                    ActionChip(
                      key: const Key('cron-preset-monthly'),
                      label: const Text('Monthly 02:00'),
                      onPressed: () => preset(const CronTaskSchedule(dom: '1')),
                    ),
                  ],
                ),
                for (final e in {
                  'minute': _minute,
                  'hour': _hour,
                  'dom': _dom,
                  'month': _month,
                  'dow': _dow,
                }.entries)
                  TextField(
                    key: Key('cron-${e.key}'),
                    controller: e.value,
                    maxLength: 100,
                    decoration: InputDecoration(labelText: e.key),
                    onChanged: (_) => setState(() {}),
                  ),
                CheckboxListTile(
                  key: const Key('cron-stdout'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Suppress standard output'),
                  value: _stdout,
                  onChanged: (v) => setState(() => _stdout = v == true),
                ),
                CheckboxListTile(
                  key: const Key('cron-stderr'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text('Suppress standard error'),
                  value: _stderr,
                  onChanged: (v) => setState(() => _stderr = v == true),
                ),
                const Text(
                  'Suppression does not hide the command in all failures or guarantee no log/email disclosure.',
                ),
                if (widget.task != null)
                  CheckboxListTile(
                    key: const Key('cron-replace-command'),
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Explicitly replace the stored command'),
                    subtitle: const Text(
                      'Unchecked preserves it without revealing or resending it.',
                    ),
                    value: _replace,
                    onChanged: (v) => setState(() {
                      _replace = v == true;
                      _command.clear();
                    }),
                  ),
                if (_replace)
                  TextField(
                    key: const Key('cron-command'),
                    controller: _command,
                    obscureText: true,
                    autocorrect: false,
                    enableSuggestions: false,
                    maxLength: 4096,
                    decoration: const InputDecoration(
                      labelText: 'New command (write-only)',
                      helperText: 'One line, at most 4096 UTF-8 bytes; no shell safety validation.',
                    ),
                    onChanged: (_) => setState(() {}),
                  )
                else
                  const Text('Stored command remains withheld and unchanged.'),
                if (error != null) Text(error),
              ],
              const SizedBox(height: 12),
              FilledButton(
                key: const Key('cron-editor-next'),
                onPressed: current && error == null
                    ? () {
                        CronTaskCommand? capsule;
                        try {
                          if (_replace) {
                            capsule = CronTaskCommand.fromText(_command.text);
                          }
                          final request = CronTasksRequest(
                            inventory: widget.inventory,
                            action: widget.task == null
                                ? CronTasksAction.create
                                : CronTasksAction.edit,
                            task: widget.task,
                            settings: effective,
                            command: capsule,
                          );
                          if (request.validationError != null) {
                            capsule?.dispose();
                            return;
                          }
                          _closing = true;
                          _clear();
                          Navigator.of(context).pop(request);
                        } on Object {
                          capsule?.dispose();
                          _expire();
                        }
                      }
                    : null,
                child: const Text('Review exact cron change'),
              ),
              TextButton(
                key: const Key('cron-editor-cancel'),
                onPressed: () {
                  _closing = true;
                  _clear();
                  Navigator.of(context).pop();
                },
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CronReview extends ConsumerStatefulWidget {
  const _CronReview({required this.session, required this.review});
  final AuthenticatedSession session;
  final CronTasksReview review;
  @override
  ConsumerState<_CronReview> createState() => _CronReviewState();
}

class _CronReviewState extends ConsumerState<_CronReview> {
  final _confirmation = TextEditingController();
  bool _impact = false,
      _execution = false,
      _command = false,
      _disclosure = false,
      _expired = false,
      _closing = false;
  late final AppLifecycleListener _lifecycle;
  late final Timer _expiry;
  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onStateChange: (s) {
        if (s != AppLifecycleState.resumed) _expire();
      },
    );
    _expiry = Timer(const Duration(minutes: 5), _expire);
  }

  void _clear() {
    _confirmation.clear();
    _impact = false;
    _execution = false;
    _command = false;
    _disclosure = false;
  }

  void _expire() {
    if (!mounted || _expired || _closing) return;
    setState(() {
      _expired = true;
      _clear();
    });
    ref.read(cronTasksControllerProvider.notifier).expireContext();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _expiry.cancel();
    _clear();
    _confirmation.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.review, request = r.request;
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(cronTasksInventoryProvider, (_, v) {
      if (v.isLoading || !identical(request.inventory, v.asData?.value)) {
        _expire();
      }
    });
    if (ModalRoute.isCurrentOf(context) == false && !_closing && !_expired) {
      _expired = true;
      _clear();
      ref.read(cronTasksControllerProvider.notifier).abandonRoute();
    }
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        identical(
          request.inventory,
          ref.watch(cronTasksInventoryProvider).asData?.value,
        ) &&
        ref.read(cronTasksControllerProvider.notifier).isReviewCurrent(r);
    final enables = request.action == CronTasksAction.enable,
        runs = request.action == CronTasksAction.run,
        needsCommand =
            enables ||
            runs ||
            request.action == CronTasksAction.create ||
            request.action == CronTasksAction.edit,
        s = request.settings ?? request.task?.settings;
    final confirmed =
        current &&
        _impact &&
        (!(enables || runs) || _execution && _disclosure) &&
        (!needsCommand || _command) &&
        _confirmation.text == r.target;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('cron-review-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? 'Review cron ${request.action.name}'
                    : 'Cron review expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              Text('Server: ${r.endpoint}'),
              Text('Host: ${request.inventory.hostId}'),
              if (request.task != null)
                Text(
                  'Task #${request.task!.id} · currently ${request.task!.enabled ? 'enabled' : 'disabled'}',
                ),
              if (s != null) ...[
                Text('Account: ${s.user}'),
                Text('Description: ${s.description}'),
                Text(
                  'Schedule: ${s.schedule.expression} (${request.inventory.timezone})',
                ),
                Text(
                  'Suppress stdout: ${s.hideStdout}; stderr: ${s.hideStderr}',
                ),
              ],
              if (request.action == CronTasksAction.edit) ...[
                const Text(
                  'Changed fields (all other selected fields preserved):',
                ),
                if (request.task!.settings.user != s!.user)
                  Text('Account: ${request.task!.settings.user} → ${s.user}'),
                if (request.task!.settings.description != s.description)
                  Text(
                    'Description: ${request.task!.settings.description} → ${s.description}',
                  ),
                if (request.task!.settings.schedule.expression !=
                    s.schedule.expression)
                  Text(
                    'Schedule: ${request.task!.settings.schedule.expression} → ${s.schedule.expression}',
                  ),
                if (request.task!.settings.hideStdout != s.hideStdout)
                  Text(
                    'Suppress stdout: ${request.task!.settings.hideStdout} → ${s.hideStdout}',
                  ),
                if (request.task!.settings.hideStderr != s.hideStderr)
                  Text(
                    'Suppress stderr: ${request.task!.settings.hideStderr} → ${s.hideStderr}',
                  ),
              ],
              Text(
                request.command == null
                    ? request.action == CronTasksAction.delete
                          ? 'Stored command: withheld; the selected saved task will be deleted, without cancelling running commands.'
                          : 'Stored command: preserved and withheld'
                    : 'Replacement command: ${request.command!.byteLength} UTF-8 bytes; text withheld',
              ),
              if (request.action == CronTasksAction.create)
                const Text(
                  'New task will be disabled. Enabling is a separate action.',
                ),
              for (final warning in r.warnings)
                Padding(
                  padding: const EdgeInsets.only(top: 12),
                  child: Text(warning),
                ),
              CheckboxListTile(
                key: const Key('cron-consent-impact'),
                contentPadding: EdgeInsets.zero,
                title: const Text(
                  'I accept global schedule regeneration and non-atomic changes. Disabling or deleting does not cancel running, fetched or queued commands; errors are not rollback.',
                ),
                value: _impact,
                onChanged: current
                    ? (v) => setState(() => _impact = v == true)
                    : null,
              ),
              if (needsCommand)
                CheckboxListTile(
                  key: const Key('cron-consent-command'),
                  contentPadding: EdgeInsets.zero,
                  title: const Text(
                    'I independently verified the command, selected local account privileges and schedule. Arbitrary shell actions can damage the appliance or data; no command safety check or test run was performed.',
                  ),
                  value: _command,
                  onChanged: current
                      ? (v) => setState(() => _command = v == true)
                      : null,
                ),
              if (enables || runs) ...[
                CheckboxListTile(
                  key: const Key('cron-consent-execution'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    runs
                        ? 'I authorize this exact enabled task to start immediately once. It can wait, run or fail without a timeout or further confirmation.'
                        : 'I authorize this preserved command to execute automatically at matching server-local schedule times, potentially without a timeout or further confirmation.',
                  ),
                  value: _execution,
                  onChanged: current
                      ? (v) => setState(() => _execution = v == true)
                      : null,
                ),
                CheckboxListTile(
                  key: const Key('cron-consent-disclosure'),
                  contentPadding: EdgeInsets.zero,
                  title: Text(
                    runs
                        ? 'I accept that command text, output and failures can reach middleware logs and the selected account’s configured email destination. This app does not read them or poll the job.'
                        : 'I accept that command text, output and failures can reach middleware logs and the selected account’s configured email destination. Output suppression is not a secrecy guarantee.',
                  ),
                  value: _disclosure,
                  onChanged: current
                      ? (v) => setState(() => _disclosure = v == true)
                      : null,
                ),
              ],
              Text('Type exactly: ${r.target}'),
              TextField(
                key: const Key('cron-confirmation'),
                controller: _confirmation,
                enabled: current,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'Exact target confirmation',
                ),
                onChanged: (_) => setState(() {}),
              ),
              FilledButton(
                key: const Key('cron-submit'),
                onPressed: confirmed
                    ? () {
                        _closing = true;
                        _clear();
                        Navigator.of(context).pop(true);
                      }
                    : null,
                child: Text(
                  runs
                      ? 'Submit manual run once'
                      : 'Apply reviewed cron change once',
                ),
              ),
              TextButton(
                key: const Key('cron-review-cancel'),
                onPressed: () {
                  _closing = true;
                  _clear();
                  Navigator.of(context).pop(false);
                },
                child: const Text('Cancel'),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
