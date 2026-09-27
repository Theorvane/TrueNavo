import 'dart:convert';

import 'package:truenas_api/truenas_api.dart';

import 'nvme_host_overview.dart';
import 'nvme_overview.dart';

/// The public, bounded projection used for guarded NVMe-oF changes. This does
/// not prove an atomic view because middleware queries are sequential.
final class NvmeMutationSnapshot {
  const NvmeMutationSnapshot(this.topology, this.hosts);

  final NvmeOverview topology;
  final NvmeHostOverview hosts;

  static Future<NvmeMutationSnapshot> load({
    required AuthenticatedAdminSession api,
    required AuthenticatedNvmeHostSession hostsApi,
    required bool Function() isCurrent,
  }) async {
    final topology = await loadNvmeOverviewFromAdmin(
      api: api,
      isCurrent: isCurrent,
    );
    if (!isCurrent()) throw StateError('The server connection changed.');
    final rows = await hostsApi.loadNvmeHostReferences();
    if (!isCurrent()) throw StateError('The server connection changed.');
    final hosts = NvmeHostOverview.parse(
      hosts: rows.hosts,
      mappings: rows.mappings,
    );
    if (topology.unresolvedReferences != 0 ||
        hosts.unresolvedReferences(
              topology.subsystems.map((s) => s.id).toSet(),
            ) !=
            0) {
      throw StateError('NVMe-oF references are unresolved. Nothing was sent.');
    }
    return NvmeMutationSnapshot(topology, hosts);
  }

  String proof({int? omitPortMappingId, int? omitPortId}) {
    final subsystems =
        topology.subsystems
            .map((s) => [s.id, s.name, s.subnqn, s.allowAnyHost])
            .toList()
          ..sort((a, b) => (a[0] as int).compareTo(b[0] as int));
    final ports =
        topology.ports
            .where((p) => p.id != omitPortId)
            .map((p) => [p.id, p.transport, p.enabled])
            .toList()
          ..sort((a, b) => (a[0] as int).compareTo(b[0] as int));
    final namespaces =
        topology.namespaces
            .map(
              (n) => [
                n.id,
                n.nsid,
                n.subsystemId,
                n.deviceType,
                n.enabled,
                n.locked,
              ],
            )
            .toList()
          ..sort((a, b) => (a[0] as int).compareTo(b[0] as int));
    final portMappings =
        topology.portMappings
            .where((m) => m.id != omitPortMappingId)
            .map((m) => [m.id, m.portId, m.subsystemId])
            .toList()
          ..sort((a, b) => a[0].compareTo(b[0]));
    final hostRows = hosts.hosts.map((h) => [h.id, h.nqn]).toList()
      ..sort((a, b) => (a[0] as int).compareTo(b[0] as int));
    final hostMappings =
        hosts.mappings.map((m) => [m.id, m.hostId, m.subsystemId]).toList()
          ..sort((a, b) => a[0].compareTo(b[0]));
    return jsonEncode([
      subsystems,
      ports,
      namespaces,
      portMappings,
      hostRows,
      hostMappings,
    ]);
  }
}
