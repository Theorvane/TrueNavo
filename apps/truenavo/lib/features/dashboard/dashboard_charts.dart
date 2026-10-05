import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import 'dashboard_repository.dart';

/// Current server measurements only. Each pool keeps its own denominator and
/// alert proportions use complete response counts, not the bounded alert list.
class DashboardCharts extends StatelessWidget {
  const DashboardCharts({required this.home, super.key});

  final DashboardHome home;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final wide =
          constraints.maxWidth >= 900 &&
          MediaQuery.textScalerOf(context).scale(16) <= 24;
      final storage = _PoolCharts(home: home);
      final alerts = _AlertChart(home: home);
      if (!wide) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            storage,
            const SizedBox(height: TdSpacing.component),
            alerts,
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(flex: 2, child: storage),
          const SizedBox(width: TdSpacing.component),
          Expanded(child: alerts),
        ],
      );
    },
  );
}

class _PoolCharts extends StatelessWidget {
  const _PoolCharts({required this.home});

  final DashboardHome home;

  @override
  Widget build(BuildContext context) => TdPanel(
    title: 'Storage capacity',
    description: 'Used and available space in each pool.',
    child: !home.poolsAvailable
        ? const _ChartEmpty(
            icon: Icons.storage_outlined,
            message: 'Pool capacity is unavailable on this server.',
          )
        : home.pools.isEmpty
        ? const _ChartEmpty(
            icon: Icons.storage_outlined,
            message: 'No storage pools were provided by the server.',
          )
        : LayoutBuilder(
            builder: (context, constraints) {
              final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
              final columns = constraints.maxWidth >= 560 * textScale ? 2 : 1;
              final width =
                  (constraints.maxWidth - (columns - 1) * TdSpacing.related) /
                  columns;
              return Wrap(
                spacing: TdSpacing.related,
                runSpacing: TdSpacing.related,
                children: [
                  for (final pool in home.pools)
                    SizedBox(
                      width: width,
                      child: _PoolChart(pool: pool),
                    ),
                ],
              );
            },
          ),
  );
}

class _PoolChart extends StatelessWidget {
  const _PoolChart({required this.pool});

  final DashboardPool pool;

