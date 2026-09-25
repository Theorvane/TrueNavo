import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

class RsyncConfigurationChart extends StatelessWidget {
  const RsyncConfigurationChart({
    required this.enabled,
    required this.disabled,
    super.key,
  });
  final int enabled, disabled;
  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return TdPanel(
      title: 'Configured Rsync enablement',
      description: 'Enabled tasks are not running transfers. Counts do not prove destination contents or recoverability.',
      child: Wrap(
        spacing: 24,
        runSpacing: 16,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          Semantics(
            label:
                '$enabled enabled Rsync tasks, $disabled disabled Rsync tasks',
            child: ExcludeSemantics(
              child: SizedBox(
                width: 124,
                height: 124,
                child: CustomPaint(
                  key: const Key('rsync-schedule-donut'),
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
                label: '$enabled Enabled tasks',
                dotKey: const Key('rsync-enabled-color'),
              ),
              _Legend(
                color: colors.tertiary,
                label: '$disabled Disabled tasks',
                dotKey: const Key('rsync-disabled-color'),
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

enum RsyncReportedState {
  succeeded('Reported success'),
  failed('Reported failure'),
  aborted('Reported aborted'),
  running('Reported running'),
  waiting('Reported waiting'),
  unknown('Unknown / no reported job');

  const RsyncReportedState(this.label);
  final String label;
}

class RsyncReportedStates extends StatelessWidget {
  const RsyncReportedStates({required this.states, super.key});
  final Map<RsyncReportedState, int> states;
  @override
  Widget build(BuildContext context) {
    final total = states.values.fold<int>(0, (a, b) => a + b);
    final colors = Theme.of(context).colorScheme;
    return TdPanel(
      title: 'Last recorded job states (may be stale)',
      description: 'A prior job state is not live activity, a content comparison or backup integrity. No automatic job checks or refresh.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (total == 0) const Text('No task states in the loaded inventory.'),
          for (final state in RsyncReportedState.values)
            if ((states[state] ?? 0) > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('${state.label}: ${states[state]}'),
                    Semantics(
                      label:
                          '${state.label}, ${states[state]} of $total loaded tasks',
                      child: LinearProgressIndicator(
                        key: Key('rsync-state-${state.name}'),
                        minHeight: 10,
                        value: states[state]! / total,
                        color: switch (state) {
                          RsyncReportedState.failed ||
                          RsyncReportedState.aborted => colors.error,
                          RsyncReportedState.running => colors.tertiary,
                          RsyncReportedState.waiting => colors.secondary,
                          RsyncReportedState.unknown => colors.outline,
                          RsyncReportedState.succeeded => colors.primary,
                        },
                      ),
                    ),
                  ],
                ),
              ),
        ],
      ),
    );
  }
}
