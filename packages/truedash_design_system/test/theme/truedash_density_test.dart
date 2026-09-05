import 'package:flutter_test/flutter_test.dart';
import 'package:truedash_design_system/truedash_design_system.dart';

void main() {
  test('density resolves documented width boundaries', () {
    for (final (width, expected) in [
      (320.0, TrueDashDensity.comfortable),
      (599.0, TrueDashDensity.comfortable),
      (600.0, TrueDashDensity.standard),
      (999.0, TrueDashDensity.standard),
      (1000.0, TrueDashDensity.compact),
      (1440.0, TrueDashDensity.compact),
    ]) {
      expect(TrueDashDensity.resolve(width), expected);
    }
  });
}
