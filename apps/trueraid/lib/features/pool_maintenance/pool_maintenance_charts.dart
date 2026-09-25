import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

class PoolScheduleChart extends StatelessWidget {
  const PoolScheduleChart({
    required this.enabled,
    required this.disabled,
    super.key,
  });
  final int enabled, disabled;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TdPanel(
      title: 'Scheduled scrub configuration',
      description: 'Enabled schedules are not running jobs. Counts do not prove when a scrub will next start.',
      child: Wrap(
        spacing: 24,
        runSpacing: 16,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Semantics(
            label:
                '$enabled enabled scrub schedules, $disabled disabled scrub schedules',
            child: ExcludeSemantics(
              child: SizedBox(
                width: 124,
                height: 124,
                child: CustomPaint(
                  key: const Key('pool-maintenance-schedule-donut'),
                  painter: _ScheduleRing(
                    enabled,
                    disabled,
                    colors.primary,
                    colors.tertiary,
                    colors.outlineVariant,
                  ),
                  child: Center(
                    child: Text(
                      '${enabled + disabled}',
                      style: TdTypography.titleLarge,
                    ),
                  ),
                ),
              ),
            ),
          ),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _Legend(
                color: colors.primary,
                label: '$enabled Enabled schedules',
                dotKey: const Key('pool-maintenance-enabled-color'),
              ),
              _Legend(
                color: colors.tertiary,
                label: '$disabled Disabled schedules',
                dotKey: const Key('pool-maintenance-disabled-color'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({
    required this.color,
    required this.label,
    required this.dotKey,
  });
  final Color color;
  final String label;
  final Key dotKey;
  @override
  Widget build(BuildContext context) => Row(
    mainAxisSize: MainAxisSize.min,
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 6),
        child: ExcludeSemantics(
          child: Icon(Icons.circle, key: dotKey, size: 12, color: color),
        ),
      ),
      const SizedBox(width: 8),
      Flexible(child: Text(label)),
    ],
  );
}

class _ScheduleRing extends CustomPainter {
  _ScheduleRing(
    this.enabled,
    this.disabled,
    this.active,
    this.inactive,
    this.empty,
  );
  final int enabled, disabled;
  final Color active, inactive, empty;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(9);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 14;
    canvas.drawOval(rect, paint..color = empty);
    final total = enabled + disabled;
    if (total == 0) return;
    final sweep = enabled / total * math.pi * 2;
    canvas.drawArc(rect, -math.pi / 2, sweep, false, paint..color = active);
    canvas.drawArc(
      rect,
      -math.pi / 2 + sweep,
      math.pi * 2 - sweep,
      false,
      paint..color = inactive,
    );
  }

  @override
  bool shouldRepaint(covariant _ScheduleRing old) =>
      old.enabled != enabled ||
      old.disabled != disabled ||
      old.active != active ||
      old.inactive != inactive ||
      old.empty != empty;
}
