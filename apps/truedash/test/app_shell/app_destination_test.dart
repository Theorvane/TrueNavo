import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/app_shell/app_destination.dart';

void main() {
  test('has exactly the approved destinations in order', () {
    expect(AppDestination.values, [
      AppDestination.home,
      AppDestination.alerts,
      AppDestination.manage,
      AppDestination.jobs,
    ]);
    expect(AppDestination.values.map((destination) => destination.label), [
      'Home',
      'Alerts',
      'Manage',
      'Jobs',
    ]);
  });
}
