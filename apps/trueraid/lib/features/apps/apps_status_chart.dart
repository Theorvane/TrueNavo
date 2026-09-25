import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

/// Disjoint counts from one complete, bounded installed-app inventory. No
/// percentages are invented when there is no inventory or the count is zero.
class AppsStatusChart extends StatelessWidget {
  const AppsStatusChart({required this.states, super.key});
  final List<String> states;

  @override
  Widget build(BuildContext context) {
    final td = context.tdTheme;
    final running = states.where((s) => s == 'RUNNING').length;
    final stopped = states.where((s) => s == 'STOPPED').length;
    final other = states.length - running - stopped;
    final colors = [td.statusSuccess, td.textMuted, td.statusWarning];
    final counts = [running, stopped, other];
    return TdPanel(
      title: 'Application health',
      description: 'Current states, not a historical uptime estimate.',
      child: LayoutBuilder(
        builder: (context, constraints) => Wrap(
          spacing: 24,
          runSpacing: 16,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Semantics(
              label:
                  '${states.length} applications; $running running, '
                  '$stopped stopped, $other other states.',
              child: ExcludeSemantics(
                child: SizedBox(
                  width: 136,
                  height: 136,
                  child: CustomPaint(
                    painter: _StateRing(counts, colors, td.borderSubtle),
                    child: Center(
                      child: Text(
                        '${states.length}',
                        style: TdTypography.metricMedium,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            SizedBox(
              width: math.min(260, constraints.maxWidth),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  for (var i = 0; i < counts.length; i++)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 5),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.circle, size: 10, color: colors[i]),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '${const ['Running', 'Stopped', 'Other states'][i]} · ${counts[i]}',
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StateRing extends CustomPainter {
  _StateRing(this.counts, this.colors, this.track);
  final List<int> counts;
  final List<Color> colors;
  final Color track;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(9);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12;
    canvas.drawOval(rect, paint..color = track);
    final total = counts.fold<int>(0, (a, b) => a + b);
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
  bool shouldRepaint(covariant _StateRing oldDelegate) => true;
}
