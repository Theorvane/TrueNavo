import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

import 'session_cron_tasks_test.dart' as fake;
import 'session_directory_ldap_test.dart' as ldap;

Future<fake.CronHarness> activationConnected({bool enabled = false}) =>
    fake.connected(
      configure: (wire) {
        wire.methods.addAll([
          'directoryservices.status',
          'directoryservices.update',
        ]);
        wire.metadata['directoryservices.update'] = {'job': true};
        final raw = ldap.ldapConfig();
        raw['enable'] = enabled;
        wire.values['directoryservices.config'] = raw;
        wire.values['directoryservices.status'] = enabled
            ? {'type': 'LDAP', 'status': 'HEALTHY'}
            : {'type': null, 'status': 'DISABLED'};
        wire.values['directoryservices.update'] = 117;
      },
    );

void main() {
  test(
    'disabled anonymous LDAP enables once and verifies owned saved state',
    () async {
      final h = await activationConnected();
      final review = await h.repo.reviewDirectoryLdapActivation(true);
      expect(review.confirmation, 'ENABLE LDAP ${fake.host.substring(0, 8)}');
      final pending = await h.repo.executeDirectoryLdapActivation(
        review,
        review.confirmation,
      );
      expect(pending.outcome, DirectoryIdmapOutcome.pending);
      final writes = h.wire.calls
          .where((call) => call['method'] == 'directoryservices.update')
          .toList();
      expect(writes, hasLength(1));
      final payload = ((writes.single['params'] as List).single as Map);
      expect(payload['enable'], true);
      expect(payload['force'], false);
      expect(payload['credential'], {'credential_type': 'LDAP_ANONYMOUS'});
      expect((payload['configuration'] as Map)['server_urls'], [
        'ldaps://ldap.example.invalid',
      ]);
      h.wire.values['core.get_jobs'] = [
        {
          'id': 117,
          'method': 'directoryservices.update',
          'arguments': [payload],
          'state': 'SUCCESS',
        },
      ];
      final saved = ldap.ldapConfig();
      saved['enable'] = true;
      saved['configuration'] = payload['configuration'];
      h.wire.values['directoryservices.config'] = saved;
      h.wire.values['directoryservices.status'] = {
        'type': 'LDAP',
        'status': 'HEALTHY',
      };
      expect(
        (await h.repo.pollDirectoryLdapActivation(pending.job!)).outcome,
        DirectoryIdmapOutcome.completed,
      );
    },
  );

  test(
    'healthy anonymous LDAP disables with unchanged configuration',
    () async {
      final h = await activationConnected(enabled: true);
      final review = await h.repo.reviewDirectoryLdapActivation(false);
      expect(review.confirmation, 'DISABLE LDAP ${fake.host.substring(0, 8)}');
      final pending = await h.repo.executeDirectoryLdapActivation(
        review,
        review.confirmation,
      );
      expect(pending.outcome, DirectoryIdmapOutcome.pending);
      final payload =
          ((h.wire.calls.singleWhere(
                        (call) => call['method'] == 'directoryservices.update',
                      )['params']
                      as List)
                  .single
              as Map);
      expect(payload['enable'], false);
      h.wire.values['core.get_jobs'] = [
        {
          'id': 117,
          'method': 'directoryservices.update',
          'arguments': [payload],
          'state': 'SUCCESS',
        },
      ];
      final saved = ldap.ldapConfig();
      saved['configuration'] = payload['configuration'];
      h.wire.values['directoryservices.config'] = saved;
      h.wire.values['directoryservices.status'] = {
        'type': null,
        'status': 'DISABLED',
      };
      expect(
        (await h.repo.pollDirectoryLdapActivation(pending.job!)).outcome,
        DirectoryIdmapOutcome.completed,
      );
    },
  );

  test('insecure LDAP cannot be enabled', () async {
    final h = await activationConnected();
    final raw = ldap.ldapConfig();
    (raw['configuration'] as Map<String, Object?>)['server_urls'] = [
      'ldap://ldap.example.invalid',
    ];
    (raw['configuration'] as Map<String, Object?>)['validate_certificates'] =
        false;
    h.wire.values['directoryservices.config'] = raw;
    await expectLater(
      h.repo.reviewDirectoryLdapActivation(true),
      throwsA(isA<DirectoryIdmapException>()),
    );
    expect(
      h.wire.calls.where(
        (call) => call['method'] == 'directoryservices.update',
      ),
      isEmpty,
    );
  });

  test('configuration drift rejects activation before submission', () async {
    final h = await activationConnected();
    final review = await h.repo.reviewDirectoryLdapActivation(true);
    final raw = ldap.ldapConfig();
    raw['timeout'] = 20;
    h.wire.values['directoryservices.config'] = raw;
    final result = await h.repo.executeDirectoryLdapActivation(
      review,
      review.confirmation,
    );
    expect(result.outcome, DirectoryIdmapOutcome.rejected);
    expect(
      h.wire.calls.where(
        (call) => call['method'] == 'directoryservices.update',
      ),
      isEmpty,
    );
  });

  test('foreign owned-job evidence fences activation without replay', () async {
    final h = await activationConnected();
    final review = await h.repo.reviewDirectoryLdapActivation(true);
    final pending = await h.repo.executeDirectoryLdapActivation(
      review,
      review.confirmation,
    );
    h.wire.values['core.get_jobs'] = [
      {
        'id': 117,
        'method': 'directoryservices.update',
        'arguments': const [],
        'state': 'SUCCESS',
      },
    ];
    expect(
      (await h.repo.pollDirectoryLdapActivation(pending.job!)).outcome,
      DirectoryIdmapOutcome.unknown,
    );
    expect(
      h.wire.calls.where(
        (call) => call['method'] == 'directoryservices.update',
      ),
      hasLength(1),
    );
  });
  test('successful job without healthy LDAP stays uncertain', () async {
    final h = await activationConnected();
    final review = await h.repo.reviewDirectoryLdapActivation(true);
    final pending = await h.repo.executeDirectoryLdapActivation(
      review,
      review.confirmation,
    );
    final payload =
        ((h.wire.calls.singleWhere(
                      (call) => call['method'] == 'directoryservices.update',
                    )['params']
                    as List)
                .single
            as Map);
    h.wire.values['core.get_jobs'] = [
      {
        'id': 117,
        'method': 'directoryservices.update',
        'arguments': [payload],
        'state': 'SUCCESS',
      },
    ];
    final saved = ldap.ldapConfig();
    saved['enable'] = true;
    saved['configuration'] = payload['configuration'];
    h.wire.values['directoryservices.config'] = saved;
    h.wire.values['directoryservices.status'] = {
      'type': 'LDAP',
      'status': 'FAULTED',
    };
    expect(
      (await h.repo.pollDirectoryLdapActivation(pending.job!)).outcome,
      DirectoryIdmapOutcome.unknown,
    );
  });

  test('status drift after review prevents activation submission', () async {
    final h = await activationConnected();
    final review = await h.repo.reviewDirectoryLdapActivation(true);
    h.wire.values['directoryservices.status'] = {'type': null, 'status': null};
    final result = await h.repo.executeDirectoryLdapActivation(
      review,
      review.confirmation,
    );
    expect(result.outcome, DirectoryIdmapOutcome.rejected);
    expect(
      h.wire.calls.where(
        (call) => call['method'] == 'directoryservices.update',
      ),
      isEmpty,
    );
  });
}
