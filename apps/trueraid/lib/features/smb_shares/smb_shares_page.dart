import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import '../smb_settings/smb_settings_page.dart';
import 'smb_share_editor.dart';
import 'smb_share_review.dart';
import 'smb_shares_controller.dart';

class SmbSharesPage extends ConsumerStatefulWidget {
  const SmbSharesPage({super.key});
  @override
  ConsumerState<SmbSharesPage> createState() => _SmbSharesPageState();
}

class _SmbSharesPageState extends ConsumerState<SmbSharesPage> {
  final _scroll = ScrollController();
  final _search = TextEditingController();
  bool _reviewing = false;
  String? _error;
  @override
  void dispose() {
    _scroll.dispose();
    _search.dispose();
    super.dispose();
  }

  Future<void> _delete(
    AuthenticatedSession session,
    SmbShareInventory inventory,
    SmbShareEntry share,
  ) async {
    if (_reviewing) return;
    setState(() {
      _reviewing = true;
      _error = null;
    });
    try {
      await reviewSmbShareChange(
        context: context,
        ref: ref,
        session: session,
        request: SmbShareRequest(
          inventory: inventory,
          action: SmbShareAction.delete,
          share: share,
        ),
      );
    } on Object {
      if (mounted &&
          identical(session, ref.read(dashboardActiveSessionProvider))) {
        setState(
          () => _error = 'This share could not be reviewed safely. Nothing was sent. Reload the current inventory.',
        );
      }
    } finally {
      if (mounted) {
        setState(() => _reviewing = false);
        if (_scroll.hasClients &&
            ref.read(smbSharesControllerProvider).result != null) {
          _scroll.jumpTo(0);
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    final caps = ref.watch(smbSharesSessionProvider)?.smbSharesCapabilities;
    final state = ref.watch(smbSharesControllerProvider);
    final available = caps?.supported == true && session?.endpoint != null;
    ref.listen(dashboardActiveSessionProvider, (previous, next) {
      if (!identical(previous, next)) {
        setState(() {
          _search.clear();
          _error = null;
        });
      }
    });
    return Scaffold(
      appBar: AppBar(
        title: const Text('SMB shares'),
        actions: [
          IconButton(
            key: const Key('smb-server-settings'),
            tooltip: 'SMB server settings',
            onPressed: !state.locked && !_reviewing
                ? () => Navigator.of(context).push<void>(
                    MaterialPageRoute(builder: (_) => const SmbSettingsPage()),
                  )
                : null,
            icon: const Icon(Icons.settings_outlined),
          ),
          IconButton(
            key: const Key('smb-refresh'),
            tooltip: 'Reload SMB shares',
            onPressed: available && !state.locked && !_reviewing
                ? () => ref.invalidate(smbSharesInventoryProvider)
                : null,
            icon: const Icon(Icons.refresh_rounded),
          ),
        ],
      ),
      body: SmbSharesWorkspace(
        controller: _scroll,
        children: [
          const Text('NETWORK FILE ACCESS', style: TdTypography.micro),
          const SizedBox(height: TdSpacing.related),
          const Text('SMB shares', style: TdTypography.titleLarge),
          const SizedBox(height: TdSpacing.related),
          Text(session?.endpoint ?? 'No authenticated connection'),
          const SizedBox(height: TdSpacing.component),
          const SmbSharesOperationBanner(),
          if (!available)
            TdPanel(
              title: 'SMB shares unavailable',
              child: Text(
                caps?.blockedReason ??
                    'Connect to a supported TrueNAS instance.',
              ),
            )
          else if (state.locked && !state.connectionCurrent)
            const TdPanel(
              title: 'Original operation needs attention',
              child: Text(
                'Previous share details are hidden. Resolve the original outcome before another change.',
              ),
            )
          else
            ref
                .watch(smbSharesInventoryProvider)
                .when(
                  skipLoadingOnRefresh: false,
                  skipLoadingOnReload: false,
                  loading: () =>
                      const Center(child: CircularProgressIndicator()),
                  error: (_, _) => TdPanel(
                    title: 'SMB inventory unavailable',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        const Text(
                          'Remote details were withheld. This read is not retried automatically.',
                        ),
                        OutlinedButton(
                          key: const Key('smb-retry'),
                          onPressed: state.locked || _reviewing
                              ? null
                              : () =>
                                    ref.invalidate(smbSharesInventoryProvider),
                          child: const Text('Try again'),
                        ),
                      ],
                    ),
                  ),
                  data: (inventory) => Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _SmbSummaries(inventory: inventory),
                      const SizedBox(height: TdSpacing.component),
                      SmbShareEnablementChart(shares: inventory.shares),
                      const SizedBox(height: TdSpacing.component),
                      const Text(
                        'Default-purpose shares on existing verified dataset roots. Filesystem permissions are not edited here. No client/session counts or connectivity checks are inferred.',
                      ),
                      const SizedBox(height: TdSpacing.component),
                      TextField(
                        key: const Key('smb-search'),
                        controller: _search,
                        decoration: const InputDecoration(
                          labelText: 'Find a share or path',
                          prefixIcon: Icon(Icons.search_rounded),
                        ),
                        onChanged: (_) => setState(() {}),
                      ),
                      const SizedBox(height: TdSpacing.related),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: FilledButton.icon(
                          key: const Key('smb-create'),
                          icon: const Icon(Icons.add_rounded),
                          label: const Text('Create share'),
                          onPressed:
                              !state.locked &&
                                  !_reviewing &&
                                  caps!.canCreate &&
                                  smbCreationDatasets(inventory).isNotEmpty
                              ? () => Navigator.of(context).push(
                                  MaterialPageRoute<void>(
                                    builder: (_) => SmbShareEditorPage(
                                      session: session!,
                                      inventory: inventory,
                                    ),
                                  ),
                                )
                              : null,
                        ),
                      ),
                      if (!caps!.canCreate)
                        const Text(
                          'Creation is unavailable: required public methods or permissions are missing.',
                        ),
                      if (smbCreationDatasets(inventory).isEmpty)
                        const Text(
                          'No eligible existing dataset roots were returned. This workspace never creates a path or dataset.',
                        ),
                      if (_error != null)
                        Text(
                          _error!,
                          style: TextStyle(
                            color: context.tdTheme.statusCritical,
                          ),
                        ),
                      const SizedBox(height: TdSpacing.component),
                      if (inventory.shares.isEmpty)
                        const Text('No SMB shares were returned.'),
                      if (inventory.shares.isNotEmpty &&
                          !inventory.shares.any(
                            (s) => '${s.name} ${s.path}'.toLowerCase().contains(
                              _search.text.toLowerCase(),
                            ),
                          ))
                        const Text('No shares match this filter.'),
                      for (final share in inventory.shares.where(
                        (s) => '${s.name} ${s.path}'.toLowerCase().contains(
                          _search.text.toLowerCase(),
                        ),
                      )) ...[
                        TdPanel(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Text(share.name, style: TdTypography.titleSmall),
                              const SizedBox(height: TdSpacing.related),
                              Text(share.path),
                              Text(
                                'Share #${share.id} · ${share.enabled ? 'Enabled' : 'Disabled'} · ${share.readonly ? 'Read-only' : 'Read/write configured'}',
                              ),
                              Text(
                                'Dataset lock: ${switch (share.locked) {
                                  true => 'Locked',
                                  false => 'Unlocked',
                                  null => 'Unknown',
                                }}',
                              ),
                              Text('Purpose: ${share.purpose}'),
                              if (share.comment.isNotEmpty) Text(share.comment),
                              if (share.blockedReason != null)
                                Text(share.blockedReason!),
                              const SizedBox(height: TdSpacing.related),
                              Wrap(
                                spacing: TdSpacing.related,
                                runSpacing: TdSpacing.related,
                                children: [
                                  OutlinedButton.icon(
                                    key: ValueKey('smb-edit-${share.id}'),
                                    icon: const Icon(Icons.edit_outlined),
                                    label: const Text('Inspect & edit'),
                                    onPressed: state.locked || _reviewing
                                        ? null
                                        : () => Navigator.of(context).push(
                                            MaterialPageRoute<void>(
                                              builder: (_) =>
                                                  SmbShareEditorPage(
                                                    session: session!,
                                                    inventory: inventory,
                                                    share: share,
                                                  ),
                                            ),
                                          ),
                                  ),
                                  OutlinedButton.icon(
                                    key: ValueKey('smb-delete-${share.id}'),
                                    icon: const Icon(
                                      Icons.delete_outline_rounded,
                                    ),
                                    label: const Text('Review deletion'),
                                    onPressed:
                                        state.locked ||
                                            _reviewing ||
                                            !share.editable ||
                                            !caps.canDelete
                                        ? null
                                        : () => _delete(
                                            session!,
                                            inventory,
                                            share,
                                          ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: TdSpacing.component),
                      ],
                    ],
                  ),
                ),
        ],
      ),
    );
  }
}

