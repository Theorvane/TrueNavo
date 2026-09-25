import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid_design_system/trueraid_design_system.dart';

void main() {
  test('density resolves documented width boundaries', () {
    for (final (width, expected) in [
      (320.0, TrueRAIDDensity.comfortable),
      (599.0, TrueRAIDDensity.comfortable),
      (600.0, TrueRAIDDensity.standard),
      (999.0, TrueRAIDDensity.standard),
      (1000.0, TrueRAIDDensity.compact),
      (1440.0, TrueRAIDDensity.compact),
    ]) {
      expect(TrueRAIDDensity.resolve(width), expected);
    }
  });
}
