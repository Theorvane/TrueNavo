import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'system_update_review.dart';
import 'system_updates_controller.dart';

class SystemUpdatesPage extends ConsumerStatefulWidget {
  const SystemUpdatesPage({super.key});
  @override
  ConsumerState<SystemUpdatesPage> createState() => _SystemUpdatesPageState();
}

class _SystemUpdatesPageState extends ConsumerState<SystemUpdatesPage> {
  final _scroll = ScrollController();
  bool _reviewing = false;
  String? _error;
  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _review(
    AuthenticatedSession session,
    SystemUpdateRequest request,
  ) async {
    if (_reviewing) return;
    setState(() {
      _reviewing = true;
      _error = null;
    });
    try {
      await reviewSystemUpdateChange(
        context: context,
        ref: ref,
        session: session,
        request: request,
      );
    } on Object {
      if (mounted &&
          identical(session, ref.read(dashboardActiveSessionProvider))) {
        setState(
          () => _error = 'This update could not be reviewed safely. Nothing was submitted. Reload local information.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _reviewing = false);
        if (_scroll.hasClients &&
            ref.read(systemUpdatesControllerProvider).result != null) {
          _scroll.jumpTo(0);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final caps = ref
        .watch(systemUpdatesSessionProvider)
        ?.systemUpdatesCapabilities;
    final state = ref.watch(systemUpdatesControllerProvider);
    final available = session?.endpoint != null && caps?.supported == true;
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (!identical(previous, next)) setState(() => _error = null);
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('System updates'),
        actions: [
          IconButton(
            key: const Key('updates-refresh'),
            tooltip: 'Reload local update information',
            onPressed: available && !state.locked && !_reviewing
                ? () => ref.invalidate(systemUpdatesInventoryProvider)
                : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SingleChildScrollView(
        key: const Key('updates-workspace-scroll'),
        controller: _scroll,
        padding: const EdgeInsets.all(TdSpacing.component),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('OPERATING SYSTEM', style: TdTypography.micro),
                const SizedBox(height: TdSpacing.related),
                const Text('System updates', style: TdTypography.titleLarge),
                const SizedBox(height: TdSpacing.related),
                Text(session?.endpoint ?? 'No authenticated connection'),
                const SizedBox(height: TdSpacing.component),
                const SystemUpdatesOperationBanner(),
                if (!available)
                  TdPanel(
                    title: 'System updates unavailable',
                    child: Text(
                      caps?.blockedReason ??
                          'Connect to a supported TrueNAS instance.',
                    ),
                  )
                else if (state.locked && !state.connectionCurrent)
                  const TdPanel(
                    title: 'Original update needs attention',
                    child: Text(
                      'Previous release details are hidden. Verify the original server before acknowledging this operation.',
                    ),
                  )
                else
                  ref
                      .watch(systemUpdatesInventoryProvider)
                      .when(
                        skipLoadingOnRefresh: false,
                        skipLoadingOnReload: false,
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (_, _) => TdPanel(
                          title: 'Local update information unavailable',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Remote details were withheld. Local reads are not retried automatically, and no update-source check was started.',
                              ),
                              OutlinedButton(
                                key: const Key('updates-retry'),
                                onPressed: state.locked || _reviewing
                                    ? null
                                    : () => ref.invalidate(
                                        systemUpdatesInventoryProvider,
                                      ),
                                child: const Text('Retry local reads'),
                              ),
                            ],
                          ),
                        ),
                        data: (inventory) => Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _UpdateSummaries(inventory: inventory),
                            const SizedBox(height: TdSpacing.component),
                            const Text(
                              'Opening this page and reloading local information do not contact the update source. Check, download and install each require a separate exact-target review. No upload, resume, automatic polling or reboot is offered.',
                            ),
                            if (inventory.blockedReason case final reason?) ...[
                              const SizedBox(height: TdSpacing.related),
                              Text(reason),
                            ],
                            const SizedBox(height: TdSpacing.component),
                            TdPanel(
                              title: 'Update source',
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  Text(
                                    !inventory.checked
                                        ? 'Not checked this session'
                                        : inventory.checkError != null
                                        ? 'Source check did not complete'
                                        : 'Checked catalog · ${inventory.versions.length} releases · ${inventory.versions.map((v) => v.train).toSet().length} trains',
                                    style: TdTypography.titleSmall,
                                  ),
                                  if (inventory.currentTrain case final train?)
                                    Text('Current train: $train'),
                                  if (inventory.currentProfile
                                      case final profile?)
                                    Text('Current profile: $profile'),
                                  if (inventory.checked)
                                    Text(
                                      'Profile match: ${switch (inventory.matchesProfile) {
                                        true => 'Yes',
                                        false => 'No',
                                        null => 'Unknown',
                                      }}',
                                    ),
                                  if (inventory.checkError != null)
                                    const Text(
                                      'The update source could not be checked safely. Remote error details are withheld. No download or installation is enabled.',
                                    ),
                                  const SizedBox(height: TdSpacing.related),
                                  const Text(
                                    'A check contacts the upstream source and may initialize the server update profile.',
                                  ),
                                  Align(
                                    alignment: Alignment.centerLeft,
                                    child: FilledButton.icon(
                                      key: const Key('updates-check'),
                                      icon: const Icon(
                                        Icons.fact_check_outlined,
                                      ),
                                      label: const Text('Review source check'),
                                      onPressed:
                                          !state.locked &&
                                              !_reviewing &&
                                              caps!.canCheck &&
                                              inventory.blockedReason == null
                                          ? () => _review(
                                              session!,
                                              SystemUpdateRequest(
                                                inventory: inventory,
                                                action:
                                                    SystemUpdateAction.check,
                                              ),
                                            )
                                          : null,
                                    ),
                                  ),
                                  if (!caps!.canCheck)
                                    const Text(
                                      'Source checking is unavailable: required public methods or permissions are missing.',
                                    ),
                                ],
                              ),
                            ),
                            const SizedBox(height: TdSpacing.component),
                            if (_error case final error?)
                              Padding(
                                padding: const EdgeInsets.only(
                                  bottom: TdSpacing.related,
                                ),
                                child: Text(error),
                              ),
                            if (inventory.downloadPercent != null ||
                                inventory.downloadVersion != null)
                              TdPanel(
                                title: 'Server-reported staging',
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      'Release: ${inventory.downloadVersion ?? 'Unknown'}',
                                    ),
                                    Text(
                                      'Reported download: ${_percent(inventory.downloadPercent)}',
                                    ),
                                    const Text(
                                      'This is a reported staging status, not an owned live job, checksum verification, or installation readiness.',
                                    ),
                                  ],
                                ),
                              ),
                            if (inventory.checked && inventory.versions.isEmpty)
                              const Text(
                                'No releases were returned. This does not prove the server is up to date.',
                              ),
                            for (
                              var i = 0;
                              i < inventory.versions.length;
                              i++
                            ) ...[
                              const SizedBox(height: TdSpacing.related),
                              _ReleaseCard(
                                version: inventory.versions[i],
                                index: i,
                                inventory: inventory,
                                caps: caps,
                                enabled: !state.locked && !_reviewing,
                                onReview: (request) =>
                                    _review(session!, request),
                              ),
                            ],
                            const SizedBox(height: TdSpacing.component),
                            TdPanel(
                              title: 'Boot-environment protection',
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.stretch,
                                children: [
                                  const Text(
                                    'Installation requires every inactive boot environment to be kept. This screen does not change Keep or delete environments.',
                                  ),
                                  if (inventory.installBlockedReason
                                      case final reason?)
                                    Text('Installation blocked: $reason'),
                                  for (final environment
                                      in inventory.environments)
                                    Padding(
                                      padding: const EdgeInsets.only(
                                        top: TdSpacing.related,
                                      ),
                                      child: Text(
                                        '${environment.id} · ${environment.active ? 'Current' : 'Inactive'} · ${environment.activated ? 'Next boot' : 'Not selected'} · Keep ${environment.keep ? 'on' : 'off'}',
                                      ),
                                    ),
                                ],
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
    );
  }
}

