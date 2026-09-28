import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import 'nvme_global_panel.dart';
import 'nvme_host_overview.dart';
import 'nvme_host_access_revoke_editor.dart';
import 'nvme_host_access_grant_editor.dart';
import 'nvme_host_delete_editor.dart';
import 'nvme_port_access_revoke_editor.dart';
import 'nvme_port_access_grant_editor.dart';
import 'nvme_port_delete_editor.dart';
import 'nvme_port_disable_editor.dart';
import 'nvme_port_enable_editor.dart';
import 'nvme_port_pi_editor.dart';
import 'nvme_port_queue_editor.dart';
import 'nvme_port_inline_editor.dart';
import 'nvme_port_create_editor.dart';
import 'nvme_namespace_delete_editor.dart';
import 'nvme_overview.dart';
import 'nvme_setting_charts.dart';
import 'nvme_subsystem_create_editor.dart';
import 'nvme_subsystem_ana_editor.dart';
import 'nvme_subsystem_pi_editor.dart';
import 'nvme_subsystem_qid_editor.dart';
import 'nvme_subsystem_oui_editor.dart';
import 'nvme_subsystem_delete_editor.dart';
import 'nvme_subsystem_restrict_editor.dart';
import 'nvme_subsystem_rename_editor.dart';

class NvmePage extends ConsumerStatefulWidget {
  const NvmePage({super.key});

  @override
  ConsumerState<NvmePage> createState() => _NvmePageState();
}

class _NvmePageState extends ConsumerState<NvmePage> {
  final _filter = TextEditingController();
  final _hostFilter = TextEditingController();
  NvmeOverview? _shown;
  Object? _shownSession;
  bool _showHosts = false;

