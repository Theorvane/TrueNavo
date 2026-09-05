import 'package:flutter/material.dart';

abstract final class TdMotion {
  static const instant = Duration.zero;
  static const fast = Duration(milliseconds: 100);
  static const standard = Duration(milliseconds: 180);
  static const emphasized = Duration(milliseconds: 240);
  static const emphasis = emphasized;
  static Duration effective(
    Duration duration, {
    required bool disableAnimations,
  }) => disableAnimations ? Duration.zero : duration;
  static Duration of(BuildContext context, Duration duration) => effective(
    duration,
    disableAnimations: MediaQuery.disableAnimationsOf(context),
  );
}
