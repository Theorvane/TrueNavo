import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/app_shell/app_destination.dart';

void main() {
  test('has exactly the approved destinations in order', () {
    expect(AppDestination.values, [
      AppDestination.home,
      AppDestination.storage,
      AppDestination.workloads,
      AppDestination.alerts,
      AppDestination.jobs,
    ]);
    expect(AppDestination.values.map((destination) => destination.label), [
      'Home',
      'Storage',
      'Workloads',
      'Alerts',
      'Jobs',
    ]);
  });
}
