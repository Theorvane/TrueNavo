import 'package:flutter/material.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

/// Calendar-only schedule state. The original cron spelling is preserved until
/// the user explicitly changes that field; there is no executable text input.
final class SnapshotCalendarValue {
  const SnapshotCalendarValue({
    this.minute = '0',
    this.hour = '0',
    this.dayOfMonth = '*',
    this.month = '*',
    this.dayOfWeek = '*',
  });
  final String minute, hour, dayOfMonth, month, dayOfWeek;
  List<String> get fields => [minute, hour, dayOfMonth, month, dayOfWeek];
  String get expression => fields.join(' ');
  bool get supported => [
    for (var index = 0; index < fields.length; index++)
      calendarFieldValues(fields[index], calendarFields[index]),
  ].every((values) => values != null);
  String get summary =>
      'Minutes ${_summary(minute, calendarFields[0])}; hours ${_summary(hour, calendarFields[1])}; '
      'days of month ${_summary(dayOfMonth, calendarFields[2])}; months ${_summary(month, calendarFields[3])}; '
      'weekdays ${_summary(dayOfWeek, calendarFields[4])}.';
  SnapshotCalendarValue replace(int index, String value) {
    final next = [...fields];
    next[index] = value;
    return SnapshotCalendarValue(
      minute: next[0],
      hour: next[1],
      dayOfMonth: next[2],
      month: next[3],
      dayOfWeek: next[4],
    );
  }
}

final class SnapshotCalendarField {
  const SnapshotCalendarField(
    this.id,
    this.label,
    this.minimum,
    this.maximum, {
    this.labels,
  });
  final String id, label;
  final int minimum, maximum;
  final List<String>? labels;
  String describe(int value) => labels?[value - minimum] ?? '$value';
}

const calendarFields = [
  SnapshotCalendarField('minute', 'Minute', 0, 59),
  SnapshotCalendarField('hour', 'Hour', 0, 23),
  SnapshotCalendarField('day-of-month', 'Day of month', 1, 31),
  SnapshotCalendarField(
    'month',
    'Month',
    1,
    12,
    labels: [
      'Jan',
      'Feb',
      'Mar',
      'Apr',
      'May',
      'Jun',
      'Jul',
      'Aug',
      'Sep',
      'Oct',
      'Nov',
      'Dec',
    ],
  ),
  SnapshotCalendarField(
    'day-of-week',
    'Day of week',
    0,
    7,
    labels: ['Sun (alias 0)', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'],
  ),
];

/// The bounded numeric cron subset rendered by the native calendar. Names,
/// aliases, wraparound ranges, modifiers and zero steps remain unsupported.
Set<int>? calendarFieldValues(String expression, SnapshotCalendarField field) {
  if (expression.isEmpty || expression.length > 240) return null;
  final values = <int>{};
  for (final part in expression.split(',')) {
    final match = RegExp(r'^(\*|[0-9]+(?:-[0-9]+)?)(?:/([0-9]+))?$')
        .firstMatch(part);
    if (match == null) return null;
    final base = match.group(1)!;
    final step = int.tryParse(match.group(2) ?? '1');
    if (step == null || step < 1 || step > field.maximum - field.minimum + 1) {
      return null;
    }
    final bounds = base.split('-');
    if (base != '*' && bounds.length == 1 && match.group(2) != null) {
      return null;
    }
    final start = base == '*' ? field.minimum : int.tryParse(bounds.first);
    final end = base == '*' ? field.maximum : int.tryParse(bounds.last);
    if (start == null ||
        end == null ||
        start < field.minimum ||
        end > field.maximum ||
        start > end) {
      return null;
    }
    for (var value = start; value <= end; value += step) {
      values.add(value);
    }
  }
  return values.isEmpty ? null : values;
}

String _summary(String raw, SnapshotCalendarField field) {
  if (raw == '*') return 'any';
  final values = calendarFieldValues(raw, field);
  if (values == null) return 'unsupported ($raw)';
  final interval = RegExp(r'^\*/([0-9]+)$').firstMatch(raw);
  if (interval != null) {
    return 'every ${interval.group(1)} starting at ${field.describe(field.minimum)}';
  }
  final sorted = values.toList()..sort();
  return sorted.map(field.describe).join(', ');
}

class SnapshotCalendarEditor extends StatelessWidget {
  const SnapshotCalendarEditor({
    required this.value,
    required this.onChanged,
    this.enabled = true,
    super.key,
  });
  final SnapshotCalendarValue value;
  final ValueChanged<SnapshotCalendarValue> onChanged;
  final bool enabled;
  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      const Text('Calendar schedule', style: TdTypography.titleSmall),
      const SizedBox(height: TdSpacing.related),
      const Text(
        'Choose a preset, or expand individual calendar fields. Times use the TrueNAS server timezone, not this device.',
      ),
      const SizedBox(height: TdSpacing.related),
      Wrap(
        spacing: TdSpacing.related,
        runSpacing: TdSpacing.related,
        children: [
          for (final preset in const [
            ('hourly', 'Hourly', SnapshotCalendarValue(hour: '*')),
            ('daily', 'Daily at midnight', SnapshotCalendarValue()),
            (
              'weekdays',
              'Weekdays at 09:00',
              SnapshotCalendarValue(hour: '9', dayOfWeek: '1-5'),
            ),
            (
              'weekly',
              'Sunday at 02:00',
              SnapshotCalendarValue(hour: '2', dayOfWeek: '7'),
            ),
            (
              'monthly',
              'Monthly on day 1',
              SnapshotCalendarValue(hour: '3', dayOfMonth: '1'),
            ),
          ])
            ChoiceChip(
              key: ValueKey('schedule-preset-${preset.$1}'),
              label: Text(preset.$2),
              selected: value.expression == preset.$3.expression,
              onSelected: enabled ? (_) => onChanged(preset.$3) : null,
            ),
        ],
      ),
      const SizedBox(height: TdSpacing.component),
      Text(value.summary, key: const Key('schedule-calendar-summary')),
      Text(
        value.dayOfMonth != '*' && value.dayOfWeek != '*'
            ? 'Day matching: selected day of month OR selected weekday. Other selected calendar fields must also match.'
            : 'Other selected calendar fields must all match. Sunday accepts 0 or 7; the original spelling is preserved.',
      ),
      const SizedBox(height: TdSpacing.related),
      SelectableText(
        'Cron: ${value.expression}',
        key: const Key('schedule-calendar-expression'),
      ),
      if (!value.supported)
        const Text(
          'This schedule contains a rule outside the native calendar subset. It is not silently converted. Explicitly choose a preset to replace it, or manage the original rule in TrueNAS.',
        ),
      const SizedBox(height: TdSpacing.related),
      Material(
        type: MaterialType.transparency,
        child: Column(
          children: [
            for (var index = 0; index < calendarFields.length; index++)
              _CalendarFieldEditor(
                key: ValueKey('schedule-calendar-${calendarFields[index].id}'),
                field: calendarFields[index],
                expression: value.fields[index],
                enabled: enabled,
                onChanged: (raw) => onChanged(value.replace(index, raw)),
              ),
          ],
        ),
      ),
      const SizedBox(height: TdSpacing.related),
      const Text(
        'A selected day that does not exist in a month is not created or shifted to another date. No next-run time is calculated on this device.',
      ),
    ],
  );
}

