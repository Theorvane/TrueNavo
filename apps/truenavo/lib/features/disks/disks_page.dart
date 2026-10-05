import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import '../connection/connection_controller.dart';
import '../dashboard/dashboard_controller.dart';
import 'disks_controller.dart';
import 'disks_editor.dart';
import 'disks_review.dart';

String diskKind(DiskSnapshot disk) => switch (disk.type) {
  'HDD' => 'HDD',
  'SSD' => 'SSD',
  _ => 'Unknown',
};

class DisksPage extends ConsumerStatefulWidget {
  const DisksPage({super.key});
  @override
  ConsumerState<DisksPage> createState() => _DisksPageState();
}

class _DisksPageState extends ConsumerState<DisksPage> {
  final _search = TextEditingController();
  String _kind = 'ALL';
  bool _restricted = false, _reviewing = false;
  String? _error;
  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  Future<void> _edit(
    AuthenticatedSession session,
    DiskInventory inventory,
    DiskSnapshot disk,
  ) async {
    if (_reviewing) return;
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
    final inventoryWatch = ref.listenManual(disksInventoryProvider, (_, b) {
      if (b.isLoading || !identical(inventory, b.asData?.value)) expired = true;
    });
    bool current() =>
        mounted &&
        !expired &&
        identical(session, ref.read(dashboardActiveSessionProvider)) &&
        !ref.read(disksInventoryProvider).isLoading &&
        identical(inventory, ref.read(disksInventoryProvider).asData?.value);
    try {
      if (!current()) return;
      final settings = await showDialog<DiskSettings>(
        context: context,
        barrierDismissible: false,
        builder: (_) =>
            DisksEditor(session: session, inventory: inventory, disk: disk),
      );
      if (settings == null || !current()) return;
      final request = DiskRequest(
        inventory: inventory,
        disk: disk,
        settings: settings,
      );
      if (request.validationError != null) {
        setState(() => _error = request.validationError);
        return;
      }
      final api = ref.read(disksSessionProvider);
      if (api == null) return;
      final review = await api.reviewDisk(request);
      if (!mounted || !current()) return;
      if (!identical(review.request, request) ||
          review.endpoint != session.endpoint) {
        throw StateError('Mismatching disk review');
      }
      final confirmed = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => DisksReviewDialog(session: session, review: review),
      );
      if (confirmed != true || !current()) return;
      await ref
          .read(disksControllerProvider.notifier)
          .execute(
            expectedSession: session,
            review: review,
            confirmation: review.target,
          );
    } on Object {
      if (current()) {
        setState(
          () => _error = 'Disk settings could not be reviewed safely. Remote details were withheld. Reload before trying again.',
        );
      }
    } finally {
      lifecycle.dispose();
      sessionWatch.close();
      inventoryWatch.close();
      if (mounted) setState(() => _reviewing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (a, b) {
      if (!identical(a, b)) {
        setState(() {
          _search.clear();
          _kind = 'ALL';
          _restricted = false;
          _error = null;
        });
      }
    });
    final session = ref.watch(dashboardActiveSessionProvider),
        api = ref.watch(disksSessionProvider),
        state = ref.watch(disksControllerProvider);
    final controller = ref.read(disksControllerProvider.notifier),
        caps = api?.disksCapabilities;
    final available = session?.endpoint != null && caps?.supported == true;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Disks'),
        actions: [
          IconButton(
            key: const Key('disks-refresh'),
            tooltip: 'Reload passive disk inventory',
            onPressed: available && !state.locked && !_reviewing
                ? () => ref.invalidate(disksInventoryProvider)
                : null,
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SingleChildScrollView(
        key: const Key('disks-scroll'),
        padding: const EdgeInsets.all(20),
        child: Align(
          alignment: Alignment.topCenter,
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const Text('STORAGE · DEVICES', style: TdTypography.micro),
                const SizedBox(height: 8),
                const Text(
                  'Your physical disks',
                  style: TdTypography.titleLarge,
                ),
                const SizedBox(height: 8),
                const Text(
                  'Passive inventory and stored settings. No temperature probe or SMART test is requested.',
                ),
                const SizedBox(height: 20),
                if (state.result case final result?)
                  TdPanel(
                    title: 'Operation · ${result.outcome.name}',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text(result.message),
                        if (controller.canAcknowledge)
                          TextButton(
                            onPressed: controller.acknowledgeAfterReconnect,
                            child: const Text(
                              'I inspected the original server; reload',
                            ),
                          ),
                      ],
                    ),
                  ),
                if (_error != null)
                  Text(_error!, key: const Key('disks-error')),
                if (!available)
                  TdPanel(
                    title: 'Disk management unavailable',
                    child: Text(
                      caps?.blockedReason ??
                          'Connect to read a supported disk inventory.',
                    ),
                  )
                else
                  ref
                      .watch(disksInventoryProvider)
                      .when(
                        skipLoadingOnRefresh: false,
                        skipLoadingOnReload: false,
                        loading: () =>
                            const Center(child: CircularProgressIndicator()),
                        error: (_, _) => TdPanel(
                          title: 'Disk inventory unavailable',
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              const Text(
                                'Current disks could not be read safely. Missing information is not zero or healthy. No automatic retry.',
                              ),
                              TextButton(
                                key: const Key('disks-retry'),
                                onPressed: state.locked || _reviewing
                                    ? null
                                    : () => ref.invalidate(
                                        disksInventoryProvider,
                                      ),
                                child: const Text('Reload'),
                              ),
                            ],
                          ),
                        ),
                        data: (inventory) => _inventory(
                          session!,
                          inventory,
                          canUpdate:
                              caps?.canUpdate == true &&
                              !state.locked &&
                              !_reviewing,
                        ),
                      ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _inventory(
    AuthenticatedSession session,
    DiskInventory inventory, {
    required bool canUpdate,
  }) {
    final filter = _search.text.trim().toLowerCase();
    final visible = inventory.disks
        .where(
          (d) =>
              (_kind == 'ALL' || diskKind(d) == _kind) &&
              (!_restricted ||
                  d.blockedReason != null ||
                  d.powerManagementBlockedReason != null ||
                  inventory.blockedReason != null) &&
              '${d.name} ${d.identifier} ${d.serial} ${d.model ?? ''} ${d.pool ?? ''} ${d.description}'
                  .toLowerCase()
                  .contains(filter),
        )
        .toList();
    final largest = inventory.disks.fold<int>(
      0,
      (value, disk) => math.max(value, disk.sizeBytes ?? 0),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SelectableText(inventory.endpoint),
        const SizedBox(height: 16),
        _DiskSummary(inventory: inventory),
        const SizedBox(height: 20),
        if (inventory.blockedReason case final reason?)
          TdPanel(title: 'Changes restricted', child: Text(reason)),
        for (final warning in inventory.warnings)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(warning),
          ),
        TextField(
          key: const Key('disks-search'),
          controller: _search,
          decoration: const InputDecoration(
            labelText: 'Find a disk, serial or pool',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (_) => setState(() {}),
        ),
        const SizedBox(height: 12),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final type in ['ALL', 'HDD', 'SSD', 'Unknown'])
              ChoiceChip(
                key: Key('disks-type-$type'),
                label: Text(type),
                selected: _kind == type,
                onSelected: (_) => setState(() => _kind = type),
              ),
            FilterChip(
              key: const Key('disks-restricted'),
              label: const Text('Restricted settings'),
              selected: _restricted,
              onSelected: (v) => setState(() => _restricted = v),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          '${visible.length} matching / ${inventory.disks.length} recorded disks',
        ),
        const SizedBox(height: 12),
        if (visible.isEmpty)
          const TdPanel(
            title: 'No matching disks',
            child: Text(
              'Adjust the filters or explicitly reload the inventory.',
            ),
          ),
        for (final disk in visible)
          Padding(
            padding: const EdgeInsets.only(bottom: 16),
            child: TdPanel(
              title: disk.name,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${diskKind(disk)} · ${disk.bus} · ${disk.model ?? 'Model unknown'}',
                  ),
                  SelectableText(disk.identifier),
                  Text(
                    'Serial: ${disk.serial.isEmpty ? 'Unavailable' : disk.serial}',
                  ),
                  Text(
                    disk.identityVerified
                        ? 'Passive device name and serial matched'
                        : 'Identity unverified; changes blocked',
                  ),
                  Text(
                    disk.bootDisk
                        ? 'Boot-pool disk'
                        : 'Recorded pool: ${disk.pool ?? 'None — not proof of an unused disk'}',
                  ),
                  const SizedBox(height: 12),
                  Text(
                    disk.sizeBytes == null
                        ? 'Capacity unavailable'
                        : 'Reported raw capacity: ${_bytes(disk.sizeBytes!)} (${disk.sizeBytes} bytes)',
                  ),
                  if (disk.sizeBytes != null && largest > 0) ...[
                    const SizedBox(height: 6),
                    LinearProgressIndicator(
                      key: Key('disk-capacity-${disk.identifier}'),
                      value: disk.sizeBytes! / largest,
                      semanticsLabel: 'Raw capacity relative to the largest recorded disk; not used or free space',
                    ),
                    const Text(
                      'Relative raw size · not pool usable/free space',
                    ),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    'Description: ${disk.description.isEmpty ? '(empty)' : disk.description}',
                  ),
                  Text(
                    'Stored standby: ${disk.hddStandby} · Stored APM: ${disk.advancedPowerManagement}',
                  ),
                  const Text(
                    'Temperature and SMART health: not available from passive inventory',
                  ),
                  if (disk.blockedReason case final reason?) Text(reason),
                  if (disk.powerManagementBlockedReason case final reason?)
                    Text(reason),
                  const SizedBox(height: 12),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.icon(
                      key: Key('disk-edit-${disk.identifier}'),
                      onPressed:
                          canUpdate &&
                              inventory.blockedReason == null &&
                              disk.blockedReason == null
                          ? () => _edit(session, inventory, disk)
                          : null,
                      icon: const Icon(Icons.tune),
                      label: const Text('Edit settings'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        const TdPanel(
          title: 'Native scope',
          child: Text(
            'Description and admitted HDD standby/power policies only. Wipe, SED keys, replacement, partition changes and SMART execution require separate workflows. Configured ownership does not prove a disk is safe to erase.',
          ),
        ),
      ],
    );
  }
}

String _bytes(int value) {
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  var amount = value.toDouble(), index = 0;
  while (amount >= 1024 && index < units.length - 1) {
    amount /= 1024;
    index++;
  }
  return '${amount.toStringAsFixed(index == 0 ? 0 : 1)} ${units[index]}';
}

class _DiskSummary extends StatelessWidget {
  const _DiskSummary({required this.inventory});
  final DiskInventory inventory;
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final kinds = ['HDD', 'SSD', 'Unknown'];
    final counts = [
      for (final type in kinds)
        inventory.disks.where((disk) => diskKind(disk) == type).length,
    ];
    final colors = [scheme.primary, scheme.tertiary, scheme.outline];
    return TdPanel(
      title: 'Recorded disk types',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            spacing: 24,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                label:
                    '${inventory.disks.length} disks; ${counts[0]} HDD, ${counts[1]} SSD, ${counts[2]} unknown type',
                child: SizedBox(
                  width: 124,
                  height: 124,
                  child: CustomPaint(
                    key: const Key('disks-type-chart'),
                    painter: _DiskRing(counts, colors),
                    child: Center(
                      child: Text(
                        '${inventory.disks.length}',
                        style: TdTypography.titleLarge,
                      ),
                    ),
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < kinds.length; i++)
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.circle, size: 12, color: colors[i]),
                        const SizedBox(width: 8),
                        Flexible(child: Text('${kinds[i]} · ${counts[i]}')),
                      ],
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '${inventory.disks.where((d) => d.identityVerified).length} passive name/serial matches · ${inventory.disks.where((d) => d.bootDisk).length} boot disks',
          ),
          Text(
            '${inventory.disks.where((d) => d.sizeBytes == null).length} capacities unavailable',
          ),
          const Text(
            'Counts describe inventory, not drive health, redundancy or available pool space.',
          ),
        ],
      ),
    );
  }
}

class _DiskRing extends CustomPainter {
  _DiskRing(this.counts, this.colors);
  final List<int> counts;
  final List<Color> colors;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(9),
        paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 14;
    canvas.drawOval(rect, paint..color = colors.first.withValues(alpha: .12));
    final total = counts.fold<int>(0, (sum, count) => sum + count);
    if (total == 0) return;
    var start = -math.pi / 2;
    for (var i = 0; i < counts.length; i++) {
      final sweep = math.pi * 2 * counts[i] / total;
      canvas.drawArc(rect, start, sweep, false, paint..color = colors[i]);
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DiskRing oldDelegate) => true;
}
