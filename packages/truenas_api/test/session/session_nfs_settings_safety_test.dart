import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

import 'nfs_settings_fixtures.dart' as f;

const _forbidden = {
  'directoryservices.status',
  'directoryservices.health.check',
  'directoryservices.cache_refresh',
  'user.get_user_obj',
  'group.get_group_obj',
  'nfs.get_nfs3_clients',
  'nfs.get_nfs4_clients',
  'nfs.client_count',
  'nfs.sec',
  'nfs.bindip',
  'nfs.setup_directories',
  'service.control',
  'sharing.nfs.create',
  'sharing.nfs.update',
  'sharing.nfs.delete',
  'filesystem.set_zfs_attributes',
  'zfs.dataset.update',
  'core.job_abort',
};
const _smbReads = {
  'smb.config',
  'smb.update',
  'system.security.config',
  'sharing.smb.query',
};
Iterable<Map<String, dynamic>> _writes(f.NfsSettingsHarness h) =>
    h.wire.calls.where((c) => c['method'] == 'nfs.update');
void _noSideCalls(f.NfsSettingsHarness h) => expect(
  h.wire.calls.where((c) => _forbidden.contains(c['method'])),
  isEmpty,
);

void main() {
  test('global NFS uses only selected dependencies, never status, client or DNS probes', () async {
    final h = await f.nfsSettingsConnected(
      configure: (w) => w.methods.addAll(_forbidden),
    );
    final r = await f.nfsSettingsReview(h);
    expect(
      (await f.nfsSettingsExecute(h, r)).outcome,
      NfsSettingsOutcome.completed,
    );
    _noSideCalls(h);
    for (final c in h.wire.calls.where(
      (c) => c['method'] == 'sharing.nfs.query',
    )) {
      final options = (c['params'] as List).last as Map;
      expect(options['select'], ['id', 'enabled', 'security']);
      expect(options['extra'], {'retrieve_locked_info': false});
      expect(options.containsKey('force_sql_filters'), isFalse);
    }
    expect(_writes(h).single['params'], [
      {'servers': 12},
    ]);
  });

  for (final key in ['credential', 'configuration', 'kerberos_realm']) {
    test(
      'dormant directory $key remains private and cannot authorize update',
      () async {
        final h = await f.nfsSettingsConnected(
          configure: (w) {
            (w.values['directoryservices.config']
                as Map)[key] = key == 'kerberos_realm'
                ? f.nfsSettingsPrivate
                : {'password': f.nfsSettingsPrivate};
          },
        );
        final i = await h.repo.loadNfsSettings();
        expect(i.directoryConfigured, isTrue);
        expect(
          '${i.blockedReason} ${i.config.settings.protocols}',
          isNot(contains(f.nfsSettingsPrivate)),
        );
        await expectLater(
          h.repo.reviewNfsSettings(
            NfsSettingsRequest(inventory: i, settings: f.nfsChanged(i)),
          ),
          throwsA(isA<NfsSettingsException>()),
        );
        expect(_writes(h), isEmpty);
        _noSideCalls(h);
      },
    );
  }

  for (final security in ['KRB5', 'KRB5I', 'KRB5P']) {
    test('disabled $security export still prevents removal of NFSV4', () async {
      final h = await f.nfsSettingsConnected(
        configure: (w) {
          w.exports.single['security'] = [security];
        },
      );
      final i = await h.repo.loadNfsSettings();
      expect(i.enabledExportCount, 0);
      final request = NfsSettingsRequest(
        inventory: i,
        settings: f.nfsChanged(i, protocols: ['NFSV3']),
      );
      expect(request.validationError, contains('including disabled exports'));
      await expectLater(
        h.repo.reviewNfsSettings(request),
        throwsA(isA<NfsSettingsException>()),
      );
      expect(_writes(h), isEmpty);
    });
  }

  test('autotuned log-only patch does not pin the computed worker count or erase protected fields', () async {
    final h = await f.nfsSettingsConnected(
      configure: (w) {
        w.config['mountd_port'] = 20048;
        w.config['rpcstatd_port'] = 662;
        w.config['rpclockd_port'] = 32803;
        w.config['allow_nonroot'] = true;
        w.config['userd_manage_gids'] = true;
      },
    );
    final before = Map<String, Object?>.from(h.wire.config);
    final r = await f.nfsSettingsReview(
      h,
      settings: (i) => f.nfsChanged(i, threads: null, mountdLog: false),
    );
    expect(r.request.inventory.config.reportedServers, 8);
    expect(r.request.inventory.config.settings.serverThreads, isNull);
    expect(
      (await f.nfsSettingsExecute(h, r)).outcome,
      NfsSettingsOutcome.completed,
    );
    expect(_writes(h).single['params'], [
      {'mountd_log': false},
    ]);
    expect(h.wire.config, {...before, 'mountd_log': false});
    _noSideCalls(h);
  });

  test('manual to automatic sends explicit null and accepts separately computed count', () async {
    final h = await f.nfsSettingsConnected(
      configure: (w) {
        w.config['managed_nfsd'] = false;
        w.config['servers'] = 17;
      },
    );
    final r = await f.nfsSettingsReview(
      h,
      settings: (i) => f.nfsChanged(i, threads: null),
    );
    expect(
      (await f.nfsSettingsExecute(h, r)).outcome,
      NfsSettingsOutcome.completed,
    );
    expect(_writes(h).single['params'], [
      {'servers': null},
    ]);
    expect(h.wire.config['servers'], 8);
    expect(h.wire.config['managed_nfsd'], isTrue);
  });

  for (final protocols in <List<String>>[
    ['NFSV3', 'NFSV4', 'NFSV5'],
    ['NFSV4', 'NFSV4'],
    [],
  ]) {
    test(
      'unsupported or duplicate configured protocols $protocols are not silently discarded',
      () async {
        final h = await f.nfsSettingsConnected(
          configure: (w) => w.config['protocols'] = protocols,
        );
        await expectLater(
          h.repo.loadNfsSettings(),
          throwsA(isA<NfsSettingsException>()),
        );
        expect(_writes(h), isEmpty);
      },
    );
  }

  for (final address in ['0.0.0.0', '127.0.0.1', '224.0.0.1', '169.254.1.1']) {
    test('server choice $address cannot broaden a new IPv4 binding', () async {
      final h = await f.nfsSettingsConnected(
        configure: (w) {
          (w.values['nfs.bindip_choices'] as Map)[address] = address;
        },
      );
      final i = await h.repo.loadNfsSettings();
      final request = NfsSettingsRequest(
        inventory: i,
        settings: f.nfsChanged(i, bindings: [address]),
      );
      expect(request.validationError, isNotNull);
      expect(_writes(h), isEmpty);
    });
  }

  for (final field in ['allow_nonroot', 'mountd_port', 'userd_manage_gids']) {
    test(
      'post-write protected $field drift is unknown, not silently accepted',
      () async {
        final h = await f.nfsSettingsConnected();
        final r = await f.nfsSettingsReview(h);
        h.wire.afterWrite = () =>
            h.wire.config[field] = field == 'mountd_port' ? 20048 : true;
        expect(
          (await f.nfsSettingsExecute(h, r)).outcome,
          NfsSettingsOutcome.unknown,
        );
        expect(_writes(h), hasLength(1));
        _noSideCalls(h);
      },
    );
  }

  test(
    'last dependency read losing current authorization cannot dispatch',
    () async {
      final h = await f.nfsSettingsConnected();
      final r = await f.nfsSettingsReview(h);
      final before = h.wire.counts['service.query']!;
      h.wire.beforeReply = (method, count) {
        if (method == 'service.query' && count > before) h.authorized = false;
      };
      expect(
        (await f.nfsSettingsExecute(h, r)).outcome,
        NfsSettingsOutcome.rejected,
      );
      expect(_writes(h), isEmpty);
    },
  );

  test(
    'pending then unknown NFS write fences SMB without reads, polls or replay',
    () async {
      final h = await f.nfsSettingsConnected(
        configure: (w) => w.methods.addAll(_smbReads),
      );
      final r = await f.nfsSettingsReview(h);
      final entered = Completer<void>(), release = Completer<void>();
      h.wire.hold = 'nfs.update';
      h.wire.held = release;
      h.wire.overrideReceipt = true;
      h.wire.receipt = null;
      h.wire.beforeReply = (method, _) {
        if (method == 'nfs.update' && !entered.isCompleted) entered.complete();
      };
      final pending = f.nfsSettingsExecute(h, r);
      await entered.future;
      final calls = h.wire.calls.length;
      await expectLater(
        h.repo.loadSmbSettings(),
        throwsA(
          isA<SmbSettingsException>().having(
            (e) => e.reason,
            'reason',
            SmbSettingsExceptionReason.busy,
          ),
        ),
      );
      expect(h.wire.calls, hasLength(calls));
      release.complete();
      expect((await pending).outcome, NfsSettingsOutcome.unknown);
      await expectLater(
        h.repo.loadSmbSettings(),
        throwsA(
          isA<SmbSettingsException>().having(
            (e) => e.reason,
            'reason',
            SmbSettingsExceptionReason.busy,
          ),
        ),
      );
      expect(
        (await f.nfsSettingsExecute(h, r)).outcome,
        NfsSettingsOutcome.rejected,
      );
      expect(_writes(h), hasLength(1));
      expect(h.wire.calls, hasLength(calls));
      _noSideCalls(h);
    },
  );

  test('remote exception text never escapes the public NFS failure', () async {
    final h = await f.nfsSettingsConnected();
    h.wire.fault = 'directoryservices.config';
    try {
      await h.repo.loadNfsSettings();
      fail('The failed dependency must not produce an inventory.');
    } on NfsSettingsException catch (e) {
      expect('$e', isNot(contains(f.nfsSettingsPrivate)));
    }
    expect(jsonEncode(_writes(h).toList()), '[]');
  });
}
