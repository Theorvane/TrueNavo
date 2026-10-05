import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'configuration_restore_controller.dart';
import 'configuration_restore_file.dart';
import '../configuration_reset/configuration_reset_page.dart';

class ConfigurationRestorePage extends ConsumerStatefulWidget {
  const ConfigurationRestorePage({super.key});
  @override
  ConsumerState<ConfigurationRestorePage> createState() =>
      _ConfigurationRestorePageState();
}

class _ConfigurationRestorePageState
    extends ConsumerState<ConfigurationRestorePage> {
  bool _consent = false, _reviewing = false, _ownReviewOpen = false;
  late final ConfigurationRestoreController _controller;
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    _controller = ref.read(configurationRestoreControllerProvider.notifier);
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed && mounted) {
          setState(() => _consent = false);
        }
      },
    );
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _controller.abandonRoute();
    super.dispose();
  }

  Future<void> _review(
    AuthenticatedSession session,
    ConfigurationRestoreInventory inventory,
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
      configurationRestoreInventoryProvider,
      (_, next) {
        if (next.isLoading || !identical(inventory, next.asData?.value)) {
          expired = true;
        }
      },
    );
    bool current() =>
        mounted &&
        !expired &&
        ModalRoute.of(context)?.isCurrent == true &&
        identical(session, ref.read(dashboardActiveSessionProvider)) &&
        !ref.read(configurationRestoreInventoryProvider).isLoading &&
        identical(
          inventory,
          ref.read(configurationRestoreInventoryProvider).asData?.value,
        );
    try {
      if (!current()) return;
      final review = await _controller.review(
        expectedSession: session,
        inventory: inventory,
        isRouteCurrent: () =>
            mounted && ModalRoute.of(context)?.isCurrent == true,
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
          builder: (_) => ConfigurationRestoreReviewDialog(
            session: session,
            review: review,
          ),
        );
      } finally {
        if (mounted) setState(() => _ownReviewOpen = false);
      }
      if (confirmed != true || !current()) {
        _controller.discardSelection();
        return;
      }
      await _controller.execute(
        expectedSession: session,
        review: review,
        confirmation: review.target,
        fileHashConfirmation: review.request.file.sha256,
        recoveryAccessAccepted: true,
        independentBackupAccepted: true,
        trustedFileAccepted: true,
        replacementAndRebootAccepted: true,
        missingMaterialLossAccepted: true,
        isRouteCurrent: () =>
            mounted && ModalRoute.of(context)?.isCurrent == true,
      );
    } finally {
      lifecycle.dispose();
      sessionWatch.close();
      inventoryWatch.close();
      if (mounted) {
        setState(() {
          _reviewing = false;
          _consent = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final departing = ref.read(configurationRestoreControllerProvider);
    if (ModalRoute.isCurrentOf(context) == false &&
        !_ownReviewOpen &&
        (departing.selection != null || departing.busy)) {
      _controller.abandonRoute();
    }
    final session = ref.watch(dashboardActiveSessionProvider),
        caps = ref
            .watch(configurationRestoreSessionProvider)
            ?.configurationRestoreCapabilities;
    final picker = ref.watch(configurationRestoreFilePickerProvider),
        state = ref.watch(configurationRestoreControllerProvider);
    final available =
        session?.endpoint != null &&
        caps?.supported == true &&
        picker.supported;
    final idle = !state.busy && !state.locked && !_reviewing;
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) setState(() => _consent = false);
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuration restore'),
        actions: [
          IconButton(
            key: const Key('restore-refresh'),
            tooltip: 'Read restore readiness',
            onPressed: available && idle
                ? () {
                    _controller.discardSelection();
                    ref.invalidate(configurationRestoreInventoryProvider);
                  }
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          key: const Key('restore-scroll'),
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
                    'Restore configuration & reboot',
                    style: TdTypography.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(session?.endpoint ?? 'No authenticated connection'),
                  const TdPanel(
                    title:
                        'This replaces configuration and automatically reboots',
                    child: Text(
                      'A successful TrueNAS 25.10.1 migration schedules a reboot after about 10 seconds. Network settings, accounts, credentials and services may change. The app can lose access permanently. Arrange independent console access, recovery keys and a secured backup of the current configuration before proceeding.',
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'A file may contain stored encrypted dataset keys, SSH private keys and other secrets. It is not a separate or complete recovery-key backup. Missing password secret seed or root authorized-key members are removed from their destination during startup; do not assume existing values will be preserved.',
                  ),
                  const SizedBox(height: 16),
                  if (state.busy || state.verifying)
                    const LinearProgressIndicator(),
                  if (state.message != null)
                    TdPanel(
                      title: state.status == ConfigurationRestoreStatus.accepted
                          ? 'Accepted — completion unverified'
                          : state.unresolved
                          ? 'Inspect the original machine'
                          : 'Restore status',
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
                              'Management writes remain locked across navigation and connection changes. No job polling, retry, automatic reconnect or upload replay is offered.',
                            ),
                            OutlinedButton(
                              key: const Key('restore-verify-reconnected'),
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
                                'No address was discovered or dialled automatically. Host identifiers are claimed identifiers, not remote attestation. Verify the changed address independently.',
                              ),
                              Material(
                                color: Colors.transparent,
                                child: CheckboxListTile(
                                  key: const Key('restore-changed-address'),
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
                              key: const Key('restore-acknowledge'),
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
                      title: 'Configuration restore unavailable',
                      child: Text(
                        !picker.supported
                            ? 'Restore requires the supported Android document picker and certificate-pinned upload transport. There is no browser upload fallback.'
                            : caps?.blockedReason ??
                                  'Connect to a supported TrueNAS instance.',
                      ),
                    )
                  else if (state.locked && !state.connectionCurrent)
                    const TdPanel(
                      title: 'Original restore needs attention',
                      child: Text(
                        'Previous readiness and file information are hidden. Verify the original machine independently before acknowledging.',
                      ),
                    )
                  else
                    ref
                        .watch(configurationRestoreInventoryProvider)
                        .when(
                          skipLoadingOnRefresh: false,
                          skipLoadingOnReload: false,
                          loading: () =>
                              const Center(child: CircularProgressIndicator()),
                          error: (_, _) => TdPanel(
                            title: 'Restore readiness unavailable',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Text(
                                  'Host identity, boot state or privileges could not be verified. Unknown does not mean ready. Details were withheld.',
                                ),
                                OutlinedButton(
                                  key: const Key('restore-retry'),
                                  onPressed: idle
                                      ? () => ref.invalidate(
                                          configurationRestoreInventoryProvider,
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
                                    ? 'Ready for an independent recovery review'
                                    : 'Restore blocked',
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
                                    const Text('Full public host identity'),
                                    SelectableText(inventory.hostId),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'I consent to reading a sensitive, trusted local configuration backup for review. Selecting a file does not upload it. Its original filename, path and configuration contents are not shown.',
                              ),
                              CheckboxListTile(
                                key: const Key('restore-read-consent'),
                                contentPadding: EdgeInsets.zero,
                                value: _consent,
                                onChanged:
                                    idle && inventory.blockedReason == null
                                    ? (value) => setState(
                                        () => _consent = value ?? false,
                                      )
                                    : null,
                                title: const Text(
                                  'I authorize local file inspection.',
                                ),
                              ),
                              OutlinedButton(
                                key: const Key('restore-choose-file'),
                                onPressed:
                                    idle &&
                                        inventory.blockedReason == null &&
                                        _consent
                                    ? () => _controller.chooseFile(
                                        expectedSession: session!,
                                        sensitiveReadAccepted: _consent,
                                        isRouteCurrent: () =>
                                            mounted &&
                                            ModalRoute.of(context)?.isCurrent ==
                                                true,
                                      )
                                    : null,
                                child: Text(
                                  state.selection == null
                                      ? 'Choose trusted configuration file'
                                      : 'Replace selected file',
                                ),
                              ),
                              if (state.selection != null) ...[
                                const SizedBox(height: 12),
                                _RestoreMetadata(summary: state.selection!),
                                OutlinedButton(
                                  key: const Key('restore-discard-file'),
                                  onPressed: idle
                                      ? _controller.discardSelection
                                      : null,
                                  child: const Text('Discard selected file'),
                                ),
                                FilledButton(
                                  key: const Key('restore-review'),
                                  onPressed:
                                      idle && inventory.blockedReason == null
                                      ? () => _review(session!, inventory)
                                      : null,
                                  child: const Text(
                                    'Review replacement and automatic reboot',
                                  ),
                                ),
                              ],
                            ],
                          ),
                        ),
                  const SizedBox(height: 16),
                  TdPanel(
                    title: 'Factory reset is a separate recovery workflow',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Restoring a trusted backup and resetting to factory defaults are different operations. Factory reset discards server settings and requests a reboot. Neither workflow is secure erasure, disk-data restoration or a guarantee of recoverability.',
                        ),
                        OutlinedButton.icon(
                          key: const Key('restore-open-reset'),
                          onPressed: !idle
                              ? null
                              : () {
                                  _controller.discardSelection();
                                  Navigator.of(context).push<void>(
                                    MaterialPageRoute<void>(
                                      builder: (_) =>
                                          const ConfigurationResetPage(),
                                    ),
                                  );
                                },
                          icon: const Icon(Icons.restart_alt),
                          label: const Text('Open factory reset review'),
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

class _RestoreMetadata extends StatelessWidget {
  const _RestoreMetadata({required this.summary});
  final RestoreFileSummary summary;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      Text('Format: ${summary.format.name}'),
      Text('Size: ${summary.byteLength} bytes'),
      Text(
        'Password secret seed: ${summary.hasSecretSeed ? 'Present' : 'Absent — destination seed will be removed on startup'}',
      ),
      Text(
        'Root authorized-key members: ${summary.authorizedKeyMembers.isEmpty ? 'Absent — destination authorized keys will be removed on startup' : summary.authorizedKeyMembers.join(', ')}',
      ),
      const Text('SHA-256 fingerprint'),
      SelectableText(summary.sha256),
      const Text(
        'Structural inspection does NOT verify the source server, source version, migration compatibility or recovery suitability. Independently verify the file and retain separate recovery material.',
      ),
    ],
  );
}

class ConfigurationRestoreReviewDialog extends ConsumerStatefulWidget {
  const ConfigurationRestoreReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final ConfigurationRestoreReview review;
  @override
  ConsumerState<ConfigurationRestoreReviewDialog> createState() =>
      _ConfigurationRestoreReviewDialogState();
}

class _ConfigurationRestoreReviewDialogState
    extends ConsumerState<ConfigurationRestoreReviewDialog> {
  final _target = TextEditingController();
  final _ack = List<bool>.filled(6, false);
  bool _expired = false, _closing = false;
  late final AppLifecycleListener _lifecycle;
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
  }

  void _expire() {
    if (_expired) return;
    setState(() {
      _expired = true;
      _target.clear();
      _ack.fillRange(0, 6, false);
    });
  }

  void _finish(bool confirmed) {
    if (_closing) return;
    _closing = true;
    Navigator.of(context).pop(confirmed);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _target.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (ModalRoute.isCurrentOf(context) == false &&
        !_closing &&
        !widget.review.request.file.isDisposed) {
      ref.read(configurationRestoreControllerProvider.notifier).abandonRoute();
    }
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(configurationRestoreInventoryProvider, (_, next) {
      if (next.isLoading ||
          !identical(widget.review.request.inventory, next.asData?.value)) {
        _expire();
      }
    });
    final state = ref.watch(configurationRestoreControllerProvider),
        inventory = ref.watch(configurationRestoreInventoryProvider);
    final current =
        !_expired &&
        !widget.review.request.file.isDisposed &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(widget.review.request.inventory, inventory.asData?.value);
    const labels = [
      'I secured an independent current backup.',
      'I independently verified this file and its compatibility.',
      'I have independent console access and recovery material.',
      'I accept configuration replacement and automatic reboot.',
      'I accept removal of missing seed and authorized-key material.',
      'I compared this fingerprint to my trusted backup.',
    ];
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('restore-review-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? 'Review replacement & automatic reboot'
                    : 'Restore review expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous server and file details are hidden. Choose and review a trusted file again.',
                )
              else ...[
                SelectableText(widget.review.endpoint),
                _RestoreMetadata(
                  summary: RestoreFileSummary(widget.review.request.file),
                ),
                for (final warning in widget.review.warnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(warning),
                  ),
                const Text(
                  'Successful migration automatically schedules reboot after about 10 seconds. Accounts, network, credentials and access may change. Missing seed and authorized-key members are removed on startup. An accepted job or lost connection is not completion.',
                ),
                const Text(
                  'This review is single-use and expires after five minutes. Type the full server target and independently compare the displayed file fingerprint with your trusted backup.',
                ),
                SelectableText(widget.review.target),
                TextField(
                  key: const Key('restore-confirm-target'),
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
                    key: Key('restore-confirm-ack-$i'),
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
                    onPressed: () => _finish(false),
                    child: const Text('Cancel and discard file'),
                  ),
                  FilledButton(
                    key: const Key('restore-confirm-submit'),
                    onPressed:
                        current &&
                            !_closing &&
                            !state.locked &&
                            _ack.every((v) => v) &&
                            _target.text == widget.review.target
                        ? () => _finish(true)
                        : null,
                    child: const Text(
                      'Restore once and allow automatic reboot',
                    ),
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
