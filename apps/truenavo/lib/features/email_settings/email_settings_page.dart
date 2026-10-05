import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'email_settings_controller.dart';
import 'email_settings_editor.dart';
import 'email_settings_review.dart';

class EmailSettingsPage extends ConsumerStatefulWidget {
  const EmailSettingsPage({super.key});
  @override
  ConsumerState<EmailSettingsPage> createState() => _EmailSettingsPageState();
}

class _EmailSettingsPageState extends ConsumerState<EmailSettingsPage> {
  bool _working = false, _ownModalOpen = false, _routeAbandoned = false;
  late final EmailSettingsController _controller;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(emailSettingsControllerProvider.notifier);
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
    EmailSettingsInventory inventory,
    EmailSettingsAction action,
  ) async {
    if (_working) return;
    setState(() => _working = true);
    var expired = false;
    EmailSettingsRequest? request;
    final lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) expired = true;
      },
    );
    final sessions = ref.listenManual(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) expired = true;
    });
    final inventories = ref.listenManual(emailSettingsInventoryProvider, (
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
        !ref.read(emailSettingsInventoryProvider).isLoading &&
        identical(
          inventory,
          ref.read(emailSettingsInventoryProvider).asData?.value,
        );
    try {
      if (!current()) return;
      setState(() => _ownModalOpen = true);
      try {
        request = await showDialog<EmailSettingsRequest>(
          context: context,
          barrierDismissible: false,
          builder: (_) => EmailSettingsEditorDialog(
            session: session,
            inventory: inventory,
            action: action,
          ),
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
              EmailSettingsReviewDialog(session: session, review: review),
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
        serverContactAccepted: true,
        queuedMailImpactAccepted: true,
        passwordClearAccepted: true,
        testDisclosureAccepted: true,
        isRouteCurrent: () => _routeCurrent,
      );
    } finally {
      request?.password.dispose();
      lifecycle.dispose();
      sessions.close();
      inventories.close();
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _checkJob() async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await _controller.checkJob(isRouteCurrent: () => _routeCurrent);
    } finally {
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
        caps = ref
            .watch(emailSettingsSessionProvider)
            ?.emailSettingsCapabilities,
        state = ref.watch(emailSettingsControllerProvider);
    final available = session?.endpoint != null && caps?.supported == true,
        idle = !state.busy && !state.locked && !_working;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Email settings'),
        actions: [
          IconButton(
            key: const Key('email-refresh'),
            tooltip: 'Read email configuration',
            onPressed: available && idle
                ? _controller.refreshConfiguration
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          key: const Key('email-scroll'),
          padding: const EdgeInsets.all(20),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'SYSTEM · NOTIFICATIONS',
                    style: TdTypography.micro,
                  ),
                  const SizedBox(height: 8),
                  const Text('Email & SMTP', style: TdTypography.titleLarge),
                  const SizedBox(height: 12),
                  Text(session?.endpoint ?? 'No authenticated connection'),
                  const SizedBox(height: 8),
                  const Text(
                    'Saved configuration, not delivery statistics. Password values are never displayed.',
                  ),
                  if (state.busy || state.verifying)
                    const LinearProgressIndicator(),
                  if (state.message != null)
                    TdPanel(
                      title: state.status == EmailSettingsStatus.completed
                          ? state.action == EmailSettingsAction.test
                                ? 'SMTP job success — delivery unverified'
                                : 'SMTP configuration verified'
                          : state.pendingJob
                          ? 'Test accepted — check explicitly'
                          : state.unresolved
                          ? 'Inspect the original server'
                          : 'Email operation status',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(state.message!),
                          if (state.server != null)
                            Text('Original server: ${state.server}'),
                          if (state.jobId != null)
                            Text('Owned test job: ${state.jobId}'),
                          if (state.pendingJob)
                            OutlinedButton(
                              key: const Key('email-check-job'),
                              onPressed: _controller.canCheckJob && !_working
                                  ? _checkJob
                                  : null,
                              child: const Text('Check this test job once'),
                            ),
                          if (state.unresolved) ...[
                            const Text(
                              'Management writes remain locked across navigation and connection changes. Reconnect manually to the original address using normal authentication and certificate trust, then verify the original machine and independently inspect its configuration or test effects. No resend, retry or automatic polling is offered.',
                            ),
                            OutlinedButton(
                              key: const Key('email-verify-reconnected'),
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
                              key: const Key('email-acknowledge'),
                              onPressed: _controller.canAcknowledge
                                  ? _controller.acknowledgeAfterReconnect
                                  : null,
                              child: const Text(
                                'I independently inspected the original server and effects',
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  if (!available)
                    TdPanel(
                      title: 'Email configuration unavailable',
                      child: Text(
                        caps?.blockedReason ??
                            'Connect to a supported TrueNAS instance.',
                      ),
                    )
                  else if (state.locked)
                    const TdPanel(
                      title: 'Original email operation needs attention',
                      child: Text(
                        'Configuration is not refreshed while the operation is pending or unresolved. Only an explicit owned-job check or original-server recovery inspection is available.',
                      ),
                    )
                  else if (state.status == EmailSettingsStatus.completed ||
                      state.status == EmailSettingsStatus.rejected)
                    TdPanel(
                      title: 'Read fresh configuration before another action',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          const Text(
                            'The previous review was consumed or expired. Old SMTP fields are hidden rather than presented as current. New password input is no longer retained.',
                          ),
                          OutlinedButton(
                            key: const Key('email-refresh-after-review'),
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
                        .watch(emailSettingsInventoryProvider)
                        .when(
                          skipLoadingOnRefresh: false,
                          skipLoadingOnReload: false,
                          loading: () =>
                              const Center(child: CircularProgressIndicator()),
                          error: (_, _) => TdPanel(
                            title: 'Email configuration could not be verified',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Text(
                                  'Public configuration or readiness was unavailable. Secret and remote details were withheld; unknown does not mean ready.',
                                ),
                                OutlinedButton(
                                  key: const Key('email-retry'),
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
                          data: (inventory) {
                            final config = inventory.config,
                                smtp = inventory.config.settings;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                TdPanel(
                                  title: 'Saved SMTP configuration',
                                  child: Column(
                                    crossAxisAlignment:
                                        CrossAxisAlignment.stretch,
                                    children: [
                                      Text(
                                        'SMTP: ${smtp.outgoingServer.isEmpty ? 'Not configured' : smtp.outgoingServer}:${smtp.port}',
                                      ),
                                      Text(
                                        'From: ${smtp.fromEmail.isEmpty ? 'Not configured' : smtp.fromEmail}',
                                      ),
                                      if (smtp.fromName.isNotEmpty)
                                        Text('Display name: ${smtp.fromName}'),
                                      Wrap(
                                        spacing: 8,
                                        runSpacing: 8,
                                        children: [
                                          Chip(
                                            label: Text(
                                              emailSecurityLabel(smtp.security),
                                            ),
                                          ),
                                          Chip(
                                            label: Text(
                                              smtp.smtpAuth
                                                  ? 'SMTP auth configured'
                                                  : 'No SMTP authentication',
                                            ),
                                          ),
                                          Chip(
                                            label: Text(
                                              !config.passwordKnown
                                                  ? 'Password state unavailable'
                                                  : config.passwordPresent ==
                                                        true
                                                  ? 'Password set — not shown'
                                                  : 'No saved password',
                                            ),
                                          ),
                                        ],
                                      ),
                                      const Text(
                                        'Transport settings are not a certificate-verification guarantee.',
                                      ),
                                      if (inventory.blockedReason != null)
                                        Text(inventory.blockedReason!),
                                      if (inventory.blockedReason == null &&
                                          inventory.testBlockedReason != null)
                                        Text(
                                          'Test unavailable: ${inventory.testBlockedReason}',
                                        ),
                                      if (config.oauthPresent)
                                        const Text(
                                          'OAuth is protected and read-only here. This workflow will not enroll, clear, replace or migrate OAuth configuration.',
                                        ),
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Wrap(
                                  spacing: 8,
                                  runSpacing: 8,
                                  children: [
                                    OutlinedButton.icon(
                                      key: const Key('email-edit'),
                                      onPressed:
                                          idle &&
                                              caps!.supports(
                                                EmailSettingsAction.configure,
                                              ) &&
                                              inventory.blockedReason == null
                                          ? () => _change(
                                              session!,
                                              inventory,
                                              EmailSettingsAction.configure,
                                            )
                                          : null,
                                      icon: const Icon(Icons.settings_outlined),
                                      label: const Text('Edit SMTP settings'),
                                    ),
                                    OutlinedButton.icon(
                                      key: const Key('email-test'),
                                      onPressed:
                                          idle &&
                                              caps!.supports(
                                                EmailSettingsAction.test,
                                              ) &&
                                              inventory.testBlockedReason ==
                                                  null
                                          ? () => _change(
                                              session!,
                                              inventory,
                                              EmailSettingsAction.test,
                                            )
                                          : null,
                                      icon: const Icon(
                                        Icons.mark_email_read_outlined,
                                      ),
                                      label: const Text(
                                        'Review one test recipient',
                                      ),
                                    ),
                                  ],
                                ),
                                const Text(
                                  'Saving and testing are separate. A test uses only saved settings, one explicit recipient and queue=false. Opening this page sends nothing.',
                                ),
                                const ExpansionTile(
                                  key: Key('email-security-details'),
                                  title: Text('Security & email side effects'),
                                  children: [
                                    Padding(
                                      padding: EdgeInsets.only(bottom: 12),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          Text(emailSecurityWarning),
                                          SizedBox(height: 12),
                                          Text(emailQueueWarning),
                                          SizedBox(height: 12),
                                          Text(emailTestWarning),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                                ExpansionTile(
                                  key: const Key('email-readiness-details'),
                                  title: const Text('Server readiness details'),
                                  children: [
                                    Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.stretch,
                                      children: [
                                        Text(
                                          'Version: ${inventory.currentVersion} · State: ${inventory.state}',
                                        ),
                                        Text(
                                          'Full administrator: ${inventory.fullAdmin ? 'Verified' : 'Not verified'}',
                                        ),
                                        Text(
                                          'HA licensed: ${inventory.failoverLicensed ? 'Yes' : 'No'} · Conflicting jobs: ${inventory.conflictingJob ? 'Yes' : 'None in last read'}',
                                        ),
                                        Text(
                                          'Boot pool: ${inventory.bootPool} · Boot readiness: ${inventory.bootHealthy ? 'Healthy in last read' : 'Not ready'}',
                                        ),
                                        const Text('Full public host identity'),
                                        SelectableText(inventory.hostId),
                                        const SizedBox(height: 12),
                                      ],
                                    ),
                                  ],
                                ),
                              ],
                            );
                          },
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
