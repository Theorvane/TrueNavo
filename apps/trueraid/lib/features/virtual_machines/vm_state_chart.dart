import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

/// Disjoint counts from the returned inventory, never utilization or uptime.
class VmStateChart extends StatelessWidget {
  const VmStateChart({required this.states, super.key});
  final List<String> states;

  @override
  Widget build(BuildContext context) {
    final td = context.tdTheme;
    final counts = [
      states.where((state) => state == 'RUNNING').length,
      states.where((state) => state == 'STOPPED').length,
      states.where((state) => state == 'SUSPENDED').length,
      states
          .where(
            (state) =>
                !const {'RUNNING', 'STOPPED', 'SUSPENDED'}.contains(state),
          )
          .length,
    ];
    final colors = [
      td.statusSuccess,
      td.textMuted,
      td.statusWarning,
      td.statusInfo,
    ];
    const labels = ['Running', 'Stopped', 'Suspended', 'Other states'];
    final summary = states.isEmpty
        ? 'VM inventory state counts. No virtual machines in the returned inventory.'
        : 'VM inventory state counts. ${states.length} total; ${counts[0]} running, ${counts[1]} stopped, ${counts[2]} suspended, ${counts[3]} other states.';
    return TdPanel(
      title: 'Inventory state counts',
      description: 'Returned VM inventory, not runtime utilization or uptime.',
      child: LayoutBuilder(
        builder: (context, constraints) {
          final diameter = math.min(120.0, constraints.maxWidth);
          final inline =
              constraints.maxWidth >= 280 &&
              MediaQuery.textScalerOf(context).scale(14) <= 21;
          final legendWidth = inline
              ? math.min(240.0, constraints.maxWidth - diameter - 24)
              : math.min(240.0, constraints.maxWidth);
          return Wrap(
            spacing: 24,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                label: summary,
                child: ExcludeSemantics(
                  child: SizedBox(
                    width: diameter,
                    height: diameter,
                    child: CustomPaint(
                      painter: _VmStateRing(counts, colors, td.borderSubtle),
                      child: Center(
                        child: Padding(
                          padding: const EdgeInsets.all(22),
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text(
                              '${states.length}',
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (states.isEmpty)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 8),
                        child: Text('No virtual machines in this inventory.'),
                      ),
                    for (var i = 0; i < counts.length; i++)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 4),
                        child: Row(
                          children: [
                            ExcludeSemantics(
                              child: Icon(
                                Icons.circle,
                                size: 10,
                                color: colors[i],
                              ),
                            ),
                            const SizedBox(width: 8),
                            Expanded(
                              child: Text('${labels[i]} · ${counts[i]}'),
                            ),
                          ],
                        ),
                      ),
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

class VmStateBadge extends StatelessWidget {
  const VmStateBadge({required this.state, super.key});
  final String state;
  @override
  Widget build(BuildContext context) {
    final td = context.tdTheme;
    final (label, color) = switch (state) {
      'RUNNING' => ('Running', td.statusSuccess),
      'STOPPED' => ('Stopped', td.textMuted),
      'SUSPENDED' => ('Suspended', td.statusWarning),
      'ERROR' => ('Error', td.statusCritical),
      _ => ('Other state: $state', td.statusInfo),
    };
    return Semantics(
      label: 'VM state: $label',
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: color.withValues(alpha: 0.12),
            border: Border.all(color: color.withValues(alpha: 0.5)),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.circle, size: 8, color: color),
                const SizedBox(width: 7),
                Flexible(
                  child: Text(
                    label,
                    style: TextStyle(color: color, fontWeight: FontWeight.w600),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _VmStateRing extends CustomPainter {
  const _VmStateRing(this.counts, this.colors, this.track);
  final List<int> counts;
  final List<Color> colors;
  final Color track;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(8);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 10;
    canvas.drawOval(rect, paint..color = track);
    final total = counts.fold(0, (sum, count) => sum + count);
    if (total == 0) return;
    var start = -math.pi / 2;
    for (var i = 0; i < counts.length; i++) {
      final sweep = counts[i] / total * 2 * math.pi;
      if (sweep > 0) {
        canvas.drawArc(rect, start, sweep, false, paint..color = colors[i]);
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _VmStateRing oldDelegate) =>
      !listEquals(counts, oldDelegate.counts) ||
      !listEquals(colors, oldDelegate.colors) ||
      track != oldDelegate.track;
}