  @override
  void dispose() {
    _filter.dispose();
    _hostFilter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(nvmeOverviewProvider);
    final session = ref.watch(dashboardActiveSessionProvider);
    if (!identical(session, _shownSession)) {
      _shownSession = session;
      _shown = null;
      _showHosts = false;
      _hostFilter.clear();
    }
    final current = state.asData?.value;
    if (current != null && !identical(current, _shown)) {
      _shown = current;
      _filter.clear();
      _hostFilter.clear();
      _showHosts = false;
    }
    final hostState = _showHosts && current != null
        ? ref.watch(nvmeHostOverviewProvider)
        : null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('NVMe-oF topology'),
        actions: [
          IconButton(
            key: const Key('nvme-refresh'),
            tooltip: 'Reload NVMe-oF inventory',
            onPressed: state.isLoading
                ? null
                : () {
                    setState(() => _showHosts = false);
                    ref.invalidate(nvmeOverviewProvider);
                    ref.invalidate(nvmeGlobalProvider);
                  },
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: SafeArea(
        child: Center(
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 1100),
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(TdSpacing.pageMobile),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Text(
                    'SHARES · BLOCK STORAGE',
                    style: TdTypography.micro,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'NVMe-over-Fabrics',
                    style: TdTypography.titleLarge,
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Saved configuration from four sequential reads. No host keys, device paths, serials or client sessions are loaded. Mappings do not prove reachability or current access.',
                  ),
                  const SizedBox(height: 20),
                  const NvmeGlobalPanel(),
                  const SizedBox(height: 20),
                  switch (state) {
                    AsyncData(:final value) => _Content(
                      value: value,
                      filter: _filter,
                      onChanged: () => setState(() {}),
                    ),
                    AsyncError() => const TdPanel(
                      title: 'NVMe-oF unavailable',
                      child: Text(
                        'The server did not return a complete, supported NVMe-oF inventory. Counts are unknown, not zero.',
                      ),
                    ),
                    _ => const Center(child: CircularProgressIndicator()),
                  },
                  if (current != null) ...[
                    const SizedBox(height: 20),
                    _HostAccessPanel(
                      topology: current,
                      hostState: hostState,
                      filter: _hostFilter,
                      onChanged: () => setState(() {}),
                      onLoad: () => setState(() => _showHosts = true),
                      onReload: () => ref.invalidate(nvmeHostOverviewProvider),
                    ),
                  ],
                  const SizedBox(height: 20),
                  const NvmeSubsystemCreateEditor(),
                  const SizedBox(height: 20),
                  const NvmeSubsystemDeleteEditor(),
                  const SizedBox(height: 20),
                  const NvmeSubsystemRestrictEditor(),
                  const SizedBox(height: 20),
                  const NvmeSubsystemRenameEditor(),
                  const SizedBox(height: 20),
                  const NvmeSubsystemAnaEditor(),
                  const SizedBox(height: 20),
                  const NvmeSubsystemPiEditor(),
                  const SizedBox(height: 20),
                  const NvmeSubsystemQidEditor(),
                  const SizedBox(height: 20),
                  const NvmeSubsystemOuiEditor(),
                  const SizedBox(height: 20),
                  const NvmeHostAccessRevokeEditor(),
                  const SizedBox(height: 20),
                  const NvmeHostAccessGrantEditor(),
                  const SizedBox(height: 20),
                  const NvmeHostDeleteEditor(),
                  const SizedBox(height: 20),
                  const NvmePortAccessRevokeEditor(),
                  const SizedBox(height: 20),
                  const NvmePortAccessGrantEditor(),
                  const SizedBox(height: 20),
                  const NvmePortDeleteEditor(),
                  const SizedBox(height: 20),
                  const NvmePortDisableEditor(),
                  const SizedBox(height: 20),
                  const NvmePortEnableEditor(),
                  const SizedBox(height: 20),
                  const NvmePortPiEditor(),
                  const SizedBox(height: 20),
                  const NvmePortQueueEditor(),
                  const SizedBox(height: 20),
                  const NvmePortInlineEditor(),
                  const SizedBox(height: 20),
                  const NvmePortCreateEditor(),
                  const SizedBox(height: 20),
                  const NvmeNamespaceDeleteEditor(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _HostAccessPanel extends StatelessWidget {
  const _HostAccessPanel({
    required this.topology,
    required this.hostState,
    required this.filter,
    required this.onChanged,
    required this.onLoad,
    required this.onReload,
  });

  final NvmeOverview topology;
  final AsyncValue<NvmeHostOverview>? hostState;
  final TextEditingController filter;
  final VoidCallback onChanged, onLoad, onReload;

  @override
  Widget build(BuildContext context) => TdPanel(
    title: 'Host access configuration',
    description: 'Load host identities only when needed. DH-CHAP keys are never requested. Saved associations do not prove a current session or client reachability.',
    child: hostState == null
        ? OutlinedButton(
            key: const Key('nvme-host-load'),
            onPressed: onLoad,
            child: const Text('Load host access configuration'),
          )
        : switch (hostState!) {
            AsyncData(:final value) => _HostAccessContent(
              topology: topology,
              value: value,
              filter: filter,
              onChanged: onChanged,
              onReload: onReload,
            ),
            AsyncError() => Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  'Host access inventory unavailable; counts are unknown, not zero.',
                ),
                OutlinedButton(
                  onPressed: onReload,
                  child: const Text('Retry host access read'),
                ),
              ],
            ),
            _ => const CircularProgressIndicator(),
          },
  );
}

class _HostAccessContent extends StatelessWidget {
  const _HostAccessContent({
    required this.topology,
    required this.value,
    required this.filter,
    required this.onChanged,
    required this.onReload,
  });

  final NvmeOverview topology;
  final NvmeHostOverview value;
  final TextEditingController filter;
  final VoidCallback onChanged, onReload;

  @override
  Widget build(BuildContext context) {
    final query = filter.text.trim().toLowerCase();
    final visible = value.hosts
        .where(
          (host) =>
              query.isEmpty ||
              host.nqn.toLowerCase().contains(query) ||
              host.id.toString() == query,
        )
        .toList();
    final associatedHostIds = value.mappings.map((row) => row.hostId).toSet();
    final associatedReturnedHosts = value.hosts
        .where((host) => associatedHostIds.contains(host.id))
        .length;
    final unresolved = value.unresolvedReferences(
      topology.subsystems.map((row) => row.id).toSet(),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '${value.hosts.length} hosts · ${value.mappings.length} host–subsystem associations',
        ),
        const SizedBox(height: 12),
        Text(
          '$associatedReturnedHosts of ${value.hosts.length} hosts have a returned association',
        ),
        LinearProgressIndicator(
          key: const Key('nvme-host-association-ratio'),
          value: value.hosts.isEmpty
              ? 0
              : associatedReturnedHosts / value.hosts.length,
          minHeight: 10,
        ),
        if (unresolved > 0) ...[
          const SizedBox(height: 12),
          Text(
            '$unresolved host associations reference a host or subsystem not returned by these separate reads.',
          ),
        ],
        const SizedBox(height: 12),
        TextField(
          key: const Key('nvme-host-filter'),
          controller: filter,
          decoration: const InputDecoration(
            labelText: 'Find host NQN or exact ID',
            prefixIcon: Icon(Icons.search),
          ),
          onChanged: (_) => onChanged(),
        ),
        Text('${visible.length} matching hosts'),
        if (visible.length > 20)
          const Text(
            'Showing the first 20. Narrow the search to inspect others.',
          ),
        for (final host in visible.take(20))
          Material(
            type: MaterialType.transparency,
            child: ExpansionTile(
              key: Key('nvme-host-${host.id}'),
              title: Text(host.nqn),
              subtitle: Text(
                'Host #${host.id} · ${value.mappings.where((row) => row.hostId == host.id).length} returned associations',
              ),
              children: [
                for (final mapping in value.mappings.where(
                  (row) => row.hostId == host.id,
                ))
                  ListTile(
                    title: Text(
                      topology.subsystems
                              .where((row) => row.id == mapping.subsystemId)
                              .map((row) => row.name)
                              .firstOrNull ??
                          'Subsystem #${mapping.subsystemId} not returned',
                    ),
                    subtitle: Text(
                      'Association #${mapping.id} · subsystem #${mapping.subsystemId}',
                    ),
                  ),
              ],
            ),
          ),
        OutlinedButton(
          key: const Key('nvme-host-refresh'),
          onPressed: onReload,
          child: const Text('Reload host access'),
        ),
      ],
    );
  }
}

class _Content extends StatelessWidget {
  const _Content({
    required this.value,
    required this.filter,
    required this.onChanged,
  });
  final NvmeOverview value;
  final TextEditingController filter;
  final VoidCallback onChanged;