String systemUpdateBytes(int? bytes) {
  if (bytes == null || bytes < 0) return 'Unknown';
  if (bytes == 0) return '0 B';
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB'];
  var value = bytes.toDouble(), unit = 0;
  while (value >= 1024 && unit < units.length - 1) {
    value /= 1024;
    unit++;
  }
  return '${value.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}

String _percent(double? percent) =>
    percent == null || !percent.isFinite || percent < 0 || percent > 100
    ? 'Unknown'
    : '${percent.toStringAsFixed(1)}%';

class _UpdateSummaries extends StatelessWidget {
  const _UpdateSummaries({required this.inventory});
  final SystemUpdateInventory inventory;
  @override
  Widget build(BuildContext context) {
    final current = TdPanel(
      key: const Key('updates-summary-version'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Current system', style: TdTypography.titleSmall),
          const SizedBox(height: TdSpacing.component),
          Text(inventory.currentVersion, style: TdTypography.metricMedium),
          Text('Boot pool: ${inventory.bootPool}'),
          Text(
            'Boot pool: ${inventory.bootHealthy ? 'Healthy' : 'Not healthy'}',
          ),
          Text('HA licensed: ${inventory.failoverLicensed ? 'Yes' : 'No'}'),
        ],
      ),
    );
    final size = inventory.bootSizeBytes,
        allocated = inventory.bootAllocatedBytes;
    final ratio =
        size != null &&
            size > 0 &&
            allocated != null &&
            allocated >= 0 &&
            allocated <= size
        ? allocated / size
        : null;
    final capacity = TdPanel(
      key: const Key('updates-summary-capacity'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const Text('Raw boot-pool capacity', style: TdTypography.titleSmall),
          const SizedBox(height: TdSpacing.component),
          Text('Size: ${systemUpdateBytes(size)}'),
          Text('Allocated: ${systemUpdateBytes(allocated)}'),
          Text('Free: ${systemUpdateBytes(inventory.bootFreeBytes)}'),
          if (ratio != null) ...[
            const SizedBox(height: TdSpacing.related),
            Semantics(
              label:
                  'Raw boot-pool allocated capacity ${(ratio * 100).toStringAsFixed(1)} percent. Not installation progress or sufficient installation space.',
              child: SizedBox(
                height: 4,
                child: LinearProgressIndicator(
                  key: const Key('updates-boot-capacity'),
                  value: ratio,
                ),
              ),
            ),
          ],
          const SizedBox(height: TdSpacing.related),
          const Text(
            'Raw free space is not proof of sufficient installation capacity.',
          ),
        ],
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        if (constraints.maxWidth < 720 ||
            MediaQuery.textScalerOf(context).scale(14) > 21) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              current,
              const SizedBox(height: TdSpacing.related),
              capacity,
            ],
          );
        }
        return IntrinsicHeight(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Expanded(child: current),
              const SizedBox(width: TdSpacing.related),
              Expanded(child: capacity),
            ],
          ),
        );
      },
    );
  }
}

