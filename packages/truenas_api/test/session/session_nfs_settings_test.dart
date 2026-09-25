import 'dart:async';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

import 'nfs_settings_fixtures.dart';

void main() {
  test(
    'readonly opening has safe projections and no service or directory probe',
    () async {
      final h = await nfsSettingsConnected(),
          i = await h.repo.loadNfsSettings();
      expect(i.config.settings.serverThreads, isNull);
      expect(i.config.reportedServers, 8);
      expect(i.blockedReason, isNull);
      expect(i.exports.single.id, 4);
      expect(i.bindChoices, contains('2001:db8::10'));
      expect(h.wire.calls.where((c) => c['method'] == 'nfs.update'), isEmpty);
      expect(
        h.wire.calls.where(
          (c) =>
              (c['method'] as String).contains('health') ||
              c['method'] == 'service.control' ||
              c['method'] == 'directoryservices.status',
        ),
        isEmpty,
      );
    },
  );
  for (final change in [
    'manual1',
    'manual256',
    'automatic',
    'protocol',
    'bindings',
    'allinterfaces',
    'mountd',
    'statd',
    'combined',
  ]) {
    test('$change exact changed-field patch and complete readback', () async {
      final h = await nfsSettingsConnected(
        configure: (w) {
          if (change == 'automatic') {
            w.config['managed_nfsd'] = false;
            w.config['servers'] = 64;
          }
        },
      );
      final i = await h.repo.loadNfsSettings();
      final settings = switch (change) {
        'manual1' => nfsChanged(i, threads: 1),
        'manual256' => nfsChanged(i, threads: 256),
        'automatic' => nfsChanged(i, threads: null),
        'protocol' => nfsChanged(i, threads: null, protocols: ['NFSV4']),
        'bindings' => nfsChanged(i, threads: null, bindings: ['192.0.2.11']),
        'allinterfaces' => nfsChanged(i, threads: null, bindings: []),
        'mountd' => nfsChanged(i, threads: null, mountdLog: false),
        'statd' => nfsChanged(i, threads: null, statdLockdLog: true),
        _ => nfsChanged(
          i,
          threads: 16,
          protocols: ['NFSV4'],
          bindings: [],
          mountdLog: false,
          statdLockdLog: true,
        ),
      };
      final r = await h.repo.reviewNfsSettings(
        NfsSettingsRequest(inventory: i, settings: settings),
      );
      expect(r.target, 'UPDATE NFS $nfsSettingsHost');
      expect(r.warnings.join(' '), contains('syslogd'));
      expect(
        (await nfsSettingsExecute(h, r)).outcome,
        NfsSettingsOutcome.completed,
      );
      final patch =
          (h.wire.calls.singleWhere(
                        (c) => c['method'] == 'nfs.update',
                      )['params']
                      as List)
                  .single
              as Map;
      final expected = switch (change) {
        'manual1' => {'servers': 1},
        'manual256' => {'servers': 256},
        'automatic' => {'servers': null},
        'protocol' => {
          'protocols': ['NFSV4'],
        },
        'bindings' => {
          'bindip': ['192.0.2.11'],
        },
        'allinterfaces' => {'bindip': []},
        'mountd' => {'mountd_log': false},
        'statd' => {'statd_lockd_log': true},
        _ => {
          'servers': 16,
          'protocols': ['NFSV4'],
          'bindip': [],
          'mountd_log': false,
          'statd_lockd_log': true,
        },
      };
      expect(patch, expected);
      expect(
        (await nfsSettingsExecute(h, r)).outcome,
        NfsSettingsOutcome.rejected,
      );
      expect(
        h.wire.calls.where((c) => c['method'] == 'nfs.update'),
        hasLength(1),
      );
      await expectLater(
        h.repo.reviewNfsSettings(
          NfsSettingsRequest(inventory: i, settings: settings),
        ),
        throwsA(isA<NfsSettingsException>()),
      );
    });
  }
  for (final gate in [
    'running',
    'crashed',
    'unknown',
    'directory',
    'realm',
    'kerberos',
    'keytab',
    'rdma',
    'ha',
    'notready',
    'noadmin',
    'boot',
    'nextboot',
    'job',
    'missingbinding',
  ]) {
    test('$gate visible but cannot review/write', () async {
      final h = await nfsSettingsConnected(
        configure: (w) {
          switch (gate) {
            case 'running':
            case 'crashed':
            case 'unknown':
              (w.service as List).single['state'] = gate.toUpperCase();
            case 'directory':
              (w.values['directoryservices.config'] as Map)['service_type'] =
                  'LDAP';
            case 'realm':
              (w.values['directoryservices.config'] as Map)['kerberos_realm'] =
                  'EXAMPLE.TEST';
            case 'kerberos':
              w.config['v4_krb'] = true;
              w.config['v4_krb_enabled'] = true;
            case 'keytab':
              w.config['keytab_has_nfs_spn'] = true;
              w.config['v4_krb_enabled'] = true;
            case 'rdma':
              w.config['rdma'] = true;
            case 'ha':
              w.values['failover.licensed'] = true;
            case 'notready':
              w.values['system.state'] = 'BOOTING';
            case 'noadmin':
              w.values['auth.me'] = {
                'privilege': {
                  'roles': ['READONLY_ADMIN'],
                },
              };
            case 'boot':
              (w.values['boot.get_state'] as Map)['healthy'] = false;
            case 'nextboot':
              w.values['boot.environment.query'] = [
                {...nfsSettingsEnvironment(), 'activated': false},
                {
                  ...nfsSettingsEnvironment(),
                  'id': 'other',
                  'dataset': 'boot-pool/ROOT/other',
                  'active': false,
                },
              ];
            case 'job':
              w.values['core.get_jobs'] = [
                {'id': 1, 'method': 'pool.import_pool', 'state': 'RUNNING'},
              ];
            case 'missingbinding':
              w.config['bindip'] = ['192.0.2.99'];
          }
        },
      );
      final i = await h.repo.loadNfsSettings();
      expect(i.blockedReason, isNotNull);
      await expectLater(
        h.repo.reviewNfsSettings(
          NfsSettingsRequest(inventory: i, settings: nfsChanged(i)),
        ),
        throwsA(isA<NfsSettingsException>()),
      );
      expect(h.wire.calls.where((c) => c['method'] == 'nfs.update'), isEmpty);
    });
  }
  for (final change in ['protocol', 'binding']) {
    test('$change blocked by enabled exports; logging still allowed', () async {
      final h = await nfsSettingsConnected(
            configure: (w) => w.exports.single['enabled'] = true,
          ),
          i = await h.repo.loadNfsSettings();
      final s = change == 'protocol'
          ? nfsChanged(i, threads: null, protocols: ['NFSV4'])
          : nfsChanged(i, threads: null, bindings: []);
      expect(
        NfsSettingsRequest(inventory: i, settings: s).validationError,
        contains('zero enabled'),
      );
      final r = await h.repo.reviewNfsSettings(
        NfsSettingsRequest(
          inventory: i,
          settings: nfsChanged(i, threads: null, mountdLog: false),
        ),
      );
      expect(
        (await nfsSettingsExecute(h, r)).outcome,
        NfsSettingsOutcome.completed,
      );
    });
  }
  for (final bad in [0, -1, 257]) {
    test('invalid thread $bad rejected locally', () async {
      final h = await nfsSettingsConnected(),
          i = await h.repo.loadNfsSettings();
      expect(nfsChanged(i, threads: bad).validationError, isNotNull);
    });
  }
  for (final bad in <List<String>>[
    [],
    ['NFSV2'],
    ['NFSV3', 'NFSV3'],
  ]) {
    test('invalid protocols $bad rejected locally', () async {
      final h = await nfsSettingsConnected(),
          i = await h.repo.loadNfsSettings();
      expect(nfsChanged(i, protocols: bad).validationError, isNotNull);
    });
  }
  for (final field in [
    'extra',
    'servers',
    'managed_nfsd',
    'v4_krb_enabled',
    'protocols',
    'bindip',
    'mountd_port',
    'id',
  ]) {
    test('malformed config $field fails closed', () async {
      final h = await nfsSettingsConnected(
        configure: (w) => w.config[field] = switch (field) {
          'extra' => true,
          'servers' => 0,
          'managed_nfsd' => 'true',
          'v4_krb_enabled' => true,
          'protocols' => ['NFSV2'],
          'bindip' => ['::::'],
          'mountd_port' => 20049,
          _ => 0,
        },
      );
      await expectLater(
        h.repo.loadNfsSettings(),
        throwsA(isA<NfsSettingsException>()),
      );
    });
  }
  for (final method in nfsSettingsReads) {
    test(
      'missing required $method advertises unavailable without RPC',
      () async {
        final h = await nfsSettingsConnected(
          configure: (w) => w.methods.remove(method),
        );
        expect(h.repo.nfsSettingsCapabilities.supported, false);
        final count = h.wire.calls.length;
        await expectLater(
          h.repo.loadNfsSettings(),
          throwsA(isA<NfsSettingsException>()),
        );
        expect(h.wire.calls.length, count);
      },
    );
  }
  test('no update permission is readonly', () async {
    final h = await nfsSettingsConnected(
      configure: (w) => w.methods.remove('nfs.update'),
    );
    expect(h.repo.nfsSettingsCapabilities.supported, true);
    expect(h.repo.nfsSettingsCapabilities.canConfigure, false);
    await h.repo.loadNfsSettings();
  });
  for (final field in [
    'job',
    'uploadable',
    'downloadable',
    'no_auth_required',
    'private',
    'check_pipes',
  ]) {
    test('unsafe update metadata $field no mutation', () async {
      final h = await nfsSettingsConnected(
        configure: (w) => w.metadata['nfs.update'] = {field: true},
      );
      expect(h.repo.nfsSettingsCapabilities.canConfigure, false);
    });
  }
  for (final version in [
    '25.04.2',
    '26.04.0',
    '25.10.1-MASTER',
    'TrueNAS-SCALE-25.10.1-RC.1',
  ]) {
    test('unsupported $version no reads', () async {
      final h = await nfsSettingsConnected(
        configure: (w) => w.version = version,
      );
      expect(h.repo.nfsSettingsCapabilities.versionSupported, false);
      await expectLater(
        h.repo.loadNfsSettings(),
        throwsA(isA<NfsSettingsException>()),
      );
    });
  }
  for (final drift in [
    'host',
    'boot',
    'role',
    'config',
    'directory',
    'choices',
    'exports',
    'service',
    'version',
  ]) {
    test('preflight $drift drift consumes review without write', () async {
      final h = await nfsSettingsConnected(), r = await nfsSettingsReview(h);
      switch (drift) {
        case 'host':
          h.wire.values['system.host_id'] = 'f' * 64;
        case 'boot':
          (h.wire.values['system.reboot.info'] as Map)['boot_id'] =
              'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
        case 'role':
          h.wire.values['auth.me'] = {
            'privilege': {'roles': []},
          };
        case 'config':
          h.wire.config['userd_manage_gids'] = true;
        case 'directory':
          (h.wire.values['directoryservices.config'] as Map)['timeout'] = 10;
        case 'choices':
          (h.wire.values['nfs.bindip_choices'] as Map)['192.0.2.12'] =
              '192.0.2.12';
        case 'exports':
          h.wire.exports.single['security'] = ['KRB5'];
        case 'service':
          (h.wire.service as List).single['enable'] = true;
        case 'version':
          h.wire.values['system.version_short'] = '25.10.2';
      }
      expect(
        (await nfsSettingsExecute(h, r)).outcome,
        NfsSettingsOutcome.rejected,
      );
      expect(h.wire.calls.where((c) => c['method'] == 'nfs.update'), isEmpty);
    });
  }
  for (final minutes in [-1, 6]) {
    test('age $minutes rejects one-use review', () async {
      final h = await nfsSettingsConnected(), r = await nfsSettingsReview(h);
      h.now = h.now.add(Duration(minutes: minutes));
      expect(
        (await nfsSettingsExecute(h, r)).outcome,
        NfsSettingsOutcome.rejected,
      );
    });
  }
  test('wrong exact confirmation consumes review', () async {
    final h = await nfsSettingsConnected(), r = await nfsSettingsReview(h);
    expect(
      (await nfsSettingsExecute(h, r, target: '${r.target} ')).outcome,
      NfsSettingsOutcome.rejected,
    );
    expect(
      (await nfsSettingsExecute(h, r)).outcome,
      NfsSettingsOutcome.rejected,
    );
  });
  for (final failure in [
    'rpc',
    'receipt',
    'mismatch',
    'readback',
    'latecontext',
    'timeout',
  ]) {
    test('postdispatch $failure permanently fences without retries', () async {
      final h = await nfsSettingsConnected(), r = await nfsSettingsReview(h);
      switch (failure) {
        case 'rpc':
          h.wire.fault = 'nfs.update';
        case 'receipt':
          h.wire.overrideReceipt = true;
          h.wire.receipt = false;
        case 'mismatch':
          h.wire.mutate = false;
        case 'readback':
          h.wire.afterWrite = () => h.wire.config['allow_nonroot'] = true;
        case 'latecontext':
          h.wire.afterWrite = () => h.authorized = false;
        case 'timeout':
          h.wire.hold = 'nfs.update';
          h.wire.held = Completer<void>();
      }
      expect(
        (await nfsSettingsExecute(h, r)).outcome,
        NfsSettingsOutcome.unknown,
      );
      if (failure == 'timeout') {
        h.wire.held!.complete();
        await Future<void>.delayed(Duration.zero);
      }
      final count = h.wire.calls.length;
      expect(
        (await nfsSettingsExecute(h, r)).outcome,
        NfsSettingsOutcome.rejected,
      );
      await expectLater(
        h.repo.loadNfsSettings(),
        throwsA(isA<NfsSettingsException>()),
      );
      expect(h.wire.calls.length, count);
    });
  }
  test('held preflight current false prevents late RPC', () async {
    final h = await nfsSettingsConnected(), r = await nfsSettingsReview(h);
    h.wire.hold = 'directoryservices.config';
    h.wire.held = Completer<void>();
    final future = nfsSettingsExecute(h, r);
    await Future<void>.delayed(const Duration(milliseconds: 5));
    h.authorized = false;
    h.wire.held!.complete();
    expect((await future).outcome, NfsSettingsOutcome.rejected);
    expect(h.wire.calls.where((c) => c['method'] == 'nfs.update'), isEmpty);
  });
  test('error messages contain no remote details', () async {
    final h = await nfsSettingsConnected(
      configure: (w) => w.fault = 'nfs.config',
    );
    try {
      await h.repo.loadNfsSettings();
      fail('must reject');
    } on NfsSettingsException catch (e) {
      expect(e.toString(), isNot(contains(nfsSettingsPrivate)));
    }
  });
}
