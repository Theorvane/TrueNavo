import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

/// Two complementary configuration counts. A configured task is not evidence
/// of a successful snapshot, recoverable backup, or future scheduled execution.
class SnapshotScheduleEnablementChart extends StatelessWidget {
  const SnapshotScheduleEnablementChart({required this.tasks, super.key});
  final List<SnapshotScheduleTask> tasks;

  @override
  Widget build(BuildContext context) {
    final enabled = tasks.where((task) => task.settings.enabled).length;
    final disabled = tasks.length - enabled;
    final td = context.tdTheme;
    return TdPanel(
      title: 'Schedule enablement',
      description: 'All returned schedules, independent of the text filter. Enabled does not mean healthy or completed.',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final besideWidth = constraints.maxWidth - 112 - TdSpacing.component;
          final readableLegendWidth =
              128 * MediaQuery.textScalerOf(context).scale(14) / 14;
          final legendWidth = math.min(
            220.0,
            besideWidth >= readableLegendWidth
                ? besideWidth
                : constraints.maxWidth,
          );
          return Wrap(
            spacing: TdSpacing.component,
            runSpacing: TdSpacing.component,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                key: const Key('schedule-enablement-semantics'),
                label:
                    'Schedule configuration: $enabled enabled, $disabled disabled, ${tasks.length} total. Not snapshot success or backup coverage.',
                child: ExcludeSemantics(
                  child: SizedBox(
                    width: 112,
                    height: 112,
                    child: CustomPaint(
                      key: const Key('schedule-enablement-ring'),
                      painter: _EnablementPainter(
                        enabled: enabled,
                        total: tasks.length,
                        enabledColor: td.statusSuccess,
                        disabledColor: td.textMuted,
                        trackColor: td.borderSubtle,
                      ),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(16),
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
                width: legendWidth,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _Legend(
                      label: 'Enabled · $enabled',
                      color: td.statusSuccess,
                    ),
                    const SizedBox(height: TdSpacing.related),
                    _Legend(label: 'Disabled · $disabled', color: td.textMuted),
                    if (tasks.isEmpty) ...[
                      const SizedBox(height: TdSpacing.related),
                      const Text(
                        'No schedules returned; no percentage is inferred.',
                      ),
                    ],
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.label, required this.color});
  final String label;
  final Color color;
  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Padding(
        padding: const EdgeInsets.only(top: 7),
        child: DecoratedBox(
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
          child: const SizedBox(width: 10, height: 10),
        ),
      ),
      const SizedBox(width: 8),
      Expanded(child: Text(label)),
    ],
  );
}

class _EnablementPainter extends CustomPainter {
  const _EnablementPainter({
    required this.enabled,
    required this.total,
    required this.enabledColor,
    required this.disabledColor,
    required this.trackColor,
  });
  final int enabled, total;
  final Color enabledColor, disabledColor, trackColor;
  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 10.0;
    final rect = Rect.fromLTWH(
      stroke / 2,
      stroke / 2,
      size.width - stroke,
      size.height - stroke,
    );
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke;
    canvas.drawOval(
      rect,
      paint..color = total == 0 ? trackColor : disabledColor,
    );
    if (enabled > 0 && total > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * enabled / total,
        false,
        paint..color = enabledColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EnablementPainter oldDelegate) =>
      enabled != oldDelegate.enabled ||
      total != oldDelegate.total ||
      enabledColor != oldDelegate.enabledColor ||
      disabledColor != oldDelegate.disabledColor ||
      trackColor != oldDelegate.trackColor;
}
