import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';

import '../dashboard/dashboard_controller.dart';

/// Bounded, secret-free projection of four separate NVMe-oF queries.
/// Backing paths, device UUIDs, serials and host credentials are not requested.
final class NvmeOverview {
  NvmeOverview({
    required List<NvmeSubsystem> subsystems,
    required List<NvmePort> ports,
    required List<NvmeNamespace> namespaces,
    required List<NvmePortMapping> portMappings,
  }) : subsystems = List.unmodifiable(subsystems),
       ports = List.unmodifiable(ports),
       namespaces = List.unmodifiable(namespaces),
       portMappings = List.unmodifiable(portMappings);

  final List<NvmeSubsystem> subsystems;
  final List<NvmePort> ports;
  final List<NvmeNamespace> namespaces;
  final List<NvmePortMapping> portMappings;

  factory NvmeOverview.parse({
    required Object? subsystems,
    required Object? ports,
    required Object? namespaces,
    required Object? portMappings,
  }) => NvmeOverview(
    subsystems: _rows(subsystems, NvmeSubsystem.parse),
    ports: _rows(ports, NvmePort.parse),
    namespaces: _rows(namespaces, NvmeNamespace.parse),
    portMappings: _rows(portMappings, NvmePortMapping.parse),
  );

  NvmePort? portById(int id) {
    for (final port in ports) {
      if (port.id == id) return port;
    }
    return null;
  }

  int get unresolvedReferences =>
      namespaces
          .where((n) => !subsystems.any((s) => s.id == n.subsystemId))
          .length +
      portMappings
          .where(
            (m) =>
                !subsystems.any((s) => s.id == m.subsystemId) ||
                !ports.any((p) => p.id == m.portId),
          )
          .length;

  int get exposedSubsystems => subsystems
      .where((s) => portMappings.any((m) => m.subsystemId == s.id))
      .length;
}

final class NvmeSubsystem {
  const NvmeSubsystem(
    this.id,
    this.name,
    this.allowAnyHost,
    this.subnqn, {
    this.ana,
    this.anaReported = false,
    this.piEnable,
    this.piReported = false,
    this.qidMax,
    this.qidReported = false,
    this.ieeeOui,
    this.ieeeOuiReported = false,
  });
  final int id;
  final String name;
  final bool allowAnyHost;
  final String? subnqn;

  /// Null inherits nvmet.global.config.ana only when the field was returned.
  final bool? ana;
  final bool anaReported;

  /// Null means server default only when the field was returned.
  final bool? piEnable;
  final bool piReported;
  final int? qidMax;
  final bool qidReported;

  /// Null is the server default only when the field was returned.
  final String? ieeeOui;
  final bool ieeeOuiReported;

  static NvmeSubsystem? parse(Map row) {
    final id = _id(row['id']);
    final name = _label(row['name']);
    final allowAnyHost = row['allow_any_host'];
    final rawNqn = row['subnqn'];
    final ana = row['ana'];
    final pi = row['pi_enable'];
    final qid = row['qid_max'];
    final rawOui = row['ieee_oui'];
    final subnqn = rawNqn == null ? null : _nqn(rawNqn);
    final ieeeOui = rawOui == null ? null : _oui(rawOui);
    if (id == null ||
        name == null ||
        allowAnyHost is! bool ||
        (rawNqn != null && subnqn == null) ||
        (ana != null && ana is! bool) ||
        (pi != null && pi is! bool) ||
        (qid != null && (qid is! int || qid < 0 || qid > 2147483647)) ||
        (rawOui != null && ieeeOui == null)) {
      return null;
    }
    return NvmeSubsystem(
      id,
      name,
      allowAnyHost,
      subnqn,
      ana: ana as bool?,
      anaReported: row.containsKey('ana'),
      piEnable: pi as bool?,
      piReported: row.containsKey('pi_enable'),
      qidMax: qid as int?,
      qidReported: row.containsKey('qid_max'),
      ieeeOui: ieeeOui,
      ieeeOuiReported: row.containsKey('ieee_oui'),
    );
  }
}

final class NvmePort {
  const NvmePort(
    this.id,
    this.transport,
    this.enabled, {
    this.inlineDataSize,
    this.inlineDataSizeReported = false,
    this.maxQueueSize,
    this.maxQueueSizeReported = false,
    this.piEnable,
    this.piReported = false,
  });
  final int id;
  final String transport;
  final bool enabled;
  final int? inlineDataSize;
  final bool inlineDataSizeReported;
  final int? maxQueueSize;
  final bool maxQueueSizeReported;
  final bool? piEnable;
  final bool piReported;

  static NvmePort? parse(Map row) {
    final id = _id(row['id']);
    final transport = row['addr_trtype'];
    final enabled = row['enabled'];
    final inlineDataSize = row['inline_data_size'];
    final maxQueueSize = row['max_queue_size'];
    final piEnable = row['pi_enable'];
    if (id == null ||
        !const {'TCP', 'RDMA', 'FC'}.contains(transport) ||
        enabled is! bool ||
        (inlineDataSize != null &&
            (inlineDataSize is! int ||
                inlineDataSize < 0 ||
                inlineDataSize > 2147483647)) ||
        (maxQueueSize != null &&
            (maxQueueSize is! int ||
                maxQueueSize < 0 ||
                maxQueueSize > 2147483647)) ||
        (piEnable != null && piEnable is! bool)) {
      return null;
    }
    return NvmePort(
      id,
      transport as String,
      enabled,
      inlineDataSize: inlineDataSize as int?,
      inlineDataSizeReported: row.containsKey('inline_data_size'),
      maxQueueSize: maxQueueSize as int?,
      maxQueueSizeReported: row.containsKey('max_queue_size'),
      piEnable: piEnable as bool?,
      piReported: row.containsKey('pi_enable'),
    );
  }
}

