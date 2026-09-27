import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import 'nvme_overview.dart';
import 'nvme_subsystem_create_editor.dart';

class NvmePage extends ConsumerStatefulWidget {
  const NvmePage({super.key});

  @override
  ConsumerState<NvmePage> createState() => _NvmePageState();
}

class _NvmePageState extends ConsumerState<NvmePage> {
  final _filter = TextEditingController();
  NvmeOverview? _shown;

  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(nvmeOverviewProvider);
    final current = state.asData?.value;
    if (current != null && !identical(current, _shown)) {
      _shown = current;
      _filter.clear();
    }
    return Scaffold(
      appBar: AppBar(
        title: const Text('NVMe-oF topology'),
        actions: [
          IconButton(
            key: const Key('nvme-refresh'),
            tooltip: 'Reload NVMe-oF inventory',
            onPressed: state.isLoading
                ? null
                : () => ref.invalidate(nvmeOverviewProvider),
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
                  const SizedBox(height: 20),
                  const NvmeSubsystemCreateEditor(),
                ],
              ),
            ),
          ),
        ),
      ),
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
          title: 'Subsystem explorer',
          description: 'Search only filters this list; charts always include all returned records.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('nvme-filter'),
                controller: filter,
                decoration: const InputDecoration(
                  labelText: 'Find subsystem or namespace ID',
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
