import 'dart:convert';

import 'package:crypto/crypto.dart';

/// Stable section identifiers are a local UI contract, not server API names.
enum DashboardSection {
  metrics('Summary', 'Pool and active alert counts'),
  liveMetrics('Live performance', 'CPU, memory and network activity'),
  charts('Capacity and alerts', 'Storage capacity and alert distribution'),
  performanceHistory(
    'Performance history',
    'Explore historical server metrics',
  );

  const DashboardSection(this.label, this.description);
  final String label;
  final String description;
}

/// A profile and its authenticated endpoint together scope preferences. Names,
/// selected accounts, API keys and mutable display labels are never persisted.
final class DashboardLayoutIdentity {
  DashboardLayoutIdentity._(this.storageKey);

  static DashboardLayoutIdentity? fromEndpoint({
    required String profileId,
    required String? endpoint,
  }) {
    if (profileId.isEmpty ||
        profileId.length > 128 ||
        endpoint == null ||
        endpoint.length > 2048 ||
        RegExp(r'[\x00-\x1f\x7f]').hasMatch('$profileId$endpoint')) {
      return null;
    }
    final uri = Uri.tryParse(endpoint);
    if (uri == null ||
        !const {'ws', 'wss', 'http', 'https'}.contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      return null;
    }
    return DashboardLayoutIdentity._(
      sha256
          .convert(utf8.encode(jsonEncode([profileId, uri.toString()])))
          .toString(),
    );
  }

  final String storageKey;
  @override
  bool operator ==(Object other) =>
      other is DashboardLayoutIdentity && other.storageKey == storageKey;
  @override
  int get hashCode => storageKey.hashCode;
}

final class DashboardLayout {
  DashboardLayout({
    required List<DashboardSection> order,
    required Set<DashboardSection> hidden,
  }) : order = List.unmodifiable(order),
       hidden = Set.unmodifiable(hidden) {
    if (order.length != DashboardSection.values.length ||
        order.toSet().length != DashboardSection.values.length) {
      throw ArgumentError(
        'A layout must contain every dashboard section once.',
      );
    }
  }

  factory DashboardLayout.defaults() =>
      DashboardLayout(order: DashboardSection.values, hidden: {});
  final List<DashboardSection> order;
  final Set<DashboardSection> hidden;
  Iterable<DashboardSection> get visible =>
      order.where((item) => !hidden.contains(item));

  DashboardLayout toggle(DashboardSection section, bool show) =>
      DashboardLayout(
        order: order,
        hidden: {...hidden}
          ..removeWhere((item) => item == section && show)
          ..addAll(show ? {} : {section}),
      );

  DashboardLayout move(DashboardSection section, int offset) {
    final index = order.indexOf(section);
    final target = index + offset;
    if (target < 0 || target >= order.length) return this;
    final next = [...order]
      ..removeAt(index)
      ..insert(target, section);
    return DashboardLayout(order: next, hidden: hidden);
  }

  String encode() => jsonEncode({
    'version': 1,
    'order': [for (final section in order) section.name],
    'hidden': [
      for (final section in order)
        if (hidden.contains(section)) section.name,
    ],
  });

  /// Unknown versions, duplicates, excess fields and oversized inputs are not
  /// partially applied. New known sections receive default positions on v1.
  static DashboardLayout? decode(String raw) {
    if (raw.length > 8192) return null;
    try {
      final value = jsonDecode(raw);
      if (value is! Map<String, dynamic> ||
          value.length != 3 ||
          value['version'] != 1 ||
          value['order'] is! List ||
          value['hidden'] is! List) {
        return null;
      }
      final order = value['order'] as List;
      final hidden = value['hidden'] as List;
      final known = {
        for (final section in DashboardSection.values) section.name: section,
      };
      if (order.isEmpty ||
          order.length > known.length ||
          hidden.length > known.length ||
          order.any((item) => item is! String || !known.containsKey(item)) ||
          hidden.any((item) => item is! String || !known.containsKey(item)) ||
          order.toSet().length != order.length ||
          hidden.toSet().length != hidden.length ||
          hidden.any((item) => !order.contains(item))) {
        return null;
      }
      return DashboardLayout(
        order: [
          for (final name in order) known[name]!,
          for (final section in DashboardSection.values)
            if (!order.contains(section.name)) section,
        ],
        hidden: {for (final name in hidden) known[name]!},
      );
    } catch (_) {
      return null;
    }
  }
}
