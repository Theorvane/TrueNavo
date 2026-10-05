import 'package:flutter/material.dart';

abstract final class TdTypography {
  static const uiFamily = 'packages/truenavo_design_system/Pretendard';
  static const monoFamily = 'packages/truenavo_design_system/JetBrainsMono';
  static const display = TextStyle(
    fontFamily: uiFamily,
    fontSize: 32,
    height: 38 / 32,
    fontWeight: FontWeight.w600,
    letterSpacing: -.9,
  );
  static const titleLarge = TextStyle(
    fontFamily: uiFamily,
    fontSize: 28,
    height: 34 / 28,
    fontWeight: FontWeight.w600,
    letterSpacing: -.7,
  );
  static const titleMedium = TextStyle(
    fontFamily: uiFamily,
    fontSize: 22,
    height: 28 / 22,
    fontWeight: FontWeight.w600,
    letterSpacing: -.4,
  );
  static const titleSmall = TextStyle(
    fontFamily: uiFamily,
    fontSize: 18,
    height: 24 / 18,
    fontWeight: FontWeight.w600,
    letterSpacing: -.2,
  );
  static const bodyLarge = TextStyle(
    fontFamily: uiFamily,
    fontSize: 16,
    height: 24 / 16,
    fontWeight: FontWeight.w400,
  );
  static const body = TextStyle(
    fontFamily: uiFamily,
    fontSize: 15,
    height: 22 / 15,
    fontWeight: FontWeight.w400,
  );
  static const label = TextStyle(
    fontFamily: uiFamily,
    fontSize: 13,
    height: 18 / 13,
    fontWeight: FontWeight.w600,
  );
  static const metadata = TextStyle(
    fontFamily: uiFamily,
    fontSize: 12,
    height: 17 / 12,
    fontWeight: FontWeight.w400,
    letterSpacing: .1,
  );
  static const micro = TextStyle(
    fontFamily: uiFamily,
    fontSize: 11,
    height: 15 / 11,
    fontWeight: FontWeight.w500,
    letterSpacing: .3,
  );
  static const metricLarge = TextStyle(
    fontFamily: monoFamily,
    fontSize: 32,
    height: 36 / 32,
    fontWeight: FontWeight.w600,
    letterSpacing: -.8,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const metricMedium = TextStyle(
    fontFamily: monoFamily,
    fontSize: 24,
    height: 30 / 24,
    fontWeight: FontWeight.w600,
    letterSpacing: -.5,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const monoBody = TextStyle(
    fontFamily: monoFamily,
    fontSize: 13,
    height: 19 / 13,
    fontWeight: FontWeight.w400,
    fontFeatures: [FontFeature.tabularFigures()],
  );
  static const monoMetadata = TextStyle(
    fontFamily: monoFamily,
    fontSize: 11,
    height: 16 / 11,
    fontWeight: FontWeight.w500,
    letterSpacing: .2,
    fontFeatures: [FontFeature.tabularFigures()],
  );
}
