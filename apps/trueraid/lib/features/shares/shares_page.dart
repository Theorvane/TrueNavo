import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import '../iscsi/iscsi_overview.dart';
import '../iscsi/iscsi_page.dart';
import '../management/management_page.dart';
import '../nvme/nvme_page.dart';
import '../nvme/nvme_overview.dart';
import '../nfs_shares/nfs_shares_controller.dart';
import '../nfs_shares/nfs_shares_page.dart';
import '../smb_shares/smb_shares_controller.dart';
import '../smb_shares/smb_shares_page.dart';
import 'shares_overview.dart';

class SharesPage extends ConsumerStatefulWidget {
  const SharesPage({super.key});
  @override
  ConsumerState<SharesPage> createState() => _SharesPageState();
}

class _SharesPageState extends ConsumerState<SharesPage> {
  final _filter = TextEditingController();
  ShareProtocol? _protocol;
  bool _attention = false;
  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  void _open(ShareProtocol protocol) {
    // Overview reads replace SDK-issued inventory leases. A previously visited
    // workspace must obtain a fresh lease rather than reuse its provider cache.
    if (protocol == ShareProtocol.smb) {
      ref.invalidate(smbSharesInventoryProvider);
    } else {
      ref.invalidate(nfsSharesInventoryProvider);
    }
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => protocol == ShareProtocol.smb
            ? const SmbSharesPage()
            : const NfsSharesPage(),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(dashboardActiveSessionProvider, (before, after) {
      if (!identical(before, after)) {
        _filter.clear();
        _protocol = null;
        _attention = false;
      }
    });
    final overview = ref.watch(sharesOverviewProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Shares'),
        actions: [
          IconButton(
            key: const Key('shares-overview-refresh'),
            tooltip: 'Refresh local inventories',
            onPressed: overview.isLoading
                ? null
                : () {
                    ref.invalidate(sharesOverviewProvider);
                    ref.invalidate(iscsiOverviewProvider);
                    ref.invalidate(nvmeOverviewProvider);
                  },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: overview.when(
        skipLoadingOnRefresh: false,
        skipLoadingOnReload: false,
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (_, _) => Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'File-sharing information is unavailable. Connect to the selected server or finish the pending operation, then refresh. No automatic retry.',
                ),
                const SizedBox(height: 12),
                FilledButton(
                  onPressed: () => ref.invalidate(sharesOverviewProvider),
                  child: const Text('Refresh'),
                ),
              ],
            ),
          ),
        ),
        data: _content,
      ),
    );
  }

  Widget _content(SharesOverview value) {
    // The file-share read releases its operation lock before this separate
    // block-storage read starts. The two inventories are never atomic.
    final block = ref.watch(iscsiOverviewProvider);
    final nvme = ref.watch(nvmeOverviewProvider);
    final sources = value.protocols;
    final visible = value.shares
        .where(
          (s) =>
              (_protocol == null || s.protocol == _protocol) &&
              s.matches(_filter.text) &&
              (!_attention ||
                  sources
                      .firstWhere((p) => p.protocol == s.protocol)
                      .needsAttention(s)),
        )
        .toList();
    return SingleChildScrollView(
      key: const Key('shares-overview-scroll'),
      padding: const EdgeInsets.all(16),
      child: Align(
        alignment: Alignment.topCenter,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1100),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const Text('SHARES & SERVICES', style: TdTypography.micro),
              const SizedBox(height: 8),
              const Text(
                'File and block sharing at a glance',
                style: TdTypography.titleLarge,
              ),
              const SizedBox(height: 12),
              Text(value.endpoint),
              Text(
                'Read ${value.loadedSources} of 2 file-sharing inventories · ${value.observedAt.toIso8601String()} (client UTC)',
              ),
              const SizedBox(height: 12),
              const Text(
                'Configuration and last-read service state only. Enabled does not prove client access, network reachability or valid permissions. File inventories are sequential; block inventories are independent. These are not an atomic server snapshot.',
              ),
              const SizedBox(height: 20),
              _ShareEnablement(value),
              const SizedBox(height: 16),
              LayoutBuilder(
                builder: (context, constraints) => Wrap(
                  spacing: 16,
                  runSpacing: 16,
                  children: [
                    for (final source in sources)
                      SizedBox(
                        width: constraints.maxWidth >= 800
                            ? (constraints.maxWidth - 16) / 2
                            : constraints.maxWidth,
                        child: _ProtocolCard(
                          source: source,
                          open: () => _open(source.protocol),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              _BlockStorageCard(
                key: ValueKey(value),
                state: block,
                open: () {
                  ref.invalidate(iscsiOverviewProvider);
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const IscsiPage()),
                  );
                },
              ),
              const SizedBox(height: 16),
              _NvmeStorageCard(
                state: nvme,
                open: () {
                  ref.invalidate(nvmeOverviewProvider);
                  Navigator.of(context).push(
                    MaterialPageRoute<void>(builder: (_) => const NvmePage()),
                  );
                },
              ),
              const SizedBox(height: 16),
              OutlinedButton.icon(
                key: const Key('shares-service-controls'),
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const ManagementPage(),
                  ),
                ),
                icon: const Icon(Icons.settings_outlined),
                label: const Text('Open reviewed service controls'),
              ),
              const SizedBox(height: 24),
              TdPanel(
                title: 'Share explorer',
                description: 'Search applies to the list below; charts always describe all loaded shares.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    TextField(
                      key: const Key('shares-overview-filter'),
                      controller: _filter,
                      decoration: const InputDecoration(
                        labelText: 'Find name, path or dataset',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        ChoiceChip(
                          label: const Text('All'),
                          selected: _protocol == null,
                          onSelected: (_) => setState(() => _protocol = null),
                        ),
                        for (final p in ShareProtocol.values)
                          ChoiceChip(
                            label: Text(p.label),
                            selected: _protocol == p,
                            onSelected: (_) => setState(() => _protocol = p),
                          ),
                      ],
                    ),
                    Material(
                      type: MaterialType.transparency,
                      child: CheckboxListTile(
                        contentPadding: EdgeInsets.zero,
                        title: const Text(
                          'Service, lock or editing restrictions only',
                        ),
                        value: _attention,
                        onChanged: (v) =>
                            setState(() => _attention = v == true),
                      ),
                    ),
                    Text('${visible.length} matching shares'),
                    if (visible.isEmpty)
                      const Text(
                        'No matches among successfully read inventories.',
                      ),
                    for (final entry in visible)
                      Padding(
                        padding: const EdgeInsets.only(top: 12),
                        child: Card(
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  entry.name,
                                  style: TdTypography.titleSmall,
                                ),
                                Text(
                                  '${entry.protocol.label} #${entry.id} · ${entry.enabled ? 'Enabled' : 'Disabled'} · ${entry.readOnly ? 'Read-only' : 'Read-write'}',
                                ),
                                Text(entry.path),
                                Text(
                                  'Exact dataset-root match: ${entry.dataset ?? 'not established'}',
                                ),
                                if (entry.protocol == ShareProtocol.smb)
                                  Text(
                                    'Reported SMB lock: ${switch (entry.locked) {
                                      true => 'locked',
                                      false => 'not locked',
                                      null => 'unknown',
                                    }}',
                                  ),
                                if (entry.restriction != null)
                                  Text(
                                    'Native editing restriction: ${entry.restriction}',
                                  ),
                                TextButton(
                                  key: Key('shares-inspect-${entry.identity}'),
                                  onPressed: () => _open(entry.protocol),
                                  child: const Text('Inspect in workspace'),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              TdPanel(
                title: 'Exact shared paths',
                description: 'All loaded shares, including disabled entries. Equal path strings are not proof of filesystem identity; aliases, descendants and block-storage consumers are not resolved.',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (value.paths.isEmpty)
                      const Text(
                        'No paths from successfully read inventories.',
                      ),
                    for (final group in value.paths.entries)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Text(group.key, style: TdTypography.label),
                            Text(
                              '${group.value.length} share records · ${group.value.map((s) => s.protocol.label).toSet().join(' + ')}',
                            ),
                            Text(
                              '${group.value.where((s) => s.enabled).length} enabled · ${group.value.where((s) => s.readOnly).length} configured read-only',
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text(
                'Fibre Channel and WebShare are not included yet. This screen never starts services, changes shares or probes clients. Refresh manually after making changes elsewhere.',
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _NvmeStorageCard extends StatelessWidget {
  const _NvmeStorageCard({required this.state, required this.open});

  final AsyncValue<NvmeOverview> state;
  final VoidCallback open;

  @override
  Widget build(BuildContext context) => TdPanel(
    title: 'NVMe-oF block storage',
    description: 'Separate saved topology read. Associations and configured enablement do not prove a running listener or client access.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        switch (state) {
          AsyncData(:final value) => _NvmeStorageCounts(value),
          AsyncError() => const Text(
            'NVMe-oF inventory unavailable. Its counts are unknown, not zero.',
          ),
          _ => const LinearProgressIndicator(),
        },
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('shares-open-nvme'),
          onPressed: open,
          icon: const Icon(Icons.open_in_new),
          label: const Text('Inspect NVMe-oF topology'),
        ),
      ],
    ),
  );
}

class _NvmeStorageCounts extends StatelessWidget {
  const _NvmeStorageCounts(this.value);
  final NvmeOverview value;

  @override
  Widget build(BuildContext context) {
    final enabledNamespaces = value.namespaces.where((n) => n.enabled).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${value.subsystems.length} subsystems · ${value.ports.length} ports · ${value.namespaces.length} namespaces · ${value.portMappings.length} port associations',
        ),
        const SizedBox(height: 8),
        Text(
          '${value.exposedSubsystems} of ${value.subsystems.length} subsystems have a returned port association',
        ),
        Semantics(
          label:
              '${value.exposedSubsystems} of ${value.subsystems.length} returned NVMe-oF subsystems have a port association',
          child: LinearProgressIndicator(
            key: const Key('shares-nvme-port-associated-ratio'),
            value: value.subsystems.isEmpty
                ? 0
                : value.exposedSubsystems / value.subsystems.length,
            minHeight: 12,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          '$enabledNamespaces of ${value.namespaces.length} namespaces configured enabled',
        ),
        Semantics(
          label:
              '$enabledNamespaces of ${value.namespaces.length} returned NVMe-oF namespaces are configured enabled',
          child: LinearProgressIndicator(
            key: const Key('shares-nvme-namespace-enabled-ratio'),
            value: value.namespaces.isEmpty
                ? 0
                : enabledNamespaces / value.namespaces.length,
            minHeight: 12,
          ),
        ),
        if (value.unresolvedReferences > 0) ...[
          const SizedBox(height: 8),
          Text(
            '${value.unresolvedReferences} namespace or port association references are unresolved. Inspect the NVMe-oF workspace.',
          ),
        ],
      ],
    );
  }
}

