import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'init_shutdown_tasks_controller.dart';

class InitShutdownTasksEditorDialog extends ConsumerStatefulWidget {
  const InitShutdownTasksEditorDialog({
    required this.session,
    required this.inventory,
    required this.action,
    this.task,
    super.key,
  });
  final AuthenticatedSession session;
  final InitShutdownTasksInventory inventory;
  final InitShutdownTasksAction action;
  final InitShutdownTaskSnapshot? task;
  @override
  ConsumerState<InitShutdownTasksEditorDialog> createState() =>
      _InitShutdownTasksEditorDialogState();
}

class _InitShutdownTasksEditorDialogState
    extends ConsumerState<InitShutdownTasksEditorDialog> {
  late final TextEditingController _command, _timeout;
  late InitShutdownTaskPhase _phase;
  bool _expired = false, _closing = false;
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    _command = TextEditingController();
    _timeout = TextEditingController(
      text: '${widget.task?.timeoutSeconds ?? 10}',
    );
    _phase = widget.task?.phase ?? InitShutdownTaskPhase.postinit;
    final initial = WidgetsBinding.instance.lifecycleState;
    _expired = initial != null && initial != AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) _expire();
      },
    );
  }

  void _clear() {
    _command.clear();
    _timeout.clear();
  }

  void _expire() {
    if (_expired || _closing || !mounted) return;
    ref.read(initShutdownTasksControllerProvider.notifier).expireContext();
    setState(() {
      _expired = true;
      _clear();
    });
  }

  InitShutdownTasksRequest _request(InitShutdownTaskCommand command) =>
      InitShutdownTasksRequest(
        inventory: widget.inventory,
        action: widget.action,
        task: widget.task,
        settings: InitShutdownTaskSettings(
          phase: _phase,
          timeoutSeconds: int.tryParse(_timeout.text) ?? 0,
        ),
        command: command,
      );
  String? get _validation {
    final command = InitShutdownTaskCommand(_command.text);
    try {
      return _request(command).validationError;
    } finally {
      command.dispose();
    }
  }

  void _submit() {
    final command = InitShutdownTaskCommand(_command.text),
        request = _request(command);
    if (request.validationError != null) {
      command.dispose();
      return;
    }
    _finish(request);
  }

  void _finish(InitShutdownTasksRequest? request) {
    _closing = true;
    _clear();
    Navigator.of(context).pop(request);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _clear();
    _command.dispose();
    _timeout.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (ModalRoute.isCurrentOf(context) == false && !_closing && !_expired) {
      _expired = true;
      ref.read(initShutdownTasksControllerProvider.notifier).abandonRoute();
      scheduleMicrotask(() {
        if (mounted) _clear();
      });
    }
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(initShutdownTasksInventoryProvider, (_, next) {
      if (next.isLoading || !identical(widget.inventory, next.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(initShutdownTasksInventoryProvider);
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
          key: const Key('init-editor-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? widget.action == InitShutdownTasksAction.create
                          ? 'Create disabled command task'
                          : 'Replace disabled command task'
                    : 'Task editor expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous server fields were cleared. Reload configuration and begin again.',
                )
              else ...[
                const Text(
                  'Manually enter one new command body. Existing commands, script paths and comments are never loaded into this editor. Creation and replacement remain disabled.',
                ),
                const SizedBox(height: 12),
                TextField(
                  key: const Key('init-command'),
                  controller: _command,
                  obscureText: true,
                  maxLength: 300,
                  autocorrect: false,
                  enableSuggestions: false,
                  enableIMEPersonalizedLearning: false,
                  autofillHints: const [],
                  decoration: const InputDecoration(
                    labelText: 'New command body (write-only)',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const Text(
                  'One line, printable ASCII, 1–300 characters. Shell syntax is not validated or executed. This app clears its input after hand-off; the NAS may store or log command text and output.',
                ),
                const SizedBox(height: 12),
                const Text('Execution phase'),
                for (final phase in InitShutdownTaskPhase.values)
                  Semantics(
                    checked: _phase == phase,
                    inMutuallyExclusiveGroup: true,
                    child: ListTile(
                      key: Key('init-phase-${phase.name}'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        _phase == phase
                            ? Icons.radio_button_checked
                            : Icons.radio_button_unchecked,
                      ),
                      title: Text(phase.wireName),
                      onTap: () => setState(() => _phase = phase),
                    ),
                  ),
                TextField(
                  key: const Key('init-timeout'),
                  controller: _timeout,
                  keyboardType: TextInputType.number,
                  maxLength: 3,
                  decoration: const InputDecoration(
                    labelText: 'Wait budget in seconds (1–300)',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                const Text(
                  'A wait budget is not a process-kill deadline. Commands and descendants can continue and overlap later tasks after the wait expires.',
                ),
                if (_validation != null) Text(_validation!),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('init-editor-cancel'),
                    onPressed: () => _finish(null),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('init-editor-review'),
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
