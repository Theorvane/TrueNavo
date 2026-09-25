import 'package:flutter/material.dart';

import '../foundations/radius_tokens.dart';
import '../foundations/sizing_tokens.dart';
import '../foundations/spacing_tokens.dart';
import '../foundations/typography_tokens.dart';
import '../theme/trueraid_density.dart';
import '../theme/trueraid_theme_extension.dart';

enum TdButtonVariant { primary, secondary, ghost, danger }

enum TdButtonSize { comfortable, compact }

class TdButton extends StatelessWidget {
  const TdButton({
    required this.label,
    required this.onPressed,
    this.icon,
    this.variant = TdButtonVariant.primary,
    this.size,
    this.isLoading = false,
    this.expand = false,
    super.key,
  });
  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final TdButtonVariant variant;

  /// When omitted, the current width-derived density selects the size.
  final TdButtonSize? size;
  final bool isLoading;
  final bool expand;

  @override
  Widget build(BuildContext context) {
    final theme = context.tdTheme;
    final enabled = onPressed != null && !isLoading;
    final foreground = switch (variant) {
      TdButtonVariant.primary => theme.onActionPrimary,
      TdButtonVariant.danger => theme.onActionPrimary,
      TdButtonVariant.secondary || TdButtonVariant.ghost => theme.textPrimary,
    };
    final background = switch (variant) {
      TdButtonVariant.primary => theme.actionPrimary,
      TdButtonVariant.danger => theme.statusCritical,
      TdButtonVariant.secondary => theme.surfaceRaised,
      TdButtonVariant.ghost => Colors.transparent,
    };
    final border = switch (variant) {
      TdButtonVariant.secondary => theme.borderControl,
      TdButtonVariant.ghost => Colors.transparent,
      _ => background,
    };
    final disabledForeground = theme.onActionDisabled;
    final disabledBackground = theme.actionDisabled;
    final disabledBorder = theme.borderDisabled;
    final isSolid =
        variant == TdButtonVariant.primary || variant == TdButtonVariant.danger;
    final stateColor = WidgetStateProperty.resolveWith<Color>((states) {
      if (states.contains(WidgetState.disabled) && !isLoading) {
        return disabledForeground;
      }
      return foreground;
    });
    final stateBackground = WidgetStateProperty.resolveWith<Color>((states) {
      if (states.contains(WidgetState.disabled) && !isLoading) {
        return disabledBackground;
      }
      return background;
    });
    final stateBorder = WidgetStateProperty.resolveWith<BorderSide>((states) {
      if (states.contains(WidgetState.disabled) && !isLoading) {
        return BorderSide(color: disabledBorder);
      }
      if (states.contains(WidgetState.focused)) {
        return BorderSide(
          color: isSolid
              ? theme.actionFocusOnSolid
              : theme.actionFocusOnSurface,
          width: 2,
        );
      }
      return BorderSide(color: border);
    });
    final overlay = WidgetStateProperty.resolveWith<Color?>((states) {
      if (states.contains(WidgetState.disabled)) return Colors.transparent;
      if (states.contains(WidgetState.pressed)) {
        return isSolid
            ? theme.actionPressedOnSolid
            : theme.actionPressedOnSurface;
      }
      if (states.contains(WidgetState.hovered)) {
        return isSolid ? theme.actionHoverOnSolid : theme.actionHoverOnSurface;
      }
      return Colors.transparent;
    });
    final resolvedSize =
        size ??
        (theme.density == TrueRAIDDensity.compact
            ? TdButtonSize.compact
            : TdButtonSize.comfortable);
    final height = resolvedSize == TdButtonSize.compact
        ? TdSizing.desktopButton
        : TdSizing.mobileButton;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: TdSizing.minimumTouchTarget),
        child: SizedBox(
          width: expand ? double.infinity : null,
          height: height,
          child: TextButton.icon(
            onPressed: enabled ? onPressed : null,
            style: ButtonStyle(
              foregroundColor: stateColor,
              backgroundColor: stateBackground,
              side: stateBorder,
              overlayColor: overlay,
              shape: WidgetStatePropertyAll(
                RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(TdRadius.control),
                ),
              ),
              textStyle: WidgetStatePropertyAll(TdTypography.label),
              padding: const WidgetStatePropertyAll(
                EdgeInsets.symmetric(horizontal: TdSpacing.component),
              ),
            ),
            icon: isLoading
                ? SizedBox.square(
                    dimension: TdSizing.smallIcon,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: foreground,
                    ),
                  )
                : icon == null
                ? null
                : Icon(icon, size: TdSizing.icon),
            label: Text(label),
          ),
        ),
      ),
    );
  }
}
