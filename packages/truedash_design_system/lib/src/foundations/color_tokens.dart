import 'package:flutter/material.dart';

/// Internal primitive palette. Feature UI must consume semantic roles from
/// [TrueDashThemeExtension], never these values directly.
abstract final class TdColorTokens {
  static const darkCanvas = Color(0xFF0B1117);
  static const darkSurfaceBase = Color(0xFF111923);
  static const darkSurfaceRaised = Color(0xFF18222E);
  static const darkSurfaceOverlay = Color(0xFF202C39);
  static const lightCanvas = Color(0xFFF4F7F8);
  static const lightSurfaceBase = Color(0xFFFFFFFF);
  static const lightSurfaceRaised = Color(0xFFEEF2F4);
  static const lightSurfaceOverlay = Color(0xFFFFFFFF);
}