class _BlockStorageCard extends StatefulWidget {
  const _BlockStorageCard({required this.state, required this.open, super.key});

  final AsyncValue<IscsiOverview> state;
  final VoidCallback open;

  @override
  State<_BlockStorageCard> createState() => _BlockStorageCardState();
}

class _BlockStorageCardState extends State<_BlockStorageCard> {
  final _filter = TextEditingController();

  @override
  void didUpdateWidget(covariant _BlockStorageCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.state.asData?.value, widget.state.asData?.value)) {
      _filter.clear();
    }
  }

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => TdPanel(
    title: 'iSCSI block storage',
    description: 'Separate configuration read. A target or LUN mapping does not prove service availability or client access.',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        switch (widget.state) {
          AsyncData(:final value) => _BlockStorageCounts(
            value,
            filter: _filter,
            onFilterChanged: () => setState(() {}),
          ),
          AsyncError() => const Text(
            'iSCSI inventory unavailable. Its counts are unknown, not zero.',
          ),
          _ => const LinearProgressIndicator(),
        },
        const SizedBox(height: 12),
        FilledButton.icon(
          key: const Key('shares-open-iscsi'),
          onPressed: widget.open,
          icon: const Icon(Icons.open_in_new),
          label: const Text('Open iSCSI workspace'),
        ),
      ],
    ),
  );
}

