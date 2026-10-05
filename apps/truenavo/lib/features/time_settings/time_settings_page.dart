import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'time_settings_charts.dart';
import 'time_settings_controller.dart';
import 'time_settings_editor.dart';
import 'time_settings_review.dart';

class TimeSettingsPage extends ConsumerStatefulWidget {
  const TimeSettingsPage({super.key});
  @override
  ConsumerState<TimeSettingsPage> createState() => _TimeSettingsPageState();
}

class _TimeSettingsPageState extends ConsumerState<TimeSettingsPage> {
  bool _working = false, _ownModalOpen = false, _routeAbandoned = false;
  late final TimeSettingsController _controller;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(timeSettingsControllerProvider.notifier);
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
    TimeSettingsInventory inventory,
    TimeSettingsAction action, [
    NtpServerSnapshot? server,
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
    final inventories = ref.listenManual(timeSettingsInventoryProvider, (
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
        !ref.read(timeSettingsInventoryProvider).isLoading &&
        identical(
          inventory,
          ref.read(timeSettingsInventoryProvider).asData?.value,
        );
    try {
      if (!current()) return;
      TimeSettingsRequest? request;
      if (action == TimeSettingsAction.deleteNtp) {
        request = TimeSettingsRequest(
          inventory: inventory,
          action: action,
          server: server,
        );
      } else {
        setState(() => _ownModalOpen = true);
        try {
          request = await showDialog<TimeSettingsRequest>(
            context: context,
            barrierDismissible: false,
            builder: (_) => TimeSettingsEditorDialog(
              session: session,
              inventory: inventory,
              action: action,
              server: server,
            ),
          );
        } finally {
          if (mounted) setState(() => _ownModalOpen = false);
        }
      }
      if (request == null || !current()) {
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
              TimeSettingsReviewDialog(session: session, review: review),
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
        serviceImpactAccepted: true,
        probeAccepted: true,
        scheduleImpactAccepted: true,
        remainingSourcesAccepted: true,
        controlledBurstAccepted: true,
        isRouteCurrent: () => _routeCurrent,
      );
    } finally {
      lifecycle.dispose();
      sessions.close();
      inventories.close();
      if (mounted) setState(() => _working = false);
    }
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
        caps = ref.watch(timeSettingsSessionProvider)?.timeSettingsCapabilities,
        state = ref.watch(timeSettingsControllerProvider);
    final available = session?.endpoint != null && caps?.supported == true,
        idle = !state.busy && !state.locked && !_working;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Time settings'),
        actions: [
          IconButton(
            key: const Key('time-refresh'),
            tooltip: 'Read time configuration',
            onPressed: available && idle
                ? _controller.refreshConfiguration
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          key: const Key('time-scroll'),
          padding: const EdgeInsets.all(20),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'SYSTEM · TIME CONFIGURATION',
                    style: TdTypography.micro,
                  ),
                  const SizedBox(height: 8),
                  const Text('Timezone & NTP', style: TdTypography.titleLarge),
                  const SizedBox(height: 12),
                  Text(session?.endpoint ?? 'No authenticated connection'),
                  const SizedBox(height: 12),
                  const Text(
                    'Configured API sources only — not live synchronization.',
                  ),
                  if (state.busy || state.verifying)
                    const LinearProgressIndicator(),
                  if (state.message != null)
                    TdPanel(
                      title: state.status == TimeSettingsStatus.completed
                          ? 'Configuration verified — clock state unknown'
                          : state.unresolved
                          ? 'Inspect the original server'
                          : 'Time-settings status',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(state.message!),
                          if (state.server != null)
                            Text('Original server: ${state.server}'),
                          if (state.unresolved) ...[
                            const Text(
                              'Management writes remain locked across navigation and connection changes. Reconnect manually to the original address with normal authentication and certificate trust, then verify the original host and inspect its configuration independently. No retry, polling or replay is offered.',
                            ),
                            OutlinedButton(
                              key: const Key('time-verify-reconnected'),
                              onPressed: _controller.canVerifyReconnectedServer
                                  ? _controller.verifyReconnectedServer
                                  : null,
                              child: const Text(
                                'Verify reconnected original server once',
                              ),
                            ),
                            if (state.verificationMessage != null)
                              Text(state.verificationMessage!),
                            OutlinedButton(
                              key: const Key('time-acknowledge'),
                              onPressed: _controller.canAcknowledge
                                  ? _controller.acknowledgeAfterReconnect
                                  : null,
                              child: const Text(
                                'I independently inspected the configured values',
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  if (!available)
                    TdPanel(
                      title: 'Time configuration unavailable',
                      child: Text(
                        caps?.blockedReason ??
                            'Connect to a supported TrueNAS instance.',
                      ),
                    )
                  else if (state.locked)
                    const TdPanel(
                      title: 'Time change needs attention',
                      child: Text(
                        'No automatic inventory refresh occurs while a write is executing or unresolved. A lost connection is not proof of success.',
                      ),
                    )
                  else if (state.status == TimeSettingsStatus.completed ||
                      state.status == TimeSettingsStatus.rejected)
                    TdPanel(
                      title: 'Read fresh configuration before another change',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'The previous inventory and its charts are hidden because that review is consumed or expired. They must not be presented as current configuration. No automatic refresh occurs.',
                          ),
                          OutlinedButton(
                            key: const Key('time-refresh-after-review'),
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
                        .watch(timeSettingsInventoryProvider)
                        .when(
                          skipLoadingOnRefresh: false,
                          skipLoadingOnReload: false,
                          loading: () =>
                              const Center(child: CircularProgressIndicator()),
                          error: (_, _) => TdPanel(
                            title: 'Time configuration could not be verified',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Text(
                                  'Public configuration or readiness was unavailable. Remote details were withheld; unknown does not mean ready.',
                                ),
                                OutlinedButton(
                                  key: const Key('time-retry'),
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
                          data: (inventory) => Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TdPanel(
                                title: 'Current configuration',
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text('Timezone: ${inventory.timezone}'),
                                    Text(
                                      'Configured API sources: ${inventory.servers.length}',
                                    ),
                                    Text(
                                      'Version: ${inventory.currentVersion} · State: ${inventory.state}',
                                    ),
                                    if (inventory.blockedReason != null)
                                      Text(inventory.blockedReason!),
                                    if (inventory.blockedReason == null &&
                                        inventory.timezoneBlockedReason != null)
                                      Text(inventory.timezoneBlockedReason!),
                                    Material(
                                      color: Colors.transparent,
                                      child: ExpansionTile(
                                        key: const Key(
                                          'time-readiness-details',
                                        ),
                                        tilePadding: EdgeInsets.zero,
                                        title: const Text(
                                          'Server readiness details',
                                        ),
                                        children: [
                                          Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.stretch,
                                            children: [
                                              Text(
                                                'Full administrator: ${inventory.fullAdmin ? 'Verified' : 'Not verified — viewing only'}',
                                              ),
                                              Text(
                                                'HA licensed: ${inventory.failoverLicensed ? 'Yes' : 'No'} · Conflicting jobs: ${inventory.conflictingJob ? 'Yes' : 'None in last read'}',
                                              ),
                                              Text(
                                                'Boot pool: ${inventory.bootPool} · Boot readiness: ${inventory.bootHealthy ? 'Healthy in last read' : 'Not ready'}',
                                              ),
                                              Text(
                                                'GUI rollback: ${!inventory.guiRollbackKnown
                                                    ? 'Unknown'
                                                    : inventory.guiRollbackSeconds == null
                                                    ? 'None reported'
                                                    : 'Pending (${inventory.guiRollbackSeconds} seconds reported)'}',
                                              ),
                                              const Text(
                                                'GUI rollback restores GUI fields, not timezone. It must be resolved independently before a timezone edit.',
                                              ),
                                              const Text(
                                                'Full public host identity',
                                              ),
                                              SelectableText(inventory.hostId),
                                            ],
                                          ),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              TimeSettingsCharts(servers: inventory.servers),
                              const SizedBox(height: 12),
                              const ExpansionTile(
                                key: Key('time-scope-details'),
                                title: Text(
                                  'Configuration scope & safety details',
                                ),
                                children: [
                                  Padding(
                                    padding: EdgeInsets.only(bottom: 16),
                                    child: Text(
                                      'These are configured API rows, not all effective time sources: DHCP and configuration files may supply others. No live peer status, offset, drift, reachability, accuracy or synchronized clock is inferred. Opening this page only reads public configuration; no NTP test or write is started. Verifying a later configuration change does not establish time synchronization.',
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 12),
                              TdPanel(
                                title: 'Timezone',
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      timeSettingsImpact(
                                        TimeSettingsAction.timezone,
                                      ),
                                    ),
                                    if (inventory.timezoneBlockedReason != null)
                                      Text(inventory.timezoneBlockedReason!),
                                    OutlinedButton(
                                      key: const Key('time-edit-timezone'),
                                      onPressed:
                                          idle &&
                                              caps!.supports(
                                                TimeSettingsAction.timezone,
                                              ) &&
                                              inventory.timezoneBlockedReason ==
                                                  null
                                          ? () => _change(
                                              session!,
                                              inventory,
                                              TimeSettingsAction.timezone,
                                            )
                                          : null,
                                      child: const Text('Choose timezone'),
                                    ),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                              Text(
                                'Configured NTP sources',
                                style: Theme.of(context).textTheme.titleLarge,
                              ),
                              const Text(
                                'Create and edit use force=false: the server probes the address on save, even for an options-only edit, and can restart ntpd. No separate test action is available.',
                              ),
                              OutlinedButton.icon(
                                key: const Key('time-create-ntp'),
                                onPressed:
                                    idle &&
                                        caps!.supports(
                                          TimeSettingsAction.createNtp,
                                        ) &&
                                        inventory.blockedReason == null &&
                                        inventory.servers.length < 128
                                    ? () => _change(
                                        session!,
                                        inventory,
                                        TimeSettingsAction.createNtp,
                                      )
                                    : null,
                                icon: const Icon(Icons.add),
                                label: const Text('Add configured NTP source'),
                              ),
                              if (inventory.servers.isEmpty)
                                const Text(
                                  'No configured API sources were returned. This does not describe all effective time sources.',
                                ),
                              for (final server in inventory.servers)
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: TdPanel(
                                    title: server.settings.address,
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Text('Source ID: ${server.id}'),
                                        Text(
                                          'Burst: ${server.settings.burst} · Initial burst: ${server.settings.iburst} · Prefer: ${server.settings.prefer}',
                                        ),
                                        Text(
                                          'Configured polling: ${server.settings.minPoll}–${server.settings.maxPoll} exponents (${pollSeconds(server.settings.minPoll)}–${pollSeconds(server.settings.maxPoll)})',
                                        ),
                                        if (server.settings.validationError !=
                                            null)
                                          Text(
                                            'Existing configuration needs a supported edit: ${server.settings.validationError}',
                                          ),
                                        if (inventory.servers.length < 2)
                                          const Text(
                                            'The last configured API source cannot be deleted here.',
                                          ),
                                        Wrap(
                                          spacing: 8,
                                          runSpacing: 8,
                                          children: [
                                            OutlinedButton(
                                              key: Key(
                                                'time-edit-${server.id}',
                                              ),
                                              onPressed:
                                                  idle &&
                                                      caps!.supports(
                                                        TimeSettingsAction
                                                            .updateNtp,
                                                      ) &&
                                                      inventory.blockedReason ==
                                                          null
                                                  ? () => _change(
                                                      session!,
                                                      inventory,
                                                      TimeSettingsAction
                                                          .updateNtp,
                                                      server,
                                                    )
                                                  : null,
                                              child: const Text('Edit source'),
                                            ),
                                            TextButton(
                                              key: Key(
                                                'time-delete-${server.id}',
                                              ),
                                              onPressed:
                                                  idle &&
                                                      caps!.supports(
                                                        TimeSettingsAction
                                                            .deleteNtp,
                                                      ) &&
                                                      inventory.blockedReason ==
                                                          null &&
                                                      inventory.servers.length >
                                                          1
                                                  ? () => _change(
                                                      session!,
                                                      inventory,
                                                      TimeSettingsAction
                                                          .deleteNtp,
                                                      server,
                                                    )
                                                  : null,
                                              child: const Text(
                                                'Review deletion',
                                              ),
                                            ),
                                          ],
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                            ],
                          ),
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
