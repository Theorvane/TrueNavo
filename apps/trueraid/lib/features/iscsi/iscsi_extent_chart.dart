import 'package:flutter/material.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import 'iscsi_overview.dart';

/// Counts saved extent configuration, never I/O or storage capacity.
class IscsiExtentChart extends StatelessWidget {
  const IscsiExtentChart({required this.overview, super.key});

  final IscsiOverview overview;

  @override
  Widget build(BuildContext context) {
    final total = overview.extents.length;
    final typeCounts = <String, int>{'Disk': 0, 'File': 0, 'Unknown type': 0};
    final stateCounts = <String, int>{
      'Enabled': 0,
      'Disabled': 0,
      'Status unknown': 0,
    };
    for (final extent in overview.extents) {
      typeCounts[extent.type] = (typeCounts[extent.type] ?? 0) + 1;
      final state = switch (extent.enabled) {
        true => 'Enabled',
        false => 'Disabled',
        null => 'Status unknown',
      };
      stateCounts[state] = stateCounts[state]! + 1;
    }
    return TdPanel(
      title: 'Extent configuration distribution',
      description:
          'Counts of $total saved extents. Not capacity, I/O, availability or live client state.',
      child: total == 0
          ? const Text('No extents configured.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Backing type', style: TdTypography.titleSmall),
                for (final entry in typeCounts.entries)
                  _RatioRow(
                    label: entry.key,
                    count: entry.value,
                    total: total,
                    keyName:
                        'type-${entry.key.toLowerCase().replaceAll(' ', '-')}',
                  ),
                const SizedBox(height: 8),
                Text('Configured status', style: TdTypography.titleSmall),
                for (final entry in stateCounts.entries)
                  _RatioRow(
                    label: entry.key,
                    count: entry.value,
                    total: total,
                    keyName:
                        'state-${entry.key.toLowerCase().replaceAll(' ', '-')}',
                  ),
              ],
            ),
    );
  }
}

class _RatioRow extends StatelessWidget {
  const _RatioRow({
    required this.label,
    required this.count,
    required this.total,
    required this.keyName,
  });

  final String label;
  final int count, total;
  final String keyName;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$label · $count of $total'),
        const SizedBox(height: 4),
        LinearProgressIndicator(
          key: Key('iscsi-extent-$keyName'),
          value: count / total,
          minHeight: 8,
          borderRadius: BorderRadius.circular(4),
          semanticsLabel: '$label configured extents',
        ),
      ],
    ),
  );
}
