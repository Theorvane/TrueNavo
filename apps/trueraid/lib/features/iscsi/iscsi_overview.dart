/// Bounded, read-only projection of five TrueNAS 25.10 iSCSI queries.
/// Authentication material, extent paths and serials are never retained.
final class IscsiOverview {
  const IscsiOverview({
    required this.portals,
    required this.initiators,
    required this.targets,
    required this.extents,
    required this.mappings,
  });
  final List<IscsiPortal> portals;
  final List<IscsiInitiator> initiators;
  final List<IscsiTarget> targets;
  final List<IscsiExtent> extents;
  final List<IscsiMapping> mappings;

  factory IscsiOverview.parse({
    required Object? portals,
    required Object? initiators,
    required Object? targets,
    required Object? extents,
    required Object? mappings,
  }) {
    return IscsiOverview(
      portals: _rows(portals, IscsiPortal.parse),
      initiators: _rows(initiators, IscsiInitiator.parse),
      targets: _rows(targets, IscsiTarget.parse),
      extents: _rows(extents, IscsiExtent.parse),
      mappings: _rows(mappings, IscsiMapping.parse),
    );
  }

  IscsiTarget? targetById(int id) {
    for (final target in targets) {
      if (target.id == id) return target;
    }
    return null;
  }

  IscsiExtent? extentById(int id) {
    for (final extent in extents) {
      if (extent.id == id) return extent;
    }
    return null;
  }

  IscsiPortal? portalById(int id) {
    for (final portal in portals) {
      if (portal.id == id) return portal;
    }
    return null;
  }

  IscsiInitiator? initiatorById(int id) {
    for (final initiator in initiators) {
      if (initiator.id == id) return initiator;
    }
    return null;
  }
}

List<T> _rows<T>(Object? raw, T? Function(Map) parse) {
  if (raw is! List || raw.length > 100 || raw.any((row) => row is! Map)) {
    throw const FormatException('Incomplete iSCSI inventory');
  }
  final values = <T>[];
  final ids = <int>{};
  for (final row in raw) {
    final value = parse(row as Map);
    if (value == null) throw const FormatException('Invalid iSCSI row');
    final id = switch (value) {
      IscsiPortal(:final id) => id,
      IscsiInitiator(:final id) => id,
      IscsiTarget(:final id) => id,
      IscsiExtent(:final id) => id,
      IscsiMapping(:final id) => id,
      _ => throw const FormatException('Invalid iSCSI row'),
    };
    if (!ids.add(id)) throw const FormatException('Duplicate iSCSI identity');
    values.add(value);
  }
  return List.unmodifiable(values);
}

final class IscsiPortal {
  const IscsiPortal(this.id, this.listeners, this.comment);
  final int id;
  final List<IscsiListener> listeners;
  final String comment;

  static IscsiPortal? parse(Map raw) {
    final id = _id(raw['id']);
    final listen = raw['listen'];
    final comment = raw['comment'];
    if (comment != null && (comment is! String || comment.length > 1024)) {
      return null;
    }
    if (id == null || listen is! List || listen.length > 100) return null;
    final listeners = <IscsiListener>[];
    for (final item in listen) {
      if (item is! Map) return null;
      final ip = _label(item['ip']);
      final port = item['port'];
      if (ip == null || port is! int || port < 1 || port > 65535) return null;
      listeners.add(IscsiListener(ip, port));
    }
    return IscsiPortal(
      id,
      List.unmodifiable(listeners),
      comment as String? ?? '',
    );
  }
}

final class IscsiListener {
  const IscsiListener(this.ip, this.port);
  final String ip;
  final int port;
}

final class IscsiInitiator {
  const IscsiInitiator(this.id, this.names, this.comment);
  final int id;
  final List<String> names;
  final String comment;

