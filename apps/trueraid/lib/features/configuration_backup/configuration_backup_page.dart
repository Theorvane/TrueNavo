import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'configuration_backup_controller.dart';
import 'configuration_backup_file.dart';
import '../configuration_restore/configuration_restore_page.dart';

class ConfigurationBackupPage extends ConsumerStatefulWidget {
  const ConfigurationBackupPage({super.key});
  @override
  ConsumerState<ConfigurationBackupPage> createState() =>
      _ConfigurationBackupPageState();
}

class _ConfigurationBackupPageState
    extends ConsumerState<ConfigurationBackupPage> {
  bool _seed = false,
      _keys = false,
      _consent = false,
      _seedConsent = false,
      _reviewing = false;
  String? _error;
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    _lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed && mounted) _clearDraft();
      },
    );
  }

  void _clearDraft() => setState(() {
    _seed = false;
    _keys = false;
    _consent = false;
    _seedConsent = false;
    _error = null;
  });
  @override
  void dispose() {
    _lifecycle.dispose();
    super.dispose();
  }

  Future<void> _review(
    AuthenticatedSession session,
    ConfigurationBackupInventory inventory,
  ) async {
    if (_reviewing ||
        !_consent ||
        _seed && !_seedConsent ||
        ref.read(configurationBackupControllerProvider).locked) {
      return;
    }
    final request = ConfigurationBackupRequest(
      inventory: inventory,
      includeSecretSeed: _seed,
      includeAuthorizedKeys: _keys,
    );
    if (request.validationError != null) return;
    setState(() {
      _reviewing = true;
      _error = null;
    });
    final initial = WidgetsBinding.instance.lifecycleState;
    var expired = initial != null && initial != AppLifecycleState.resumed;
    final lifecycle = AppLifecycleListener(
      onStateChange: (state) {
        if (state != AppLifecycleState.resumed) expired = true;
      },
    );
    final sessionWatch = ref.listenManual(dashboardActiveSessionProvider, (
      a,
      b,
    ) {
      if (!identical(a, b)) expired = true;
    });
    final inventoryWatch = ref.listenManual(
      configurationBackupInventoryProvider,
      (_, next) {
        if (next.isLoading || !identical(inventory, next.asData?.value)) {
          expired = true;
        }
      },
    );
    bool current() =>
        mounted &&
        !expired &&
        identical(session, ref.read(dashboardActiveSessionProvider)) &&
        !ref.read(configurationBackupInventoryProvider).isLoading &&
        identical(
          inventory,
          ref.read(configurationBackupInventoryProvider).asData?.value,
        ) &&
        !ref.read(configurationBackupControllerProvider).locked;
    try {
      if (!current()) return;
      final api = ref.read(configurationBackupSessionProvider);
      if (api == null ||
          !api.configurationBackupCapabilities.canExport ||
          !ref.read(configurationBackupFileSaverProvider).supported) {
        return;
      }
      final review = await api.reviewConfigurationBackup(request);
      if (!mounted || !current()) return;
      if (!identical(review.request, request) ||
          review.endpoint != session.endpoint) {
        throw StateError('Mismatching backup review.');
      }
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            ConfigurationBackupReviewDialog(session: session, review: review),
      );
      if (confirmed != true || !current()) return;
      await ref
          .read(configurationBackupControllerProvider.notifier)
          .execute(
            expectedSession: session,
            review: review,
            confirmation: review.target,
            confidentialityAccepted: true,
            secretSeedAccepted: true,
          );
    } on Object {
      if (current()) {
        setState(
          () => _error = 'The export could not be reviewed safely. Remote details were withheld. Reload metadata and create a new review.',
        );
      }
    } finally {
      sessionWatch.close();
      inventoryWatch.close();
      lifecycle.dispose();
      if (mounted) {
        setState(() {
          _reviewing = false;
          _consent = false;
          _seedConsent = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final caps = ref
        .watch(configurationBackupSessionProvider)
        ?.configurationBackupCapabilities;
    final saver = ref.watch(configurationBackupFileSaverProvider);
    final state = ref.watch(configurationBackupControllerProvider);
    final controller = ref.read(configurationBackupControllerProvider.notifier);
    final canRead =
        session?.endpoint != null &&
        caps?.connected == true &&
        caps?.versionSupported == true &&
        caps?.available == true;
    final canExport = canRead && caps!.canExport && saver.supported;
    final canRefresh = canRead && !state.locked && !_reviewing;
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _clearDraft();
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('Configuration backup'),
        actions: [
          IconButton(
            key: const Key('backup-refresh'),
            tooltip: 'Read backup readiness',
            onPressed: canRefresh
                ? () => ref.invalidate(configurationBackupInventoryProvider)
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          key: const Key('backup-scroll'),
          padding: const EdgeInsets.all(20),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'SYSTEM · CONFIGURATION EXPORT',
                    style: TdTypography.micro,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Keep a configuration backup',
                    style: TdTypography.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(session?.endpoint ?? 'No authenticated connection'),
                  const Text(
                    'Export only. Opening this page reads public readiness, not configuration contents. No download, file save, polling or retry starts automatically.',
                  ),
                  const SizedBox(height: 16),
                  const TdPanel(
                    title: 'Every configuration backup is sensitive',
                    child: Text(
                      'Even without the password secret seed, this file contains private server configuration. The optional seed allows decryption of stored server credentials. Choose a trusted, protected destination; an Android document provider may upload the file to cloud storage.',
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (state.busy || state.verifying)
                    const LinearProgressIndicator(),
                  if (state.message != null)
                    TdPanel(
                      title: state.unknown
                          ? 'Inspect before continuing'
                          : state.status == ConfigurationBackupStatus.saved
                          ? 'Provider reported file saved'
                          : 'Export status',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(state.message!),
                          if (state.server != null)
                            Text('Original server: ${state.server}'),
                          if (state.jobId != null)
                            Text('Export job: ${state.jobId}'),
                          if (state.unknown) ...[
                            const Text(
                              'Other management writes remain locked. Reconnect explicitly to the original server, verify its identity once, and independently inspect its jobs and any selected destination before acknowledging.',
                            ),
                            OutlinedButton(
                              key: const Key('backup-verify-reconnected'),
                              onPressed: controller.canVerifyReconnectedServer
                                  ? controller.verifyReconnectedServer
                                  : null,
                              child: const Text(
                                'Verify reconnected server identity once',
                              ),
                            ),
                            if (state.verificationMessage != null)
                              Text(state.verificationMessage!),
                            OutlinedButton(
                              key: const Key('backup-acknowledge'),
                              onPressed: controller.canAcknowledge
                                  ? controller.acknowledgeAfterReconnect
                                  : null,
                              child: const Text(
                                'I inspected original-server jobs and the selected file',
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  if (_error != null) Text(_error!),
                  const SizedBox(height: 16),
                  if (!canRead)
                    TdPanel(
                      title: 'Configuration backup unavailable',
                      child: Text(
                        caps?.blockedReason ??
                            'Connect to a supported TrueNAS instance.',
                      ),
                    )
                  else if (state.locked && !state.connectionCurrent)
                    const TdPanel(
                      title: 'Original export needs attention',
                      child: Text(
                        'Previous readiness and export options are hidden until original-server verification and acknowledgement.',
                      ),
                    )
                  else
                    ref
                        .watch(configurationBackupInventoryProvider)
                        .when(
                          skipLoadingOnRefresh: false,
                          skipLoadingOnReload: false,
                          loading: () =>
                              const Center(child: CircularProgressIndicator()),
                          error: (_, _) => TdPanel(
                            title: 'Backup readiness unavailable',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Text(
                                  'Public host identity, authorization or job state could not be verified. Unknown does not mean ready. Remote details were withheld.',
                                ),
                                OutlinedButton(
                                  key: const Key('backup-retry'),
                                  onPressed: canRefresh
                                      ? () => ref.invalidate(
                                          configurationBackupInventoryProvider,
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
                                    ? 'Ready for a manual export review'
                                    : 'Export blocked',
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (inventory.blockedReason != null)
                                      Text(inventory.blockedReason!),
                                    Text(
                                      'Version: ${inventory.currentVersion}',
                                    ),
                                    Text('System state: ${inventory.state}'),
                                    Text(
                                      'Full administrator: ${inventory.fullAdmin ? 'Verified in last read' : 'Not verified'}',
                                    ),
                                    Text(
                                      'HA licensed: ${inventory.failoverLicensed ? 'Yes — coordinated workflow required' : 'No'}',
                                    ),
                                    Text(
                                      'Active or waiting jobs: ${inventory.conflictingJob ? 'Present — blocked' : 'None in last read'}',
                                    ),
                                    const Text('Full public host identity'),
                                    SelectableText(inventory.hostId),
                                  ],
                                ),
                              ),
                              if (!canExport)
                                const Padding(
                                  padding: EdgeInsets.only(top: 12),
                                  child: Text(
                                    'File export is unavailable here. It requires the supported Android document picker and certificate-pinned secure download transport. No fallback or external browser download is used.',
                                  ),
                                ),
                              const SizedBox(height: 16),
                              CheckboxListTile(
                                key: const Key('backup-secret-seed'),
                                contentPadding: EdgeInsets.zero,
                                value: _seed,
                                onChanged:
                                    canExport &&
                                        !state.locked &&
                                        !_reviewing &&
                                        inventory.blockedReason == null
                                    ? (value) => setState(() {
                                        _seed = value ?? false;
                                        _seedConsent = false;
                                        _consent = false;
                                      })
                                    : null,
                                title: const Text(
                                  'Include password secret seed',
                                ),
                              ),
                              if (_seed) ...[
                                const Text(
                                  'The seed enables decryption of credentials stored in this configuration. Protect this archive as a credential-bearing backup. Do not send it to an untrusted person or document provider.',
                                ),
                                CheckboxListTile(
                                  key: const Key('backup-seed-consent'),
                                  contentPadding: EdgeInsets.zero,
                                  value: _seedConsent,
                                  onChanged: !state.locked && !_reviewing
                                      ? (value) => setState(
                                          () => _seedConsent = value ?? false,
                                        )
                                      : null,
                                  title: const Text(
                                    'I accept including the decryption seed.',
                                  ),
                                ),
                              ],
                              CheckboxListTile(
                                key: const Key('backup-authorized-keys'),
                                contentPadding: EdgeInsets.zero,
                                value: _keys,
                                onChanged:
                                    canExport &&
                                        !state.locked &&
                                        !_reviewing &&
                                        inventory.blockedReason == null
                                    ? (value) => setState(() {
                                        _keys = value ?? false;
                                        _consent = false;
                                      })
                                    : null,
                                title: const Text(
                                  'Include root SSH authorized keys',
                                ),
                              ),
                              const Text(
                                'Both optional fields start off. This is not a backup of disk data or dataset contents, or a separate or complete encryption-key export. The configuration database may contain stored encrypted dataset keys, SSH private keys and other secrets. Keep independent recovery-key backups. The pool_keys option is false and ignored on SCALE; this does not remove keys already stored in the database.',
                              ),
                              const SizedBox(height: 12),
                              const Text(
                                'I understand every export is sensitive and the selected document provider may use cloud storage. I authorize this reviewed export only to a destination I trust.',
                              ),
                              CheckboxListTile(
                                key: const Key('backup-export-consent'),
                                contentPadding: EdgeInsets.zero,
                                value: _consent,
                                onChanged:
                                    canExport &&
                                        !state.locked &&
                                        !_reviewing &&
                                        inventory.blockedReason == null
                                    ? (value) => setState(
                                        () => _consent = value ?? false,
                                      )
                                    : null,
                                title: const Text(
                                  'I accept this export and destination risk.',
                                ),
                              ),
                              FilledButton.icon(
                                key: const Key('backup-review'),
                                onPressed:
                                    canExport &&
                                        !state.locked &&
                                        !_reviewing &&
                                        inventory.blockedReason == null &&
                                        _consent &&
                                        (!_seed || _seedConsent)
                                    ? () => _review(session!, inventory)
                                    : null,
                                icon: const Icon(Icons.save_alt),
                                label: const Text(
                                  'Review configuration export',
                                ),
                              ),
                            ],
                          ),
                        ),
                  const SizedBox(height: 20),
                  TdPanel(
                    title: 'Restoration is a separate recovery workflow',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'A saved export does not prove recoverability. Configuration restore replaces settings and automatically reboots TrueNAS 25.10.1. This backup page never uploads or restores a file. Factory reset requires its own independent recovery review.',
                        ),
                        OutlinedButton.icon(
                          key: const Key('backup-open-restore'),
                          onPressed: state.locked || _reviewing
                              ? null
                              : () => Navigator.of(context).push<void>(
                                  MaterialPageRoute<void>(
                                    builder: (_) =>
                                        const ConfigurationRestorePage(),
                                  ),
                                ),
                          icon: const Icon(Icons.settings_backup_restore),
                          label: const Text('Open configuration restore'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  const Text(
                    'The app keeps no cached export or download token. Cancellation or a failed document-provider write may leave an empty or partial file at your selected destination. Inspect it yourself; this app does not delete it automatically.',
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

class ConfigurationBackupReviewDialog extends ConsumerStatefulWidget {
  const ConfigurationBackupReviewDialog({
    required this.session,
    required this.review,
    super.key,
  });
  final AuthenticatedSession session;
  final ConfigurationBackupReview review;
  @override
  ConsumerState<ConfigurationBackupReviewDialog> createState() =>
      _ConfigurationBackupReviewDialogState();
}

class _ConfigurationBackupReviewDialogState
    extends ConsumerState<ConfigurationBackupReviewDialog> {
  final _target = TextEditingController();
  bool _consent = false, _seedConsent = false, _expired = false;
  late final AppLifecycleListener _lifecycle;
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
  }

  void _expire() {
    if (_expired) return;
    setState(() {
      _expired = true;
      _consent = false;
      _seedConsent = false;
      _target.clear();
    });
  }

  @override
  void dispose() {
    _target.dispose();
    _lifecycle.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) _expire();
    });
    ref.listen(configurationBackupInventoryProvider, (_, next) {
      if (next.isLoading ||
          !identical(widget.review.request.inventory, next.asData?.value)) {
        _expire();
      }
    });
    final inventory = ref.watch(configurationBackupInventoryProvider);
    final request = widget.review.request;
    final current =
        !_expired &&
        identical(widget.session, ref.watch(dashboardActiveSessionProvider)) &&
        !inventory.isLoading &&
        identical(request.inventory, inventory.asData?.value);
    final locked = ref.watch(configurationBackupControllerProvider).locked;
    return Dialog(
      insetPadding: const EdgeInsets.all(12),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 720),
        child: SingleChildScrollView(
          key: const Key('backup-review-scroll'),
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                current
                    ? 'Review sensitive configuration export'
                    : 'Backup review expired',
                style: Theme.of(context).textTheme.titleLarge,
              ),
              if (!current)
                const Text(
                  'Previous server details and confirmation are hidden. Reload and review again.',
                )
              else ...[
                SelectableText(widget.review.endpoint),
                Text('Version: ${request.inventory.currentVersion}'),
                Text(
                  'Password secret seed: ${request.includeSecretSeed ? 'Included — permits credential decryption' : 'Not included'}',
                ),
                Text(
                  'Root SSH authorized keys: ${request.includeAuthorizedKeys ? 'Included' : 'Not included'}',
                ),
                const Text(
                  'Pool-key option: False and ignored on SCALE. Stored encrypted dataset keys, SSH private keys and other secrets may still be present in the configuration database. This is not a separate or complete encryption-key export; retain independent recovery material. Disk data and dataset contents are not backed up.',
                ),
                Text(
                  'Filename: ${request.includeSecretSeed || request.includeAuthorizedKeys ? 'truenas-configuration.tar' : 'truenas-configuration.db'}',
                ),
                for (final warning in widget.review.warnings)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Text(warning),
                  ),
                const SizedBox(height: 12),
                const Text(
                  'Every file remains sensitive. After a verified export job and validated bounded download, choose a trusted Android document provider. It may use cloud storage. File saving is not transactional; cancellation or failure may leave an empty or partial file. No automatic deletion, retry or cached artifact is provided.',
                ),
                const Text(
                  'This review is single-use and expires after five minutes. Exporting does not verify restoration, recovery or durable off-device storage.',
                ),
                const SizedBox(height: 12),
                SelectableText(widget.review.target),
                TextField(
                  key: const Key('backup-confirm-target'),
                  controller: _target,
                  minLines: 1,
                  maxLines: 4,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(
                    labelText: 'Exact confirmation target',
                    helperText: 'Type the full action and host identity. Case-sensitive; no trimming.',
                  ),
                  onChanged: (_) => setState(() {}),
                ),
                if (request.includeSecretSeed) ...[
                  const Text(
                    'This archive can decrypt stored server credentials. Anyone with access to it may gain those credentials. Protect the destination as you would a credential store.',
                  ),
                  CheckboxListTile(
                    key: const Key('backup-confirm-seed'),
                    contentPadding: EdgeInsets.zero,
                    value: _seedConsent,
                    onChanged: (value) =>
                        setState(() => _seedConsent = value ?? false),
                    title: const Text(
                      'I accept including the decryption seed.',
                    ),
                  ),
                ],
                const Text(
                  'I authorize this sensitive export and understand the destination may be cloud-backed. I will independently protect the file and verify my recovery plan.',
                ),
                CheckboxListTile(
                  key: const Key('backup-confirm-consent'),
                  contentPadding: EdgeInsets.zero,
                  value: _consent,
                  onChanged: (value) =>
                      setState(() => _consent = value ?? false),
                  title: const Text(
                    'I accept this export and destination risk.',
                  ),
                ),
              ],
              Wrap(
                alignment: WrapAlignment.end,
                spacing: 8,
                runSpacing: 8,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: const Text('Cancel'),
                  ),
                  FilledButton(
                    key: const Key('backup-confirm-submit'),
                    onPressed:
                        current &&
                            !locked &&
                            _consent &&
                            (!request.includeSecretSeed || _seedConsent) &&
                            _target.text == widget.review.target
                        ? () => Navigator.of(context).pop(true)
                        : null,
                    child: const Text('Export once and choose destination'),
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
