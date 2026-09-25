import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

class InitShutdownTasksCharts extends StatelessWidget {
  const InitShutdownTasksCharts({required this.tasks, super.key});
  final List<InitShutdownTaskSnapshot> tasks;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final enabled = tasks.where((s) => s.enabled).length;
    final providers = <String, int>{};
    final thresholds = <String, int>{
      for (final level in InitShutdownTaskPhase.values)
        if (tasks.any((service) => service.phase == level))
          level.name.toUpperCase(): tasks
              .where((service) => service.phase == level)
              .length,
    };
    for (final service in tasks) {
      providers.update(service.type, (n) => n + 1, ifAbsent: () => 1);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TdPanel(
          title: 'Configured task enablement',
          description: 'Configuration only — not running processes or execution success.',
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 24,
              runSpacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Semantics(
                  label:
                      '$enabled enabled and ${tasks.length - enabled} disabled configured tasks. No execution measurements.',
                  child: ExcludeSemantics(
                    child: SizedBox(
                      width: 112,
                      height: 112,
                      child: CustomPaint(
                        key: const Key('init-enablement-ring'),
                        painter: _EnablementRing(
                          enabled,
                          tasks.length,
                          colors.primary,
                          colors.tertiary,
                          colors.outlineVariant,
                        ),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: FittedBox(
                              child: Text(
                                '${tasks.length}',
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
                        label: '${tasks.length - enabled} Disabled',
                      ),
                      if (tasks.isEmpty)
                        const Text(
                          'No configured tasks; no percentage or execution status is inferred.',
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
          title: 'Configured types & phases',
          description: 'Counts include enabled and disabled tasks. Phase names do not establish readiness, ordering or completion.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (tasks.isEmpty)
                const Text('No configured type or phase counts.'),
              for (final group in [
                (label: 'Type', values: providers),
                (label: 'Phase', values: thresholds),
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
                                    'init-count-${group.label}-${item.key}',
                                  ),
                                  widthFactor: item.value / tasks.length,
                                  heightFactor: 1,
                                  child: ColoredBox(
                                    color: group.label == 'Type'
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