  @override
  Widget build(BuildContext context) {
    final query = filter.text.trim().toLowerCase();
    final visible = value.subsystems.where((subsystem) {
      if (query.isEmpty ||
          subsystem.name.toLowerCase().contains(query) ||
          (subsystem.subnqn?.toLowerCase().contains(query) ?? false) ||
          (subsystem.ieeeOui?.toLowerCase().contains(query) ?? false) ||
          subsystem.id.toString() == query) {
        return true;
      }
      return value.namespaces.any(
        (namespace) =>
            namespace.subsystemId == subsystem.id &&
            (namespace.id.toString() == query ||
                namespace.nsid?.toString() == query),
      );
    }).toList();
    final enabledNamespaces = value.namespaces.where((n) => n.enabled).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TdPanel(
          title: 'Configuration summary',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${value.subsystems.length} subsystems · ${value.ports.length} ports · ${value.namespaces.length} namespaces · ${value.portMappings.length} port associations',
              ),
              const SizedBox(height: 12),
              Text(
                '${value.exposedSubsystems} of ${value.subsystems.length} subsystems have a returned port association',
              ),
              LinearProgressIndicator(
                key: const Key('nvme-port-association-ratio'),
                value: value.subsystems.isEmpty
                    ? 0
                    : value.exposedSubsystems / value.subsystems.length,
                minHeight: 10,
              ),
              const SizedBox(height: 12),
              Text(
                '$enabledNamespaces of ${value.namespaces.length} namespaces configured enabled',
              ),
              LinearProgressIndicator(
                key: const Key('nvme-namespace-enabled-ratio'),
                value: value.namespaces.isEmpty
                    ? 0
                    : enabledNamespaces / value.namespaces.length,
                minHeight: 10,
              ),
              const SizedBox(height: 12),
              NvmeSettingCharts(value: value, keyPrefix: 'nvme'),
              if (value.unresolvedReferences > 0) ...[
                const SizedBox(height: 12),
                Text(
                  '${value.unresolvedReferences} namespace or port association references are unresolved in these reads. Reload and inspect.',
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 16),
        TdPanel(
          title: 'Port inventory',
          description: 'Saved configuration only. A disabled port or missing association does not prove that no client was recently connected.',
          child: value.ports.isEmpty
              ? const Text('No ports returned.')
              : Column(
                  children: [
                    for (final port in value.ports)
                      ListTile(
                        key: Key('nvme-port-${port.id}'),
                        title: Text('Port #${port.id} · ${port.transport}'),
                        subtitle: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '${port.enabled ? 'Configured enabled' : 'Disabled'} · ${value.portMappings.where((m) => m.portId == port.id).length} subsystem associations',
                            ),
                            Text(
                              'Inline data size: ${!port.inlineDataSizeReported
                                  ? 'Not returned'
                                  : port.inlineDataSize == null
                                  ? 'Server default'
                                  : '${port.inlineDataSize} bytes'}',
                              key: Key('nvme-port-inline-${port.id}'),
                            ),
                            Text(
                              'Maximum queue size: ${!port.maxQueueSizeReported
                                  ? 'Not returned'
                                  : port.maxQueueSize == null
                                  ? 'Server default'
                                  : '${port.maxQueueSize} entries'}',
                              key: Key('nvme-port-queue-${port.id}'),
                            ),
                            Text(
                              'Port PI: ${!port.piReported
                                  ? 'Not returned'
                                  : port.piEnable == null
                                  ? 'Server default'
                                  : port.piEnable!
                                  ? 'Configured on'
                                  : 'Configured off'}',
                              key: Key('nvme-port-pi-${port.id}'),
                            ),
                          ],
                        ),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        TdPanel(
          title: 'Subsystem explorer',
          description: 'Search only filters this list; charts always include all returned records.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('nvme-filter'),
                controller: filter,
                decoration: const InputDecoration(
                  labelText: 'Find subsystem, NQN, IEEE OUI or namespace ID',
                  prefixIcon: Icon(Icons.search),
                ),
                onChanged: (_) => onChanged(),
              ),
              const SizedBox(height: 8),
              Text('${visible.length} matching subsystems'),
              if (visible.isEmpty)
                const Text('No matching subsystem in the returned inventory.'),
              if (visible.length > 20)
                const Text(
                  'Showing the first 20. Narrow the search to inspect others.',
                ),
              for (final subsystem in visible.take(20))
                Material(
                  type: MaterialType.transparency,
                  child: ExpansionTile(
                    key: Key('nvme-subsystem-${subsystem.id}'),
                    title: Text(subsystem.name),
                    subtitle: Text(
                      'Subsystem #${subsystem.id} · ${subsystem.allowAnyHost ? 'Any host allowed' : 'Host access restricted (host list not loaded)'}',
                    ),
                    children: [
                      ListTile(
                        title: const Text('Subsystem NQN'),
                        subtitle: Text(
                          subsystem.subnqn ?? 'Not returned by this server',
                          key: Key('nvme-subsystem-nqn-${subsystem.id}'),
                        ),
                      ),
                      ListTile(
                        title: const Text('ANA setting'),
                        subtitle: Text(
                          !subsystem.anaReported
                              ? 'Not returned by this server'
                              : switch (subsystem.ana) {
                                  true => 'Configured on for this subsystem',
                                  false => 'Configured off for this subsystem',
                                  null => 'Inherits global setting',
                                },
                        ),
                      ),
                      ListTile(
                        title: const Text('Protection information (PI)'),
                        subtitle: Text(
                          !subsystem.piReported
                              ? 'Not returned by this server'
                              : switch (subsystem.piEnable) {
                                  true => 'Configured on',
                                  false => 'Configured off',
                                  null => 'Server default',
                                },
                        ),
                      ),
                      ListTile(
                        title: const Text('Maximum queue IDs'),
                        subtitle: Text(
                          !subsystem.qidReported
                              ? 'Not returned by this server'
                              : subsystem.qidMax?.toString() ??
                                    'Server default',
                        ),
                      ),
                      ListTile(
                        title: const Text('IEEE OUI'),
                        subtitle: Text(
                          !subsystem.ieeeOuiReported
                              ? 'Not returned by this server'
                              : subsystem.ieeeOui ?? 'Server default',
                          key: Key('nvme-subsystem-oui-${subsystem.id}'),
                        ),
                      ),
                      for (final namespace in value.namespaces.where(
                        (n) => n.subsystemId == subsystem.id,
                      ))
                        ListTile(
                          title: Text(
                            'Namespace ${namespace.nsid ?? 'unassigned'} · ${namespace.deviceType}',
                          ),
                          subtitle: Text(
                            '#${namespace.id} · ${namespace.enabled ? 'Configured enabled' : 'Disabled'} · ${switch (namespace.locked) {
                              true => 'Locked',
                              false => 'Unlocked',
                              null => 'Lock state unknown',
                            }}',
                          ),
                        ),
                      for (final mapping in value.portMappings.where(
                        (m) => m.subsystemId == subsystem.id,
                      ))
                        ListTile(
                          title: Text(
                            'Port #${mapping.portId} · ${value.portById(mapping.portId)?.transport ?? 'Not returned'}',
                          ),
                          subtitle: Text('Association #${mapping.id}'),
                        ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}
