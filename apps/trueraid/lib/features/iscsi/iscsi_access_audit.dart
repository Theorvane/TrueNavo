import 'package:flutter/material.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

import 'iscsi_overview.dart';

/// A point-in-time view of saved target access associations, not live clients.
class IscsiAccessAudit extends StatelessWidget {
  const IscsiAccessAudit({required this.overview, super.key});

  final IscsiOverview overview;

  @override
  Widget build(BuildContext context) {
    final groups = [for (final target in overview.targets) ...target.groups];
    final total = groups.length;
    final counts = <String, int>{
      'No CHAP': 0,
      'CHAP': 0,
      'Mutual CHAP': 0,
      'Authentication unknown': 0,
    };
    final usedPortals = <int>{};
    final usedInitiators = <int>{};
    var missingPortals = 0;
    var missingInitiators = 0;
    for (final group in groups) {
      counts[group.authMethod] = (counts[group.authMethod] ?? 0) + 1;
      usedPortals.add(group.portalId);
      if (overview.portalById(group.portalId) == null) missingPortals++;
      final initiatorId = group.initiatorId;
      if (initiatorId != null) {
        usedInitiators.add(initiatorId);
        if (overview.initiatorById(initiatorId) == null) missingInitiators++;
      }
    }
    final unusedPortals = overview.portals
        .where((portal) => !usedPortals.contains(portal.id))
        .length;
    final unusedInitiators = overview.initiators
        .where((initiator) => !usedInitiators.contains(initiator.id))
        .length;
    return TdPanel(
      title: 'Configured access associations',
      description:
          'Authentication settings on $total target access associations. '
          'These sequential configuration reads do not prove client access or current sessions.',
      child: total == 0
          ? const Text('No target access associations configured.')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final entry in counts.entries) ...[
                  Text('${entry.key} · ${entry.value} of $total'),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(
                    key: Key(
                      'iscsi-access-${entry.key.replaceAll(' ', '-').toLowerCase()}',
                    ),
                    value: entry.value / total,
                    minHeight: 8,
                    borderRadius: BorderRadius.circular(4),
                    semanticsLabel: '${entry.key} configured associations',
                  ),
                  const SizedBox(height: 12),
                ],
                if (missingPortals > 0 || missingInitiators > 0)
                  Text(
                    'Unresolved references in this read: $missingPortals portal, '
                    '$missingInitiators initiator group. Reload and inspect before changing access.',
                  ),
                if (unusedPortals > 0 || unusedInitiators > 0)
                  Text(
                    'Unreferenced by returned targets: $unusedPortals portal, '
                    '$unusedInitiators initiator group. This does not imply safe deletion.',
                  ),
              ],
            ),
    );
  }
}