class _BlockStorageCounts extends StatelessWidget {
  const _BlockStorageCounts(
    this.value, {
    required this.filter,
    required this.onFilterChanged,
  });

  final IscsiOverview value;
  final TextEditingController filter;
  final VoidCallback onFilterChanged;

  @override
  Widget build(BuildContext context) {
    final mapped = value.mappings.map((mapping) => mapping.extentId).toSet();
    final mappedCount = value.extents
        .where((e) => mapped.contains(e.id))
        .length;
    final unresolved = value.mappings
        .where(
          (mapping) =>
              value.targetById(mapping.targetId) == null ||
              value.extentById(mapping.extentId) == null,
        )
        .length;
    final query = filter.text.trim().toLowerCase();
    final visible = value.targets.where((target) {
      if (query.isEmpty ||
          target.name.toLowerCase().contains(query) ||
          target.id.toString() == query) {
        return true;
      }
      return value.mappings.any((mapping) {
        if (mapping.targetId != target.id) return false;
        final extent = value.extentById(mapping.extentId);
        return mapping.extentId.toString() == query ||
            mapping.lun.toString() == query ||
            'lun ${mapping.lun}' == query ||
            (extent?.name.toLowerCase().contains(query) ?? false);
      });
    }).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${value.targets.length} targets · ${value.extents.length} extents · ${value.mappings.length} LUN mappings',
        ),
        const SizedBox(height: 8),
        Text('$mappedCount of ${value.extents.length} extents mapped'),
        const SizedBox(height: 8),
        Semantics(
          label:
              '$mappedCount of ${value.extents.length} returned iSCSI extents have a LUN mapping',
          child: LinearProgressIndicator(
            key: const Key('shares-iscsi-mapped-ratio'),
            value: value.extents.isEmpty
                ? 0
                : mappedCount / value.extents.length,
            minHeight: 12,
          ),
        ),
        if (unresolved > 0) ...[
          const SizedBox(height: 8),
          Text(
            '$unresolved mappings refer to a target or extent absent from this read. Inspect the iSCSI workspace.',
          ),
        ],
        const SizedBox(height: 16),
        TextField(
          key: const Key('shares-iscsi-filter'),
          controller: filter,
          decoration: const InputDecoration(
            labelText: 'Find target, extent or LUN',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (_) => onFilterChanged(),
        ),
        const SizedBox(height: 8),
        Text('${visible.length} matching targets'),
        if (visible.isEmpty)
          const Text('No target matches in the returned iSCSI inventory.'),
        if (visible.length > 20)
          const Text(
            'Showing the first 20 targets. Narrow the search to inspect others.',
          ),
        for (final target in visible.take(20))
          _BlockTargetTile(
            target: target,
            mappings:
                value.mappings
                    .where((mapping) => mapping.targetId == target.id)
                    .toList()
                  ..sort((a, b) => a.lun.compareTo(b.lun)),
            overview: value,
          ),
      ],
    );
  }
}

