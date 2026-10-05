import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

class NfsSettingsCharts extends StatelessWidget {
  const NfsSettingsCharts({required this.inventory, super.key});
  final NfsSettingsInventory inventory;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final services = inventory.exports;
    final enabled = services.where((s) => s.enabled).length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TdPanel(
          title: 'Configured export enablement',
          description: 'Configuration only — NFS may be stopped; enabled is not accessible.',
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 24,
              runSpacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Semantics(
                  label:
                      '$enabled enabled and ${services.length - enabled} disabled configured exports. No access measurements.',
                  child: ExcludeSemantics(
                    child: SizedBox(
                      width: 112,
                      height: 112,
                      child: CustomPaint(
                        key: const Key('nfs-enablement-ring'),
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
                          'No configured exports; no percentage or access status is inferred.',
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
          title: 'Configured server threads',
          description: 'Reported configuration count — not active workers, utilization or throughput.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${inventory.config.reportedServers} ${inventory.config.managedNfsd ? 'automatically chosen' : 'manually configured'}',
              ),
              const Text(
                'Scale: 0–256 threads (manual API limit); automatic tuning is 1–32.',
              ),
              const SizedBox(height: 8),
              Semantics(
                label:
                    '${inventory.config.reportedServers} configured threads on a zero to 256 count scale.',
                child: ExcludeSemantics(
                  child: SizedBox(
                    height: 12,
                    child: ColoredBox(
                      color: colors.outlineVariant,
                      child: Align(
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          key: const Key('nfs-thread-bar'),
                          widthFactor: inventory.config.reportedServers / 256,
                          heightFactor: 1,
                          child: ColoredBox(color: colors.primary),
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
