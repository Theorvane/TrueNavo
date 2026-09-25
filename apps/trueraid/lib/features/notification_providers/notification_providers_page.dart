import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../alert_settings/alert_settings_page.dart';
import 'notification_providers_charts.dart';
import 'notification_providers_controller.dart';
import 'notification_providers_editor.dart';
import 'notification_providers_review.dart';

class NotificationProvidersPage extends ConsumerStatefulWidget {
  const NotificationProvidersPage({super.key});
  @override
  ConsumerState<NotificationProvidersPage> createState() =>
      _NotificationProvidersPageState();
}

class _NotificationProvidersPageState
    extends ConsumerState<NotificationProvidersPage> {
  bool _working = false, _ownModalOpen = false, _routeAbandoned = false;
  late final NotificationProvidersController _controller;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(notificationProvidersControllerProvider.notifier);
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
    NotificationProvidersInventory inventory,
    NotificationProvidersAction action, [
    NotificationProviderSnapshot? service,
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
    final inventories = ref.listenManual(
      notificationProvidersInventoryProvider,
      (_, next) {
        if (next.isLoading || !identical(inventory, next.asData?.value)) {
          expired = true;
        }
      },
    );
    bool current() =>
        _routeCurrent &&
        !expired &&
        identical(session, ref.read(dashboardActiveSessionProvider)) &&
        !ref.read(notificationProvidersInventoryProvider).isLoading &&
        identical(
          inventory,
          ref.read(notificationProvidersInventoryProvider).asData?.value,
        );
    try {
      if (!current()) return;
      NotificationProvidersRequest? request;
      if (action == NotificationProvidersAction.create ||
          action == NotificationProvidersAction.replace) {
        setState(() => _ownModalOpen = true);
        try {
          request = await showDialog<NotificationProvidersRequest>(
            context: context,
            barrierDismissible: false,
            builder: (_) => NotificationProvidersEditorDialog(
              session: session,
              inventory: inventory,
              action: action,
              service: service,
            ),
          );
        } finally {
          if (mounted) setState(() => _ownModalOpen = false);
        }
      } else {
        request = NotificationProvidersRequest(
          inventory: inventory,
          action: action,
          service: service,
        );
      }
      if (request == null || !current()) {
        request?.credentials?.dispose();
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
          builder: (_) => NotificationProvidersReviewDialog(
            session: session,
            review: review,
          ),
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
        externalDeliveryAccepted: true,
        noRecallAccepted: true,
        unencryptedDisclosureAccepted: true,
        isRouteCurrent: () => _routeCurrent,
      );
    } finally {
      lifecycle.dispose();
      sessions.close();
      inventories.close();
      if (mounted) setState(() => _working = false);
    }
  }

  Widget _status(NotificationProvidersState state) => TdPanel(
    title: state.status == NotificationProvidersStatus.completed
        ? 'Configuration verified — delivery not established'
        : state.unresolved
        ? 'Inspect the original server'
        : 'Notification-provider status',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(state.message!),
        if (state.server != null) Text('Original server: ${state.server}'),
        if (state.unresolved) ...[
          const Text(
            'Management writes remain locked across navigation and connection changes. Reconnect manually to the original address with normal authentication and certificate trust, then explicitly verify its identity and inspect settings and external delivery independently. No retry, polling or replay is offered.',
          ),
          OutlinedButton(
            key: const Key('provider-verify-reconnected'),
            onPressed: _controller.canVerifyReconnectedServer
                ? _controller.verifyReconnectedServer
                : null,
            child: const Text('Verify reconnected original server once'),
          ),
          if (state.verificationMessage != null)
            Text(state.verificationMessage!),
          OutlinedButton(
            key: const Key('provider-acknowledge'),
            onPressed: _controller.canAcknowledge
                ? _controller.acknowledgeAfterReconnect
                : null,
            child: const Text(
              'I independently inspected settings and delivery',
            ),
          ),
        ],
      ],
    ),
  );

  Widget _configuration(
    AuthenticatedSession session,
    NotificationProvidersInventory inventory,
    bool idle,
  ) {
    final caps = ref
        .read(notificationProvidersSessionProvider)!
        .notificationProvidersCapabilities;
    bool allowed(
      NotificationProvidersAction action, [
      NotificationProviderSnapshot? service,
    ]) =>
        idle &&
        caps.supports(action) &&
        inventory.blockedReason == null &&
        switch (action) {
          NotificationProvidersAction.create => inventory.services.length < 128,
          NotificationProvidersAction.replace =>
            service?.provider != null && !service!.enabled,
          _ =>
            NotificationProvidersRequest(
                  inventory: inventory,
                  action: action,
                  service: service,
                ).validationError ==
                null,
        };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TdPanel(
          title: 'Current provider configuration',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${inventory.services.length} configured services · ${inventory.services.where((s) => s.enabled).length} enabled',
              ),
              Text(
                'Version: ${inventory.currentVersion} · State: ${inventory.state}',
              ),
              if (inventory.blockedReason != null)
                Text(inventory.blockedReason!),
              Material(
                color: Colors.transparent,
                child: ExpansionTile(
                  key: const Key('provider-readiness-details'),
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Server readiness details'),
                  children: [
                    Text(
                      'Full administrator: ${inventory.fullAdmin} · HA: ${inventory.failoverLicensed} · Conflicting jobs: ${inventory.conflictingJob}',
                    ),
                    Text(
                      'Boot pool: ${inventory.bootPool} · Readiness: ${inventory.bootHealthy}',
                    ),
                    const Text('Full public host identity'),
                    SelectableText(inventory.hostId),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        NotificationProvidersCharts(services: inventory.services),
        const SizedBox(height: 12),
        const ExpansionTile(
          key: Key('provider-scope-details'),
          title: Text('Provider scope & credential safety'),
          children: [
            Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                'Only public service headers are listed. Selected attributes are privately verified during review; stored URLs, tokens, passwords and keys never populate forms. Replacing a disabled provider requires every setting and fresh credential. Nine compiled providers are supported; SNMP v3 and unknown/masked attribute variants require TrueNAS. Configured counts do not measure actual alerts, deliveries, incident state or global notification coverage. No provider tests, probes or forced delivery are offered.',
              ),
            ),
          ],
        ),
        OutlinedButton(
          key: const Key('provider-mail-settings'),
          onPressed: idle
              ? () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AlertSettingsPage(),
                  ),
                )
              : null,
          child: const Text('Open separate Mail notification services'),
        ),
        OutlinedButton.icon(
          key: const Key('provider-create'),
          onPressed: allowed(NotificationProvidersAction.create)
              ? () => _change(
                  session,
                  inventory,
                  NotificationProvidersAction.create,
                )
              : null,
          icon: const Icon(Icons.add),
          label: const Text('Create disabled provider'),
        ),
        if (inventory.services.isEmpty)
          const Text(
            'No configured services. This does not establish that all TrueNAS notification delivery is disabled.',
          ),
        for (final service in inventory.services)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: TdPanel(
              title: service.name,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    'Service ${service.id} · ${service.type} · ${service.enabled ? 'Enabled' : 'Disabled'}',
                  ),
                  Text('Minimum severity: ${service.level.name.toUpperCase()}'),
                  if (service.provider == null)
                    const Text(
                      'Separate or unsupported provider — public headers only. Credentials and attributes are not shown.',
                    )
                  else ...[
                    const Text(
                      'Header-only inventory. The exact stored provider variant and credentials are verified privately during review.',
                    ),
                    if (service.enabled)
                      const Text(
                        'Disable separately before replacement or deletion. Existing messages and open incidents cannot be recalled.',
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          key: Key('provider-replace-${service.id}'),
                          onPressed:
                              allowed(
                                NotificationProvidersAction.replace,
                                service,
                              )
                              ? () => _change(
                                  session,
                                  inventory,
                                  NotificationProvidersAction.replace,
                                  service,
                                )
                              : null,
                          child: const Text('Replace disabled configuration'),
                        ),
                        OutlinedButton(
                          key: Key('provider-toggle-${service.id}'),
                          onPressed:
                              allowed(
                                service.enabled
                                    ? NotificationProvidersAction.disable
                                    : NotificationProvidersAction.enable,
                                service,
                              )
                              ? () => _change(
                                  session,
                                  inventory,
                                  service.enabled
                                      ? NotificationProvidersAction.disable
                                      : NotificationProvidersAction.enable,
                                  service,
                                )
                              : null,
                          child: Text(
                            service.enabled
                                ? 'Review disabling'
                                : 'Review enabling',
                          ),
                        ),
                        TextButton(
                          key: Key('provider-delete-${service.id}'),
                          onPressed:
                              allowed(
                                NotificationProvidersAction.delete,
                                service,
                              )
                              ? () => _change(
                                  session,
                                  inventory,
                                  NotificationProvidersAction.delete,
                                  service,
                                )
                              : null,
                          child: const Text('Review deletion'),
                        ),
                      ],
                    ),
                  ],
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
            .watch(notificationProvidersSessionProvider)
            ?.notificationProvidersCapabilities,
        state = ref.watch(notificationProvidersControllerProvider);
    final available = session?.endpoint != null && caps?.supported == true,
        idle = !state.busy && !state.locked && !_working;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notification providers'),
        actions: [
          IconButton(
            key: const Key('provider-refresh'),
            tooltip: 'Read notification configuration',
            onPressed: available && idle
                ? _controller.refreshConfiguration
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          key: const Key('provider-scroll'),
          padding: const EdgeInsets.all(20),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'SYSTEM · NOTIFICATION PROVIDERS',
                    style: TdTypography.micro,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Notification providers',
                    style: TdTypography.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(session?.endpoint ?? 'No authenticated connection'),
                  const SizedBox(height: 12),
                  const Text(
                    'Configured services only — not delivery measurements.',
                  ),
                  if (state.busy || state.verifying)
                    const LinearProgressIndicator(),
                  if (state.message != null) _status(state),
                  const SizedBox(height: 16),
                  if (!available)
                    TdPanel(
                      title: 'Notification configuration unavailable',
                      child: Text(
                        caps?.blockedReason ??
                            'Connect to a supported TrueNAS instance.',
                      ),
                    )
                  else if (state.locked)
                    const TdPanel(
                      title: 'Notification change needs attention',
                      child: Text(
                        'No automatic inventory refresh occurs while a write is executing or unresolved. A lost connection is not proof of success or stopped delivery.',
                      ),
                    )
                  else if (state.status ==
                          NotificationProvidersStatus.completed ||
                      state.status == NotificationProvidersStatus.rejected)
                    TdPanel(
                      title: 'Read fresh configuration before another change',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'The previous inventory and charts are hidden because that review is consumed or expired. No automatic refresh occurs.',
                          ),
                          OutlinedButton(
                            key: const Key('provider-refresh-after-review'),
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
                        .watch(notificationProvidersInventoryProvider)
                        .when(
                          skipLoadingOnRefresh: false,
                          skipLoadingOnReload: false,
                          loading: () =>
                              const Center(child: CircularProgressIndicator()),
                          error: (_, _) => TdPanel(
                            title: 'Notification configuration could not be verified',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Text(
                                  'Public configuration or readiness was unavailable. Remote details were withheld; unknown does not mean ready.',
                                ),
                                OutlinedButton(
                                  key: const Key('provider-retry'),
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
