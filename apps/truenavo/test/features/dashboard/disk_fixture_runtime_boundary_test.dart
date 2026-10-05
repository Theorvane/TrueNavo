import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/dashboard/dashboard_capabilities.dart';
import 'package:truenavo/features/dashboard/disk_fixture_contract.dart';

void main() {
  test('Disk fixture contract cannot enable runtime support', () {
    for (final family in DashboardVersionFamily.values) {
      expect(DiskFixtureContract.select(family).isRuntimeEnabled, isFalse);
      final capabilities = DashboardCapabilities.forSession(
        version: switch (family) {
          DashboardVersionFamily.v25_04 => '25.04',
          DashboardVersionFamily.v25_10 => '25.10',
          DashboardVersionFamily.v26Plus => '26.0',
          DashboardVersionFamily.unknownUnsupported => 'unknown',
        },
        availableMethodNames: const {
          'system.info',
          'pool.query',
          'pool.dataset.query',
          'service.query',
          'alert.list',
          'core.get_jobs',
          'disk.query',
        },
      );

      expect(capabilities.supports(DashboardFeature.disks), isFalse);
      expect(capabilities.allowedMethods, const {
        'system.info',
        'pool.query',
        'pool.dataset.query',
        'service.query',
        'alert.list',
        'core.get_jobs',
      });
    }
  });
}
