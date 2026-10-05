import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';
import 'package:truenas_api/truenas_api.dart';

enum ReportingPlotStyle { line, area, bar }

/// Actual timestamped samples. Gaps split paths; absent values are never zero.
class ReportingChart extends StatefulWidget {
  const ReportingChart({required this.history, required this.title, super.key});
  final ReportingHistory history;
  final String title;
  @override
  State<ReportingChart> createState() => _ReportingChartState();
}

class _ReportingChartState extends State<ReportingChart> {
  RangeValues _window = const RangeValues(0, 1);
  ReportingPlotStyle _style = ReportingPlotStyle.line;
  int? _selected;
  late Set<int> _visible = _initialSeries();
  late Map<int, int> _colorSlots = {for (final index in _visible) index: index};
  Set<int> _initialSeries() => {
    for (
      var index = 0;
      index < widget.history.legend.length && index < 8;
      index++
    )
      index,
  };
  @override
  void didUpdateWidget(covariant ReportingChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.history, widget.history)) {
      _visible = _initialSeries();
      _colorSlots = {for (final index in _visible) index: index};
      _window = const RangeValues(0, 1);
      _selected = null;
    }
  }

  void _zoom(double factor) {
    final minimum = 1 / math.max(1, widget.history.points.length - 1);
    final span = ((_window.end - _window.start) / factor).clamp(minimum, 1.0);
    final center = (_window.start + _window.end) / 2;
    final start = (center - span / 2).clamp(0.0, 1.0 - span);
    setState(() {
      _window = RangeValues(start, start + span);
      _selected = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final history = widget.history;
    final td = context.tdTheme;
    final colors = [
      td.actionPrimary,
      td.statusWarning,
      td.statusSuccess,
      const Color(0xFF9B8AFB),
      const Color(0xFFEF8BA8),
      const Color(0xFF66B8FA),
      const Color(0xFFC4BD75),
      const Color(0xFFBE91CE),
    ];
    final indexes = _visible.toList()..sort();
    final palette = {
      for (final index in indexes) index: colors[_colorSlots[index]!],
    };
    final values = [
      for (final point in history.points)
        for (final index in indexes) ?_value(point, index),
    ];
    final scale = MediaQuery.textScalerOf(context).scale(16) / 16;
    return TdPanel(
      title: widget.title,
      description: history.identifier == null
          ? history.unit
          : '${history.identifier} · ${history.unit}',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (history.points.isEmpty || values.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: TdSpacing.group),
              child: Text(
                indexes.isEmpty ? 'Select a series to view its history.' : 'No usable measurements for the selected series. Missing data is not zero.',
              ),
            )
          else ...[
            Semantics(
              image: true,
              label:
                  '${widget.title}. ${history.unit}. '
                  '${history.points.length} timestamped samples. '
                  '${indexes.map((index) => _seriesSummary(history, index)).join(' ')} '
                  'The sample table provides exact values.',
              child: ExcludeSemantics(
                child: SizedBox(
                  key: const Key('reporting-line-chart'),
                  height: 250 + 60 * (scale - 1).clamp(0, 2),
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      return GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTapUp: (details) {
                          final plot = reportingPlotRect(
                            Size(constraints.maxWidth, constraints.maxHeight),
                            scale.clamp(1, 2),
                          );
                          if (!plot.contains(details.localPosition)) return;
                          final fraction =
                              _window.start +
                              ((details.localPosition.dx - plot.left) /
                                      plot.width) *
                                  (_window.end - _window.start);
                          setState(
                            () => _selected = reportingNearestSample(
                              history,
                              fraction,
                            ),
                          );
                        },
                        child: CustomPaint(
                          painter: _HistoryPainter(
                            history: history,
                            indexes: indexes,
                            colors: palette,
                            gridColor: td.borderSubtle,
                            labelColor: td.textSecondary,
                            textScale: scale.clamp(1, 2),
                            window: _window,
                            style: _style,
                            selected: _selected,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
            const SizedBox(height: TdSpacing.related),
            if (_selected case final selected?)
              Semantics(
                liveRegion: true,
                child: Text(
                  'Selected sample · ${reportingTimestamp(history.points[selected].timestamp)}\n'
                  '${indexes.map((index) => '${history.legend[index]}: ${reportingValue(_value(history.points[selected], index))} ${history.unit}').join(' · ')}',
                  key: const Key('reporting-selected-sample'),
                ),
              ),
            Material(
              type: MaterialType.transparency,
              child: ExpansionTile(
                key: const Key('reporting-chart-tools'),
                tilePadding: EdgeInsets.zero,
                title: const Text('Explore chart'),
                subtitle: const Text(
                  'Tap a sample · zoom · line, area or bars',
                ),
                children: [
                  Wrap(
                    spacing: TdSpacing.related,
                    runSpacing: TdSpacing.related,
                    children: [
                      for (final style in ReportingPlotStyle.values)
                        ChoiceChip(
                          key: ValueKey('reporting-style-${style.name}'),
                          label: Text(switch (style) {
                            ReportingPlotStyle.line => 'Line',
                            ReportingPlotStyle.area => 'Area',
                            ReportingPlotStyle.bar => 'Bars',
                          }),
                          selected: _style == style,
                          onSelected: (_) => setState(() => _style = style),
                        ),
                      IconButton(
                        key: const Key('reporting-zoom-in'),
                        tooltip: 'Zoom in',
                        onPressed: history.points.length < 3
                            ? null
                            : () => _zoom(2),
                        icon: const Icon(Icons.zoom_in_rounded),
                      ),
                      IconButton(
                        key: const Key('reporting-zoom-out'),
                        tooltip: 'Zoom out',
                        onPressed: () => _zoom(.5),
                        icon: const Icon(Icons.zoom_out_rounded),
                      ),
                      TextButton(
                        key: const Key('reporting-zoom-reset'),
                        onPressed: () => setState(() {
                          _window = const RangeValues(0, 1);
                          _selected = null;
                        }),
                        child: const Text('Full range'),
                      ),
                    ],
                  ),
                  if (history.points.length > 2)
                    RangeSlider(
                      key: const Key('reporting-viewport'),
                      values: _window,
                      labels: RangeLabels(
                        '${(_window.start * 100).round()}%',
                        '${(_window.end * 100).round()}%',
                      ),
                      semanticFormatterCallback: (value) =>
                          '${(value * 100).round()} percent of the returned time interval',
                      onChanged: (values) {
                        if (values.end - values.start <
                            1 / (history.points.length - 1)) {
                          return;
                        }
                        setState(() {
                          _window = values;
                          _selected = null;
                        });
                      },
                    ),
                  Text(
                    'Visible interval · ${reportingTimestamp(reportingViewportTime(history, _window.start))} → '
                    '${reportingTimestamp(reportingViewportTime(history, _window.end))}',
                    key: const Key('reporting-visible-interval'),
                  ),
                  const Text(
                    'Zoom uses returned samples, not a higher-resolution server query. Series are independent, never stacked or summed.',
                  ),
                  Wrap(
                    spacing: TdSpacing.related,
                    children: [
                      TextButton.icon(
                        key: const Key('reporting-sample-previous'),
                        onPressed: history.points.isEmpty
                            ? null
                            : () => setState(() {
                                _selected = math.max(
                                  0,
                                  (_selected ?? history.points.length) - 1,
                                );
                                _revealSelected();
                              }),
                        icon: const Icon(Icons.chevron_left),
                        label: const Text('Previous sample'),
                      ),
                      TextButton.icon(
                        key: const Key('reporting-sample-next'),
                        onPressed: history.points.isEmpty
                            ? null
                            : () => setState(() {
                                _selected = math.min(
                                  history.points.length - 1,
                                  (_selected ?? -1) + 1,
                                );
                                _revealSelected();
                              }),
                        icon: const Icon(Icons.chevron_right),
                        label: const Text('Next sample'),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
          Text(
            'Server range · ${reportingTimestamp(history.returnedStart)} → '
            '${reportingTimestamp(history.returnedEnd)}',
            style: TdTypography.metadata.copyWith(color: td.textSecondary),
          ),
          const SizedBox(height: TdSpacing.component),
          Text(
            'Series · ${indexes.length} of ${history.legend.length} visible',
            style: TdTypography.label,
          ),
          if (history.legend.length > 8)
            const Text(
              'Choose up to 8 lines at once. All series remain available below.',
            ),
          const SizedBox(height: TdSpacing.related),
          Wrap(
            spacing: TdSpacing.related,
            runSpacing: TdSpacing.related,
            children: [
              for (var index = 0; index < history.legend.length; index++)
                FilterChip(
                  key: ValueKey('reporting-series-$index'),
                  avatar: _visible.contains(index)
                      ? Icon(
                          Icons.show_chart_rounded,
                          size: 18,
                          color: palette[index],
                        )
                      : null,
                  label: Text(history.legend[index]),
                  selected: _visible.contains(index),
                  onSelected: _visible.contains(index) || _visible.length < 8
                      ? (selected) => setState(() {
                          if (selected) {
                            _visible.add(index);
                            _colorSlots[index] =
                                List.generate(8, (value) => value).firstWhere(
                                  (slot) => !_colorSlots.containsValue(slot),
                                );
                          } else {
                            _visible.remove(index);
                            _colorSlots.remove(index);
                          }
                        })
                      : null,
                ),
            ],
          ),
          const SizedBox(height: TdSpacing.component),
          for (final index in indexes)
            Padding(
              padding: const EdgeInsets.only(bottom: TdSpacing.related),
              child: Text(_seriesSummary(history, index)),
            ),
          if (history.graphName == 'cpu')
            const Text(
              'CPU aggregate and individual cores overlap. These are independent lines, not parts of a pie.',
            ),
          if (history.graphName == 'memory')
            const Text(
              'This graph reports the server’s available memory measurement, not a used/free breakdown.',
            ),
          if (history.hasGaps) ...[
            const SizedBox(height: TdSpacing.related),
            const Text(
              'Missing or irregular samples were reported. Lines break across missing intervals.',
            ),
          ],
          if (history.truncated) ...[
            const SizedBox(height: TdSpacing.related),
            const Text(
              'Samples outside the requested interval were omitted. Remaining timestamps and values are unchanged.',
            ),
          ],
          const SizedBox(height: TdSpacing.component),
          Material(
            type: MaterialType.transparency,
            child: ExpansionTile(
              key: const Key('reporting-sample-table'),
              tilePadding: EdgeInsets.zero,
              title: const Text('View exact samples'),
              subtitle: Text(
                '${history.points.length} rows · all ${history.legend.length} series · UTC',
              ),
              children: [_SampleTable(history: history)],
            ),
          ),
          const SizedBox(height: TdSpacing.related),
          Text(
            'TrueNAS may fill missing upstream samples with zero.',
            style: TdTypography.metadata.copyWith(color: td.textMuted),
          ),
        ],
      ),
    );
  }

  void _revealSelected() {
    final history = widget.history;
    final duration = history.points.last.timestamp
        .difference(history.points.first.timestamp)
        .inMicroseconds;
    if (duration <= 0 || _selected == null) return;
    final fraction =
        history.points[_selected!].timestamp
            .difference(history.points.first.timestamp)
            .inMicroseconds /
        duration;
    if (fraction < _window.start || fraction > _window.end) {
      final span = _window.end - _window.start;
      final start = (fraction - span / 2).clamp(0.0, 1.0 - span);
      _window = RangeValues(start, start + span);
    }
  }
}

DateTime reportingViewportTime(ReportingHistory history, double fraction) {
  if (history.points.isEmpty) return history.returnedStart;
  final first = history.points.first.timestamp;
  final duration = history.points.last.timestamp
      .difference(first)
      .inMicroseconds;
  return first.add(
    Duration(microseconds: (duration * fraction.clamp(0.0, 1.0)).round()),
  );
}

int? reportingNearestSample(ReportingHistory history, double fraction) {
  if (history.points.isEmpty) return null;
  final target = reportingViewportTime(history, fraction);
  var best = 0;
  var distance = history.points.first.timestamp
      .difference(target)
      .inMicroseconds
      .abs();
  for (var index = 1; index < history.points.length; index++) {
    final next = history.points[index].timestamp
        .difference(target)
        .inMicroseconds
        .abs();
    if (next < distance) {
      best = index;
      distance = next;
    }
  }
  return best;
}

Rect reportingPlotRect(Size size, double textScale) => Rect.fromLTRB(
  (55 * textScale).clamp(55, size.width * .38),
  12,
  math.max(size.width - 8, 1),
  size.height - 36 * textScale,
);

/// Kept testable independently of pixels to guard against false continuity.
List<List<ReportingPoint>> reportingLineSegments(
  ReportingHistory history,
  int series,
) {
  final intervals = <int>[
    for (var i = 1; i < history.points.length; i++)
      if (history.points[i].timestamp.isAfter(history.points[i - 1].timestamp))
        history.points[i].timestamp
            .difference(history.points[i - 1].timestamp)
            .inMicroseconds,
  ];
  final cadence = intervals.isEmpty ? null : intervals.reduce(math.min);
  final segments = <List<ReportingPoint>>[];
  List<ReportingPoint>? segment;
  ReportingPoint? previous;
  for (final point in history.points) {
    final value = _value(point, series);
    final gap =
        previous != null &&
        cadence != null &&
        point.timestamp.difference(previous.timestamp).inMicroseconds >
            cadence * 1.5;
    if (value == null) {
      segment = null;
    } else {
      if (segment == null || gap) {
        segment = <ReportingPoint>[];
        segments.add(segment);
      }
      segment.add(point);
    }
    previous = point;
  }
  return segments;
}

double? _value(ReportingPoint point, int index) {
  if (index < 0 || index >= point.values.length) return null;
  final value = point.values[index];
  return value != null && value.isFinite ? value : null;
}

String _seriesSummary(ReportingHistory history, int index) {
  final values = [for (final point in history.points) ?_value(point, index)];
  final name = history.legend[index];
  if (values.isEmpty) return '$name · no usable samples';
  final latest = history.points.isEmpty
      ? null
      : _value(history.points.last, index);
  final current = latest == null ? 'unavailable' : reportingValue(latest);
  return '$name · latest $current · sample min ${reportingValue(values.reduce(math.min))} '
      '· max ${reportingValue(values.reduce(math.max))} ${history.unit}';
}

String reportingValue(double? value) {
  if (value == null || !value.isFinite) return 'Missing';
  if (value.abs() < 1e12 && value == value.roundToDouble()) {
    return value.toInt().toString();
  }
  return value.toString();
}

String reportingTimestamp(DateTime value) =>
    '${value.toUtc().toIso8601String().substring(0, 19).replaceFirst('T', ' ')} UTC';

/// A finite normalized axis; multiply its bounds by normalizer for labels.
({double minimum, double maximum, double normalizer}) reportingAxisScale(
  List<double> values,
) {
  final finite = values.where((value) => value.isFinite).toList();
  if (finite.isEmpty) return (minimum: 0, maximum: 1, normalizer: 1);
  final maximumAbsolute = finite.map((value) => value.abs()).reduce(math.max);
  final normalizer = maximumAbsolute == 0 ? 1.0 : maximumAbsolute;
  final minimum = math.min(0.0, finite.reduce(math.min) / normalizer);
  final maxValue = math.max(0.0, finite.reduce(math.max) / normalizer);
  return (
    minimum: minimum,
    maximum: maxValue == minimum ? minimum + 1 : maxValue,
    normalizer: normalizer,
  );
}

class _HistoryPainter extends CustomPainter {
  const _HistoryPainter({
    required this.history,
    required this.indexes,
    required this.colors,
    required this.gridColor,
    required this.labelColor,
    required this.textScale,
    required this.window,
    required this.style,
    required this.selected,
  });
  final ReportingHistory history;
  final List<int> indexes;
  final Map<int, Color> colors;
  final Color gridColor;
  final Color labelColor;
  final double textScale;
  final RangeValues window;
  final ReportingPlotStyle style;
  final int? selected;
  @override
  void paint(Canvas canvas, Size size) {
    if (history.points.isEmpty || indexes.isEmpty) return;
    final values = [
      for (final p in history.points)
        for (final i in indexes) ?_value(p, i),
    ];
    if (values.isEmpty) return;
    // Normalize before subtraction: two finite extremes can have an infinite
    // difference, which must never become an invalid canvas coordinate.
    final axis = reportingAxisScale(values);
    final normalizer = axis.normalizer;
    final minimum = axis.minimum;
    final maximum = axis.maximum;
    final first = reportingViewportTime(
      history,
      window.start,
    ).microsecondsSinceEpoch;
    final last = reportingViewportTime(
      history,
      window.end,
    ).microsecondsSinceEpoch;
    final duration = math.max(1, last - first);
    final plot = reportingPlotRect(size, textScale);
    final grid = Paint()
      ..color = gridColor
      ..strokeWidth = 1;
    for (var tick = 0; tick <= 4; tick++) {
      final y = plot.top + tick / 4 * plot.height;
      canvas.drawLine(Offset(plot.left, y), Offset(plot.right, y), grid);
      final value = (maximum - tick / 4 * (maximum - minimum)) * normalizer;
      _text(
        canvas,
        _compactAxis(value),
        Offset(0, y - 7 * textScale),
        plot.left - 6,
      );
    }
    _text(
      canvas,
      reportingAxisTimestamp(
        reportingViewportTime(history, window.start),
        Duration(microseconds: duration),
      ),
      Offset(plot.left, plot.bottom + 10),
      plot.width / 2,
    );
    final lastText = reportingAxisTimestamp(
      reportingViewportTime(history, window.end),
      Duration(microseconds: duration),
    );
    _text(
      canvas,
      lastText,
      Offset(plot.left + plot.width / 2, plot.bottom + 10),
      plot.width / 2,
      right: true,
    );
    canvas.save();
    canvas.clipRect(plot.inflate(3));
    final baseline =
        plot.bottom - (0 - minimum) / (maximum - minimum) * plot.height;
    final intervals = <int>[
      for (var i = 1; i < history.points.length; i++)
        history.points[i].timestamp
            .difference(history.points[i - 1].timestamp)
            .inMicroseconds,
    ].where((value) => value > 0).toList();
    final cadence = intervals.isEmpty ? duration : intervals.reduce(math.min);
    final groupWidth = (cadence / duration * plot.width * .8).clamp(.2, 32.0);
    for (final series in indexes) {
      final paint = Paint()
        ..color = colors[series]!
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke;
      for (final segment in reportingLineSegments(history, series)) {
        final path = Path();
        Offset? beginning;
        Offset? single;
        for (var i = 0; i < segment.length; i++) {
          final point = segment[i];
          final x =
              plot.left +
              (point.timestamp.microsecondsSinceEpoch - first) /
                  duration *
                  plot.width;
          final y =
              plot.bottom -
              (_value(point, series)! / normalizer - minimum) /
                  (maximum - minimum) *
                  plot.height;
          single = Offset(x, y);
          beginning ??= single;
          if (style == ReportingPlotStyle.bar) {
            final width = groupWidth / indexes.length;
            final left = x - groupWidth / 2 + indexes.indexOf(series) * width;
            canvas.drawRect(
              Rect.fromLTRB(
                left,
                math.min(y, baseline),
                left + width,
                math.max(y, baseline),
              ),
              Paint()..color = colors[series]!,
            );
            if (y == baseline) {
              canvas.drawCircle(single, 1.5, Paint()..color = colors[series]!);
            }
          }
          if (i == 0) {
            path.moveTo(x, y);
          } else {
            path.lineTo(x, y);
          }
        }
        if (style == ReportingPlotStyle.bar) continue;
        if (style == ReportingPlotStyle.area &&
            beginning != null &&
            single != null &&
            segment.length > 1) {
          final fill = Path.from(path)
            ..lineTo(single.dx, baseline)
            ..lineTo(beginning.dx, baseline)
            ..close();
          canvas.drawPath(
            fill,
            Paint()..color = colors[series]!.withValues(alpha: .18),
          );
        }
        if (segment.length == 1 && single != null) {
          canvas.drawCircle(single, 2.5, Paint()..color = colors[series]!);
        } else {
          canvas.drawPath(path, paint);
        }
      }
    }
    if (selected case final index?) {
      final point = history.points[index];
      final x =
          plot.left +
          (point.timestamp.microsecondsSinceEpoch - first) /
              duration *
              plot.width;
      canvas.drawLine(
        Offset(x, plot.top),
        Offset(x, plot.bottom),
        Paint()
          ..color = labelColor
          ..strokeWidth = 1,
      );
      for (final series in indexes) {
        final value = _value(point, series);
        if (value == null) continue;
        final y =
            plot.bottom -
            (value / normalizer - minimum) / (maximum - minimum) * plot.height;
        canvas.drawCircle(Offset(x, y), 4, Paint()..color = colors[series]!);
      }
    }
    canvas.restore();
  }

  void _text(
    Canvas canvas,
    String text,
    Offset offset,
    double width, {
    bool right = false,
  }) {
    final painter = TextPainter(
      text: TextSpan(
        text: text,
        style: TextStyle(color: labelColor, fontSize: 10 * textScale),
      ),
      textDirection: TextDirection.ltr,
      textAlign: right ? TextAlign.right : TextAlign.left,
      maxLines: 1,
      ellipsis: '…',
    )..layout(minWidth: width, maxWidth: width);
    painter.paint(canvas, offset);
  }

  @override
  bool shouldRepaint(covariant _HistoryPainter oldDelegate) =>
      !identical(history, oldDelegate.history) ||
      indexes.toString() != oldDelegate.indexes.toString() ||
      gridColor != oldDelegate.gridColor ||
      labelColor != oldDelegate.labelColor ||
      textScale != oldDelegate.textScale ||
      window != oldDelegate.window ||
      style != oldDelegate.style ||
      selected != oldDelegate.selected;
}

String reportingAxisTimestamp(DateTime time, Duration visibleDuration) =>
    visibleDuration >= const Duration(days: 1)
    ? '${time.toUtc().toIso8601String().substring(0, 10)} UTC'
    : '${time.toUtc().hour.toString().padLeft(2, '0')}:'
          '${time.toUtc().minute.toString().padLeft(2, '0')} UTC';
String _compactAxis(double value) {
  final absolute = value.abs();
  for (final entry in [(1e12, 'T'), (1e9, 'G'), (1e6, 'M'), (1e3, 'k')]) {
    if (absolute >= entry.$1) {
      return '${(value / entry.$1).toStringAsPrecision(3)}${entry.$2}';
    }
  }
  return value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toStringAsPrecision(3);
}

class _SampleTable extends StatefulWidget {
  const _SampleTable({required this.history});
  final ReportingHistory history;
  @override
  State<_SampleTable> createState() => _SampleTableState();
}

class _SampleTableState extends State<_SampleTable> {
  int _page = 0;
  @override
  void didUpdateWidget(covariant _SampleTable oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.history, widget.history)) _page = 0;
  }

  @override
  Widget build(BuildContext context) {
    final history = widget.history;
    if (history.points.isEmpty) {
      return const Text('No sample rows were returned.');
    }
    final start = _page * 20;
    final end = math.min(start + 20, history.points.length);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: DataTable(
            headingRowHeight:
                56 * MediaQuery.textScalerOf(context).scale(16) / 16,
            dataRowMinHeight:
                48 * MediaQuery.textScalerOf(context).scale(16) / 16,
            dataRowMaxHeight:
                64 * MediaQuery.textScalerOf(context).scale(16) / 16,
            columns: [
              const DataColumn(label: Text('Timestamp (UTC)')),
              for (final name in history.legend)
                DataColumn(label: Text('$name\n${history.unit}')),
            ],
            rows: [
              for (var i = start; i < end; i++)
                DataRow(
                  cells: [
                    DataCell(
                      Text(reportingTimestamp(history.points[i].timestamp)),
                    ),
                    for (
                      var series = 0;
                      series < history.legend.length;
                      series++
                    )
                      DataCell(
                        Text(reportingValue(_value(history.points[i], series))),
                      ),
                  ],
                ),
            ],
          ),
        ),
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text('Rows ${start + 1}–$end of ${history.points.length}'),
            IconButton(
              key: const Key('reporting-previous-samples'),
              tooltip: 'Previous samples',
              onPressed: _page == 0 ? null : () => setState(() => _page--),
              icon: const Icon(Icons.chevron_left),
            ),
            IconButton(
              key: const Key('reporting-next-samples'),
              tooltip: 'Next samples',
              onPressed: end >= history.points.length
                  ? null
                  : () => setState(() => _page++),
              icon: const Icon(Icons.chevron_right),
            ),
          ],
        ),
      ],
    );
  }
}
