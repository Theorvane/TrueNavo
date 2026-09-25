import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/iscsi/iscsi_global.dart';

void main() {
  test('projects documented global settings without extra response fields', () {
    final config = IscsiGlobalConfig.parse({
      'id': 1,
      'basename': 'iqn.2005-10.org.freenas.ctl',
      'isns_servers': ['192.0.2.1'],
      'listen_port': 3260,
      'pool_avail_threshold': 20,
      'alua': false,
      'iser': true,
      'private_token': 'do-not-retain',
    });
    expect(config.basename, 'iqn.2005-10.org.freenas.ctl');
    expect(config.isnsServers, ['192.0.2.1']);
    expect(config.listenPort, 3260);
    expect(config.poolAvailThreshold, 20);
    expect(config.alua, isFalse);
    expect(config.iser, isTrue);
    expect(() => config.isnsServers.clear(), throwsUnsupportedError);
    expect(config.toString(), isNot(contains('do-not-retain')));
  });

  test('rejects incomplete global settings', () {
    final valid = <String, Object?>{
      'basename': 'iqn.example',
      'isns_servers': <String>[],
      'listen_port': 3260,
      'pool_avail_threshold': null,
      'alua': false,
      'iser': false,
    };
    expect(() => IscsiGlobalConfig.parse(null), throwsFormatException);
    expect(
      () => IscsiGlobalConfig.parse({...valid, 'basename': ''}),
      throwsFormatException,
    );
    expect(
      () => IscsiGlobalConfig.parse({
        ...valid,
        'isns_servers': [null],
      }),
      throwsFormatException,
    );
    expect(
      () => IscsiGlobalConfig.parse({...valid, 'listen_port': 100}),
      throwsFormatException,
    );
    expect(
      () => IscsiGlobalConfig.parse({...valid, 'alua': null}),
      throwsFormatException,
    );
  });

  test('service status accepts only the exact iSCSI service row', () {
    expect(
      IscsiServiceStatus.parse([
        {
          'service': 'iscsitarget',
          'enable': true,
          'state': 'RUNNING',
          'pids': [1],
        },
      ])?.state,
      'RUNNING',
    );
    expect(
      IscsiServiceStatus.parse([
        {'service': 'nfs', 'enable': true, 'state': 'RUNNING'},
      ]),
      isNull,
    );
    expect(IscsiServiceStatus.parse([]), isNull);
    expect(IscsiServiceStatus.parse([{}, {}]), isNull);
  });
}