  @override
  Widget build(BuildContext context) {
    final td = context.tdTheme;
    final candidate = pool.capacityPercent;
    final used =
        candidate != null &&
            candidate.isFinite &&
            candidate >= 0 &&
            candidate <= 100
        ? candidate
        : null;
    final statusColor = switch (pool.statusKind) {
      DashboardStatus.critical => td.statusCritical,
      DashboardStatus.warning => td.statusWarning,
      DashboardStatus.success => td.statusSuccess,
      DashboardStatus.info => td.statusInfo,
      DashboardStatus.stale => td.statusStaleForeground,
      DashboardStatus.neutral => td.textSecondary,
    };
    final summary = used == null
        ? '${pool.name}: capacity unavailable. ${pool.status}.'
        : '${pool.name}: ${_percent(used)} used, '
              '${_percent(100 - used)} available. ${pool.status}.';
    return Semantics(
      container: true,
      label: summary,
      child: ExcludeSemantics(
        child: Container(
          padding: const EdgeInsets.all(TdSpacing.component),
          decoration: BoxDecoration(
            color: td.surfaceRaised,
            borderRadius: BorderRadius.circular(TdRadius.control),
            border: Border.all(color: td.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(pool.name, style: TdTypography.titleSmall),
              const SizedBox(height: TdSpacing.inlineTight),
              Text(
                pool.status,
                style: TdTypography.metadata.copyWith(color: statusColor),
              ),
              const SizedBox(height: TdSpacing.component),
              _ChartWithLegend(
                chart: _Donut(
                  segments: [
                    if (used != null)
                      (fraction: used / 100, color: td.actionPrimary),
                  ],
                  center: Text(
                    used == null ? '—' : _percent(used),
                    style: TdTypography.metricMedium,
                  ),
                ),
                legend: used == null
                    ? Text(
                        'Capacity unavailable',
                        style: TdTypography.body.copyWith(
                          color: td.textSecondary,
                        ),
                      )
                    : Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _Legend(
                            color: td.actionPrimary,
                            label: '${_percent(used)} used',
                          ),
                          const SizedBox(height: TdSpacing.inline),
                          _Legend(
                            color: td.borderControl,
                            label: '${_percent(100 - used)} available',
                          ),
                        ],
                      ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AlertChart extends StatelessWidget {
  const _AlertChart({required this.home});

  final DashboardHome home;

  @override
  Widget build(BuildContext context) {
    final td = context.tdTheme;
    final total = home.activeAlertCount;
    final critical = home.criticalAlertCount;
    final warning = home.warningAlertCount;
    // An incomplete or inconsistent response must never become a zero-alert
    // healthy state, or a chart calculated from the shorter visible list.
    final complete =
        home.alertsAvailable &&
        total != null &&
        critical != null &&
        warning != null &&
        total >= 0 &&
        critical >= 0 &&
        warning >= 0 &&
        critical + warning <= total;
    if (!complete) {
      return TdPanel(
        title: 'Alert distribution',
        child: _ChartEmpty(
          icon: Icons.notifications_none_rounded,
          message: home.alertsAvailable
              ? 'Alert severity is unavailable.'
              : 'Alerts are unavailable on this server.',
        ),
      );
    }
    final other = total - critical - warning;
    final summary = total == 0
        ? 'No active alerts.'
        : '$total active alerts: $critical critical, $warning warning, $other other.';
    return TdPanel(
      title: 'Alert distribution',
      description: 'All active alerts, grouped by severity.',
      child: Semantics(
        container: true,
        label: summary,
        child: ExcludeSemantics(
          child: _ChartWithLegend(
            chart: _Donut(
              segments: [
                if (total > 0) ...[
                  (fraction: critical / total, color: td.statusCritical),
                  (fraction: warning / total, color: td.statusWarning),
                  (fraction: other / total, color: td.statusInfo),
                ],
              ],
              center: Icon(
                total == 0
                    ? Icons.check_rounded
                    : Icons.notifications_active_outlined,
                size: 32,
                color: total == 0 ? td.statusSuccess : td.textSecondary,
              ),
            ),
            legend: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  total == 0 ? 'No active alerts' : '$total active alerts',
                  style: TdTypography.titleSmall,
                ),
                const SizedBox(height: TdSpacing.related),
                _Legend(color: td.statusCritical, label: '$critical critical'),
                const SizedBox(height: TdSpacing.inline),
                _Legend(color: td.statusWarning, label: '$warning warning'),
                const SizedBox(height: TdSpacing.inline),
                _Legend(color: td.statusInfo, label: '$other other'),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _ChartWithLegend extends StatelessWidget {
  const _ChartWithLegend({required this.chart, required this.legend});

  final Widget chart;
  final Widget legend;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
      if (constraints.maxWidth >= 280 && scale <= 1.3) {
        return Row(
          children: [
            chart,
            const SizedBox(width: TdSpacing.component),
            Expanded(child: legend),
          ],
        );
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Center(child: chart),
          const SizedBox(height: TdSpacing.component),
          legend,
        ],
      );
    },
  );
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
        padding: const EdgeInsets.only(top: 5),
        child: Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
      ),
      const SizedBox(width: TdSpacing.inline),
      Expanded(child: Text(label, style: TdTypography.body)),
    ],
  );
}

class _ChartEmpty extends StatelessWidget {
  const _ChartEmpty({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: TdSpacing.component),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: context.tdTheme.textMuted, size: 28),
        const SizedBox(height: TdSpacing.related),
        Text(
          message,
          style: TdTypography.body.copyWith(
            color: context.tdTheme.textSecondary,
          ),
        ),
      ],
    ),
  );
}

class _Donut extends StatelessWidget {
  const _Donut({required this.segments, required this.center});

  final List<({double fraction, Color color})> segments;
  final Widget center;

  @override
  Widget build(BuildContext context) {
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final diameter = 112 * scale.clamp(1.0, 1.7);
    return SizedBox.square(
      dimension: diameter,
      child: CustomPaint(
        painter: _DonutPainter(
          trackColor: context.tdTheme.borderControl,
          segments: segments,
        ),
        child: Center(child: center),
      ),
    );
  }
}

class _DonutPainter extends CustomPainter {
  const _DonutPainter({required this.trackColor, required this.segments});

  final Color trackColor;
  final List<({double fraction, Color color})> segments;

  @override
  void paint(Canvas canvas, Size size) {
    final stroke = math.min(size.width, size.height) * .095;
    final bounds = (Offset.zero & size).deflate(stroke / 2);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke
      ..color = trackColor;
    canvas.drawOval(bounds, paint);
    var start = -math.pi / 2;
    for (final segment in segments) {
      final sweep = segment.fraction * 2 * math.pi;
      if (sweep > 0) {
        paint.color = segment.color;
        canvas.drawArc(bounds, start, sweep, false, paint);
      }
      start += sweep;
    }
  }

  @override
  bool shouldRepaint(covariant _DonutPainter oldDelegate) =>
      trackColor != oldDelegate.trackColor ||
      segments.length != oldDelegate.segments.length ||
      !Iterable<int>.generate(segments.length)
          .every((index) => segments[index] == oldDelegate.segments[index]);
}

String _percent(double value) =>
    '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)}%';
