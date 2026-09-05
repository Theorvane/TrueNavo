import 'package:flutter/material.dart';

import '../foundations/spacing_tokens.dart';
import '../foundations/typography_tokens.dart';
import '../theme/truedash_theme_extension.dart';
import 'td_panel.dart';

class TdMetricCard extends StatelessWidget {
  const TdMetricCard({
    required this.label,
    required this.value,
    this.unit,
    this.freshness,
    this.trend,
    super.key,
  });
  final String label;
  final String value;
  final String? unit;
  final String? freshness;
  final String? trend;
  @override
  Widget build(BuildContext context) {
    final td = context.tdTheme;
    final semanticParts = <String>[label, value];
    if (unit != null) semanticParts.add(unit!);
    if (freshness != null) semanticParts.add(freshness!);
    return Semantics(
      label: semanticParts.join(', '),
      child: TdPanel(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TdTypography.label.copyWith(color: td.textSecondary),
            ),
            const SizedBox(height: TdSpacing.related),
            Wrap(
              crossAxisAlignment: WrapCrossAlignment.end,
              spacing: TdSpacing.inline,
              children: [
                Text(
                  value,
                  style: TdTypography.metricLarge.copyWith(
                    color: td.textPrimary,
                  ),
                ),
                if (unit != null)
                  Padding(
                    padding: const EdgeInsets.only(
                      bottom: TdSpacing.inlineTight,
                    ),
                    child: Text(
                      unit!,
                      style: TdTypography.label.copyWith(
                        color: td.textSecondary,
                      ),
                    ),
                  ),
              ],
            ),
            if (trend != null || freshness != null) ...[
              const SizedBox(height: TdSpacing.related),
              Text(
                [?trend, ?freshness].join(' · '),
                style: TdTypography.metadata.copyWith(color: td.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