final class NvmeNamespace {
  const NvmeNamespace(
    this.id,
    this.nsid,
    this.subsystemId,
    this.deviceType,
    this.enabled,
    this.locked,
  );
  final int id, subsystemId;
  final int? nsid;
  final String deviceType;
  final bool enabled;
  final bool? locked;

  static NvmeNamespace? parse(Map row) {
    final id = _id(row['id']);
    final nsid = row['nsid'];
    final subsystem = row['subsys'];
    final subsystemId = subsystem is Map ? _id(subsystem['id']) : null;
    final type = row['device_type'];
    final enabled = row['enabled'];
    final locked = row['locked'];
    if (id == null ||
        (nsid != null && _id(nsid) == null) ||
        subsystemId == null ||
        !const {'ZVOL', 'FILE'}.contains(type) ||
        enabled is! bool ||
        (locked != null && locked is! bool)) {
      return null;
    }
    return NvmeNamespace(
      id,
      nsid as int?,
      subsystemId,
      type as String,
      enabled,
      locked as bool?,
    );
  }
}

final class NvmePortMapping {
  const NvmePortMapping(this.id, this.portId, this.subsystemId);
  final int id, portId, subsystemId;

  static NvmePortMapping? parse(Map row) {
    final id = _id(row['id']);
    final port = row['port'];
    final subsystem = row['subsys'];
    final portId = port is Map ? _id(port['id']) : null;
    final subsystemId = subsystem is Map ? _id(subsystem['id']) : null;
    if (id == null || portId == null || subsystemId == null) return null;
    return NvmePortMapping(id, portId, subsystemId);
  }
}

List<T> _rows<T>(Object? raw, T? Function(Map) parse) {
  if (raw is! List || raw.length > 100 || raw.any((row) => row is! Map)) {
    throw const FormatException('Incomplete NVMe-oF inventory');
  }
  final rows = <T>[];
  final ids = <int>{};
  for (final item in raw) {
    final row = parse(item as Map);
    final id = switch (row) {
      NvmeSubsystem(:final id) => id,
      NvmePort(:final id) => id,
      NvmeNamespace(:final id) => id,
      NvmePortMapping(:final id) => id,
      _ => null,
    };
    if (row == null || id == null || !ids.add(id)) {
      throw const FormatException('Invalid NVMe-oF identity');
    }
    rows.add(row);
  }
  return List.unmodifiable(rows);
}

int? _id(Object? value) => value is int && value > 0 ? value : null;
String? _label(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 120 ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    return null;
  }
  return value;
}

String? _nqn(Object? value) {
  if (value is! String ||
      value.length < 11 ||
      value.length > 223 ||
      !value.startsWith('nqn.') ||
      value.contains(RegExp(r'[\x00-\x1f\x7f]'))) {
    return null;
  }
  return value;
}

String? _oui(Object? value) {
  if (value is! String ||
      value.isEmpty ||
      value.length > 32 ||
      !RegExp(r'^[\x20-\x7e]+$').hasMatch(value)) {
    return null;
  }
  return value;
}

Future<NvmeOverview> loadNvmeOverviewFromAdmin({
  required AuthenticatedAdminSession api,
  required bool Function() isCurrent,
}) async {
  const names = [
    'nvmet.subsys.query',
    'nvmet.port.query',
    'nvmet.namespace.query',
    'nvmet.port_subsys.query',
  ];
  const fields = [
    [
      'id',
      'name',
      'subnqn',
      'allow_any_host',
      'ana',
      'pi_enable',
      'qid_max',
      'ieee_oui',
    ],
    [
      'id',
      'addr_trtype',
      'enabled',
      'inline_data_size',
      'max_queue_size',
      'pi_enable',
    ],
    ['id', 'nsid', 'subsys.id', 'device_type', 'enabled', 'locked'],
    ['id', 'port.id', 'subsys.id'],
  ];
  final methods = [for (final name in names) api.adminCatalog.method(name)];
  if (!api.adminCatalog.versionSupported ||
      methods.any((method) => method == null || !method.supported)) {
    throw StateError(
      'This server does not support the complete NVMe-oF overview.',
    );
  }
  final values = <Object?>[];
  for (var i = 0; i < methods.length; i++) {
    if (!isCurrent()) throw StateError('The server connection changed.');
    final result = await api.invokeAdmin(
      AdminRequest(
        method: methods[i]!,
        arguments: [
          const [],
          {'select': fields[i], 'limit': 101},
        ],
      ),
    );
    if (!isCurrent()) {
      throw StateError('The server connection changed.');
    }
    if (result is! AdminCompleted) {
      throw StateError('NVMe-oF inventory is unavailable for this account.');
    }
    values.add(result.value);
  }
  return NvmeOverview.parse(
    subsystems: values[0],
    ports: values[1],
    namespaces: values[2],
    portMappings: values[3],
  );
}

final nvmeOverviewProvider = FutureProvider.autoDispose<NvmeOverview>((
  ref,
) async {
  final session = ref.watch(dashboardActiveSessionProvider);
  final repository = session?.repository;
  if (session?.endpoint == null || repository is! AuthenticatedAdminSession) {
    throw StateError('Connect to inspect NVMe-oF.');
  }
  return loadNvmeOverviewFromAdmin(
    api: repository as AuthenticatedAdminSession,
    isCurrent: () =>
        ref.mounted &&
        identical(session, ref.read(dashboardActiveSessionProvider)),
  );
}, retry: (_, _) => null);