class _SmbSummaries extends StatelessWidget {
  const _SmbSummaries({required this.inventory});
  final SmbShareInventory inventory;
  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final counts = TdPanel(
        key: const Key('smb-summary-count'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('${inventory.shares.length}', style: TdTypography.titleLarge),
            const Text('Configured shares'),
            Text(
              '${inventory.shares.where((s) => !s.editable).length} inspect-only',
            ),
          ],
        ),
      );
      final readiness = TdPanel(
        key: const Key('smb-summary-service'),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(inventory.serviceState, style: TdTypography.titleSmall),
            Text(
              'Start at boot: ${inventory.serviceEnabled ? 'Enabled' : 'Disabled'}',
            ),
            Text(
              inventory.serviceState == 'RUNNING'
                  ? 'Running is not proof of client access.'
                  : inventory.serviceState == 'STOPPED'
                  ? 'Stopped. Saving a share does not start SMB.'
                  : 'Service readiness is not established.',
            ),
          ],
        ),
      );
      final scale = MediaQuery.textScalerOf(context).scale(15) / 15;
      if (constraints.maxWidth < 440 * scale) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            counts,
            const SizedBox(height: TdSpacing.related),
            readiness,
          ],
        );
      }
      return IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(child: counts),
            const SizedBox(width: TdSpacing.related),
            Expanded(child: readiness),
          ],
        ),
      );
    },
  );
}

