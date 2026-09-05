import 'package:flutter/material.dart';

import 'truedash_density.dart';

@immutable
class TrueDashThemeExtension extends ThemeExtension<TrueDashThemeExtension> {
  const TrueDashThemeExtension({
    required this.canvas,
    required this.surfaceBase,
    required this.surfaceRaised,
    required this.surfaceOverlay,
    required this.borderSubtle,
    required this.borderStrong,
    required this.borderControl,
    required this.textPrimary,
    required this.textSecondary,
    required this.textMuted,
    required this.actionPrimary,
    required this.onActionPrimary,
    required this.actionDisabled,
    required this.onActionDisabled,
    required this.borderDisabled,
    required this.actionHoverOnSolid,
    required this.actionPressedOnSolid,
    required this.actionHoverOnSurface,
    required this.actionPressedOnSurface,
    required this.actionFocusOnSolid,
    required this.actionFocusOnSurface,
    required this.statusSuccess,
    required this.statusWarning,
    required this.statusWarningSurface,
    required this.statusCritical,
    required this.statusInfo,
    required this.statusStaleForeground,
    required this.statusStaleSurface,
    required this.density,
    required this.highContrast,
  });

  final Color canvas;
  final Color surfaceBase;
  final Color surfaceRaised;
  final Color surfaceOverlay;
  final Color borderSubtle;
  final Color borderStrong;
  final Color borderControl;
  final Color textPrimary;
  final Color textSecondary;
  final Color textMuted;
  final Color actionPrimary;
  final Color onActionPrimary;
  final Color actionDisabled;
  final Color onActionDisabled;
  final Color borderDisabled;
  final Color actionHoverOnSolid;
  final Color actionPressedOnSolid;
  final Color actionHoverOnSurface;
  final Color actionPressedOnSurface;
  final Color actionFocusOnSolid;
  final Color actionFocusOnSurface;
  final Color statusSuccess;
  final Color statusWarning;
  final Color statusWarningSurface;
  final Color statusCritical;
  final Color statusInfo;
  final Color statusStaleForeground;
  final Color statusStaleSurface;
  final TrueDashDensity density;
  final bool highContrast;

  @override
  TrueDashThemeExtension copyWith({
    Color? canvas,
    Color? surfaceBase,
    Color? surfaceRaised,
    Color? surfaceOverlay,
    Color? borderSubtle,
    Color? borderStrong,
    Color? borderControl,
    Color? textPrimary,
    Color? textSecondary,
    Color? textMuted,
    Color? actionPrimary,
    Color? onActionPrimary,
    Color? actionDisabled,
    Color? onActionDisabled,
    Color? borderDisabled,
    Color? actionHoverOnSolid,
    Color? actionPressedOnSolid,
    Color? actionHoverOnSurface,
    Color? actionPressedOnSurface,
    Color? actionFocusOnSolid,
    Color? actionFocusOnSurface,
    Color? statusSuccess,
    Color? statusWarning,
    Color? statusWarningSurface,
    Color? statusCritical,
    Color? statusInfo,
    Color? statusStaleForeground,
    Color? statusStaleSurface,
    TrueDashDensity? density,
    bool? highContrast,
  }) => TrueDashThemeExtension(
    canvas: canvas ?? this.canvas,
    surfaceBase: surfaceBase ?? this.surfaceBase,
    surfaceRaised: surfaceRaised ?? this.surfaceRaised,
    surfaceOverlay: surfaceOverlay ?? this.surfaceOverlay,
    borderSubtle: borderSubtle ?? this.borderSubtle,
    borderStrong: borderStrong ?? this.borderStrong,
    borderControl: borderControl ?? this.borderControl,
    textPrimary: textPrimary ?? this.textPrimary,
    textSecondary: textSecondary ?? this.textSecondary,
    textMuted: textMuted ?? this.textMuted,
    actionPrimary: actionPrimary ?? this.actionPrimary,
    onActionPrimary: onActionPrimary ?? this.onActionPrimary,
    actionDisabled: actionDisabled ?? this.actionDisabled,
    onActionDisabled: onActionDisabled ?? this.onActionDisabled,
    borderDisabled: borderDisabled ?? this.borderDisabled,
    actionHoverOnSolid: actionHoverOnSolid ?? this.actionHoverOnSolid,
    actionPressedOnSolid: actionPressedOnSolid ?? this.actionPressedOnSolid,
    actionHoverOnSurface: actionHoverOnSurface ?? this.actionHoverOnSurface,
    actionPressedOnSurface:
        actionPressedOnSurface ?? this.actionPressedOnSurface,
    actionFocusOnSolid: actionFocusOnSolid ?? this.actionFocusOnSolid,
    actionFocusOnSurface: actionFocusOnSurface ?? this.actionFocusOnSurface,
    statusSuccess: statusSuccess ?? this.statusSuccess,
    statusWarning: statusWarning ?? this.statusWarning,
    statusWarningSurface: statusWarningSurface ?? this.statusWarningSurface,
    statusCritical: statusCritical ?? this.statusCritical,
    statusInfo: statusInfo ?? this.statusInfo,
    statusStaleForeground: statusStaleForeground ?? this.statusStaleForeground,
    statusStaleSurface: statusStaleSurface ?? this.statusStaleSurface,
    density: density ?? this.density,
    highContrast: highContrast ?? this.highContrast,
  );

