import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo_design_system/truenavo_design_system.dart';

void main() {
  test('density resolves documented width boundaries', () {
    for (final (width, expected) in [
      (320.0, TrueNavoDensity.comfortable),
      (599.0, TrueNavoDensity.comfortable),
      (600.0, TrueNavoDensity.standard),
      (999.0, TrueNavoDensity.standard),
      (1000.0, TrueNavoDensity.compact),
      (1440.0, TrueNavoDensity.compact),
    ]) {
      expect(TrueNavoDensity.resolve(width), expected);
    }
  });
}