class _ReleaseCard extends StatelessWidget {
  const _ReleaseCard({
    required this.version,
    required this.index,
    required this.inventory,
    required this.caps,
    required this.enabled,
    required this.onReview,
  });
  final SystemUpdateVersion version;
  final int index;
  final SystemUpdateInventory inventory;
  final SystemUpdatesCapabilities caps;
  final bool enabled;
  final ValueChanged<SystemUpdateRequest> onReview;
  @override
  Widget build(BuildContext context) => TdPanel(
    title: version.version,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('Train: ${version.train}'),
        Text('Profile: ${version.profile}'),
        Text('Download size: ${systemUpdateBytes(version.downloadBytes)}'),
        if (version.blockedReason case final reason?) Text(reason),
        if (version.releaseNotes case final notes?)
          SelectableText('Source-reported release notes: $notes'),
        const SizedBox(height: TdSpacing.related),
        Wrap(
          spacing: TdSpacing.related,
          runSpacing: TdSpacing.related,
          children: [
            for (final action in [
              SystemUpdateAction.download,
              SystemUpdateAction.install,
            ])
              OutlinedButton(
                key: ValueKey('updates-${action.name}-$index'),
                onPressed:
                    enabled &&
                        caps.supports(action) &&
                        SystemUpdateRequest(
                              inventory: inventory,
                              action: action,
                              version: version,
                            ).validationError ==
                            null
                    ? () => onReview(
                        SystemUpdateRequest(
                          inventory: inventory,
                          action: action,
                          version: version,
                        ),
                      )
                    : null,
                child: Text('Review ${action.name}'),
              ),
          ],
        ),
        if (!caps.canDownload || !caps.canInstall)
          const Text(
            'Some actions are unavailable: required public methods or permissions are missing.',
          ),
      ],
    ),
  );
}

