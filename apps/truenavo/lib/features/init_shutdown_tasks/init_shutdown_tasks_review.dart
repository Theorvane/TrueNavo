import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'init_shutdown_tasks_controller.dart';

String initShutdownTasksActionLabel(InitShutdownTasksAction action) =>
    switch (action) {
      InitShutdownTasksAction.create => 'Create disabled command task',
      InitShutdownTasksAction.replace => 'Replace disabled command task',
      InitShutdownTasksAction.enable => 'Enable command task',
      InitShutdownTasksAction.disable => 'Disable command task',
      InitShutdownTasksAction.delete => 'Delete disabled command task',
    };
String initShutdownTasksImpact(InitShutdownTasksAction action) =>
    switch (action) {
      InitShutdownTasksAction.create => 'Stores a new disabled COMMAND task. No command is run or tested and no lifecycle transition is requested. Activation needs a separate review.',
      InitShutdownTasksAction.replace => 'Replaces the complete command body, phase and wait budget while disabled. The prior body is not shown or filled in; protected empty/null script and existing comment are preserved. No command is run.',
      InitShutdownTasksAction.enable => 'Enabling permits this shell command to run as root at the configured boot/shutdown phase. It can change data and security, contact external systems, expose credentials or prevent boot/shutdown and access. Independently inspect the exact task body before enabling.',
      _ => 'Disabling or deleting a task is not process cancellation. A lifecycle job may already have snapshotted it; commands and descendants already started can continue. This is not a kill switch.',
    };

class InitShutdownTasksReviewDialog extends ConsumerStatefulWidget {
  const InitShutdownTasksReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final InitShutdownTasksReview review;
  @override
  ConsumerState<InitShutdownTasksReviewDialog> createState() =>
      _InitShutdownTasksReviewDialogState();
}

class _InitShutdownTasksReviewDialogState
    extends ConsumerState<InitShutdownTasksReviewDialog> {
  final _target = TextEditingController();
  bool _budget = false,
      _bodyChecked = false,
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
    ref.read(initShutdownTasksControllerProvider.notifier).expireContext();
    setState(() {
      _expired = true;
      _budget = false;
      _bodyChecked = false;
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
      _budget = false;
      _bodyChecked = false;
      ref.read(initShutdownTasksControllerProvider.notifier).abandonRoute();
      scheduleMicrotask(() {
        if (mounted) _target.clear();
      });
    }
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(initShutdownTasksInventoryProvider, (_, next) {
      if (next.isLoading ||
          !identical(widget.review.request.inventory, next.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(initShutdownTasksInventoryProvider),
        state = ref.watch(initShutdownTasksControllerProvider);
    final current =
        !_expired &&
        !_closing &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(inventory.asData?.value, widget.review.request.inventory) &&
        ref
            .read(initShutdownTasksControllerProvider.notifier)
            .isReviewCurrent(widget.review) &&
        widget.review.request.validationError == null;
    final action = widget.review.action;
    final specific = switch (action) {
      InitShutdownTasksAction.enable => 'I authorize this task to run as root and accept boot/shutdown, data, security and external-connection risks.',
      InitShutdownTasksAction.disable || InitShutdownTasksAction.delete => 'I understand this cannot cancel snapshotted, running or descendant processes.',
      _ => null,
    };
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('init-review-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? 'Review ${initShutdownTasksActionLabel(action).toLowerCase()}'
                    : 'Task review expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous server details are hidden. Reload configuration and begin a new review.',
                )
              else ...[
                SelectableText(widget.review.endpoint),
                const SizedBox(height: 12),
                Text(
                  'Task: ${widget.review.request.task?.id ?? 'New disabled COMMAND'}',
                ),
                Text(
                  'Phase: ${widget.review.request.task?.phase.wireName ?? 'Not configured'} → ${action == InitShutdownTasksAction.delete ? 'Removed' : (widget.review.request.settings?.phase ?? widget.review.request.task!.phase).wireName}',
                ),
                Text(
                  'Wait budget: ${widget.review.request.task?.timeoutSeconds ?? 'Not configured'} → ${action == InitShutdownTasksAction.delete ? 'Removed' : widget.review.request.settings?.timeoutSeconds ?? widget.review.request.task!.timeoutSeconds} seconds',
                ),
                Text(
                  'Enabled after change: ${action == InitShutdownTasksAction.enable}',
                ),
                const Text(
                  'Command body, script path and existing comment are withheld. This reference binds the reviewed body; it is not a content preview or security assessment.',
                ),
                SelectableText(widget.review.commandReference),
                const SizedBox(height: 12),
                Text(initShutdownTasksImpact(action)),
                const SizedBox(height: 12),
                const Text(
                  'The wait budget does not reliably stop a command or descendants; they can continue and overlap later tasks. The NAS may store/broadcast task rows and log command text/output. A configuration write can precede an error. No execution test, automatic retry or polling is offered.',
                ),
                if (widget.review.warnings.isNotEmpty)
                  ExpansionTile(
                    key: const Key('init-review-details'),
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
                  key: const Key('init-confirm-target'),
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
                  key: const Key('init-confirm-impact'),
                  contentPadding: EdgeInsets.zero,
                  value: _impact,
                  onChanged: (value) =>
                      setState(() => _impact = value ?? false),
                  title: const Text(
                    'I authorize this task configuration change; verified settings do not prove safe or successful execution.',
                  ),
                ),
                if (specific != null)
                  CheckboxListTile(
                    key: const Key('init-confirm-specific'),
                    contentPadding: EdgeInsets.zero,
                    value: _specific,
                    onChanged: (value) =>
                        setState(() => _specific = value ?? false),
                    title: Text(specific),
                  ),
              ],
              if (current && action == InitShutdownTasksAction.enable) ...[
                CheckboxListTile(
                  key: const Key('init-confirm-body'),
                  contentPadding: EdgeInsets.zero,
                  value: _bodyChecked,
                  onChanged: (v) => setState(() => _bodyChecked = v ?? false),
                  title: const Text(
                    'I independently inspected the exact command body for this task and verified trusted console/recovery access.',
                  ),
                ),
                CheckboxListTile(
                  key: const Key('init-confirm-budget'),
                  contentPadding: EdgeInsets.zero,
                  value: _budget,
                  onChanged: (v) => setState(() => _budget = v ?? false),
                  title: const Text(
                    'I accept that wait expiry is not reliable termination and tasks may overlap or delay boot/shutdown.',
                  ),
                ),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('init-review-cancel'),
                    onPressed: () => _finish(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('init-confirm-submit'),
                    style:
                        action == InitShutdownTasksAction.delete ||
                            action == InitShutdownTasksAction.enable
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
                            (action != InitShutdownTasksAction.enable ||
                                (_bodyChecked && _budget)) &&
                            _target.text == widget.review.target
                        ? () => _finish(true)
                        : null,
                    child: Text(initShutdownTasksActionLabel(action)),
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
