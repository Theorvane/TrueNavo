import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/dashboard/dashboard_capabilities.dart';
import 'package:truedash/features/dashboard/disk_fixture_contract.dart';

void main() {
  test('Disk fixture contract never enables runtime support', () {
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

  test('production dashboard layers do not import Disk fixture contract', () {
    for (final path in const [
      'lib/features/dashboard/dashboard_repository.dart',
      'lib/features/dashboard/dashboard_controller.dart',
      'lib/features/dashboard/dashboard_page.dart',
      'lib/features/dashboard/dashboard_capabilities.dart',
    ]) {
      expect(
        File(path).readAsStringSync(),
        isNot(contains('disk_fixture_contract.dart')),
        reason: path,
      );
    }
  });

  test('session transport retains exact six-method allowlist without disk', () {
    final source = File(
      '../../packages/truenas_api/lib/src/session/true_nas_session_repository.dart',
    ).readAsStringSync();
    final declaration = RegExp(
      r'static const readOnlyMethods = <String>\{([\s\S]*?)\};',
    ).firstMatch(source)!;
    final methods = RegExp(r"'([^']+)'")
        .allMatches(declaration.group(1)!)
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
    expect(methods, isNot(contains('disk.query')));
  });

  test('Storage keeps disks unavailable and admission disabled', () {
    final page = File('lib/features/dashboard/dashboard_page.dart')
        .readAsStringSync();
    expect(page, contains("title: 'VDEVs and disks unavailable'"));
    final admission = File(
      'lib/features/dashboard/deferred_admission_record.dart',
    ).readAsStringSync();
    final evidence = File(
      'lib/features/dashboard/live_observation_evidence.dart',
    ).readAsStringSync();
    expect(admission, contains('bool get apiCapabilityEnabled => false;'));
    expect(evidence, contains('bool get apiCapabilityEnabled => false;'));
  });
}