/// Only complementary enabled/disabled counts; unknown lock and service state
/// do not change the counts into availability or health estimates.
class SmbShareEnablementChart extends StatelessWidget {
  const SmbShareEnablementChart({required this.shares, super.key});
  final List<SmbShareEntry> shares;
  @override
  Widget build(BuildContext context) {
    final enabled = shares.where((s) => s.enabled).length;
    final disabled = shares.length - enabled;
    final td = context.tdTheme;
    return TdPanel(
      title: 'Share enablement',
      description: 'All returned shares, independent of the filter. Configuration counts, not clients, capacity or health.',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final scale = MediaQuery.textScalerOf(context).scale(14) / 14;
          final beside = constraints.maxWidth - 112 - TdSpacing.component;
          final legendWidth = math.min(
            220.0,
            beside >= 125 * scale ? beside : constraints.maxWidth,
          );
          return Wrap(
            spacing: TdSpacing.component,
            runSpacing: TdSpacing.component,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                key: const Key('smb-enablement-semantics'),
                label:
                    'SMB configuration: $enabled enabled, $disabled disabled, ${shares.length} total. Not clients, capacity or health.',
                child: ExcludeSemantics(
                  child: SizedBox(
                    width: 112,
                    height: 112,
                    child: CustomPaint(
                      key: const Key('smb-enablement-ring'),
                      painter: _SmbRing(
                        enabled,
                        shares.length,
                        td.actionPrimary,
                        td.textMuted,
                        td.borderSubtle,
                      ),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: FittedBox(
                            child: Text(
                              '${shares.length}',
                              style: TdTypography.metricMedium,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: legendWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SmbLegend('Enabled · $enabled', td.actionPrimary),
                    const SizedBox(height: TdSpacing.related),
                    _SmbLegend('Disabled · $disabled', td.textMuted),
                    if (shares.isEmpty) ...[
                      const SizedBox(height: TdSpacing.related),
                      const Text(
                        'No shares returned; no percentage is inferred.',
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _SmbLegend extends StatelessWidget {
  const _SmbLegend(this.label, this.color);
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 7),
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: const SizedBox(width: 10, height: 10),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(child: Text(label)),
    ],
  );
}

class _SmbRing extends CustomPainter {
  const _SmbRing(
    this.enabled,
    this.total,
    this.active,
    this.disabled,
    this.track,
  );
  final int enabled, total;
  final Color active, disabled, track;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(5, 5, size.width - 10, size.height - 10);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10;
    canvas.drawOval(rect, paint..color = total == 0 ? track : disabled);
    if (enabled > 0 && total > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * enabled / total,
        false,
        paint..color = active,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _SmbRing oldDelegate) =>
      enabled != oldDelegate.enabled ||
      total != oldDelegate.total ||
      active != oldDelegate.active ||
      disabled != oldDelegate.disabled ||
      track != oldDelegate.track;
}

class SmbSharesOperationBanner extends ConsumerStatefulWidget {
  const SmbSharesOperationBanner({super.key});
  @override
  ConsumerState<SmbSharesOperationBanner> createState() =>
      _SmbSharesOperationBannerState();
}

class _SmbSharesOperationBannerState
    extends ConsumerState<SmbSharesOperationBanner> {
  bool _acknowledged = false;
  @override
  Widget build(BuildContext context) {
    final state = ref.watch(smbSharesControllerProvider);
    ref.watch(dashboardActiveSessionProvider);
    ref.listen(dashboardActiveSessionProvider, (_, _) {
      if (mounted) setState(() => _acknowledged = false);
    });
    if (!state.busy && state.result == null && state.recoveryMessage == null) {
      return const SizedBox.shrink();
    }
    final controller = ref.read(smbSharesControllerProvider.notifier);
    return Padding(
      padding: const EdgeInsets.only(bottom: TdSpacing.component),
      child: TdPanel(
        title: state.busy
            ? 'Submitting once'
            : switch (state.result?.outcome) {
                SmbShareOutcome.verified => 'SMB configuration verified',
                SmbShareOutcome.rejected => 'Change not submitted',
                SmbShareOutcome.unknown => 'Outcome needs verification',
                null => 'Prior completion remains unverified',
              },
        child: Material(
          type: MaterialType.transparency,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (state.server != null)
                Text('Original server: ${state.server}'),
              if (state.target != null)
                Text('Original target: ${state.target}'),
              if (state.busy) const LinearProgressIndicator(),
              if (state.result != null) Text(state.result!.message),
              if (state.recoveryMessage != null) Text(state.recoveryMessage!),
              if (controller.canAcknowledge) ...[
                CheckboxListTile(
                  key: const Key('smb-reconnect-ack'),
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: _acknowledged,
                  onChanged: (v) => setState(() => _acknowledged = v ?? false),
                  title: const Text(
                    'I independently inspected the original share and clients. The prior outcome remains unverified in this app.',
                  ),
                ),
                OutlinedButton(
                  key: const Key('smb-reconnect-release'),
                  onPressed: _acknowledged
                      ? () {
                          controller.acknowledgeAfterReconnect();
                          setState(() => _acknowledged = false);
                        }
                      : null,
                  child: const Text('Reload after reconnect'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class SmbSharesWorkspace extends StatelessWidget {
  const SmbSharesWorkspace({
    required this.children,
    this.controller,
    super.key,
  });
  final List<Widget> children;
  final ScrollController? controller;
  @override
  Widget build(BuildContext context) => SafeArea(
    child: Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1050),
        child: ListView(
          controller: controller,
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.all(TdSpacing.component),
          children: children,
        ),
      ),
    ),
  );
}
