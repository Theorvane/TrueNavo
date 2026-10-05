import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/dashboard/dashboard_repository.dart';
import 'package:truenas_api/truenas_api.dart';

const _secret = '<script>PRIVATE-CREDENTIAL-PLACEHOLDER</script>';
const _methods = {'system.info', 'alert.list'};

void main() {
  test('home counts and severity exclude dismissed alerts without leaking raw content', () async {
    final repository = DashboardRepository(
      _Queries([
        {
          'level': 'CRITICAL',
          'klass': 'VolumeStatus',
          'dismissed': true,
          'formatted': _secret,
        },
        {
          'level': 'WARNING',
          'klass': 'ZpoolCapacityWarning',
          'dismissed': false,
          'formatted': _secret,
          'args': {'secret': _secret},
        },
        {
          'level': 'INFO',
          'klass': _secret,
          'dismissed': false,
          'message': _secret,
          'text': _secret,
          'key': _secret,
        },
      ]),
    );
    final home = ((await repository.loadHome(
      _methods,
    )) as DashboardData<DashboardHome>).value;
    expect(home.activeAlertCount, 2);
    expect(home.criticalAlertCount, 0);
    expect(home.warningAlertCount, 1);
    expect(home.alerts.map((a) => a.message), [
      'Pool capacity warning',
      'Other alert class',
    ]);
    expect(
      home.alerts.any(
        (a) => a.message.contains(_secret) || a.level.contains(_secret),
      ),
      isFalse,
    );
    final legacy = (await repository.loadAlerts({
      'alert.list',
    })) as DashboardData<List<DashboardAlert>>;
    expect(legacy.value.length, 2);
    expect(legacy.value.first.message, 'Pool capacity warning');
  });
  test(
    'all dismissed means zero active not critical health from hidden alerts',
    () async {
      final home = ((await DashboardRepository(
        _Queries([
          {'level': 'CRITICAL', 'dismissed': true},
        ]),
      ).loadHome(_methods)) as DashboardData<DashboardHome>).value;
      expect(home.activeAlertCount, 0);
      expect(home.criticalAlertCount, 0);
      expect(home.alerts, isEmpty);
      expect(home.alertsAvailable, isTrue);
    },
  );
  final malformed = <Object?>[
    null,
    {},
    [1],
    [
      {'level': 'WARNING'},
    ],
    [
      {'level': 'WARNING', 'dismissed': 'false'},
    ],
    [
      {'level': _secret, 'dismissed': false},
    ],
    [
      {'dismissed': false},
    ],
    List.generate(513, (_) => {'level': 'INFO', 'dismissed': false}),
  ];
  for (var i = 0; i < malformed.length; i++) {
    test(
      'malformed alert inventory $i is unavailable not healthy zero',
      () async {
        final repository = DashboardRepository(_Queries(malformed[i]));
        final home = ((await repository.loadHome(
          _methods,
        )) as DashboardData<DashboardHome>).value;
        expect(home.alertsAvailable, isFalse);
        expect(home.activeAlertCount, isNull);
        expect(home.alerts, isEmpty);
        expect(
          await repository.loadAlerts({'alert.list'}),
          isA<DashboardFailure<List<DashboardAlert>>>(),
        );
      },
    );
  }
  test(
    'critical counts include valid active rows beyond the displayed limit',
    () async {
      final rows = [
        ...List.generate(60, (_) => {'level': 'INFO', 'dismissed': true}),
        ...List.generate(50, (_) => {'level': 'INFO', 'dismissed': false}),
        {'level': 'CRITICAL', 'dismissed': false},
      ];
      final home = ((await DashboardRepository(
        _Queries(rows),
      ).loadHome(_methods)) as DashboardData<DashboardHome>).value;
      expect(home.alerts.length, 50);
      expect(home.activeAlertCount, 51);
      expect(home.criticalAlertCount, 1);
    },
  );
}

class _Queries implements AuthenticatedSessionQueries {
  _Queries(this.alerts);
  final Object? alerts;
  @override
  Future<Object?> query(String method) async => method == 'system.info'
      ? {'hostname': 'sample', 'version': '25.10.1'}
      : alerts;
}