class _BlockTargetTile extends StatelessWidget {
  const _BlockTargetTile({
    required this.target,
    required this.mappings,
    required this.overview,
  });

  final IscsiTarget target;
  final List<IscsiMapping> mappings;
  final IscsiOverview overview;

  @override
  Widget build(BuildContext context) => Material(
    type: MaterialType.transparency,
    child: ExpansionTile(
      key: Key('shares-iscsi-target-${target.id}'),
      title: Text(target.name),
      subtitle: Text(
        'Target #${target.id} · ${target.mode} · ${mappings.length} LUN mappings',
      ),
      children: [
        if (mappings.isEmpty)
          const ListTile(title: Text('No returned LUN mapping.')),
        for (final mapping in mappings)
          ListTile(
            title: Text(
              'LUN ${mapping.lun} · ${overview.extentById(mapping.extentId)?.name ?? 'Extent not returned'}',
            ),
            subtitle: Text(
              'Mapping #${mapping.id} · Extent #${mapping.extentId}',
            ),
          ),
      ],
    ),
  );
}

class _ProtocolCard extends StatelessWidget {
  const _ProtocolCard({required this.source, required this.open});
  final ShareProtocolOverview source;
  final VoidCallback open;
  @override
  Widget build(BuildContext context) => TdPanel(
    title: '${source.protocol.label} service',
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (!source.loaded)
          Text(source.unavailable!)
        else ...[
          Text(
            'Reported state: ${source.serviceState}',
            style: TdTypography.titleSmall,
          ),
          Text(
            'Start automatically: ${source.autostart == true ? 'On' : 'Off'}',
          ),
          const SizedBox(height: 8),
          Text('${source.shares.length} shares · ${source.enabled} enabled'),
          if (source.enabled > 0 && source.serviceState != 'RUNNING')
            const Text(
              'Enabled shares exist, but this service was not reported running. Inspect its service settings.',
            ),
          if (source.restriction != null)
            Text('Native configuration restriction: ${source.restriction}'),
          const SizedBox(height: 12),
          Semantics(
            label:
                '${source.protocol.label}: ${source.readOnly} configured read-only; ${source.shares.length - source.readOnly} configured read-write',
            child: LinearProgressIndicator(
              minHeight: 12,
              value: source.shares.isEmpty
                  ? 0
                  : source.readOnly / source.shares.length,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Read-only ${source.readOnly} / Read-write ${source.shares.length - source.readOnly} · includes disabled shares',
          ),
        ],
        const SizedBox(height: 12),
        FilledButton.icon(
          key: Key('shares-open-${source.protocol.name}'),
          onPressed: open,
          icon: const Icon(Icons.open_in_new),
          label: Text('Open ${source.protocol.label} workspace'),
        ),
      ],
    ),
  );
}

