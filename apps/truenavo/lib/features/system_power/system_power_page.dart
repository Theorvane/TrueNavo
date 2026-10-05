import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../boot_environments/boot_environments_page.dart';
import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../system_updates/system_updates_page.dart';
import 'system_power_controller.dart';
import 'system_power_identity.dart';
import 'system_power_reason.dart';
import 'system_power_review.dart';

class SystemPowerPage extends ConsumerStatefulWidget {
  const SystemPowerPage({super.key});
  @override
  ConsumerState<SystemPowerPage> createState() => _SystemPowerPageState();
}

class _SystemPowerPageState extends ConsumerState<SystemPowerPage> {
  bool _reviewing = false;
  String? _error;

  Future<void> _change(
    AuthenticatedSession session,
    SystemPowerInventory inventory,
    SystemPowerAction action,
  ) async {
    if (_reviewing || ref.read(systemPowerControllerProvider).locked) return;
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
    final inventoryWatch = ref.listenManual(systemPowerInventoryProvider, (
      _,
      next,
    ) {
      if (next.isLoading || !identical(inventory, next.asData?.value)) {
        expired = true;
      }
    });
    bool current() =>
        mounted &&
        !expired &&
        identical(session, ref.read(dashboardActiveSessionProvider)) &&
        !ref.read(systemPowerInventoryProvider).isLoading &&
        identical(
          inventory,
          ref.read(systemPowerInventoryProvider).asData?.value,
        ) &&
        !ref.read(systemPowerControllerProvider).locked;
    try {
      if (!current()) return;
      final request = await showDialog<SystemPowerRequest>(
        context: context,
        barrierDismissible: false,
        builder: (_) => SystemPowerReasonDialog(
          session: session,
          inventory: inventory,
          action: action,
        ),
      );
      if (request == null ||
          !current() ||
          request.validationError != null ||
          !identical(request.inventory, inventory) ||
          request.action != action) {
        return;
      }
      final api = ref.read(systemPowerSessionProvider);
      if (api == null || !api.systemPowerCapabilities.supports(action)) return;
      final review = await api.reviewSystemPower(request);
      if (!mounted || !current()) return;
      if (!identical(review.request, request) ||
          review.endpoint != session.endpoint) {
        throw StateError('Mismatching system power review.');
      }
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            SystemPowerReviewDialog(session: session, review: review),
      );
      if (confirmed != true || !current()) return;
      await ref
          .read(systemPowerControllerProvider.notifier)
          .execute(
            expectedSession: session,
            review: review,
            confirmation: review.target,
          );
    } on Object {
      if (current()) {
        setState(
          () => _error = 'Power review could not be completed safely. Remote details were withheld. Reload readiness before reviewing again.',
        );
      }
    } finally {
      sessionWatch.close();
      inventoryWatch.close();
      lifecycle.dispose();
      if (mounted) setState(() => _reviewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final caps = ref.watch(systemPowerSessionProvider)?.systemPowerCapabilities;
    final state = ref.watch(systemPowerControllerProvider);
    final controller = ref.read(systemPowerControllerProvider.notifier);
    final available = session?.endpoint != null && caps?.supported == true;
    final canRefresh = available && !state.locked && !_reviewing;
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) setState(() => _error = null);
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('System power'),
        actions: [
          IconButton(
            key: const Key('power-refresh'),
            tooltip: 'Read power readiness',
            onPressed: canRefresh
                ? () => ref.invalidate(systemPowerInventoryProvider)
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: SingleChildScrollView(
          key: const Key('power-scroll'),
          padding: const EdgeInsets.all(20),
          child: Align(
            alignment: Alignment.topCenter,
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 1100),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text('SYSTEM · MAINTENANCE', style: TdTypography.micro),
                  const SizedBox(height: 8),
                  const Text(
                    'Restart & shutdown',
                    style: TdTypography.titleLarge,
                  ),
                  const SizedBox(height: 12),
                  Text(session?.endpoint ?? 'No authenticated connection'),
                  const Text(
                    'Last-read readiness only. No automatic job checks, reconnect, retry, or power action. A queued job or lost connection does not prove completion.',
                  ),
                  const SizedBox(height: 16),
                  if (state.busy || state.verifying)
                    const LinearProgressIndicator(),
                  if (state.result case final result?)
                    TdPanel(
                      title: state.accepted
                          ? 'Accepted — completion unverified'
                          : state.unknown
                          ? 'Inspect the original server'
                          : 'Last power review',
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Text(result.message),
                          if (state.server != null)
                            Text('Original server: ${state.server}'),
                          if (state.accepted && result.jobId != null)
                            Text('Accepted job: ${result.jobId}'),
                          if (state.unresolved) ...[
                            const Text(
                              'Other management writes remain locked. There is no job-check, retry or automatic reconnect button. Independently verify the original machine; after shutdown you may need physical or out-of-band access to turn it on.',
                            ),
                            OutlinedButton(
                              key: const Key('power-verify-reconnected'),
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
                              key: const Key('power-acknowledge'),
                              onPressed: controller.canAcknowledge
                                  ? controller.acknowledgeAfterReconnect
                                  : null,
                              child: const Text(
                                'I independently inspected the original server and reconnected',
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  if (_error != null) Text(_error!),
                  const SizedBox(height: 16),
                  if (!available)
                    TdPanel(
                      title: 'System power unavailable',
                      child: Text(
                        caps?.blockedReason ??
                            'Connect to a supported TrueNAS instance.',
                      ),
                    )
                  else if (state.locked && !state.connectionCurrent)
                    const TdPanel(
                      title: 'Original operation needs attention',
                      child: Text(
                        'Previous readiness and boot details are hidden. Independent original-server inspection and explicit reconnect acknowledgement are required.',
                      ),
                    )
                  else
                    ref
                        .watch(systemPowerInventoryProvider)
                        .when(
                          skipLoadingOnRefresh: false,
                          skipLoadingOnReload: false,
                          loading: () =>
                              const Center(child: CircularProgressIndicator()),
                          error: (_, _) => TdPanel(
                            title: 'Power readiness unavailable',
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                const Text(
                                  'Public host identity, boot state or job metadata could not be verified. Unknown does not mean ready. Remote details were withheld.',
                                ),
                                OutlinedButton(
                                  key: const Key('power-retry'),
                                  onPressed: canRefresh
                                      ? () => ref.invalidate(
                                          systemPowerInventoryProvider,
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
                                    ? 'Ready for a manual review'
                                    : 'Power actions blocked',
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.stretch,
                                  children: [
                                    if (inventory.blockedReason != null)
                                      Text(inventory.blockedReason!),
                                    SystemPowerIdentity(inventory: inventory),
                                  ],
                                ),
                              ),
                              const SizedBox(height: 16),
                              const Text(
                                'Both actions interrupt all clients, shares, applications and virtual machines. Only standalone servers with an unchanged, bootable next-boot environment are admitted here.',
                              ),
                              for (final action in SystemPowerAction.values)
                                Padding(
                                  padding: const EdgeInsets.only(top: 12),
                                  child: OutlinedButton.icon(
                                    key: Key('power-${action.name}'),
                                    onPressed:
                                        !_reviewing &&
                                            !state.locked &&
                                            caps!.supports(action) &&
                                            inventory.blockedReason == null
                                        ? () => _change(
                                            session!,
                                            inventory,
                                            action,
                                          )
                                        : null,
                                    icon: Icon(
                                      action == SystemPowerAction.reboot
                                          ? Icons.restart_alt
                                          : Icons.power_settings_new,
                                    ),
                                    label: Text(systemPowerLabel(action)),
                                  ),
                                ),
                            ],
                          ),
                        ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const BootEnvironmentsPage(),
                          ),
                        ),
                        child: const Text('Inspect boot environments'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => const SystemUpdatesPage(),
                          ),
                        ),
                        child: const Text('Inspect system updates'),
                      ),
                    ],
                  ),
                  const Text(
                    'Opening another workspace does not release an unresolved power-operation lock.',
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
