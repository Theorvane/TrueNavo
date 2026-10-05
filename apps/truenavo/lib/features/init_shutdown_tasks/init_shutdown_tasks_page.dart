import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'init_shutdown_tasks_charts.dart';
import 'init_shutdown_tasks_controller.dart';
import 'init_shutdown_tasks_editor.dart';
import 'init_shutdown_tasks_review.dart';

class InitShutdownTasksPage extends ConsumerStatefulWidget {
  const InitShutdownTasksPage({super.key});
  @override
  ConsumerState<InitShutdownTasksPage> createState() =>
      _InitShutdownTasksPageState();
}

class _InitShutdownTasksPageState extends ConsumerState<InitShutdownTasksPage> {
  bool _working = false, _ownModalOpen = false, _routeAbandoned = false;
  late final InitShutdownTasksController _controller;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(initShutdownTasksControllerProvider.notifier);
  }

  @override
  void dispose() {
    _controller.abandonRoute();
    super.dispose();
  }

  bool get _routeCurrent =>
      mounted && ModalRoute.of(context)?.isCurrent == true;
  Future<void> _change(
    AuthenticatedSession session,
    InitShutdownTasksInventory inventory,
    InitShutdownTasksAction action, [
    InitShutdownTaskSnapshot? service,
  ]) async {
    if (_working) return;
    setState(() => _working = true);
    var expired = false;
    final lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) expired = true;
      },
    );
    final sessions = ref.listenManual(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) expired = true;
    });
    final inventories = ref.listenManual(initShutdownTasksInventoryProvider, (
      _,
      next,
    ) {
      if (next.isLoading || !identical(inventory, next.asData?.value)) {
        expired = true;
      }
    });
    bool current() =>
        _routeCurrent &&
        !expired &&
        identical(session, ref.read(dashboardActiveSessionProvider)) &&
        !ref.read(initShutdownTasksInventoryProvider).isLoading &&
        identical(
          inventory,
          ref.read(initShutdownTasksInventoryProvider).asData?.value,
        );
    try {
      if (!current()) return;
      InitShutdownTasksRequest? request;
      if (action == InitShutdownTasksAction.create ||
          action == InitShutdownTasksAction.replace) {
        setState(() => _ownModalOpen = true);
        try {
          request = await showDialog<InitShutdownTasksRequest>(
            context: context,
            barrierDismissible: false,
            builder: (_) => InitShutdownTasksEditorDialog(
              session: session,
              inventory: inventory,
              action: action,
              task: service,
            ),
          );
        } finally {
          if (mounted) setState(() => _ownModalOpen = false);
        }
      } else {
        request = InitShutdownTasksRequest(
          inventory: inventory,
          action: action,
          task: service,
        );
      }
      if (request == null || !current()) {
        request?.command?.dispose();
        _controller.abandonRoute();
        return;
      }
      final review = await _controller.review(
        expectedSession: session,
        request: request,
        isRouteCurrent: () => _routeCurrent,
      );
      if (!mounted || !current()) {
        _controller.abandonRoute();
        return;
      }
      if (review == null) return;
      bool? confirmed;
      setState(() => _ownModalOpen = true);
      try {
        confirmed = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) =>
              InitShutdownTasksReviewDialog(session: session, review: review),
        );
      } finally {
        if (mounted) setState(() => _ownModalOpen = false);
      }
      if (confirmed != true || !current()) {
        _controller.expireContext();
        return;
      }
      await _controller.execute(
        expectedSession: session,
        review: review,
        confirmation: review.target,
        configurationImpactAccepted: true,
        rootExecutionAccepted: true,
        independentlyInspectedCommand: true,
        waitBudgetRiskAccepted: true,
        noCancellationAccepted: true,
        isRouteCurrent: () => _routeCurrent,
      );
    } finally {
      lifecycle.dispose();
      sessions.close();
      inventories.close();
      if (mounted) setState(() => _working = false);
    }
  }

  Widget _status(InitShutdownTasksState state) => TdPanel(
    title: state.status == InitShutdownTasksStatus.completed
        ? 'Configuration verified — execution not established'
        : state.unresolved
        ? 'Inspect the original server'
        : 'Init/shutdown task status',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(state.message!),
        if (state.server != null) Text('Original server: ${state.server}'),
        if (state.unresolved) ...[
          const Text(
            'Management writes remain locked across navigation and connection changes. Reconnect manually to the original address with normal authentication and certificate trust, then explicitly verify its identity and inspect task settings, command bodies and active processes independently. No retry, polling or replay is offered.',
          ),
          OutlinedButton(
            key: const Key('init-verify-reconnected'),
            onPressed: _controller.canVerifyReconnectedServer
                ? _controller.verifyReconnectedServer
                : null,
            child: const Text('Verify reconnected original server once'),
          ),
          if (state.verificationMessage != null)
            Text(state.verificationMessage!),
          OutlinedButton(
            key: const Key('init-acknowledge'),
            onPressed: _controller.canAcknowledge
                ? _controller.acknowledgeAfterReconnect
                : null,
            child: const Text(
              'I independently inspected task settings and running processes',
            ),
          ),
        ],
      ],
    ),
  );

  Widget _configuration(
    AuthenticatedSession session,
    InitShutdownTasksInventory inventory,
    bool idle,
  ) {
    final caps = ref
        .read(initShutdownTasksSessionProvider)!
        .initShutdownTasksCapabilities;
    bool allowed(
      InitShutdownTasksAction action, [
      InitShutdownTaskSnapshot? task,
    ]) =>
        idle &&
        caps.supports(action) &&
        inventory.blockedReason == null &&
        switch (action) {
          InitShutdownTasksAction.create => inventory.tasks.length < 128,
          InitShutdownTasksAction.replace =>
            task?.isCommand == true && !task!.enabled,
          _ =>
            InitShutdownTasksRequest(
                  inventory: inventory,
                  action: action,
                  task: task,
                ).validationError ==
                null,
        };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TdPanel(
          title: 'Configured lifecycle tasks',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${inventory.tasks.length} tasks · ${inventory.tasks.where((t) => t.enabled).length} enabled',
              ),
              Text(
                'TrueNAS ${inventory.currentVersion} · ${inventory.readiness.state}',
              ),
              const Text(
                'Command bodies, script paths and comments are withheld.',
              ),
              if (inventory.blockedReason != null)
                Text(inventory.blockedReason!),
            ],
          ),
        ),
        const SizedBox(height: 12),
        InitShutdownTasksCharts(tasks: inventory.tasks),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('init-create'),
          onPressed: allowed(InitShutdownTasksAction.create)
              ? () =>
                    _change(session, inventory, InitShutdownTasksAction.create)
              : null,
          icon: const Icon(Icons.add),
          label: const Text('Create disabled command task'),
        ),
        const Text(
          'No run-now, reboot or shutdown control. Wait budgets do not reliably terminate commands.',
        ),
        ExpansionTile(
          key: const Key('init-readiness-details'),
          title: const Text('Server readiness & safety details'),
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Full administrator: ${inventory.readiness.fullAdmin} · HA: ${inventory.readiness.failoverLicensed}',
                ),
                Text(
                  'Boot pool: ${inventory.readiness.bootPool} · Healthy: ${inventory.readiness.bootHealthy}',
                ),
                Text(
                  'Visible conflicting jobs: ${inventory.readiness.conflictingJob}',
                ),
                const Text(
                  'Enabling permits root shell execution at a lifecycle phase. Commands can affect data, security, availability and external systems. No phase guarantees application, network or storage readiness. SCRIPT tasks remain protected.',
                ),
                const Text(
                  'The NAS stores task rows and may broadcast them or log command text/output. This app does not subscribe to task events. Configuration counts do not prove execution or cancellation.',
                ),
                const Text('Full public host identity'),
                SelectableText(inventory.hostId),
              ],
            ),
          ],
        ),
        if (inventory.tasks.isEmpty)
          const Text(
            'No configured lifecycle tasks. This is not proof that no other startup code exists.',
          ),
        for (final task in inventory.tasks)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TdPanel(
              title: 'Task #${task.id}',
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${task.type} · ${task.phase.wireName} · ${task.enabled ? 'Enabled' : 'Disabled'}',
                  ),
                  Text(
                    'Configured wait budget: ${task.timeoutSeconds} seconds',
                  ),
                  if (task.blockedReason != null) Text(task.blockedReason!),
                  if (task.timeoutSeconds < 1 || task.timeoutSeconds > 300)
                    const Text(
                      'Legacy wait budget outside the app 1–300 second editing/enabling subset. No duration guarantee is inferred.',
                    ),
                  if (task.isCommand)
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          key: Key('init-replace-${task.id}'),
                          onPressed:
                              allowed(InitShutdownTasksAction.replace, task)
                              ? () => _change(
                                  session,
                                  inventory,
                                  InitShutdownTasksAction.replace,
                                  task,
                                )
                              : null,
                          child: const Text('Replace while disabled'),
                        ),
                        OutlinedButton(
                          key: Key('init-toggle-${task.id}'),
                          onPressed:
                              allowed(
                                task.enabled
                                    ? InitShutdownTasksAction.disable
                                    : InitShutdownTasksAction.enable,
                                task,
                              )
                              ? () => _change(
                                  session,
                                  inventory,
                                  task.enabled
                                      ? InitShutdownTasksAction.disable
                                      : InitShutdownTasksAction.enable,
                                  task,
                                )
                              : null,
                          child: Text(
                            task.enabled
                                ? 'Review disabling'
                                : 'Review enabling',
                          ),
                        ),
                        TextButton(
                          key: Key('init-delete-${task.id}'),
                          onPressed:
                              allowed(InitShutdownTasksAction.delete, task)
                              ? () => _change(
                                  session,
                                  inventory,
                                  InitShutdownTasksAction.delete,
                                  task,
                                )
                              : null,
                          child: const Text('Review deletion'),
                        ),
                      ],
                    ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final routeCurrent = ModalRoute.isCurrentOf(context) != false;
    if (routeCurrent) _routeAbandoned = false;
    if (!routeCurrent && !_ownModalOpen && !_routeAbandoned && _working) {
      _routeAbandoned = true;
      _controller.abandonRoute();
    }
    final session = ref.watch(dashboardActiveSessionProvider),
        caps = ref
            .watch(initShutdownTasksSessionProvider)
            ?.initShutdownTasksCapabilities,
        state = ref.watch(initShutdownTasksControllerProvider);
    final available = session?.endpoint != null && caps?.supported == true,
        idle = !state.busy && !state.locked && !_working;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Init / Shutdown tasks'),
        actions: [
          IconButton(
            key: const Key('init-refresh'),
            tooltip: 'Read task headers',
            onPressed: available && idle
                ? _controller.refreshConfiguration
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          key: const Key('init-scroll'),
          padding: const EdgeInsets.all(20),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'SYSTEM · LIFECYCLE TASKS',
                    style: TdTypography.micro,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Init / Shutdown tasks',
                    style: TdTypography.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(session?.endpoint ?? 'No authenticated connection'),
                  const SizedBox(height: 12),
                  const Text(
                    'Configured lifecycle rows only — not execution measurements.',
                  ),
                  if (state.busy || state.verifying)
                    const LinearProgressIndicator(),
                  if (state.message != null) _status(state),
                  const SizedBox(height: 16),
                  if (!available)
                    TdPanel(
                      title: 'Task configuration unavailable',
                      child: Text(
                        caps?.blockedReason ??
                            'Connect to a supported TrueNAS instance.',
                      ),
                    )
                  else if (state.locked)
                    const TdPanel(
                      title: 'Task change needs attention',
                      child: Text(
                        'No automatic inventory refresh occurs while a write is executing or unresolved. A lost connection is not proof of success or successful execution.',
                      ),
                    )
                  else if (state.status == InitShutdownTasksStatus.completed ||
                      state.status == InitShutdownTasksStatus.rejected)
                    TdPanel(
                      title: 'Read fresh configuration before another change',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'The previous inventory and charts are hidden because that review is consumed or expired. No automatic refresh occurs.',
                          ),
                          OutlinedButton(
                            key: const Key('init-refresh-after-review'),
                            onPressed: idle
                                ? _controller.refreshConfiguration
                                : null,
                            child: const Text('Read fresh configuration'),
                          ),
                        ],
                      ),
                    )
                  else
                    ref
                        .watch(initShutdownTasksInventoryProvider)
                        .when(
                          skipLoadingOnRefresh: false,
                          skipLoadingOnReload: false,
                          loading: () =>
                              const Center(child: CircularProgressIndicator()),
                          error: (_, _) => TdPanel(
                            title: 'Task configuration could not be verified',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Text(
                                  'Public configuration or readiness was unavailable. Remote details were withheld; unknown does not mean ready.',
                                ),
                                OutlinedButton(
                                  key: const Key('init-retry'),
                                  onPressed: idle
                                      ? _controller.refreshConfiguration
                                      : null,
                                  child: const Text(
                                    'Retry configuration reads',
                                  ),
                                ),
                              ],
                            ),
                          ),
                          data: (inventory) =>
                              _configuration(session!, inventory, idle),
                        ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
