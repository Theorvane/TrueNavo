import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

import 'live_metrics_controller.dart';
import '../offline_demo/offline_demo_mode.dart';

final _coreNamePattern = RegExp(r'^cpu[0-9]+$');

/// Mounting subscribes once. Leaving the route/app or hiding this dashboard
/// widget cancels the event source; returning starts a fresh window.
class DashboardLiveMetrics extends ConsumerStatefulWidget {
  const DashboardLiveMetrics({super.key});
  @override
  ConsumerState<DashboardLiveMetrics> createState() =>
      _DashboardLiveMetricsState();
}

class _DashboardLiveMetricsState extends ConsumerState<DashboardLiveMetrics>
    with WidgetsBindingObserver {
  bool _visible = false;
  bool _manualPause = false;
  bool _foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _foreground =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final visible =
        TickerMode.valuesOf(context).enabled &&
        (ModalRoute.isCurrentOf(context) ?? true);
    if (_visible != visible) {
      _visible = visible;
      _sync();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    // Background apps may receive no more frames; cancel immediately.
    if (!_foreground || !_visible || _manualPause) {
      ref.read(liveMetricsControllerProvider.notifier).pause();
    } else {
      unawaited(ref.read(liveMetricsControllerProvider.notifier).start());
    }
  }

  void _sync() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final controller = ref.read(liveMetricsControllerProvider.notifier);
      if (_visible && _foreground && !_manualPause) {
        unawaited(controller.start());
      } else {
        controller.pause();
      }
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(liveMetricsControllerProvider);
    final demo = ref.watch(offlineDemoModeProvider);
    final running =
        state.phase == LiveMetricsPhase.live ||
        state.phase == LiveMetricsPhase.connecting;
    return TdPanel(
      title: demo ? 'Sample performance' : 'Live performance',
      description: demo
          ? 'Generated offline samples · not server measurements'
          : 'Server events · 2-second interval · up to 60 received samples',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 12,
            runSpacing: 8,
            children: [
              Text(switch (state.phase) {
                LiveMetricsPhase.live => demo ? '● Sample' : '● Live',
                LiveMetricsPhase.connecting =>
                  demo ? 'Loading samples…' : 'Connecting…',
                LiveMetricsPhase.paused => 'Paused',
                LiveMetricsPhase.unavailable => 'Unavailable',
                LiveMetricsPhase.idle => 'Ready',
              }, style: Theme.of(context).textTheme.titleMedium),
              OutlinedButton.icon(
                key: const Key('live-metrics-toggle'),
                onPressed: () {
                  _manualPause = running;
                  if (running) {
                    ref.read(liveMetricsControllerProvider.notifier).pause();
                  } else {
                    _sync();
                  }
                },
                icon: Icon(running ? Icons.pause : Icons.play_arrow),
                label: Text(running ? 'Pause' : 'Resume'),
              ),
            ],
          ),
          if (state.endpoint != null) ...[
            const SizedBox(height: 8),
            Text(state.endpoint!, style: Theme.of(context).textTheme.bodySmall),
          ],
          if (state.message != null) ...[
            const SizedBox(height: 12),
            Text(state.message!),
          ],
          if (state.phase == LiveMetricsPhase.connecting)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 16),
              child: LinearProgressIndicator(),
            ),
          if (state.latest case final sample?) ...[
            const SizedBox(height: 16),
            LiveMetricsCharts(samples: state.samples),
            const SizedBox(height: 12),
            Text(
              'Received ${sample.receivedAt.toUtc().toIso8601String()} · client UTC time',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
          const SizedBox(height: 12),
          Text(
            'Charts use arrival times; this event has no server timestamps. Gaps are not filled. TrueNAS may report zero when its upstream metric is unavailable.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}

class LiveMetricsCharts extends StatelessWidget {
  const LiveMetricsCharts({required this.samples, super.key});
  final List<RealtimeSample> samples;
  @override
  Widget build(BuildContext context) {
    if (samples.isEmpty) return const Text('Waiting for server measurements.');
    final latest = samples.last;
    final colors = Theme.of(context).colorScheme;
    final cpu = latest.cpu['cpu'];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _ChartSection(
          title: 'CPU',
          value: _value(cpu?.usage, '%'),
          child: LiveSparkline(
            samples: samples,
            select: (s) => s.cpu['cpu']?.usage,
            color: colors.primary,
            maximum: 100,
            formatValue: (value) => '${_compact(value)}%',
            label: 'Aggregate CPU usage percent',
          ),
        ),
        Wrap(
          spacing: 16,
          runSpacing: 8,
          children: [
            Text('CPU temperature ${_value(cpu?.temperature, '°C')}'),
            Text(
              '${latest.cpu.keys.where((key) => key != 'cpu').length} reported cores',
            ),
          ],
        ),
        _ChartSection(
          title: 'CPU temperature trend',
          value: _value(cpu?.temperature, '°C'),
          child: LiveSparkline(
            samples: samples,
            select: (s) => s.cpu['cpu']?.temperature,
            color: colors.secondary,
            label: 'Aggregate CPU temperature degrees Celsius',
            formatValue: (value) => '${_compact(value)} °C',
            allowNegative: true,
          ),
        ),
        _ChartSection(
          title: 'Hottest reported core trend',
          value: _value(hottestReportedCoreTemperature(latest), '°C'),
          child: LiveSparkline(
            samples: samples,
            select: hottestReportedCoreTemperature,
            color: colors.error,
            label: 'Hottest reported CPU core temperature degrees Celsius',
            formatValue: (value) => '${_compact(value)} °C',
            allowNegative: true,
          ),
        ),
        _PerCoreCpu(samples: samples),
        const Divider(height: 32),
        Text('Physical memory', style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 12),
        if (latest.memoryUnavailableBytes == null)
          const Text(
            'A consistent total and available amount is required for the memory chart.',
          )
        else
          Wrap(
            spacing: 20,
            runSpacing: 16,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                label:
                    'Physical memory: ${_bytes(latest.memoryAvailableBytes)} available, ${_bytes(latest.memoryUnavailableBytes)} not available',
                child: SizedBox(
                  width: 140,
                  height: 140,
                  child: CustomPaint(
                    painter: _MemoryPainter(
                      fraction:
                          latest.memoryAvailableBytes! /
                          latest.memoryTotalBytes!,
                      available: colors.tertiary,
                      unavailable: colors.primary,
                    ),
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('Total  ${_bytes(latest.memoryTotalBytes)}'),
                  Text('Available  ${_bytes(latest.memoryAvailableBytes)}'),
                  Text(
                    'Not available  ${_bytes(latest.memoryUnavailableBytes)}',
                  ),
                  Text('ARC cache  ${_bytes(latest.arcSizeBytes)}'),
                ],
              ),
            ],
          ),
        const SizedBox(height: 8),
        const Text(
          'Available includes reclaimable memory. ARC is shown separately, not added to the doughnut.',
        ),
        _ChartSection(
          title: 'Available memory trend',
          value: _value(memoryAvailablePercent(latest), '%'),
          child: LiveSparkline(
            samples: samples,
            select: memoryAvailablePercent,
            color: colors.tertiary,
            maximum: 100,
            formatValue: (value) => '${_compact(value)}%',
            label: 'Physical memory available percent',
          ),
        ),
        _ChartSection(
          title: 'ARC cache trend',
          value: _bytes(latest.arcSizeBytes),
          child: LiveSparkline(
            samples: samples,
            select: (s) => s.arcSizeBytes,
            color: colors.secondary,
            formatValue: _bytes,
            label: 'ZFS ARC cache bytes',
          ),
        ),
        const Divider(height: 32),
        _ChartSection(
          title: 'Disk throughput · all disks',
          value: 'Read ${_rate(latest.diskReadBytesPerSecond)}',
          child: LiveSparkline(
            samples: samples,
            select: (s) => s.diskReadBytesPerSecond,
            color: colors.primary,
            label: 'Aggregate disk read bytes per second',
            formatValue: _rate,
          ),
        ),
        _ChartSection(
          title: 'Disk writes',
          value: _rate(latest.diskWriteBytesPerSecond),
          child: LiveSparkline(
            samples: samples,
            select: (s) => s.diskWriteBytesPerSecond,
            color: colors.tertiary,
            label: 'Aggregate disk write bytes per second',
            formatValue: _rate,
          ),
        ),
        Text(
          'Read ${_value(latest.diskReadOpsPerSecond, 'IOPS')} · Write ${_value(latest.diskWriteOpsPerSecond, 'IOPS')} · Average busy ${_value(latest.diskBusyPercent, '%')}',
        ),
        _ChartSection(
          title: 'Disk read operations',
          value: _value(latest.diskReadOpsPerSecond, 'IOPS'),
          child: LiveSparkline(
            samples: samples,
            select: (s) => s.diskReadOpsPerSecond,
            color: colors.primary,
            label: 'Aggregate disk read operations per second',
          ),
        ),
        _ChartSection(
          title: 'Disk write operations',
          value: _value(latest.diskWriteOpsPerSecond, 'IOPS'),
          child: LiveSparkline(
            samples: samples,
            select: (s) => s.diskWriteOpsPerSecond,
            color: colors.tertiary,
            label: 'Aggregate disk write operations per second',
          ),
        ),
        _ChartSection(
          title: 'Average disk busy',
          value: _value(latest.diskBusyPercent, '%'),
          child: LiveSparkline(
            samples: samples,
            select: (s) => s.diskBusyPercent,
            color: colors.secondary,
            maximum: 100,
            formatValue: (value) => '${_compact(value)}%',
            label: 'Average disk busy percent',
          ),
        ),
        const Divider(height: 32),
        Text(
          'Network interfaces',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (latest.interfaces.isEmpty)
          const Text('No interface measurements reported.'),
        for (final entry in latest.interfaces.entries) ...[
          const SizedBox(height: 12),
          Text(
            '${entry.key} · ${switch (entry.value.linkUp) {
              true => 'Link up',
              false => 'Link down',
              null => 'Link unknown',
            }} · ${_value(entry.value.speedMbps, 'Mb/s')} link speed',
          ),
          _ChartSection(
            title: 'Receive',
            value: _rate(entry.value.receivedBytesPerSecond),
            child: LiveSparkline(
              samples: samples,
              select: (s) => s.interfaces[entry.key]?.receivedBytesPerSecond,
              color: colors.primary,
              label: '${entry.key} receive bytes per second',
              formatValue: _rate,
            ),
          ),
          _ChartSection(
            title: 'Send',
            value: _rate(entry.value.sentBytesPerSecond),
            child: LiveSparkline(
              samples: samples,
              select: (s) => s.interfaces[entry.key]?.sentBytesPerSecond,
              color: colors.tertiary,
              label: '${entry.key} send bytes per second',
              formatValue: _rate,
            ),
          ),
        ],
        const Divider(height: 32),
        Text(
          'ZFS ARC demand hits',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        Text(
          'Data ${_value(latest.arcDataHitPercent, '%')} · Metadata ${_value(latest.arcMetadataHitPercent, '%')}',
        ),
        const Text(
          'Separate request classes; these percentages are not slices of one total.',
        ),
        _ChartSection(
          title: 'Data hit trend',
          value: _value(latest.arcDataHitPercent, '%'),
          child: LiveSparkline(
            samples: samples,
            select: (s) => s.arcDataHitPercent,
            color: colors.primary,
            maximum: 100,
            formatValue: (value) => '${_compact(value)}%',
            label: 'ZFS ARC data demand hit percent',
          ),
        ),
        _ChartSection(
          title: 'Metadata hit trend',
          value: _value(latest.arcMetadataHitPercent, '%'),
          child: LiveSparkline(
            samples: samples,
            select: (s) => s.arcMetadataHitPercent,
            color: colors.tertiary,
            maximum: 100,
            formatValue: (value) => '${_compact(value)}%',
            label: 'ZFS ARC metadata demand hit percent',
          ),
        ),
        Material(
          type: MaterialType.transparency,
          child: ExpansionTile(
            title: const Text('Exact latest measurements'),
            tilePadding: EdgeInsets.zero,
            children: [
              SelectableText(
                [
                  'Client received UTC: ${latest.receivedAt.toUtc().toIso8601String()}',
                  'CPU aggregate (%): ${latest.cpu['cpu']?.usage ?? 'unavailable'}',
                  'CPU aggregate temperature (°C): ${latest.cpu['cpu']?.temperature ?? 'unavailable'}',
                  'Hottest reported CPU core temperature (°C): ${hottestReportedCoreTemperature(latest) ?? 'unavailable'}',
                  'Physical total (bytes): ${latest.memoryTotalBytes ?? 'unavailable'}',
                  'Physical available (bytes): ${latest.memoryAvailableBytes ?? 'unavailable'}',
                  'Physical available (%): ${memoryAvailablePercent(latest) ?? 'unavailable'}',
                  'ARC size (bytes): ${latest.arcSizeBytes ?? 'unavailable'}',
                  'Disk read (bytes/s): ${latest.diskReadBytesPerSecond ?? 'unavailable'}',
                  'Disk write (bytes/s): ${latest.diskWriteBytesPerSecond ?? 'unavailable'}',
                  'Disk read (IOPS): ${latest.diskReadOpsPerSecond ?? 'unavailable'}',
                  'Disk write (IOPS): ${latest.diskWriteOpsPerSecond ?? 'unavailable'}',
                  'Average disk busy (%): ${latest.diskBusyPercent ?? 'unavailable'}',
                  'ZFS ARC data hits (%): ${latest.arcDataHitPercent ?? 'unavailable'}',
                  'ZFS ARC metadata hits (%): ${latest.arcMetadataHitPercent ?? 'unavailable'}',
                  for (final e in latest.interfaces.entries)
                    '${e.key} receive/send (bytes/s): ${e.value.receivedBytesPerSecond ?? 'unavailable'} / ${e.value.sentBytesPerSecond ?? 'unavailable'}',
                ].join('\n'),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PerCoreCpu extends StatefulWidget {
  const _PerCoreCpu({required this.samples});
  final List<RealtimeSample> samples;
  @override
  State<_PerCoreCpu> createState() => _PerCoreCpuState();
}

class _PerCoreCpuState extends State<_PerCoreCpu> {
  String? _selectedCore;

  List<String> get _cores {
    final names = widget.samples.last.cpu.keys
        .where(_coreNamePattern.hasMatch)
        .toList();
    names.sort((a, b) {
      final left = int.tryParse(a.substring(3));
      final right = int.tryParse(b.substring(3));
      final byNumber = left == null || right == null
          ? a.compareTo(b)
          : left.compareTo(right);
      return byNumber == 0 ? a.compareTo(b) : byNumber;
    });
    return names;
  }

  @override
  void didUpdateWidget(covariant _PerCoreCpu oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_selectedCore != null && !_cores.contains(_selectedCore)) {
      _selectedCore = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    final cores = _cores;
    final selected = _selectedCore ?? cores.firstOrNull;
    final latest = selected == null ? null : widget.samples.last.cpu[selected];
    final colors = Theme.of(context).colorScheme;
    return Material(
      type: MaterialType.transparency,
      child: ExpansionTile(
        key: const Key('live-per-core-cpu'),
        title: const Text('Per-core CPU'),
        tilePadding: EdgeInsets.zero,
        children: [
          if (selected == null)
            const Text('No per-core measurements reported.')
          else ...[
            Text('Select a reported core to inspect its received history.'),
            _ChartSection(
              title: '$selected usage trend',
              value: _value(latest?.usage, '%'),
              child: LiveSparkline(
                key: ValueKey('live-core-usage-$selected'),
                samples: widget.samples,
                select: (sample) => sample.cpu[selected]?.usage,
                color: colors.primary,
                label: '$selected CPU usage percent',
                maximum: 100,
                formatValue: (value) => '${_compact(value)}%',
              ),
            ),
            _ChartSection(
              title: '$selected temperature trend',
              value: _value(latest?.temperature, '°C'),
              child: LiveSparkline(
                key: ValueKey('live-core-temperature-$selected'),
                samples: widget.samples,
                select: (sample) => sample.cpu[selected]?.temperature,
                color: colors.secondary,
                label: '$selected CPU temperature degrees Celsius',
                formatValue: (value) => '${_compact(value)} °C',
                allowNegative: true,
              ),
            ),
            for (final core in cores)
              ListTile(
                key: ValueKey('live-core-select-$core'),
                contentPadding: EdgeInsets.zero,
                selected: core == selected,
                title: Text(core),
                subtitle: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text(
                      'Usage ${_value(widget.samples.last.cpu[core]?.usage, '%')} · Temperature ${_value(widget.samples.last.cpu[core]?.temperature, '°C')}',
                    ),
                    if (widget.samples.last.cpu[core]?.usage case final usage?)
                      LinearProgressIndicator(
                        value: usage / 100,
                        semanticsLabel: '$core usage',
                        semanticsValue: _value(usage, '%'),
                      ),
                  ],
                ),
                trailing: core == selected ? const Icon(Icons.check) : null,
                onTap: () => setState(() => _selectedCore = core),
              ),
          ],
        ],
      ),
    );
  }
}

/// Report a percentage only when both quantities form the same valid sample.
/// ARC is deliberately not subtracted: reclaimable cache can be available.
double? memoryAvailablePercent(RealtimeSample sample) {
  final total = sample.memoryTotalBytes;
  final available = sample.memoryAvailableBytes;
  if (sample.memoryUnavailableBytes == null ||
      total == null ||
      available == null ||
      !total.isFinite ||
      !available.isFinite ||
      available < 0) {
    return null;
  }
  return available / total * 100;
}

/// Aggregate CPU temperature is a separate server series; do not use it as a
/// synthetic core or turn missing core sensors into zero.
double? hottestReportedCoreTemperature(RealtimeSample sample) {
  double? hottest;
  for (final entry in sample.cpu.entries) {
    if (!_coreNamePattern.hasMatch(entry.key)) {
      continue;
    }
    final temperature = entry.value.temperature;
    if (temperature == null || !temperature.isFinite) continue;
    hottest = hottest == null ? temperature : math.max(hottest, temperature);
  }
  return hottest;
}

class _ChartSection extends StatelessWidget {
  const _ChartSection({
    required this.title,
    required this.value,
    required this.child,
  });
  final String title, value;
  final Widget child;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          children: [
            Text(title),
            Text(value, style: Theme.of(context).textTheme.titleSmall),
          ],
        ),
        const SizedBox(height: 8),
        child,
      ],
    ),
  );
}

/// Segments split on missing values and receipt gaps > 6 seconds. No interpolation.
/// Callers opt into a signed lower bound only for values such as Celsius.
List<List<Offset>> liveMetricSegments(
  List<RealtimeSample> samples,
  double? Function(RealtimeSample) select, {
  double minimum = 0,
  double? maximum,
}) {
  if (samples.isEmpty) return const [];
  final values = samples.map(select).toList();
  final finite = values.whereType<double>().where(
    (v) => v.isFinite && v >= minimum,
  );
  final candidate = maximum ?? finite.fold<double>(minimum + 1, math.max);
  final upper = candidate.isFinite && candidate > minimum
      ? candidate
      : minimum + 1;
  final span = upper - minimum;
  final first = samples.first.receivedAt;
  final duration = samples.last.receivedAt.difference(first).inMicroseconds;
  final segments = <List<Offset>>[];
  var current = <Offset>[];
  for (var i = 0; i < samples.length; i++) {
    final value = values[i];
    final gap =
        i > 0 &&
        samples[i].receivedAt.difference(samples[i - 1].receivedAt) >
            const Duration(seconds: 6);
    if (gap || value == null || !value.isFinite || value < minimum) {
      if (current.isNotEmpty) segments.add(current);
      current = [];
    }
    if (value == null || !value.isFinite || value < minimum) continue;
    current.add(
      Offset(
        duration <= 0
            ? 1
            : samples[i].receivedAt.difference(first).inMicroseconds / duration,
        1 - ((value - minimum) / span).clamp(0, 1),
      ),
    );
  }
  if (current.isNotEmpty) segments.add(current);
  return segments;
}

class LiveSparkline extends StatelessWidget {
  const LiveSparkline({
    required this.samples,
    required this.select,
    required this.color,
    required this.label,
    this.maximum,
    this.formatValue,
    this.allowNegative = false,
    super.key,
  });
  final List<RealtimeSample> samples;
  final double? Function(RealtimeSample) select;
  final Color color;
  final String label;
  final double? maximum;
  final String Function(double)? formatValue;
  final bool allowNegative;
  @override
  Widget build(BuildContext context) {
    final values = samples
        .map(select)
        .whereType<double>()
        .where((v) => v.isFinite && (allowNegative || v >= 0))
        .toList();
    final minValue = allowNegative
        ? math.min(0.0, values.fold<double>(0, math.min))
        : 0.0;
    final maxValue = maximum ?? values.fold<double>(minValue + 1, math.max);
    final format = formatValue ?? _compact;
    final latest = samples.isEmpty ? null : select(samples.last);
    return Semantics(
      label:
          '$label. Latest ${latest ?? 'unavailable'}. ${values.length} reported points. '
          'Chart scale $minValue to $maxValue. Missing points are gaps.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '${format(minValue)} — ${format(maxValue)}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
          SizedBox(
            height: 64,
            child: CustomPaint(
              painter: _SparkPainter(
                segments: liveMetricSegments(
                  samples,
                  select,
                  minimum: minValue,
                  maximum: maxValue,
                ),
                color: color,
                grid: Theme.of(context).colorScheme.outlineVariant,
              ),
            ),
          ),
          if (values.isEmpty) const Text('No measured values'),
        ],
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  const _SparkPainter({
    required this.segments,
    required this.color,
    required this.grid,
  });
  final List<List<Offset>> segments;
  final Color color, grid;
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = grid
      ..strokeWidth = 1;
    for (final y in [2.0, size.height / 2, size.height - 2]) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
    paint
      ..color = color
      ..strokeWidth = 2
      ..style = PaintingStyle.stroke;
    for (final segment in segments) {
      final points = segment
          .map((p) => Offset(p.dx * size.width, 2 + p.dy * (size.height - 4)))
          .toList();
      if (points.length == 1) {
        canvas.drawCircle(points.single, 2, Paint()..color = color);
        continue;
      }
      final path = Path()..moveTo(points.first.dx, points.first.dy);
      for (final point in points.skip(1)) {
        path.lineTo(point.dx, point.dy);
      }
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _SparkPainter oldDelegate) => true;
}

class _MemoryPainter extends CustomPainter {
  const _MemoryPainter({
    required this.fraction,
    required this.available,
    required this.unavailable,
  });
  final double fraction;
  final Color available, unavailable;
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(12, 12, size.width - 24, size.height - 24);
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 22
      ..color = unavailable;
    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi, false, paint);
    paint.color = available;
    canvas.drawArc(rect, -math.pi / 2, 2 * math.pi * fraction, false, paint);
  }

  @override
  bool shouldRepaint(covariant _MemoryPainter oldDelegate) =>
      fraction != oldDelegate.fraction ||
      available != oldDelegate.available ||
      unavailable != oldDelegate.unavailable;
}

String _value(double? value, String unit) =>
    value == null ? 'Unavailable' : '${value.toStringAsFixed(1)} $unit';
String _compact(double value) => value >= 1e6 || value < 0.01 && value > 0
    ? value.toStringAsExponential(1)
    : value.toStringAsFixed(value < 10 ? 1 : 0);
String _rate(double? value) =>
    value == null ? 'Unavailable' : '${_bytes(value)}/s';

String _bytes(double? value) {
  if (value == null) return 'Unavailable';
  var number = value;
  var unit = 0;
  const units = ['B', 'KiB', 'MiB', 'GiB', 'TiB', 'PiB'];
  while (number >= 1024 && unit < units.length - 1) {
    number /= 1024;
    unit++;
  }
  return '${number.toStringAsFixed(unit == 0 ? 0 : 1)} ${units[unit]}';
}
