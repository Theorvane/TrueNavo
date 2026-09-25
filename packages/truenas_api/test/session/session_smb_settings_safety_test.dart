import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

// Import only synthetic helpers; the other suite's main is never invoked.
import 'session_smb_settings_test.dart' as f;
import 'nfs_settings_fixtures.dart' show nfsSettingsReads;

const _forbidden = {
  'directoryservices.status',
  'directoryservices.health.check',
  'directoryservices.cache_refresh',
  'smb.status',
  'smb.getparm',
  'smb.set_system_sid',
  'smb.synchronize_passdb',
  'smb.synchronize_group_mappings',
  'idmap.gencache.flush',
  'network.configuration.toggle_announcement',
  'user.get_user_obj',
  'group.get_group_obj',
  'service.control',
  'sharing.smb.create',
  'sharing.smb.update',
  'sharing.smb.delete',
  'system.security.update',
  'core.job_abort',
};
void _noSideCalls(f.SmbHarness h) => expect(
  h.wire.calls.where((c) => _forbidden.contains(c['method'])),
  isEmpty,
);

void main() {
  test('SMB dependencies avoid nested option union and direct regeneration/probe calls', () async {
    final h = await f.connected(configure: (w) => w.methods.addAll(_forbidden));
    final r = await f.review(h);
    expect((await f.execute(h, r)).outcome, SmbSettingsOutcome.completed);
    for (final c in h.wire.calls.where(
      (c) => c['method'] == 'sharing.smb.query',
    )) {
      final params = c['params'] as List, options = params.last as Map;
      expect(options['extra'], {'retrieve_locked_info': false});
      expect(options.containsKey('force_sql_filters'), isFalse);
      if (options['count'] == true) {
        expect(params.first, [
          [
            'OR',
            [
              ['options.afp', '=', true],
              ['options.timemachine', '=', true],
              ['purpose', '=', 'TIMEMACHINE_SHARE'],
              ['purpose', '=', 'FCP_SHARE'],
            ],
          ],
        ]);
        expect(options.containsKey('select'), isFalse);
      } else {
        expect(params.first, isEmpty);
        expect(options['select'], ['id', 'enabled']);
        expect(options['limit'], 257);
      }
    }
    _noSideCalls(h);
  });

  test('auxiliary credentials are represented only by protected presence and reject editing', () async {
    final h = await f.connected(
      configure: (w) {
        (w.values['smb.config'] as Map)['smb_options'] =
            'password = ${f.secret}\ninclude = /protected';
      },
    );
    final i = await h.repo.loadSmbSettings();
    expect(i.config.auxiliaryParametersPresent, isTrue);
    final public =
        '${i.blockedReason} ${i.config.settings.description} ${i.config.aliases}';
    expect(public, isNot(contains(f.secret)));
    expect(public, isNot(contains('/protected')));
    await expectLater(
      h.repo.reviewSmbSettings(
        SmbSettingsRequest(inventory: i, settings: f.settings(i)),
      ),
      throwsA(isA<SmbSettingsException>()),
    );
    expect(f.writes(h), 0);
    _noSideCalls(h);
  });

  for (final field in ['credential', 'configuration', 'kerberos_realm']) {
    test(
      'dormant directory $field does not leak or count as standalone',
      () async {
        final h = await f.connected(
          configure: (w) {
            (w.values['directoryservices.config'] as Map)[field] =
                field == 'kerberos_realm' ? f.secret : {'password': f.secret};
          },
        );
        final i = await h.repo.loadSmbSettings();
        expect(i.directoryConfigured, isTrue);
        expect(i.blockedReason, isNot(contains(f.secret)));
        await expectLater(
          h.repo.reviewSmbSettings(
            SmbSettingsRequest(inventory: i, settings: f.settings(i)),
          ),
          throwsA(isA<SmbSettingsException>()),
        );
        expect(f.writes(h), 0);
      },
    );
  }

  test('existing disabled Apple dependency prevents unsafe baseline from being overwritten', () async {
    final h = await f.connected(
      configure: (w) {
        w.shares = [
          {'id': 9, 'enabled': false},
        ];
        w.appleCount = 1;
        (w.values['smb.config'] as Map)['aapl_extensions'] = false;
      },
    );
    final i = await h.repo.loadSmbSettings();
    expect(i.shares.single.enabled, isFalse);
    expect(i.blockedReason, contains('Apple-dependent'));
    await expectLater(
      h.repo.reviewSmbSettings(
        SmbSettingsRequest(inventory: i, settings: f.settings(i)),
      ),
      throwsA(isA<SmbSettingsException>()),
    );
    expect(f.writes(h), 0);
  });

  test('changed identity patch preserves SID, aliases, masks and every other protected key', () async {
    final h = await f.connected();
    final before = Map<String, Object?>.from(
      h.wire.values['smb.config'] as Map,
    );
    final r = await f.review(
      h,
      change: (i) => f.settings(
        i,
        name: 'RENAMED',
        description: i.config.settings.description,
      ),
    );
    expect((await f.execute(h, r)).outcome, SmbSettingsOutcome.completed);
    final call = h.wire.calls.singleWhere((c) => c['method'] == 'smb.update');
    expect(call['params'], [
      {'netbiosname': 'RENAMED'},
    ]);
    expect(h.wire.values['smb.config'], {...before, 'netbiosname': 'RENAMED'});
    expect(r.warnings.join(' '), contains('password database'));
    _noSideCalls(h);
  });

  for (final sid in [null, 'S-1-5-21-1-2-4294967296', 'S-1-5-21-1-2-3\n']) {
    test(
      'absent or unsupported existing SID $sid cannot initialize a new identity',
      () async {
        final h = await f.connected(
          configure: (w) => (w.values['smb.config'] as Map)['server_sid'] = sid,
        );
        try {
          final i = await h.repo.loadSmbSettings();
          expect(i.config.serverSidKnown, isFalse);
          expect(i.blockedReason, isNotNull);
        } on SmbSettingsException {
          // Control-bearing wire values can fail before inventory projection.
        }
        expect(f.writes(h), 0);
        _noSideCalls(h);
      },
    );
  }

  for (final mutation in [
    'sid',
    'alias',
    'charset',
    'appleCount',
    'disabledShare',
  ]) {
    test(
      'post-response $mutation drift is unknown and never repaired automatically',
      () async {
        final h = await f.connected();
        final r = await f.review(h);
        h.wire.afterWrite = () {
          final config = h.wire.values['smb.config'] as Map;
          switch (mutation) {
            case 'sid':
              config['server_sid'] = 'S-1-5-21-321-654-987';
            case 'alias':
              config['netbiosalias'] = ['DIFFERENT'];
            case 'charset':
              config['unixcharset'] = 'CP1250';
            case 'appleCount':
              h.wire.appleCount = 1;
            case 'disabledShare':
              h.wire.shares = [
                {'id': 1, 'enabled': true},
                {'id': 2, 'enabled': true},
              ];
          }
        };
        expect((await f.execute(h, r)).outcome, SmbSettingsOutcome.unknown);
        expect(f.writes(h), 1);
        expect((await f.execute(h, r)).outcome, SmbSettingsOutcome.rejected);
        expect(f.writes(h), 1);
        _noSideCalls(h);
      },
    );
  }

  test(
    'pending then unknown SMB write fences NFS without any peer RPC or replay',
    () async {
      final h = await f.connected(
        configure: (w) => w.methods.addAll({...nfsSettingsReads, 'nfs.update'}),
      );
      final r = await f.review(h);
      final entered = Completer<void>(), release = Completer<void>();
      h.wire.hold = 'smb.update';
      h.wire.held = release;
      h.wire.overrideReceipt = true;
      h.wire.receipt = null;
      h.wire.beforeReply = (method, _) {
        if (method == 'smb.update' && !entered.isCompleted) entered.complete();
      };
      final pending = f.execute(h, r);
      await entered.future;
      final calls = h.wire.calls.length;
      await expectLater(
        h.repo.loadNfsSettings(),
        throwsA(
          isA<NfsSettingsException>().having(
            (e) => e.reason,
            'reason',
            NfsSettingsExceptionReason.busy,
          ),
        ),
      );
      expect(h.wire.calls, hasLength(calls));
      release.complete();
      expect((await pending).outcome, SmbSettingsOutcome.unknown);
      await expectLater(
        h.repo.loadNfsSettings(),
        throwsA(
          isA<NfsSettingsException>().having(
            (e) => e.reason,
            'reason',
            NfsSettingsExceptionReason.busy,
          ),
        ),
      );
      expect((await f.execute(h, r)).outcome, SmbSettingsOutcome.rejected);
      expect(f.writes(h), 1);
      expect(h.wire.calls, hasLength(calls));
    },
  );

  test(
    'final role loss rejects without user data or raw dependency text',
    () async {
      final h = await f.connected();
      final r = await f.review(h);
      final before = h.wire.counts['auth.me']!;
      h.wire.beforeReply = (method, count) {
        if (method == 'auth.me' && count > before) {
          h.wire.values['auth.me'] = {
            'privilege': {
              'roles': ['READONLY_ADMIN'],
            },
            'password': f.secret,
          };
        }
      };
      final result = await f.execute(h, r);
      expect(result.outcome, SmbSettingsOutcome.rejected);
      expect(result.message, isNot(contains(f.secret)));
      expect(
        jsonEncode(
          h.wire.calls.where((c) => c['method'] == 'smb.update').toList(),
        ),
        '[]',
      );
    },
  );
}
