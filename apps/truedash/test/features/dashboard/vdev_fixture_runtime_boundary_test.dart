import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/dashboard/dashboard_capabilities.dart';
import 'package:truedash/features/dashboard/vdev_fixture_contract.dart';

void main() {
  test('VDEV fixture contracts cannot enable a runtime capability', () {
    for (final family in DashboardVersionFamily.values) {
      expect(VdevFixtureContract.select(family).isRuntimeEnabled, isFalse);
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
          'vdev.query',
          'disk.query',
        },
      );
      expect(capabilities.supports(DashboardFeature.vdevs), isFalse);
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

  test('production dashboard layers do not import the fixture contract', () {
    for (final path in const [
      'lib/features/dashboard/dashboard_repository.dart',
      'lib/features/dashboard/dashboard_controller.dart',
      'lib/features/dashboard/dashboard_page.dart',
      'lib/features/dashboard/dashboard_capabilities.dart',
    ]) {
      final source = File(path).readAsStringSync();
      expect(
        source,
        isNot(contains('vdev_fixture_contract.dart')),
        reason: path,
      );
    }
  });

  test('session transport retains the exact six-method query allowlist', () {
    final source = File(
      '../../packages/truenas_api/lib/src/session/true_nas_session_repository.dart',
    ).readAsStringSync();
    final declaration = RegExp(
      r'static const readOnlyMethods = <String>\{([\s\S]*?)\};',
    ).firstMatch(source);
    expect(declaration, isNotNull);
    final methods = RegExp(r"'([^']+)'")
        .allMatches(declaration!.group(1)!)
        .map((match) => match.group(1))
        .toSet();
    expect(methods, const {
      'system.info',
      'pool.query',
      'pool.dataset.query',
      'service.query',
      'alert.list',
      'core.get_jobs',
    });
  });

  test('Storage remains explicitly unavailable for VDEVs and disks', () {
    final page = File('lib/features/dashboard/dashboard_page.dart')
        .readAsStringSync();
    expect(page, contains("title: 'VDEVs and disks unavailable'"));
    expect(
      page,
      contains('This read-only console has no approved VDEV or disk query.'),
    );
  });

  test('local deferred admission remains unable to activate an API', () {
    final source = File('lib/features/dashboard/deferred_admission_record.dart')
        .readAsStringSync();
    expect(source, contains('bool get apiCapabilityEnabled => false;'));
  });
}