  static IscsiInitiator? parse(Map raw) {
    final id = _id(raw['id']);
    final initiators = raw['initiators'];
    if (id == null || initiators is! List || initiators.length > 100) {
      return null;
    }
    final comment = raw['comment'];
    if (comment != null && (comment is! String || comment.length > 1024)) {
      return null;
    }
    final names = <String>[];
    for (final item in initiators) {
      final name = _label(item);
      if (name == null) return null;
      names.add(name);
    }
    return IscsiInitiator(
      id,
      List.unmodifiable(names),
      comment as String? ?? '',
    );
  }
}

final class IscsiTargetGroup {
  const IscsiTargetGroup(this.portalId, this.initiatorId, this.authMethod);
  final int portalId;
  final int? initiatorId;
  final String authMethod;

  static IscsiTargetGroup? parse(Map raw) {
    final portal = _id(raw['portal']);
    final rawInitiator = raw['initiator'];
    final initiator = rawInitiator == null ? null : _id(rawInitiator);
    if (portal == null || (rawInitiator != null && initiator == null)) {
      return null;
    }
    final authMethod = switch (raw['authmethod']) {
      'NONE' => 'No CHAP',
      'CHAP' => 'CHAP',
      'CHAP_MUTUAL' => 'Mutual CHAP',
      _ => 'Authentication unknown',
    };
    return IscsiTargetGroup(portal, initiator, authMethod);
  }
}

final class IscsiTarget {
  const IscsiTarget(this.id, this.name, this.mode, this.groups);
  final int id;
  final String name, mode;
  final List<IscsiTargetGroup> groups;

  static IscsiTarget? parse(Map raw) {
    final id = _id(raw['id']);
    final name = _label(raw['name']);
    if (id == null || name == null) return null;
    final rawGroups = raw['groups'];
    if (rawGroups != null && (rawGroups is! List || rawGroups.length > 100)) {
      return null;
    }
    final groups = <IscsiTargetGroup>[];
    for (final rawGroup in rawGroups ?? const []) {
      if (rawGroup is! Map) return null;
      final group = IscsiTargetGroup.parse(rawGroup);
      if (group == null) return null;
      groups.add(group);
    }
    final mode = switch (raw['mode']) {
      'ISCSI' => 'iSCSI',
      'FC' => 'Fibre Channel',
      'BOTH' => 'iSCSI + Fibre Channel',
      _ => 'Unknown mode',
    };
    return IscsiTarget(id, name, mode, List.unmodifiable(groups));
  }
}

final class IscsiExtent {
  const IscsiExtent(
    this.id,
    this.name,
    this.type,
    this.enabled,
    this.readOnly,
    this.locked,
  );
  final int id;
  final String name, type;
  final bool? enabled, readOnly, locked;

  static IscsiExtent? parse(Map raw) {
    final id = _id(raw['id']);
    final name = _label(raw['name']);
    if (id == null || name == null) return null;
    return IscsiExtent(
      id,
      name,
      switch (raw['type']) {
        'DISK' => 'Disk',
        'FILE' => 'File',
        _ => 'Unknown type',
      },
      raw['enabled'] is bool ? raw['enabled'] as bool : null,
      raw['ro'] is bool ? raw['ro'] as bool : null,
      raw['locked'] is bool ? raw['locked'] as bool : null,
    );
  }
}

final class IscsiMapping {
  const IscsiMapping(this.id, this.targetId, this.extentId, this.lun);
  final int id, targetId, extentId, lun;

  static IscsiMapping? parse(Map raw) {
    final id = _id(raw['id']);
    final target = _id(raw['target']);
    final extent = _id(raw['extent']);
    final lun = raw['lunid'];
    if (id == null ||
        target == null ||
        extent == null ||
        lun is! int ||
        lun < 0) {
      return null;
    }
    return IscsiMapping(id, target, extent, lun);
  }
}

int? _id(Object? value) => value is int && value > 0 ? value : null;

String? _label(Object? value) {
  if (value is! String) return null;
  final clean = value.replaceAll(RegExp(r'[\x00-\x1f\x7f]'), '').trim();
  if (clean.isEmpty) return null;
  return clean.length <= 120 ? clean : clean.substring(0, 120);
}
