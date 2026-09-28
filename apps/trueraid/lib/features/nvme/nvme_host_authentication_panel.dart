import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import '../dashboard/dashboard_controller.dart';
import '../connection/connection_controller.dart';
import 'nvme_setting_charts.dart';

final class NvmeHostAuthenticationSummary {
  const NvmeHostAuthenticationSummary(this.inventory, this.observedAt);
  final NvmeHostAuthenticationInventory inventory;
  final DateTime observedAt;
}

final nvmeHostAuthenticationProvider = FutureProvider.autoDispose
    .family<NvmeHostAuthenticationSummary, AuthenticatedSession>((
      ref,
      session,
    ) async {
      final repository = session.repository;
      if (!identical(session, ref.read(dashboardActiveSessionProvider)) ||
          session.endpoint == null ||
          repository is! AuthenticatedNvmeHostAuthenticationSession ||
          repository is! AuthenticatedAdminSession) {
        throw StateError('Protected NVMe authentication read is unavailable.');
      }
      final api = repository as AuthenticatedAdminSession;
      if (!api.adminCatalog.versionSupported ||
          api.adminCatalog.method('nvmet.host.query') == null) {
        throw StateError('Protected NVMe authentication read is unavailable.');
      }
      final inventory =
          await (repository as AuthenticatedNvmeHostAuthenticationSession)
              .loadNvmeHostAuthentication();
      if (!ref.mounted ||
          !identical(session, ref.read(dashboardActiveSessionProvider))) {
        throw StateError('The server connection changed.');
      }
      return NvmeHostAuthenticationSummary(inventory, DateTime.now().toUtc());
    });

class NvmeHostAuthenticationPanel extends ConsumerStatefulWidget {
  const NvmeHostAuthenticationPanel({super.key});
  @override
  ConsumerState<NvmeHostAuthenticationPanel> createState() =>
      _NvmeHostAuthenticationPanelState();
}

class _NvmeHostAuthenticationPanelState
    extends ConsumerState<NvmeHostAuthenticationPanel> {
  final _filter = TextEditingController();
  Object? _session, _shown;
  bool _loaded = false;
  @override
  void dispose() {
    _filter.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final session = ref.watch(dashboardActiveSessionProvider);
    if (!identical(session, _session)) {
      _session = session;
      _loaded = false;
      _shown = null;
      _filter.clear();
    }
    final repository = session?.repository;
    final available =
        session?.endpoint != null &&
        repository is AuthenticatedNvmeHostAuthenticationSession &&
        repository is AuthenticatedAdminSession &&
        (repository as AuthenticatedAdminSession)
            .adminCatalog
            .versionSupported &&
        (repository as AuthenticatedAdminSession).adminCatalog.method(
              'nvmet.host.query',
            ) !=
            null;
    final state = _loaded && available
        ? ref.watch(nvmeHostAuthenticationProvider(session!))
        : null;
    final current = state?.asData?.value;
    if (current != null && !identical(current, _shown)) {
      _shown = current;
      _filter.clear();
    }
    void reload() => ref.invalidate(nvmeHostAuthenticationProvider);
    return TdPanel(
      title: 'Host authentication configuration',
      description: 'On-demand protected read. Key values stay inside the SDK; only returned presence flags and public settings are displayed. Returned fields may be redacted. These counts do not prove usable credentials, initiator identity, encryption or successful authentication.',
      child: !available
          ? const Text(
              'Protected authentication inventory is unavailable on this connection; counts are unknown, not zero.',
            )
          : state == null
          ? OutlinedButton(
              key: const Key('nvme-host-auth-load'),
              onPressed: () => setState(() => _loaded = true),
              child: const Text('Load authentication metadata'),
            )
          : state.isLoading
          ? const Center(child: CircularProgressIndicator())
          : switch (state) {
              AsyncData(:final value) => Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '${value.inventory.hosts.length} returned hosts · observed ${value.observedAt.toUtc().toIso8601String()}',
                  ),
                  const SizedBox(height: 12),
                  NvmeHostAuthenticationCharts(value: value.inventory),
                  const SizedBox(height: 12),
                  const Text(
                    'Rings summarize the entire returned inventory, not the filtered list. Hash and DH group rings include saved settings even where keys are returned unset. No runtime authentication or live client session is measured.',
                  ),
                  if (value.inventory.hosts.isEmpty)
                    const Text(
                      'No hosts were returned in this complete bounded inventory.',
                    ),
                  OutlinedButton(
                    key: const Key('nvme-host-auth-reload'),
                    onPressed: reload,
                    child: const Text('Reload authentication metadata'),
                  ),
                  TextField(
                    key: const Key('nvme-host-auth-filter'),
                    controller: _filter,
                    maxLength: 120,
                    decoration: const InputDecoration(
                      labelText: 'Filter host ID or NQN',
                      border: OutlineInputBorder(),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                  for (final host in value.inventory.hosts.where(
                    (h) =>
                        _filter.text.trim().isEmpty ||
                        h.id.toString() == _filter.text.trim() ||
                        h.nqn.toLowerCase().contains(
                          _filter.text.trim().toLowerCase(),
                        ),
                  ))
                    Material(
                      type: MaterialType.transparency,
                      child: ExpansionTile(
                        key: ValueKey('nvme-host-auth-detail-${host.id}'),
                        title: Text('Host #${host.id}'),
                        subtitle: Text(host.nqn),
                        children: [
                          Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  'Host key field: ${host.hostKeyReturned ? "nonempty value returned" : "returned unset"}',
                                ),
                                Text(
                                  'Controller key field: ${host.controllerKeyReturned ? "nonempty value returned" : "returned unset"}',
                                ),
                                Text('Saved hash: ${host.hash}'),
                                Text(
                                  'Saved DH group: ${host.group ?? "returned unset"}',
                                ),
                                if (host.inconsistent)
                                  const Text(
                                    'Inconsistent returned fields: controller key or DH group without a host key. This is not a runtime diagnosis.',
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  if (value.inventory.hosts.isNotEmpty &&
                      !value.inventory.hosts.any(
                        (h) =>
                            _filter.text.trim().isEmpty ||
                            h.id.toString() == _filter.text.trim() ||
                            h.nqn.toLowerCase().contains(
                              _filter.text.trim().toLowerCase(),
                            ),
                      ))
                    const Text('No host metadata matches this local filter.'),
                ],
              ),
              _ => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Authentication metadata unavailable or incomplete; counts are unknown, not zero.',
                  ),
                  OutlinedButton(
                    key: const Key('nvme-host-auth-retry'),
                    onPressed: reload,
                    child: const Text('Retry protected read'),
                  ),
                ],
              ),
            },
    );
  }
}