class _CalendarFieldEditor extends StatelessWidget {
  const _CalendarFieldEditor({
    required this.field,
    required this.expression,
    required this.enabled,
    required this.onChanged,
    super.key,
  });
  final SnapshotCalendarField field;
  final String expression;
  final bool enabled;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) {
    final values = calendarFieldValues(expression, field);
    final interval = RegExp(r'^\*/([0-9]+)$').firstMatch(expression);
    final mode = expression == '*'
        ? 'any'
        : interval != null
        ? 'interval'
        : 'selected';
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: TdSpacing.component),
      title: Text(field.label),
      subtitle: Text(_summary(expression, field)),
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Wrap(
              spacing: TdSpacing.related,
              runSpacing: TdSpacing.related,
              children: [
                for (final choice in [
                  ('any', 'Any'),
                  ('selected', 'Selected values'),
                  ('interval', 'Fixed interval'),
                ])
                  ChoiceChip(
                    key: ValueKey('schedule-${field.id}-${choice.$1}'),
                    label: Text(choice.$2),
                    selected: mode == choice.$1,
                    onSelected: enabled && values != null
                        ? (_) => onChanged(switch (choice.$1) {
                            'any' => '*',
                            'interval' => '*/2',
                            _ => '${field.minimum}',
                          })
                        : null,
                  ),
              ],
            ),
            if (mode == 'selected' && values != null) ...[
              const SizedBox(height: TdSpacing.related),
              Wrap(
                spacing: TdSpacing.inline,
                runSpacing: TdSpacing.inline,
                children: [
                  for (
                    var number = field.minimum;
                    number <= field.maximum;
                    number++
                  )
                    FilterChip(
                      key: ValueKey('schedule-${field.id}-value-$number'),
                      label: Text(field.describe(number)),
                      selected: values.contains(number),
                      onSelected: enabled
                          ? (selected) {
                              final updated = {...values};
                              selected
                                  ? updated.add(number)
                                  : updated.remove(number);
                              if (updated.isEmpty) return;
                              final sorted = updated.toList()..sort();
                              onChanged(sorted.join(','));
                            }
                          : null,
                    ),
                ],
              ),
              const Text('At least one value is required.'),
            ],
            if (mode == 'interval' && values != null) ...[
              const SizedBox(height: TdSpacing.related),
              DropdownButtonFormField<int>(
                key: ValueKey(
                  'schedule-${field.id}-interval-${interval?.group(1)}',
                ),
                initialValue: int.tryParse(interval?.group(1) ?? ''),
                isExpanded: true,
                decoration: InputDecoration(
                  labelText:
                      'Repeat every ${field.label.toLowerCase()} interval',
                ),
                items: [
                  for (
                    var step = 1;
                    step <= field.maximum - field.minimum + 1;
                    step++
                  )
                    DropdownMenuItem(value: step, child: Text('$step')),
                ],
                onChanged: enabled
                    ? (step) {
                        if (step != null) onChanged('*/$step');
                      }
                    : null,
              ),
            ],
          ],
        ),
      ],
    );
  }
}
