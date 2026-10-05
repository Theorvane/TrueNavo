import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

class AlertSettingsCharts extends StatelessWidget {
  const AlertSettingsCharts({required this.services, super.key});
  final List<AlertServiceSnapshot> services;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = services.where((s) => s.enabled).length;
    final providers = <String, int>{};
    final thresholds = <String, int>{
      for (final level in AlertDeliveryLevel.values)
        if (services.any((service) => service.level == level))
          level.name.toUpperCase(): services
              .where((service) => service.level == level)
              .length,
    };
    for (final service in services) {
      providers.update(service.type, (n) => n + 1, ifAbsent: () => 1);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TdPanel(
          title: 'Configured service enablement',
          description: 'Configuration only — not delivery, reliability or a global mute.',
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 24,
              runSpacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Semantics(
                  label:
                      '$enabled enabled and ${services.length - enabled} disabled configured services. No delivery measurements.',
                  child: ExcludeSemantics(
                    child: SizedBox(
                      width: 112,
                      height: 112,
                      child: CustomPaint(
                        key: const Key('alert-enablement-ring'),
                        painter: _EnablementRing(
                          enabled,
                          services.length,
                          colors.primary,
                          colors.tertiary,
                          colors.outlineVariant,
                        ),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: FittedBox(
                              child: Text(
                                '${services.length}',
                                style: TdTypography.metricMedium,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                SizedBox(
                  width: math.min(250, constraints.maxWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Legend(color: colors.primary, label: '$enabled Enabled'),
                      const SizedBox(height: 8),
                      _Legend(
                        color: colors.tertiary,
                        label: '${services.length - enabled} Disabled',
                      ),
                      if (services.isEmpty)
                        const Text(
                          'No configured services; no percentage or delivery status is inferred.',
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 12),
        TdPanel(
          title: 'Configured providers & thresholds',
          description: 'Counts include enabled and disabled rows. Thresholds are configuration, not counts of generated alerts.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (services.isEmpty)
                const Text('No configured provider or threshold counts.'),
              for (final group in [
                (label: 'Provider', values: providers),
                (label: 'Threshold', values: thresholds),
              ])
                for (final item in group.values.entries)
                  Padding(
                    padding: const EdgeInsets.only(top: 12),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Text('${group.label} · ${item.key}: ${item.value}'),
                        const SizedBox(height: 4),
                        ExcludeSemantics(
                          child: SizedBox(
                            height: 10,
                            child: ColoredBox(
                              color: colors.outlineVariant,
                              child: Align(
                                alignment: Alignment.centerLeft,
                                child: FractionallySizedBox(
                                  key: Key(
                                    'alert-count-${group.label}-${item.key}',
                                  ),
                                  widthFactor: item.value / services.length,
                                  heightFactor: 1,
                                  child: ColoredBox(
                                    color: group.label == 'Provider'
                                        ? colors.primary
                                        : colors.tertiary,
                                  ),
                                ),
                              ),
                            ),
                          ),
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

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});
  final Color color;
  final String label;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 7),
        child: Icon(Icons.circle, size: 12, color: color),
      ),
      const SizedBox(width: 8),
      Expanded(child: Text(label)),
    ],
  );
}

class _EnablementRing extends CustomPainter {
  const _EnablementRing(
    this.enabled,
    this.total,
    this.active,
    this.other,
    this.track,
  );
  final int enabled, total;
  final Color active, other, track;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(6),
        paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10;
    canvas.drawOval(rect, paint..color = total == 0 ? track : other);
    if (total > 0 && enabled > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * enabled / total,
        false,
        paint..color = active,
      );
    }
  }

  @override
  bool shouldRepaint(_EnablementRing old) =>
      old.enabled != enabled ||
      old.total != total ||
      old.active != active ||
      old.other != other ||
      old.track != track;
}
