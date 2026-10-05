import 'package:flutter/material.dart';

import '../foundations/radius_tokens.dart';
import '../foundations/spacing_tokens.dart';
import '../foundations/typography_tokens.dart';
import '../theme/truenavo_theme_extension.dart';

class TdPanel extends StatelessWidget {
  const TdPanel({
    required this.child,
    this.title,
    this.description,
    this.action,
    this.padding,
    super.key,
  });
  final Widget child;
  final String? title;
  final String? description;
  final Widget? action;
  final EdgeInsetsGeometry? padding;
  @override
  Widget build(BuildContext context) {
    final td = context.tdTheme;
    return Container(
      decoration: BoxDecoration(
        color: td.surfaceBase,
        borderRadius: BorderRadius.circular(TdRadius.card),
        border: Border.all(color: td.borderSubtle),
      ),
      padding: padding ?? const EdgeInsets.all(TdSpacing.group),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (title != null || action != null)
            LayoutBuilder(
              builder: (context, constraints) {
                final titleWidget = title == null
                    ? null
                    : Text(
                        title!,
                        style: TdTypography.titleSmall.copyWith(
                          color: td.textPrimary,
                        ),
                      );
                if (constraints.maxWidth < 480) {
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ?titleWidget,
                      if (titleWidget != null && action != null)
                        const SizedBox(height: TdSpacing.related),
                      ?action,
                    ],
                  );
                }
                return Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (titleWidget != null) Expanded(child: titleWidget),
                    ?action,
                  ],
                );
              },
            ),
          if (description != null) ...[
            const SizedBox(height: TdSpacing.inline),
            Text(
              description!,
              style: TdTypography.body.copyWith(color: td.textSecondary),
            ),
          ],
          if (title != null || description != null)
            const SizedBox(height: TdSpacing.component),
          child,
        ],
      ),
    );
  }
}
