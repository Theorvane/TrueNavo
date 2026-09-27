import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';

import 'nvme_overview.dart';

/// Saved subsystem settings only. These rings do not attest client paths or
/// actual data-integrity protection.
class NvmeSettingCharts extends StatelessWidget {
  const NvmeSettingCharts({
    required this.value,
    required this.keyPrefix,
    super.key,
  });

  final NvmeOverview value;
  final String keyPrefix;

  @override
  Widget build(BuildContext context) {
    final anaOn = value.subsystems
        .where((s) => s.anaReported && s.ana == true)
        .length;
    final anaOff = value.subsystems
        .where((s) => s.anaReported && s.ana == false)
        .length;
    final anaInherited = value.subsystems
        .where((s) => s.anaReported && s.ana == null)
        .length;
    final piOn = value.subsystems
        .where((s) => s.piReported && s.piEnable == true)
        .length;
    final piOff = value.subsystems
        .where((s) => s.piReported && s.piEnable == false)
        .length;
    final piDefault = value.subsystems
        .where((s) => s.piReported && s.piEnable == null)
        .length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          spacing: 24,
          runSpacing: 16,
          children: [
            _SettingDonut(
              chartKey: Key('$keyPrefix-ana-donut'),
              title: 'ANA',
              labels: const ['on', 'off', 'inherit', 'not returned'],
              counts: [
                anaOn,
                anaOff,
                anaInherited,
                value.subsystems.length - anaOn - anaOff - anaInherited,
              ],
            ),
            _SettingDonut(
              chartKey: Key('$keyPrefix-pi-donut'),
              title: 'PI',
              labels: const ['on', 'off', 'server default', 'not returned'],
              counts: [
                piOn,
                piOff,
                piDefault,
                value.subsystems.length - piOn - piOff - piDefault,
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'ANA and PI rings summarize saved settings, not listener health, client access or verified data protection.',
        ),
      ],
    );
  }
}

class _SettingDonut extends StatelessWidget {
  const _SettingDonut({
    required this.chartKey,
    required this.title,
    required this.labels,
    required this.counts,
  });

  final Key chartKey;
  final String title;
  final List<String> labels;
  final List<int> counts;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final total = counts.fold<int>(0, (sum, count) => sum + count);
    final segmentColors = [
      colors.primary,
      colors.secondary,
      colors.tertiary,
      colors.outlineVariant,
    ];
    final detail = [
      for (var index = 0; index < counts.length; index++)
        '${labels[index]} ${counts[index]}',
    ].join(', ');
    return SizedBox(
      width: 230,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          Semantics(
            label:
                '$title saved settings among $total returned subsystems: $detail',
            child: SizedBox.square(
              dimension: 112,
              child: CustomPaint(
                key: chartKey,
                painter: _SettingsDonutPainter(
                  counts: counts,
                  colors: segmentColors,
                  track: colors.surfaceContainerHighest,
                ),
                child: Center(
                  child: Text(
                    '$total',
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(height: 8),
          for (var index = 0; index < counts.length; index++)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Row(
                children: [
                  Container(width: 10, height: 10, color: segmentColors[index]),
                  const SizedBox(width: 6),
                  Expanded(child: Text('${labels[index]}: ${counts[index]}')),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _SettingsDonutPainter extends CustomPainter {
  const _SettingsDonutPainter({
    required this.counts,
    required this.colors,
    required this.track,
  });

  final List<int> counts;
  final List<Color> colors;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final total = counts.fold<int>(0, (sum, count) => sum + count);
    final stroke = math.min(size.width, size.height) * .095;
    final bounds = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = track;
    canvas.drawOval(bounds, paint);
    if (total == 0) return;
    var start = -math.pi / 2;
    for (var index = 0; index < counts.length; index++) {
      final sweep = counts[index] / total * 2 * math.pi;
      if (sweep > 0) {
        paint.color = colors[index];
        canvas.drawArc(bounds, start, sweep, false, paint);
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _SettingsDonutPainter oldDelegate) =>
      track != oldDelegate.track ||
      !listEquals(counts, oldDelegate.counts) ||
      !listEquals(colors, oldDelegate.colors);
}
