import 'package:flutter/material.dart';

import '../foundations/color_tokens.dart';
import '../foundations/radius_tokens.dart';
import '../foundations/typography_tokens.dart';
import 'truedash_density.dart';
import 'truedash_theme_extension.dart';

abstract final class TrueDashTheme {
  static ThemeData light({
    TrueDashDensity density = TrueDashDensity.comfortable,
    bool highContrast = false,
  }) => _build(Brightness.light, _light(density, highContrast));
  static ThemeData dark({
    TrueDashDensity density = TrueDashDensity.comfortable,
    bool highContrast = false,
  }) => _build(Brightness.dark, _dark(density, highContrast));

  static ThemeData _build(Brightness brightness, TrueDashThemeExtension td) {
    final controlBorder = td.highContrast ? td.borderStrong : td.borderControl;
    final scheme =
        ColorScheme.fromSeed(
          seedColor: td.actionPrimary,
          brightness: brightness,
        ).copyWith(
          surface: td.surfaceBase,
          onSurface: td.textPrimary,
          error: td.statusCritical,
          primary: td.actionPrimary,
          onPrimary: td.onActionPrimary,
        );
    final text = TextTheme(
      displaySmall: TdTypography.display.copyWith(color: td.textPrimary),
      headlineMedium: TdTypography.titleLarge.copyWith(color: td.textPrimary),
      titleLarge: TdTypography.titleMedium.copyWith(color: td.textPrimary),
      titleMedium: TdTypography.titleSmall.copyWith(color: td.textPrimary),
      bodyLarge: TdTypography.bodyLarge.copyWith(color: td.textPrimary),
      bodyMedium: TdTypography.body.copyWith(color: td.textPrimary),
      labelLarge: TdTypography.label.copyWith(color: td.textPrimary),
      bodySmall: TdTypography.metadata.copyWith(color: td.textMuted),
    );
    return ThemeData(
      useMaterial3: true,
      brightness: brightness,
      colorScheme: scheme,
      scaffoldBackgroundColor: td.canvas,
      textTheme: text,
      extensions: [td],
      dividerColor: td.borderSubtle,
      cardTheme: CardThemeData(
        color: td.surfaceBase,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(TdRadius.card),
          side: BorderSide(color: td.borderSubtle),
        ),
      ),
      inputDecorationTheme: InputDecorationTheme(
        filled: true,
        fillColor: td.surfaceBase,
        labelStyle: TdTypography.label.copyWith(color: td.textSecondary),
        hintStyle: TdTypography.body.copyWith(color: td.textMuted),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 14,
        ),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TdRadius.control),
          borderSide: BorderSide(color: controlBorder),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TdRadius.control),
          borderSide: BorderSide(color: controlBorder),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(TdRadius.control),
          borderSide: BorderSide(color: td.actionPrimary, width: 2),
        ),
      ),
      focusColor: td.actionPrimary.withValues(alpha: .16),
      dividerTheme: DividerThemeData(color: td.borderSubtle, thickness: 1),
    );
  }

  static TrueDashThemeExtension _dark(
    TrueDashDensity density,
    bool highContrast,
  ) => TrueDashThemeExtension(
    canvas: TdColorTokens.darkCanvas,
    surfaceBase: TdColorTokens.darkSurfaceBase,
    surfaceRaised: TdColorTokens.darkSurfaceRaised,
    surfaceOverlay: TdColorTokens.darkSurfaceOverlay,
    borderSubtle: const Color(0xFF253241),
    borderStrong: const Color(0xFF3A495A),
    borderControl: const Color(0xFF60758A),
    textPrimary: const Color(0xFFF2F6F8),
    textSecondary: const Color(0xFFAAB6C2),
    textMuted: const Color(0xFF7C8997),
    actionPrimary: const Color(0xFF2CC7D4),
    onActionPrimary: const Color(0xFF031719),
    actionDisabled: const Color(0xFF245157),
    onActionDisabled: const Color(0xFFD5E5E7),
    borderDisabled: const Color(0xFF4D777C),
    actionHoverOnSolid: const Color(0x1F000000),
    actionPressedOnSolid: const Color(0x3D000000),
    actionHoverOnSurface: const Color(0x33FFFFFF),
    actionPressedOnSurface: const Color(0x52FFFFFF),
    actionFocusOnSolid: const Color(0xFF031719),
    actionFocusOnSurface: const Color(0xFFB8F7FB),
    statusSuccess: const Color(0xFF42B883),
    statusWarning: const Color(0xFFF2B84B),
    statusWarningSurface: const Color(0xFF382D16),
    statusCritical: const Color(0xFFF16D75),
    statusInfo: const Color(0xFF68A7FF),
    statusStaleForeground: const Color(0xFFAAB6C2),
    statusStaleSurface: const Color(0xFF18222E),
    density: density,
    highContrast: highContrast,
  );
  static TrueDashThemeExtension _light(
    TrueDashDensity density,
    bool highContrast,
  ) => TrueDashThemeExtension(
    canvas: TdColorTokens.lightCanvas,
    surfaceBase: TdColorTokens.lightSurfaceBase,
    surfaceRaised: TdColorTokens.lightSurfaceRaised,
    surfaceOverlay: TdColorTokens.lightSurfaceOverlay,
    borderSubtle: const Color(0xFFD8E0E5),
    borderStrong: const Color(0xFFAAB7C2),
    borderControl: const Color(0xFF738393),
    textPrimary: const Color(0xFF18212B),
    textSecondary: const Color(0xFF596878),
    textMuted: const Color(0xFF62717F),
    actionPrimary: const Color(0xFF087D87),
    onActionPrimary: const Color(0xFFFFFFFF),
    actionDisabled: const Color(0xFFB3C4C7),
    onActionDisabled: const Color(0xFF263F43),
    borderDisabled: const Color(0xFF718F93),
    actionHoverOnSolid: const Color(0x1F000000),
    actionPressedOnSolid: const Color(0x3D000000),
    actionHoverOnSurface: const Color(0x1F000000),
    actionPressedOnSurface: const Color(0x3D000000),
    actionFocusOnSolid: const Color(0xFFFFFFFF),
    actionFocusOnSurface: const Color(0xFF031719),
    statusSuccess: const Color(0xFF247653),
    statusWarning: const Color(0xFF7A4D00),
    statusWarningSurface: const Color(0xFFFFF4D6),
    statusCritical: const Color(0xFFB83A45),
    statusInfo: const Color(0xFF2768B2),
    statusStaleForeground: const Color(0xFF596878),
    statusStaleSurface: const Color(0xFFEEF2F4),
    density: density,
    highContrast: highContrast,
  );
}
