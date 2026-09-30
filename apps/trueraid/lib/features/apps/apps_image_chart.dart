import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

/// An on-demand snapshot of Docker image metadata, not reclaimable space.
class AppsImageChart extends StatelessWidget {
  const AppsImageChart({required this.images, super.key});
  final List<AppImageEntry> images;

  @override
  Widget build(BuildContext context) {
    final td = context.tdTheme;
    final dangling = images.where((image) => image.dangling).length;
    final tagged = images.length - dangling;
    final updates = images.where((image) => image.updateAvailable).length;
    final bytes = images.fold<int>(0, (sum, image) => sum + image.sizeBytes);
    return TdPanel(
      title: 'Docker image inventory',
      description: 'Point-in-time image metadata. Dangling does not prove unused or safe to delete.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 20,
            runSpacing: 12,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                label:
                    '${images.length} images; $tagged tagged, $dangling dangling.',
                child: ExcludeSemantics(
                  child: SizedBox(
                    width: 120,
                    height: 120,
                    child: CustomPaint(
                      painter: _ImageRing(
                        tagged,
                        dangling,
                        td.statusSuccess,
                        td.statusWarning,
                        td.borderSubtle,
                      ),
                      child: Center(
                        child: Text(
                          '${images.length}',
                          style: TdTypography.metricMedium,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              SizedBox(
                width: 240,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('Tagged · $tagged'),
                    Text('Dangling · $dangling'),
                    Text('Updates available · $updates'),
                    Text('Sum of image sizes · ${_formatBytes(bytes)}'),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (images.isEmpty) const Text('No Docker images returned.'),
          for (final image in images)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 5),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    image.tags.isEmpty
                        ? 'Untagged image'
                        : image.tags.join(', '),
                  ),
                  Text(
                    '${image.id} · ${_formatBytes(image.sizeBytes)}'
                    '${image.updateAvailable ? ' · Update available' : ''}',
                    style: TdTypography.metadata,
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  var value = bytes.toDouble();
  var index = -1;
  do {
    value /= 1024;
    index++;
  } while (value >= 1024 && index < units.length - 1);
  return '${value.toStringAsFixed(1)} ${units[index]}';
}

class _ImageRing extends CustomPainter {
  _ImageRing(
    this.tagged,
    this.dangling,
    this.taggedColor,
    this.danglingColor,
    this.track,
  );
  final int tagged;
  final int dangling;
  final Color taggedColor;
  final Color danglingColor;
  final Color track;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(9);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 12;
    canvas.drawOval(rect, paint..color = track);
    final total = tagged + dangling;
    if (total == 0) return;
    final first = tagged / total * 2 * math.pi;
    if (tagged > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        first,
        false,
        paint..color = taggedColor,
      );
    }
    if (dangling > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2 + first,
        2 * math.pi - first,
        false,
        paint..color = danglingColor,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ImageRing oldDelegate) =>
      tagged != oldDelegate.tagged ||
      dangling != oldDelegate.dangling ||
      taggedColor != oldDelegate.taggedColor ||
      danglingColor != oldDelegate.danglingColor ||
      track != oldDelegate.track;
}