class _ShareEnablement extends StatelessWidget {
  const _ShareEnablement(this.value);
  final SharesOverview value;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TdPanel(
      title: 'Configured share enablement',
      description: 'Only successfully read SMB and NFS inventories contribute to these counts.',
      child: Wrap(
        spacing: 24,
        runSpacing: 16,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Semantics(
            label:
                '${value.shares.length} loaded shares: ${value.enabled} enabled, ${value.disabled} disabled. Not client access.',
            child: ExcludeSemantics(
              child: SizedBox(
                width: 140,
                height: 140,
                child: CustomPaint(
                  key: const Key('shares-enablement-chart'),
                  painter: _ShareRing(
                    value.enabled,
                    value.shares.length,
                    colors.primary,
                    colors.tertiary,
                    colors.outlineVariant,
                  ),
                  child: Center(
                    child: Text(
                      '${value.shares.length}',
                      style: TdTypography.metricMedium,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '● Enabled · ${value.enabled}',
                style: TextStyle(color: colors.primary),
              ),
              Text(
                '● Disabled · ${value.disabled}',
                style: TextStyle(color: colors.tertiary),
              ),
              Text('${value.paths.length} distinct configured paths'),
            ],
          ),
        ],
      ),
    );
  }
}

class _ShareRing extends CustomPainter {
  _ShareRing(this.enabled, this.total, this.active, this.disabled, this.empty);
  final int enabled, total;
  final Color active, disabled, empty;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 15;
    final rect = (Offset.zero & size).deflate(10);
    canvas.drawOval(rect, paint..color = total == 0 ? empty : disabled);
    if (total > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        enabled / total * math.pi * 2,
        false,
        paint..color = active,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ShareRing old) =>
      old.enabled != enabled ||
      old.total != total ||
      old.active != active ||
      old.disabled != disabled ||
      old.empty != empty;
}
