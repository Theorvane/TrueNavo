import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:truenas_api/truenas_api.dart';

import 'nvme_overview.dart';

/// Saved NVMe-oF inventory only. These rings do not attest client paths,
/// listener availability or actual data-integrity protection.
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
    final tcpPorts = value.ports.where((p) => p.transport == 'TCP').length;
    final rdmaPorts = value.ports.where((p) => p.transport == 'RDMA').length;
    final fcPorts = value.ports.where((p) => p.transport == 'FC').length;
    final zvolNamespaces = value.namespaces
        .where((n) => n.deviceType == 'ZVOL')
        .length;
    final fileNamespaces = value.namespaces
        .where((n) => n.deviceType == 'FILE')
        .length;
    final portPiOn = value.ports
        .where((p) => p.piReported && p.piEnable == true)
        .length;
    final portPiOff = value.ports
        .where((p) => p.piReported && p.piEnable == false)
        .length;
    final portPiDefault = value.ports
        .where((p) => p.piReported && p.piEnable == null)
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
              unit: 'subsystems',
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
              unit: 'subsystems',
              labels: const ['on', 'off', 'server default', 'not returned'],
              counts: [
                piOn,
                piOff,
                piDefault,
                value.subsystems.length - piOn - piOff - piDefault,
              ],
            ),
            _SettingDonut(
              chartKey: Key('$keyPrefix-port-transport-donut'),
              title: 'Port transports',
              unit: 'ports',
              labels: const ['TCP', 'RDMA', 'FC'],
              counts: [tcpPorts, rdmaPorts, fcPorts],
            ),
            _SettingDonut(
              chartKey: Key('$keyPrefix-namespace-type-donut'),
              title: 'Namespace types',
              unit: 'namespaces',
              labels: const ['ZVOL', 'FILE'],
              counts: [zvolNamespaces, fileNamespaces],
            ),
            _SettingDonut(
              chartKey: Key('$keyPrefix-port-pi-donut'),
              title: 'Port PI',
              unit: 'ports',
              labels: const ['on', 'off', 'server default', 'not returned'],
              counts: [
                portPiOn,
                portPiOff,
                portPiDefault,
                value.ports.length - portPiOn - portPiOff - portPiDefault,
              ],
            ),
          ],
        ),
        const SizedBox(height: 8),
        const Text(
          'Rings summarize returned saved configuration, including disabled ports and namespaces. They do not verify listener health, client access or data protection.',
        ),
      ],
    );
  }
}

/// Counts only returned metadata, never authentication success or key validity.
class NvmeHostAuthenticationCharts extends StatelessWidget {
  const NvmeHostAuthenticationCharts({required this.value, super.key});
  final NvmeHostAuthenticationInventory value;

  @override
  Widget build(BuildContext context) {
    final hosts = value.hosts;
    final inconsistent = hosts.where((h) => h.inconsistent).length;
    final both = hosts
        .where(
          (h) =>
              !h.inconsistent && h.hostKeyReturned && h.controllerKeyReturned,
        )
        .length;
    final hostOnly = hosts
        .where(
          (h) =>
              !h.inconsistent && h.hostKeyReturned && !h.controllerKeyReturned,
        )
        .length;
    return Wrap(
      spacing: 16,
      runSpacing: 16,
      children: [
        _SettingDonut(
          chartKey: const Key('nvme-host-auth-presence-donut'),
          title: 'Returned key metadata',
          unit: 'hosts',
          labels: const [
            'keys returned unset',
            'host key returned',
            'both keys returned',
            'inconsistent fields',
          ],
          counts: [
            hosts.length - inconsistent - both - hostOnly,
            hostOnly,
            both,
            inconsistent,
          ],
        ),
        _SettingDonut(
          chartKey: const Key('nvme-host-auth-hash-donut'),
          title: 'Saved hash setting',
          unit: 'hosts',
          labels: const ['SHA-256', 'SHA-384', 'SHA-512'],
          counts: [
            for (final hash in ['SHA-256', 'SHA-384', 'SHA-512'])
              hosts.where((h) => h.hash == hash).length,
          ],
        ),
        _SettingDonut(
          chartKey: const Key('nvme-host-auth-group-donut'),
          title: 'Saved DH group setting',
          unit: 'hosts',
          labels: const ['group returned', 'group returned unset'],
          counts: [
            hosts.where((h) => h.group != null).length,
            hosts.where((h) => h.group == null).length,
          ],
        ),
      ],
    );
  }
}

class _SettingDonut extends StatelessWidget {
  const _SettingDonut({
    required this.chartKey,
    required this.title,
    required this.unit,
    required this.labels,
    required this.counts,
  });

  final Key chartKey;
  final String title;
  final String unit;
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
            label: '$title among $total returned $unit: $detail',
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
