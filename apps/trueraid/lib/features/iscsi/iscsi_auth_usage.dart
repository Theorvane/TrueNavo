import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:truenas_api/truenas_api.dart';

import 'iscsi_overview.dart';

/// Joins separately read, secret-free configuration projections. This is not
/// an atomic view or proof that a credential is safe to change or remove.
final class IscsiAuthUsage {
  IscsiAuthUsage._(
    this.total,
    this.used,
    this.targetUses,
    this.missingIds,
    this.chapWithoutId,
    this.noChapWithId,
  );

  final int total, used, chapWithoutId, noChapWithId;
  final Map<int, int> targetUses;
  final Set<int> missingIds;
  int get unreferenced => total - used;

  factory IscsiAuthUsage.from(
    IscsiAuthInventory inventory,
    IscsiOverview overview,
  ) {
    final credentialIds = inventory.references.map((row) => row.id).toSet();
    final targetUses = <int, Set<int>>{};
    final missingIds = <int>{};
    var chapWithoutId = 0;
    var noChapWithId = 0;
    for (final target in overview.targets) {
      for (final group in target.groups) {
        final id = group.authId;
        if (id == null) {
          if (group.authMethod == 'CHAP' || group.authMethod == 'Mutual CHAP') {
            chapWithoutId++;
          }
          continue;
        }
        if (group.authMethod == 'No CHAP') noChapWithId++;
        if (!credentialIds.contains(id)) {
          missingIds.add(id);
        } else {
          targetUses.putIfAbsent(id, () => <int>{}).add(target.id);
        }
      }
    }
    final used = inventory.references
        .where(
          (record) =>
              targetUses.containsKey(record.id) ||
              record.discoveryAuth != 'NONE',
        )
        .length;
    return IscsiAuthUsage._(
      inventory.references.length,
      used,
      Map.unmodifiable(
        targetUses.map((id, targets) => MapEntry(id, targets.length)),
      ),
      Set.unmodifiable(missingIds),
      chapWithoutId,
      noChapWithId,
    );
  }
}

class IscsiAuthUsageChart extends StatelessWidget {
  const IscsiAuthUsageChart({required this.usage, super.key});

  final IscsiAuthUsage usage;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (usage.total == 0)
          const Text('No CHAP credentials in the returned inventory.')
        else
          Wrap(
            spacing: 16,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Semantics(
                label:
                    '${usage.used} of ${usage.total} CHAP credentials referenced by a target or configured for discovery',
                child: SizedBox(
                  width: 112,
                  height: 112,
                  child: CustomPaint(
                    key: const Key('iscsi-auth-usage-donut'),
                    painter: _UsageRing(
                      fraction: usage.used / usage.total,
                      usedColor: scheme.primary,
                      otherColor: scheme.outlineVariant,
                    ),
                  ),
                ),
              ),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text('Target/discovery referenced · ${usage.used}'),
                  Text('No returned reference · ${usage.unreferenced}'),
                ],
              ),
            ],
          ),
        if (usage.missingIds.isNotEmpty ||
            usage.chapWithoutId > 0 ||
            usage.noChapWithId > 0) ...[
          const SizedBox(height: 8),
          Text(
            'Unresolved configuration: ${usage.missingIds.length} missing credential IDs, '
            '${usage.chapWithoutId} CHAP groups without an ID, '
            '${usage.noChapWithId} no-CHAP groups with an ID. Reload and inspect before editing.',
          ),
        ],
        const SizedBox(height: 8),
        const Text(
          'Counts join separate saved-configuration reads. No client access or safe deletion is inferred.',
        ),
      ],
    );
  }
}

final class _UsageRing extends CustomPainter {
  const _UsageRing({
    required this.fraction,
    required this.usedColor,
    required this.otherColor,
  });

  final double fraction;
  final Color usedColor, otherColor;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromCircle(
      center: Offset(size.width / 2, size.height / 2),
      radius: math.min(size.width, size.height) / 2 - 10,
    );
    final background = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 16
      ..color = otherColor;
    canvas.drawArc(rect, 0, math.pi * 2, false, background);
    if (fraction > 0) {
      final foreground = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 16
        ..strokeCap = StrokeCap.round
        ..color = usedColor;
      canvas.drawArc(
        rect,
        -math.pi / 2,
        math.pi * 2 * fraction,
        false,
        foreground,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _UsageRing oldDelegate) =>
      fraction != oldDelegate.fraction ||
      usedColor != oldDelegate.usedColor ||
      otherColor != oldDelegate.otherColor;
}