  @override
  TrueDashThemeExtension lerp(
    ThemeExtension<TrueDashThemeExtension>? other,
    double t,
  ) {
    if (other is! TrueDashThemeExtension) return this;
    return TrueDashThemeExtension(
      canvas: Color.lerp(canvas, other.canvas, t)!,
      surfaceBase: Color.lerp(surfaceBase, other.surfaceBase, t)!,
      surfaceRaised: Color.lerp(surfaceRaised, other.surfaceRaised, t)!,
      surfaceOverlay: Color.lerp(surfaceOverlay, other.surfaceOverlay, t)!,
      borderSubtle: Color.lerp(borderSubtle, other.borderSubtle, t)!,
      borderStrong: Color.lerp(borderStrong, other.borderStrong, t)!,
      borderControl: Color.lerp(borderControl, other.borderControl, t)!,
      textPrimary: Color.lerp(textPrimary, other.textPrimary, t)!,
      textSecondary: Color.lerp(textSecondary, other.textSecondary, t)!,
      textMuted: Color.lerp(textMuted, other.textMuted, t)!,
      actionPrimary: Color.lerp(actionPrimary, other.actionPrimary, t)!,
      onActionPrimary: Color.lerp(onActionPrimary, other.onActionPrimary, t)!,
      actionDisabled: Color.lerp(actionDisabled, other.actionDisabled, t)!,
      onActionDisabled: Color.lerp(
        onActionDisabled,
        other.onActionDisabled,
        t,
      )!,
      borderDisabled: Color.lerp(borderDisabled, other.borderDisabled, t)!,
      actionHoverOnSolid: Color.lerp(
        actionHoverOnSolid,
        other.actionHoverOnSolid,
        t,
      )!,
      actionPressedOnSolid: Color.lerp(
        actionPressedOnSolid,
        other.actionPressedOnSolid,
        t,
      )!,
      actionHoverOnSurface: Color.lerp(
        actionHoverOnSurface,
        other.actionHoverOnSurface,
        t,
      )!,
      actionPressedOnSurface: Color.lerp(
        actionPressedOnSurface,
        other.actionPressedOnSurface,
        t,
      )!,
      actionFocusOnSolid: Color.lerp(
        actionFocusOnSolid,
        other.actionFocusOnSolid,
        t,
      )!,
      actionFocusOnSurface: Color.lerp(
        actionFocusOnSurface,
        other.actionFocusOnSurface,
        t,
      )!,
      statusSuccess: Color.lerp(statusSuccess, other.statusSuccess, t)!,
      statusWarning: Color.lerp(statusWarning, other.statusWarning, t)!,
      statusWarningSurface: Color.lerp(
        statusWarningSurface,
        other.statusWarningSurface,
        t,
      )!,
      statusCritical: Color.lerp(statusCritical, other.statusCritical, t)!,
      statusInfo: Color.lerp(statusInfo, other.statusInfo, t)!,
      statusStaleForeground: Color.lerp(
        statusStaleForeground,
        other.statusStaleForeground,
        t,
      )!,
      statusStaleSurface: Color.lerp(
        statusStaleSurface,
        other.statusStaleSurface,
        t,
      )!,
      density: t < .5 ? density : other.density,
      highContrast: t < .5 ? highContrast : other.highContrast,
    );
  }
}

extension TrueDashThemeContext on BuildContext {
  TrueDashThemeExtension get tdTheme {
    final value = Theme.of(this).extension<TrueDashThemeExtension>();
    assert(
      value != null,
      'TrueDashTheme must be installed above this context.',
    );
    return value!;
  }
}
