import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../dashboard/dashboard_controller.dart';

/// Public host identifiers only. DH-CHAP key fields are never selected.
final class NvmeHostOverview {
  NvmeHostOverview({
    required List<NvmeHost> hosts,
    required List<NvmeHostMapping> mappings,
  }) : hosts = List.unmodifiable(hosts),
       mappings = List.unmodifiable(mappings);

  final List<NvmeHost> hosts;
  final List<NvmeHostMapping> mappings;

  factory NvmeHostOverview.parse({
    required Object? hosts,
    required Object? mappings,
  }) => NvmeHostOverview(
    hosts: _rows(hosts, NvmeHost.parse),
    mappings: _rows(mappings, NvmeHostMapping.parse),
  );

  int unresolvedReferences(Set<int> subsystemIds) => mappings
      .where(
        (row) =>
            !hosts.any((host) => host.id == row.hostId) ||
            !subsystemIds.contains(row.subsystemId),
      )
      .length;
}

final class NvmeHost {
  const NvmeHost(this.id, this.nqn);
  final int id;
  final String nqn;

  static NvmeHost? parse(Map row) {
    final id = _id(row['id']);
    final nqn = row['hostnqn'];
    if (id == null ||
        nqn is! String ||
        nqn.isEmpty ||
        nqn.length > 512 ||
        nqn.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
      return null;
    }
    return NvmeHost(id, nqn);
  }
}

final class NvmeHostMapping {
  const NvmeHostMapping(this.id, this.hostId, this.subsystemId);
  final int id, hostId, subsystemId;

  static NvmeHostMapping? parse(Map row) {
    final id = _id(row['id']);
    final host = row['host'];
    final subsys = row['subsys'];
    final hostId = host is Map ? _id(host['id']) : null;
    final subsystemId = subsys is Map ? _id(subsys['id']) : null;
    if (id == null || hostId == null || subsystemId == null) return null;
    return NvmeHostMapping(id, hostId, subsystemId);
  }
}

List<T> _rows<T>(Object? raw, T? Function(Map) parse) {
  if (raw is! List || raw.length > 100 || raw.any((row) => row is! Map)) {
    throw const FormatException('Incomplete NVMe-oF host inventory');
  }
  final rows = <T>[];
  final ids = <int>{};
  for (final item in raw) {
    final row = parse(item as Map);
    final id = switch (row) {
      NvmeHost(:final id) => id,
      NvmeHostMapping(:final id) => id,
      _ => null,
    };
    if (row == null || id == null || !ids.add(id)) {
      throw const FormatException('Invalid NVMe-oF host identity');
    }
    rows.add(row);
  }
  return List.unmodifiable(rows);
}

int? _id(Object? value) => value is int && value > 0 ? value : null;

final nvmeHostOverviewProvider = FutureProvider.autoDispose<NvmeHostOverview>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider);
  final repository = session?.repository;
  if (session?.endpoint == null ||
      repository is! AuthenticatedNvmeHostSession) {
    throw StateError('Connect to inspect NVMe-oF hosts.');
  }
  final publicRows = await (repository as AuthenticatedNvmeHostSession)
      .loadNvmeHostReferences();
  if (!ref.mounted ||
      !identical(session, ref.read(dashboardActiveSessionProvider))) {
    throw StateError('The server connection changed.');
  }
  return NvmeHostOverview.parse(
    hosts: publicRows.hosts,
    mappings: publicRows.mappings,
  );
}, retry: (_, _) => null);