class SystemUpdatesOperationBanner extends ConsumerWidget {
  const SystemUpdatesOperationBanner({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(systemUpdatesControllerProvider);
    final controller = ref.read(systemUpdatesControllerProvider.notifier);
    final result = state.result;
    if (result == null && !state.busy && state.recoveryMessage == null) {
      return const SizedBox.shrink();
    }
    final title = state.busy
        ? 'Update request in progress'
        : state.unknown
        ? 'Update outcome needs verification'
        : state.pending
        ? 'Update job pending'
        : result?.rebootRequired == true
        ? 'Server requires reboot — verify in TrueNAS'
        : 'Update result';
    return Padding(
      padding: const EdgeInsets.only(bottom: TdSpacing.component),
      child: TdPanel(
        key: const Key('updates-operation-banner'),
        title: title,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (state.server != null)
              SelectableText('Original server: ${state.server}'),
            if (state.target != null)
              SelectableText('Exact target: ${state.target}'),
            if (result != null) Text(result.message),
            if (state.recoveryMessage case final message?) Text(message),
            if (result?.job case final job?)
              Text('Owned ${job.action.name} job #${job.id}'),
            if (result?.percent != null)
              Text(
                'Server-reported job progress: ${_percent(result!.percent)}',
              ),
            if (state.busy)
              const Padding(
                padding: EdgeInsets.only(top: TdSpacing.related),
                child: LinearProgressIndicator(),
              ),
            if (state.pending || state.unknown)
              const Text(
                'No automatic polling or retry. A missing or failed job read does not prove the operation stopped.',
              ),
            if (result?.outcome == SystemUpdateOutcome.failed)
              const Text(
                'A terminal failure can leave staging files or partial update effects. Inspect TrueNAS before another attempt.',
              ),
            if (result?.rebootRequired == true)
              const Text(
                'The server reports a reboot requirement. No reboot was requested. Verify the current system, installed boot environment and next-boot selection in TrueNAS. This session remains fenced; reconnect after independent verification.',
              ),
            if (controller.canPoll)
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton(
                  key: const Key('updates-poll'),
                  onPressed: controller.poll,
                  child: const Text('Check job status once'),
                ),
              ),
            if (state.requiresVerification) ...[
              const Text(
                'Inspect the original server first. Only a fresh connection to that same endpoint can acknowledge this uncertainty. No earlier request is replayed.',
              ),
              if (controller.canAcknowledge)
                Align(
                  alignment: Alignment.centerLeft,
                  child: OutlinedButton(
                    key: const Key('updates-acknowledge'),
                    onPressed: controller.acknowledgeAfterReconnect,
                    child: const Text(
                      'I inspected the original server; reload local state',
                    ),
                  ),
                ),
            ],
          ],
        ),
      ),
    );
  }
}
