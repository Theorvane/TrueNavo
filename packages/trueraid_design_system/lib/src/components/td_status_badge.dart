import 'package:flutter/material.dart';

import '../foundations/radius_tokens.dart';
import '../foundations/sizing_tokens.dart';
import '../foundations/spacing_tokens.dart';
import '../foundations/typography_tokens.dart';
import '../theme/trueraid_theme_extension.dart';

enum TdStatus { neutral, success, warning, critical, info, stale }

class TdStatusBadge extends StatelessWidget {
  const TdStatusBadge({required this.status, required this.label, super.key});
  final TdStatus status;
  final String label;
  @override
  Widget build(BuildContext context) {
    final td = context.tdTheme;
    final (color, surface, icon) = switch (status) {
      TdStatus.neutral => (
        td.textSecondary,
        td.textSecondary.withValues(alpha: .12),
        Icons.remove_circle_outline,
      ),
      TdStatus.success => (
        td.statusSuccess,
        td.statusSuccess.withValues(alpha: .12),
        Icons.check_circle_outline,
      ),
      TdStatus.warning => (
        td.statusWarning,
        td.statusWarning.withValues(alpha: .12),
        Icons.warning_amber_rounded,
      ),
      TdStatus.critical => (
        td.statusCritical,
        td.statusCritical.withValues(alpha: .12),
        Icons.error_outline,
      ),
      TdStatus.info => (
        td.statusInfo,
        td.statusInfo.withValues(alpha: .12),
        Icons.info_outline,
      ),
      TdStatus.stale => (
        td.statusStaleForeground,
        td.statusStaleSurface,
        Icons.schedule_outlined,
      ),
    };
    return Semantics(
      label: '$label status',
      child: Container(
        padding: const EdgeInsets.symmetric(
          horizontal: TdSpacing.inline,
          vertical: TdSpacing.inlineTight,
        ),
        decoration: BoxDecoration(
          color: surface,
          borderRadius: BorderRadius.circular(TdRadius.pill),
        ),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: TdSpacing.inlineTight,
          children: [
            ExcludeSemantics(
              child: Icon(icon, size: TdSizing.smallIcon, color: color),
            ),
            Text(label, style: TdTypography.label.copyWith(color: color)),
          ],
        ),
      ),
    );
  }
}
