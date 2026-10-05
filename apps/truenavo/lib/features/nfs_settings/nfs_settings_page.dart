import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'nfs_settings_charts.dart';
import 'nfs_settings_controller.dart';
import 'nfs_settings_editor.dart';
import 'nfs_settings_review.dart';

class NfsSettingsPage extends ConsumerStatefulWidget {
  const NfsSettingsPage({super.key});
  @override
  ConsumerState<NfsSettingsPage> createState() => _NfsSettingsPageState();
}

class _NfsSettingsPageState extends ConsumerState<NfsSettingsPage> {
  bool _working = false, _ownModalOpen = false, _routeAbandoned = false;
  late final NfsSettingsController _controller;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(nfsSettingsControllerProvider.notifier);
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
    NfsSettingsInventory inventory,
  ) async {
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
    final inventories = ref.listenManual(nfsSettingsInventoryProvider, (
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
        !ref.read(nfsSettingsInventoryProvider).isLoading &&
        identical(
          inventory,
          ref.read(nfsSettingsInventoryProvider).asData?.value,
        );
    try {
      if (!current()) return;
      NfsSettingsRequest? request;
      setState(() => _ownModalOpen = true);
      try {
        request = await showDialog<NfsSettingsRequest>(
          context: context,
          barrierDismissible: false,
          builder: (_) =>
              NfsSettingsEditorDialog(session: session, inventory: inventory),
        );
      } finally {
        if (mounted) setState(() => _ownModalOpen = false);
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
              NfsSettingsReviewDialog(session: session, review: review),
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
        clientImpactAccepted: true,
        bindingExposureAccepted: true,
        isRouteCurrent: () => _routeCurrent,
      );
    } finally {
      lifecycle.dispose();
      sessions.close();
      inventories.close();
      if (mounted) setState(() => _working = false);
    }
  }

  Widget _status(NfsSettingsState state) => TdPanel(
    title: state.status == NfsSettingsStatus.completed
        ? 'Configuration verified — access not established'
        : state.unresolved
        ? 'Inspect the original server'
        : 'NFS settings status',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(state.message!),
        if (state.server != null) Text('Original server: ${state.server}'),
        if (state.unresolved) ...[
          const Text(
            'Management writes remain locked across navigation and connection changes. Reconnect manually to the original address with normal authentication and certificate trust, then explicitly verify its identity and inspect NFS settings and client access independently. No retry, polling or replay is offered.',
          ),
          OutlinedButton(
            key: const Key('nfs-verify-reconnected'),
            onPressed: _controller.canVerifyReconnectedServer
                ? _controller.verifyReconnectedServer
                : null,
            child: const Text('Verify reconnected original server once'),
          ),
          if (state.verificationMessage != null)
            Text(state.verificationMessage!),
          OutlinedButton(
            key: const Key('nfs-acknowledge'),
            onPressed: _controller.canAcknowledge
                ? _controller.acknowledgeAfterReconnect
                : null,
            child: const Text(
              'I independently inspected NFS settings and client access',
            ),
          ),
        ],
      ],
    ),
  );

  Widget _configuration(
    AuthenticatedSession session,
    NfsSettingsInventory inventory,
    bool idle,
  ) {
    final config = inventory.config, settings = config.settings;
    final canEdit =
        idle &&
        ref
            .read(nfsSettingsSessionProvider)!
            .nfsSettingsCapabilities
            .canConfigure &&
        inventory.blockedReason == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TdPanel(
          title: 'Current global configuration',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'NFS ${inventory.serviceState} · ${settings.protocols.join(' + ')}',
              ),
              Text(
                '${config.managedNfsd ? 'Automatic' : 'Manual'} threads: ${config.reportedServers} · ${inventory.enabledExportCount}/${inventory.exports.length} exports enabled',
              ),
              Text('TrueNAS ${inventory.currentVersion}'),
              if (inventory.blockedReason != null)
                Text(inventory.blockedReason!),
              if (!ref
                  .read(nfsSettingsSessionProvider)!
                  .nfsSettingsCapabilities
                  .canConfigure)
                const Text(
                  'Viewing only: the public NFS update method is unavailable.',
                ),
              if (config.allowNonroot)
                const Text(
                  'Non-root source ports are accepted by the existing configuration. This protected setting is not a root-user mapping rule.',
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        NfsSettingsCharts(inventory: inventory),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('nfs-edit'),
          onPressed: canEdit ? () => _change(session, inventory) : null,
          icon: const Icon(Icons.tune),
          label: const Text('Edit global NFS settings'),
        ),
        const Text(
          'Updates require NFS stopped. Manage the service independently; this page never starts or stops it. Protocol and binding changes also require zero enabled exports.',
        ),
        ExpansionTile(
          key: const Key('nfs-protected-details'),
          title: const Text('Protected settings & server readiness'),
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Bindings: ${settings.bindAddresses.isEmpty ? 'All interfaces when started' : settings.bindAddresses.join(', ')}',
                ),
                Text('Start at boot: ${inventory.serviceEnabled} (unchanged)'),
                Text(
                  'Mountd logging: ${settings.mountdLog} · Statd/lockd logging: ${settings.statdLockdLog}',
                ),
                Text(
                  'Mountd / statd / lockd ports: ${config.mountdPort ?? 'Automatic'} / ${config.rpcstatdPort ?? 'Automatic'} / ${config.rpclockdPort ?? 'Automatic'}',
                ),
                Text(
                  'Group-list management: ${config.userdManageGids} · RDMA: ${config.rdma}',
                ),
                Text(
                  'NFSV4 domain: ${config.v4Domain.isEmpty ? 'Not configured' : config.v4Domain}',
                ),
                Text(
                  'Kerberos configured: ${config.v4Krb} · NFS keytab capability: ${config.keytabHasNfsSpn}',
                ),
                const Text(
                  'Keytab capability is not proof that every export requires Kerberos.',
                ),
                Text(
                  'Directory profile configured: ${inventory.directoryConfigured}',
                ),
                Text(
                  'Full administrator: ${inventory.readiness.fullAdmin} · HA: ${inventory.readiness.failoverLicensed}',
                ),
                Text(
                  'Boot pool: ${inventory.readiness.bootPool} · Healthy: ${inventory.readiness.bootHealthy}',
                ),
                Text(
                  'State: ${inventory.readiness.state} · Conflicting jobs: ${inventory.readiness.conflictingJob}',
                ),
                const Text('Public host identity'),
                SelectableText(inventory.hostId),
              ],
            ),
          ],
        ),
        const ExpansionTile(
          key: Key('nfs-scope-details'),
          title: Text('Configuration scope & safety details'),
          children: [
            Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                'These are configured thread and export counts, not clients, active workers, throughput, access or health. Ports, source-port policy, group-list management, Kerberos, RDMA and individual exports remain protected. Configuration writes still regenerate rc settings; changing mountd logging also reloads syslogd. A concurrent service start can race the non-atomic checks and cause restart, client interruption and export regeneration. No DNS, directory health, mount or performance probe is initiated by this app.',
              ),
            ),
          ],
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
        caps = ref.watch(nfsSettingsSessionProvider)?.nfsSettingsCapabilities,
        state = ref.watch(nfsSettingsControllerProvider);
    final available = session?.endpoint != null && caps?.supported == true,
        idle = !state.busy && !state.locked && !_working;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Global NFS settings'),
        actions: [
          IconButton(
            key: const Key('nfs-refresh'),
            tooltip: 'Read NFS configuration',
            onPressed: available && idle
                ? _controller.refreshConfiguration
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          key: const Key('nfs-scroll'),
          padding: const EdgeInsets.all(20),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'SERVICES · GLOBAL NFS',
                    style: TdTypography.micro,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Global NFS settings',
                    style: TdTypography.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(session?.endpoint ?? 'No authenticated connection'),
                  const SizedBox(height: 12),
                  const Text(
                    'Configured capacity and exports — not live clients or throughput.',
                  ),
                  if (state.busy || state.verifying)
                    const LinearProgressIndicator(),
                  if (state.message != null) _status(state),
                  const SizedBox(height: 16),
                  if (!available)
                    TdPanel(
                      title: 'NFS configuration unavailable',
                      child: Text(
                        caps?.blockedReason ??
                            'Connect to a supported TrueNAS instance.',
                      ),
                    )
                  else if (state.locked)
                    const TdPanel(
                      title: 'NFS change needs attention',
                      child: Text(
                        'No automatic inventory refresh occurs while a write is executing or unresolved. A lost connection is not proof of success or working NFS access.',
                      ),
                    )
                  else if (state.status == NfsSettingsStatus.completed ||
                      state.status == NfsSettingsStatus.rejected)
                    TdPanel(
                      title: 'Read fresh configuration before another change',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'The previous inventory and charts are hidden because that review is consumed or expired. No automatic refresh occurs.',
                          ),
                          OutlinedButton(
                            key: const Key('nfs-refresh-after-review'),
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
                        .watch(nfsSettingsInventoryProvider)
                        .when(
                          skipLoadingOnRefresh: false,
                          skipLoadingOnReload: false,
                          loading: () =>
                              const Center(child: CircularProgressIndicator()),
                          error: (_, _) => TdPanel(
                            title: 'NFS configuration could not be verified',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Text(
                                  'Public configuration or readiness was unavailable. Remote details were withheld; unknown does not mean ready.',
                                ),
                                OutlinedButton(
                                  key: const Key('nfs-retry'),
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
