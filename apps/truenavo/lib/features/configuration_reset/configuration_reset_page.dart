import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'configuration_reset_controller.dart';

const _resetImpact =
    'Factory reset replaces the live configuration database before later hooks and reboot. Accounts, network settings, certificates, credentials and service settings can be lost. Access through the old address or login may stop working; first-time setup and a new login password may be required. A later failure does not undo earlier changes.';
const _resetRecovery =
    'Factory reset is not secure erasure or a data backup. It does not itself destroy storage pools, but recoverability is not guaranteed. Database-stored dataset keys and settings can be lost. Independently retain a current configuration backup, its required password secret seed, dataset keys and passphrases. Pools may need re-import, unlocking and service reconfiguration; have independently tested console access.';
const _resetPending =
    'A previously staged restore can supersede factory defaults on restart; the app cannot detect or clear it. Independently check for pending configuration restoration and arrange a recovery plan. An accepted job does not prove that the next boot uses factory defaults.';

class ConfigurationResetPage extends ConsumerStatefulWidget {
  const ConfigurationResetPage({super.key});
  @override
  ConsumerState<ConfigurationResetPage> createState() =>
      _ConfigurationResetPageState();
}

class _ConfigurationResetPageState
    extends ConsumerState<ConfigurationResetPage> {
  bool _reviewing = false, _ownReviewOpen = false, _routeAbandoned = false;
  late final ConfigurationResetController _controller;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(configurationResetControllerProvider.notifier);
  }

  @override
  void dispose() {
    _controller.abandonRoute();
    super.dispose();
  }

  bool get _routeCurrent =>
      mounted && ModalRoute.of(context)?.isCurrent == true;
  Future<void> _review(
    AuthenticatedSession session,
    ConfigurationResetInventory inventory,
  ) async {
    if (_reviewing) return;
    setState(() => _reviewing = true);
    var expired = false;
    final lifecycle = AppLifecycleListener(
      onStateChange: (next) {
        if (next != AppLifecycleState.resumed) expired = true;
      },
    );
    final sessionWatch = ref.listenManual(dashboardActiveSessionProvider, (
      a,
      b,
    ) {
      if (!identical(a, b)) expired = true;
    });
    final inventoryWatch = ref.listenManual(
      configurationResetInventoryProvider,
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
        !ref.read(configurationResetInventoryProvider).isLoading &&
        identical(
          inventory,
          ref.read(configurationResetInventoryProvider).asData?.value,
        );
    try {
      if (!current()) return;
      final review = await _controller.review(
        expectedSession: session,
        inventory: inventory,
        isRouteCurrent: () => _routeCurrent,
      );
      if (!mounted || !current()) {
        _controller.abandonRoute();
        return;
      }
      if (review == null) return;
      bool? confirmed;
      setState(() => _ownReviewOpen = true);
      try {
        confirmed = await showDialog<bool>(
          context: context,
          barrierDismissible: false,
          builder: (_) =>
              ConfigurationResetReviewDialog(session: session, review: review),
        );
      } finally {
        if (mounted) setState(() => _ownReviewOpen = false);
      }
      if (confirmed != true || !current()) {
        _controller.expireContext();
        return;
      }
      await _controller.execute(
        expectedSession: session,
        review: review,
        confirmation: review.target,
        consoleAccessAccepted: true,
        independentBackupAccepted: true,
        dataAndKeyRecoveryAccepted: true,
        configurationLossAccepted: true,
        rebootAndPartialFailureAccepted: true,
        pendingRestoreCheckedAccepted: true,
        isRouteCurrent: () => _routeCurrent,
      );
    } finally {
      lifecycle.dispose();
      sessionWatch.close();
      inventoryWatch.close();
      if (mounted) setState(() => _reviewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final routeCurrent = ModalRoute.isCurrentOf(context) != false;
    if (routeCurrent) _routeAbandoned = false;
    if (!routeCurrent && !_ownReviewOpen && !_routeAbandoned && _reviewing) {
      _routeAbandoned = true;
      _controller.abandonRoute();
    }
    final session = ref.watch(dashboardActiveSessionProvider),
        caps = ref
            .watch(configurationResetSessionProvider)
            ?.configurationResetCapabilities;
    final state = ref.watch(configurationResetControllerProvider);
    final available = session?.endpoint != null && caps?.canReset == true;
    final idle = !state.busy && !state.locked && !_reviewing;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Factory reset'),
        actions: [
          IconButton(
            key: const Key('reset-refresh'),
            tooltip: 'Read reset readiness',
            onPressed: available && idle
                ? () {
                    _controller.expireContext();
                    ref.invalidate(configurationResetInventoryProvider);
                  }
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          key: const Key('reset-scroll'),
          padding: const EdgeInsets.all(20),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('SYSTEM · RECOVERY', style: TdTypography.micro),
                  const SizedBox(height: 8),
                  const Text(
                    'Factory defaults & automatic reboot',
                    style: TdTypography.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(session?.endpoint ?? 'No authenticated connection'),
                  const SizedBox(height: 12),
                  const TdPanel(
                    title: 'Destructive configuration replacement',
                    child: Text(_resetImpact),
                  ),
                  const SizedBox(height: 12),
                  const Text(_resetRecovery),
                  const SizedBox(height: 12),
                  const TdPanel(
                    title: 'Check independently for a staged restore',
                    child: Text(_resetPending),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'Automatic reboot is fixed on. After database replacement and successful hooks, TrueNAS schedules reboot after about 10 seconds. There is no no-reboot or dry-run option. HA systems must not be factory-reset. Opening this page only reads readiness; no reset is submitted.',
                  ),
                  const SizedBox(height: 16),
                  if (state.busy || state.verifying)
                    const LinearProgressIndicator(),
                  if (state.message != null)
                    TdPanel(
                      title: state.status == ConfigurationResetStatus.accepted
                          ? 'Accepted — completion unverified'
                          : state.unresolved
                          ? 'Inspect the original machine'
                          : 'Factory-reset status',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(state.message!),
                          if (state.server != null)
                            Text('Original server: ${state.server}'),
                          if (state.jobId != null)
                            Text('Accepted job: ${state.jobId}'),
                          if (state.unresolved) ...[
                            const Text(
                              'Management writes stay locked across navigation and connections. No job polling, retry, automatic reconnect or reset replay is offered. Reconnect manually using normal authentication and certificate trust only after independent recovery inspection.',
                            ),
                            OutlinedButton(
                              key: const Key('reset-verify-reconnected'),
                              onPressed: _controller.canVerifyReconnectedServer
                                  ? _controller.verifyReconnectedServer
                                  : null,
                              child: const Text(
                                'Verify reconnected server identity once',
                              ),
                            ),
                            if (state.verificationMessage != null)
                              Text(state.verificationMessage!),
                            if (state.addressChanged) ...[
                              Text('Original address: ${state.server}'),
                              Text(
                                'Manually connected address: ${state.verifiedEndpoint}',
                              ),
                              const Text(
                                'A matching claimed host identifier is not remote attestation. The app did not discover or dial this changed address.',
                              ),
                              Material(
                                color: Colors.transparent,
                                child: CheckboxListTile(
                                  key: const Key('reset-changed-address'),
                                  contentPadding: EdgeInsets.zero,
                                  value: state.changedAddressAccepted,
                                  onChanged: (value) =>
                                      _controller.acknowledgeChangedAddress(
                                        value ?? false,
                                      ),
                                  title: const Text(
                                    'I independently verified this changed address belongs to the original machine.',
                                  ),
                                ),
                              ),
                            ],
                            OutlinedButton(
                              key: const Key('reset-acknowledge'),
                              onPressed: _controller.canAcknowledge
                                  ? _controller.acknowledgeAfterReconnect
                                  : null,
                              child: const Text(
                                'I independently inspected the original machine',
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  const SizedBox(height: 16),
                  if (!available)
                    TdPanel(
                      title: 'Factory reset unavailable',
                      child: Text(
                        caps?.blockedReason ??
                            'Connect to a supported TrueNAS instance.',
                      ),
                    )
                  else if (state.locked)
                    const TdPanel(
                      title: 'Original reset needs attention',
                      child: Text(
                        'Readiness is not refreshed automatically while a reset is executing or unresolved. An accepted job or lost connection is not proof of factory defaults, recovery or reboot completion.',
                      ),
                    )
                  else
                    ref
                        .watch(configurationResetInventoryProvider)
                        .when(
                          skipLoadingOnRefresh: false,
                          skipLoadingOnReload: false,
                          loading: () =>
                              const Center(child: CircularProgressIndicator()),
                          error: (_, _) => TdPanel(
                            title: 'Reset readiness unavailable',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Text(
                                  'Host identity, boot readiness or full administrator privileges could not be verified. Unknown does not mean ready. Details were withheld.',
                                ),
                                OutlinedButton(
                                  key: const Key('reset-retry'),
                                  onPressed: idle
                                      ? () => ref.invalidate(
                                          configurationResetInventoryProvider,
                                        )
                                      : null,
                                  child: const Text('Retry readiness reads'),
                                ),
                              ],
                            ),
                          ),
                          data: (inventory) => Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              TdPanel(
                                title: inventory.blockedReason == null
                                    ? 'Readiness verified — recovery still requires your checks'
                                    : 'Factory reset blocked',
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (inventory.blockedReason != null)
                                      Text(inventory.blockedReason!),
                                    Text(
                                      'Current version: ${inventory.currentVersion}',
                                    ),
                                    Text('System state: ${inventory.state}'),
                                    Text(
                                      'Full administrator: ${inventory.fullAdmin ? 'Verified' : 'Not verified'}',
                                    ),
                                    Text(
                                      'HA licensed: ${inventory.failoverLicensed ? 'Yes' : 'No'}',
                                    ),
                                    Text('Boot pool: ${inventory.bootPool}'),
                                    Text(
                                      'Boot readiness: ${inventory.bootHealthy ? 'Healthy in last read' : 'Not ready'}',
                                    ),
                                    Text(
                                      'Current boot environment: ${inventory.currentEnvironment?.id ?? 'Unavailable'}',
                                    ),
                                    Text(
                                      'Next boot environment: ${inventory.nextEnvironment?.id ?? 'Unavailable'}',
                                    ),
                                    const Text('Full public host identity'),
                                    SelectableText(inventory.hostId),
                                    const Text('Boot identity'),
                                    SelectableText(inventory.bootId),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                              FilledButton.icon(
                                key: const Key('reset-review'),
                                onPressed:
                                    idle && inventory.blockedReason == null
                                    ? () => _review(session!, inventory)
                                    : null,
                                icon: const Icon(Icons.warning_amber_rounded),
                                label: const Text(
                                  'Review factory reset & automatic reboot',
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

class ConfigurationResetReviewDialog extends ConsumerStatefulWidget {
  const ConfigurationResetReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final ConfigurationResetReview review;
  @override
  ConsumerState<ConfigurationResetReviewDialog> createState() =>
      _ConfigurationResetReviewDialogState();
}

class _ConfigurationResetReviewDialogState
    extends ConsumerState<ConfigurationResetReviewDialog> {
  final _target = TextEditingController();
  final _ack = List<bool>.filled(6, false);
  bool _expired = false, _routeAbandoned = false, _closing = false;
  late final AppLifecycleListener _lifecycle;
  late final Timer _expiry;
  @override
  void initState() {
    super.initState();
    final initial = WidgetsBinding.instance.lifecycleState;
    _expired = initial != null && initial != AppLifecycleState.resumed;
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) _expire();
      },
    );
    _expiry = Timer(const Duration(minutes: 5), _expire);
  }

  void _expire() {
    if (_expired || _closing || !mounted) return;
    ref.read(configurationResetControllerProvider.notifier).expireContext();
    setState(() {
      _expired = true;
      _target.clear();
      _ack.fillRange(0, 6, false);
    });
  }

  @override
  void dispose() {
    _expiry.cancel();
    _lifecycle.dispose();
    _target.dispose();
    super.dispose();
  }

  void _finish(bool confirmed) {
    _closing = true;
    Navigator.of(context).pop(confirmed);
  }

  @override
  Widget build(BuildContext context) {
    if (ModalRoute.isCurrentOf(context) == false &&
        !_routeAbandoned &&
        !_closing) {
      _routeAbandoned = true;
      _expired = true;
      ref.read(configurationResetControllerProvider.notifier).abandonRoute();
    }
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(configurationResetInventoryProvider, (_, next) {
      if (next.isLoading ||
          !identical(widget.review.request.inventory, next.asData?.value)) {
        _expire();
      }
    });
    final state = ref.watch(configurationResetControllerProvider),
        inventory = ref.watch(configurationResetInventoryProvider);
    final current =
        !_expired &&
        ref
            .read(configurationResetControllerProvider.notifier)
            .isReviewCurrent(widget.review) &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(widget.review.request.inventory, inventory.asData?.value);
    const labels = [
      'I independently tested console access.',
      'I secured a separate current backup and required secret seed.',
      'I retained keys and accept pool recovery risks.',
      'I accept complete configuration loss and first-time setup.',
      'I accept automatic reboot and irreversible partial failure.',
      'I independently checked staged restores and have a recovery plan.',
    ];
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('reset-review-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? 'Review factory reset & automatic reboot'
                    : 'Factory-reset review expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous server details are hidden. Read readiness and begin a new review; nothing is submitted automatically.',
                )
              else ...[
                SelectableText(widget.review.endpoint),
                const Text(_resetImpact),
                const SizedBox(height: 12),
                const Text(_resetRecovery),
                const SizedBox(height: 12),
                const Text(_resetPending),
                for (final warning in widget.review.warnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(warning),
                  ),
                const SizedBox(height: 12),
                const Text(
                  'Automatic reboot is fixed on; it is scheduled after about 10 seconds only if the reset and later hooks reach that step. Failure or disconnection can leave configuration already replaced. Neither job acceptance nor reboot proves factory defaults or recoverability.',
                ),
                const SizedBox(height: 12),
                const Text(
                  'This single-use review expires after five minutes. Type the full public server target exactly and acknowledge every independent recovery check.',
                ),
                SelectableText(widget.review.target),
                TextField(
                  key: const Key('reset-confirm-target'),
                  controller: _target,
                  minLines: 1,
                  maxLines: 4,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Exact server confirmation target',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                for (var i = 0; i < labels.length; i++)
                  CheckboxListTile(
                    key: Key('reset-confirm-ack-$i'),
                    contentPadding: EdgeInsets.zero,
                    value: _ack[i],
                    onChanged: (value) =>
                        setState(() => _ack[i] = value ?? false),
                    title: Text(labels[i]),
                  ),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    key: const Key('reset-cancel'),
                    onPressed: () => _finish(false),
                    child: const Text('Cancel reset'),
                  ),
                  FilledButton(
                    key: const Key('reset-confirm-submit'),
                    style: FilledButton.styleFrom(
                      backgroundColor: Theme.of(context).colorScheme.error,
                      foregroundColor: Theme.of(context).colorScheme.onError,
                    ),
                    onPressed:
                        current &&
                            !_closing &&
                            !state.locked &&
                            _ack.every((v) => v) &&
                            _target.text == widget.review.target
                        ? () => _finish(true)
                        : null,
                    child: const Text('Reset once & allow automatic reboot'),
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
