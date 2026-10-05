import 'package:flutter/material.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

import 'iscsi_overview.dart';

/// Visualizes configured target-to-LUN relationships, not active I/O.
class IscsiMappingChart extends StatelessWidget {
  const IscsiMappingChart({required this.overview, super.key});

  final IscsiOverview overview;

  @override
  Widget build(BuildContext context) {
    final total = overview.mappings.length;
    final grouped = <int, int>{};
    for (final mapping in overview.mappings) {
      grouped.update(mapping.targetId, (count) => count + 1, ifAbsent: () => 1);
    }
    final unresolved = overview.mappings
        .where((mapping) => overview.targetById(mapping.targetId) == null)
        .length;
    return TdPanel(
      title: 'Configured LUN distribution',
      description:
          'Share of $total configured target–extent mappings. Not traffic or connected clients.',
      child: total == 0
          ? const Text('No LUN mappings configured.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final target in overview.targets) ...[
                  Text('${target.name} · ${grouped[target.id] ?? 0} of $total'),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    key: Key('iscsi-target-mappings-${target.id}'),
                    value: (grouped[target.id] ?? 0) / total,
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(4),
                    semanticsLabel: '${target.name} configured LUN mappings',
                  ),
                  const SizedBox(height: 12),
                ],
                if (unresolved > 0)
                  Text(
                    '$unresolved mapping${unresolved == 1 ? '' : 's'} ${unresolved == 1 ? 'references' : 'reference'} targets missing from this read.',
                  ),
              ],
            ),
    );
  }
}
