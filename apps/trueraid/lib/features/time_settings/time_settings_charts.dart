import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

String pollSeconds(int exponent) => exponent >= 4 && exponent <= 17
    ? '${1 << exponent} seconds'
    : 'Outside supported chart/editor range';
bool supportedPolling(NtpServerSettings settings) =>
    settings.minPoll >= 4 &&
    settings.minPoll < settings.maxPoll &&
    settings.maxPoll <= 17;

class TimeSettingsCharts extends StatelessWidget {
  const TimeSettingsCharts({required this.servers, super.key});
  final List<NtpServerSnapshot> servers;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme,
        preferred = servers.where((server) => server.settings.prefer).length;
    final maxExponent = servers
        .where((server) => supportedPolling(server.settings))
        .fold<int>(1, (max, server) => math.max(max, server.settings.maxPoll));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TdPanel(
          title: 'Configured source preference',
          description: 'Configured flags, not accuracy. DHCP/files may add other sources.',
          child: LayoutBuilder(
            builder: (context, constraints) => Wrap(
              spacing: 24,
              runSpacing: 16,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Semantics(
                  label:
                      '$preferred preferred and ${servers.length - preferred} not preferred NTP sources. Configuration only.',
                  child: ExcludeSemantics(
                    child: SizedBox(
                      width: 112,
                      height: 112,
                      child: CustomPaint(
                        key: const Key('time-preference-ring'),
                        painter: _PreferenceRing(
                          preferred,
                          servers.length,
                          colors.primary,
                          colors.tertiary,
                          colors.outlineVariant,
                        ),
                        child: Center(
                          child: Padding(
                            padding: const EdgeInsets.all(20),
                            child: FittedBox(
                              child: Text(
                                '${servers.length}',
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
                  width: math.min(240, constraints.maxWidth),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _Legend(
                        color: colors.primary,
                        label: '$preferred Preferred',
                      ),
                      const SizedBox(height: 8),
                      _Legend(
                        color: colors.tertiary,
                        label: '${servers.length - preferred} Not preferred',
                      ),
                      if (servers.isEmpty)
                        const Text(
                          'No configured sources; no percentage is inferred.',
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
          title: 'Configured polling bounds',
          description: 'Bar lengths are configured exponents on a log₂-seconds scale. They are not observed polling, delay, offset, reachability or health.',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _Legend(color: colors.primary, label: 'Minimum exponent'),
              _Legend(color: colors.tertiary, label: 'Maximum exponent'),
              if (servers.isEmpty) const Text('No configured polling bounds.'),
              for (final server in servers)
                Padding(
                  padding: const EdgeInsets.only(top: 16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Text(server.settings.address),
                      Text(
                        'Min ${server.settings.minPoll} → ${pollSeconds(server.settings.minPoll)}; max ${server.settings.maxPoll} → ${pollSeconds(server.settings.maxPoll)}',
                      ),
                      if (!supportedPolling(server.settings))
                        const Text(
                          'Outside supported chart/editor range — raw exponents retained; bars omitted.',
                        )
                      else ...[
                        _Bar(
                          key: Key('time-poll-min-${server.id}'),
                          value: server.settings.minPoll / maxExponent,
                          color: colors.primary,
                        ),
                        const SizedBox(height: 4),
                        _Bar(
                          key: Key('time-poll-max-${server.id}'),
                          value: server.settings.maxPoll / maxExponent,
                          color: colors.tertiary,
                        ),
                      ],
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

class _Bar extends StatelessWidget {
  const _Bar({required this.value, required this.color, super.key});
  final double value;
  final Color color;
  @override
  Widget build(BuildContext context) => ExcludeSemantics(
    child: SizedBox(
      height: 10,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.outlineVariant,
        ),
        child: Align(
          alignment: Alignment.centerLeft,
          child: FractionallySizedBox(
            widthFactor: value.clamp(0, 1),
            heightFactor: 1,
            child: ColoredBox(color: color),
          ),
        ),
      ),
    ),
  );
}

class _PreferenceRing extends CustomPainter {
  const _PreferenceRing(
    this.preferred,
    this.total,
    this.active,
    this.other,
    this.track,
  );
  final int preferred, total;
  final Color active, other, track;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = (Offset.zero & size).deflate(6),
        paint = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 10;
    canvas.drawOval(rect, paint..color = total == 0 ? track : other);
    if (total > 0 && preferred > 0) {
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * preferred / total,
        false,
        paint..color = active,
      );
    }
  }

  @override
  bool shouldRepaint(_PreferenceRing old) =>
      old.preferred != preferred ||
      old.total != total ||
      old.active != active ||
      old.other != other ||
      old.track != track;
}
