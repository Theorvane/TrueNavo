import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../email_settings/email_settings_page.dart';
import '../alert_policies/alert_policies_page.dart';
import '../notification_providers/notification_providers_page.dart';
import 'alert_settings_charts.dart';
import 'alert_settings_controller.dart';
import 'alert_settings_editor.dart';
import 'alert_settings_review.dart';

class AlertSettingsPage extends ConsumerStatefulWidget {
  const AlertSettingsPage({super.key});
  @override
  ConsumerState<AlertSettingsPage> createState() => _AlertSettingsPageState();
}

class _AlertSettingsPageState extends ConsumerState<AlertSettingsPage> {
  bool _working = false, _ownModalOpen = false, _routeAbandoned = false;
  late final AlertSettingsController _controller;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(alertSettingsControllerProvider.notifier);
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
    AlertSettingsInventory inventory,
    AlertSettingsAction action, [
    AlertServiceSnapshot? service,
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
    final inventories = ref.listenManual(alertSettingsInventoryProvider, (
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
        !ref.read(alertSettingsInventoryProvider).isLoading &&
        identical(
          inventory,
          ref.read(alertSettingsInventoryProvider).asData?.value,
        );
    try {
      if (!current()) return;
      AlertSettingsRequest? request;
      if (action == AlertSettingsAction.createEmail ||
          action == AlertSettingsAction.editEmail) {
        setState(() => _ownModalOpen = true);
        try {
          request = await showDialog<AlertSettingsRequest>(
            context: context,
            barrierDismissible: false,
            builder: (_) => AlertSettingsEditorDialog(
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
        request = AlertSettingsRequest(
          inventory: inventory,
          action: action,
          service: service,
        );
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
              AlertSettingsReviewDialog(session: session, review: review),
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
        isRouteCurrent: () => _routeCurrent,
      );
    } finally {
      lifecycle.dispose();
      sessions.close();
      inventories.close();
      if (mounted) setState(() => _working = false);
    }
  }

  Widget _status(AlertSettingsState state) => TdPanel(
    title: state.status == AlertSettingsStatus.completed
        ? 'Configuration verified — delivery not established'
        : state.unresolved
        ? 'Inspect the original server'
        : 'Notification-service status',
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
            key: const Key('alert-verify-reconnected'),
            onPressed: _controller.canVerifyReconnectedServer
                ? _controller.verifyReconnectedServer
                : null,
            child: const Text('Verify reconnected original server once'),
          ),
          if (state.verificationMessage != null)
            Text(state.verificationMessage!),
          OutlinedButton(
            key: const Key('alert-acknowledge'),
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
    AlertSettingsInventory inventory,
    bool idle,
  ) {
    final caps = ref
        .read(alertSettingsSessionProvider)!
        .alertSettingsCapabilities;
    bool allowed(AlertSettingsAction action, [AlertServiceSnapshot? service]) =>
        idle &&
        caps.supports(action) &&
        inventory.blockedReason == null &&
        switch (action) {
          AlertSettingsAction.createEmail => inventory.services.length < 128,
          AlertSettingsAction.editEmail =>
            service?.supportedEmail == true && !service!.enabled,
          _ =>
            AlertSettingsRequest(
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
          title: 'Current notification configuration',
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
                  key: const Key('alert-readiness-details'),
                  tilePadding: EdgeInsets.zero,
                  title: const Text('Server readiness details'),
                  children: [
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
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
                        const Text('Full public host identity'),
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
        AlertSettingsCharts(services: inventory.services),
        const SizedBox(height: 12),
        const ExpansionTile(
          key: Key('alert-scope-details'),
          title: Text('Notification scope & safety details'),
          children: [
            Padding(
              padding: EdgeInsets.only(bottom: 16),
              child: Text(
                'These charts describe configured notification-service rows, not generated alerts, mail queue depth, actual deliveries or reliability. Other independent default alert mail may continue. This page edits Mail; protected external providers have a separate workspace. Opening this page reads configuration only and never invokes provider tests. Alert-class overrides and SMTP settings are separate workflows.',
              ),
            ),
          ],
        ),
        OutlinedButton.icon(
          key: const Key('alert-settings-email'),
          onPressed: idle
              ? () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const EmailSettingsPage(),
                  ),
                )
              : null,
          icon: const Icon(Icons.mail_outline),
          label: const Text('Open saved SMTP settings'),
        ),
        OutlinedButton.icon(
          key: const Key('alert-settings-policies'),
          onPressed: idle
              ? () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const AlertPoliciesPage(),
                  ),
                )
              : null,
          icon: const Icon(Icons.rule_outlined),
          label: const Text('Open alert policies'),
        ),
        OutlinedButton.icon(
          key: const Key('alert-settings-providers'),
          onPressed: idle
              ? () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const NotificationProvidersPage(),
                  ),
                )
              : null,
          icon: const Icon(Icons.hub_outlined),
          label: const Text('Open notification providers'),
        ),
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('alert-create'),
          onPressed: allowed(AlertSettingsAction.createEmail)
              ? () =>
                    _change(session, inventory, AlertSettingsAction.createEmail)
              : null,
          icon: const Icon(Icons.add),
          label: const Text('Create disabled email service'),
        ),
        if (inventory.services.isEmpty)
          const Text(
            'No notification services are configured. This does not mean all TrueNAS alert mail is disabled.',
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
                  Text('Threshold: ${service.level.name.toUpperCase()}'),
                  if (service.isEmail)
                    Text(
                      service.usesAdministratorFallback
                          ? 'Recipient: administrator fallback (legacy)'
                          : 'Recipient: ${service.recipient ?? 'Unavailable'}',
                    ),
                  if (service.blockedReason != null)
                    Text(service.blockedReason!),
                  if (!service.supportedEmail)
                    const Text(
                      'Protected provider configuration — viewing public metadata only. No credentials, provider test or conversion is offered.',
                    )
                  else ...[
                    if (service.enabled)
                      const Text(
                        'Disable separately before editing or deleting. This does not recall existing mail.',
                      ),
                    if (service.usesAdministratorFallback)
                      const Text(
                        'An empty legacy recipient may target all local full administrators. Set one explicit recipient while disabled before enabling.',
                      ),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        OutlinedButton(
                          key: Key('alert-edit-${service.id}'),
                          onPressed:
                              allowed(AlertSettingsAction.editEmail, service)
                              ? () => _change(
                                  session,
                                  inventory,
                                  AlertSettingsAction.editEmail,
                                  service,
                                )
                              : null,
                          child: const Text('Edit disabled service'),
                        ),
                        OutlinedButton(
                          key: Key('alert-toggle-${service.id}'),
                          onPressed:
                              allowed(
                                service.enabled
                                    ? AlertSettingsAction.disableEmail
                                    : AlertSettingsAction.enableEmail,
                                service,
                              )
                              ? () => _change(
                                  session,
                                  inventory,
                                  service.enabled
                                      ? AlertSettingsAction.disableEmail
                                      : AlertSettingsAction.enableEmail,
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
                          key: Key('alert-delete-${service.id}'),
                          onPressed:
                              allowed(AlertSettingsAction.deleteEmail, service)
                              ? () => _change(
                                  session,
                                  inventory,
                                  AlertSettingsAction.deleteEmail,
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
            .watch(alertSettingsSessionProvider)
            ?.alertSettingsCapabilities,
        state = ref.watch(alertSettingsControllerProvider);
    final available = session?.endpoint != null && caps?.supported == true,
        idle = !state.busy && !state.locked && !_working;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Notification services'),
        actions: [
          IconButton(
            key: const Key('alert-refresh'),
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
          key: const Key('alert-scroll'),
          padding: const EdgeInsets.all(20),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'SYSTEM · NOTIFICATION DELIVERY',
                    style: TdTypography.micro,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Notification services',
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
                  else if (state.status == AlertSettingsStatus.completed ||
                      state.status == AlertSettingsStatus.rejected)
                    TdPanel(
                      title: 'Read fresh configuration before another change',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'The previous inventory and charts are hidden because that review is consumed or expired. No automatic refresh occurs.',
                          ),
                          OutlinedButton(
                            key: const Key('alert-refresh-after-review'),
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
                        .watch(alertSettingsInventoryProvider)
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
                                  key: const Key('alert-retry'),
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
