import 'package:flutter/material.dart';

import '../foundations/spacing_tokens.dart';
import '../foundations/typography_tokens.dart';
import '../theme/truenavo_theme_extension.dart';
import 'td_button.dart';
import 'td_panel.dart';

enum TdStateKind { loading, error, empty }

class TdStateView extends StatelessWidget {
  const TdStateView({
    required this.kind,
    required this.title,
    this.description,
    this.actionLabel,
    this.onAction,
    this.compact = false,
    super.key,
  });
  final TdStateKind kind;
  final String title;
  final String? description;
  final String? actionLabel;
  final VoidCallback? onAction;
  final bool compact;
  @override
  Widget build(BuildContext context) {
    final td = context.tdTheme;
    final color = kind == TdStateKind.error ? td.statusCritical : td.statusInfo;
    final icon = kind == TdStateKind.loading
        ? Icons.hourglass_top_rounded
        : kind == TdStateKind.error
        ? Icons.error_outline
        : Icons.inbox_outlined;
    final content = Semantics(
      liveRegion: kind != TdStateKind.empty,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, color: color),
          const SizedBox(width: TdSpacing.related),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TdTypography.titleSmall.copyWith(
                    color: td.textPrimary,
                  ),
                ),
                if (description != null) ...[
                  const SizedBox(height: TdSpacing.inline),
                  Text(
                    description!,
                    style: TdTypography.body.copyWith(color: td.textSecondary),
                  ),
                ],
                if (actionLabel != null) ...[
                  const SizedBox(height: TdSpacing.component),
                  TdButton(
                    label: actionLabel!,
                    onPressed: onAction,
                    variant: TdButtonVariant.secondary,
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
    return compact ? content : TdPanel(child: content);
  }
}
