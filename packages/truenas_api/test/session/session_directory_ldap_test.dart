import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

import 'session_cron_tasks_test.dart' as fake;

Map<String, Object?> ldapConfig() => {
  'id': 1,
  'enable': false,
  'service_type': 'LDAP',
  'credential': {'credential_type': 'LDAP_ANONYMOUS'},
  'configuration': {
    'server_urls': ['ldaps://ldap.example.invalid'],
    'basedn': 'dc=example,dc=invalid',
    'starttls': false,
    'validate_certificates': true,
    'schema': 'RFC2307',
    'search_bases': {'base_user': null, 'base_group': null},
    'attribute_maps': null,
    'auxiliary_parameters': null,
  },
  'kerberos_realm': null,
  'enable_account_cache': true,
  'enable_dns_updates': false,
  'timeout': 10,
};

DirectoryLdapDraft draft({
  List<String> urls = const ['ldaps://ldap2.example.invalid'],
  bool startTls = false,
  bool validateCertificates = true,
}) => DirectoryLdapDraft(
  serverUrls: urls,
  baseDn: 'dc=example,dc=invalid',
  schema: 'RFC2307',
  startTls: startTls,
  validateCertificates: validateCertificates,
  userSearchBase: null,
  groupSearchBase: null,
  netgroupSearchBase: null,
  attributeMaps: DirectoryLdapAttributeMaps.parse(null),
);

Future<fake.CronHarness> connectedLdap() => fake.connected(
  configure: (wire) {
    wire.methods.addAll([
      'directoryservices.status',
      'directoryservices.update',
    ]);
    wire.metadata['directoryservices.update'] = {'job': true};
    wire.values['directoryservices.config'] = ldapConfig();
    wire.values['directoryservices.status'] = {
      'type': null,
      'status': 'DISABLED',
    };
    wire.values['directoryservices.update'] = 91;
  },
);

void main() {
  test(
    'anonymous LDAP update is reviewed, submitted once and verified',
    () async {
      final h = await connectedLdap();
      final review = await h.repo.reviewDirectoryLdap(draft());
      expect(review.changes, hasLength(1));
      final pending = await h.repo.executeDirectoryLdap(
        review,
        review.confirmation,
      );
      expect(pending.outcome, DirectoryIdmapOutcome.pending);
      final calls = h.wire.calls
          .where((call) => call['method'] == 'directoryservices.update')
          .toList();
      expect(calls, hasLength(1));
      final payload = ((calls.single['params'] as List).single as Map);
      expect(payload['enable'], false);
      expect(payload['force'], false);
      expect(payload['credential'], {'credential_type': 'LDAP_ANONYMOUS'});
      expect((payload['configuration'] as Map)['server_urls'], [
        'ldaps://ldap2.example.invalid',
      ]);
      expect(payload.toString(), isNot(contains('password')));
      h.wire.values['core.get_jobs'] = [
        {
          'id': 91,
          'method': 'directoryservices.update',
          'arguments': [payload],
          'state': 'SUCCESS',
        },
      ];
      final saved = ldapConfig();
      saved['configuration'] = payload['configuration'];
      h.wire.values['directoryservices.config'] = saved;
      expect(
        (await h.repo.pollDirectoryLdap(pending.job!)).outcome,
        DirectoryIdmapOutcome.completed,
      );
    },
  );

  test('unsafe transport and mixed schemes are locally rejected', () async {
    final h = await connectedLdap();
    final inventory = await h.repo.loadDirectoryIdmap();
    expect(
      draft(urls: const ['ldap://ldap2.example.invalid'])
          .validateAgainst(inventory),
      isNotNull,
    );
    expect(
      draft(
        urls: const ['ldaps://a.example.invalid', 'ldap://b.example.invalid'],
        startTls: true,
      ).validateAgainst(inventory),
      isNotNull,
    );
    expect(
      draft(validateCertificates: false).validateAgainst(inventory),
      isNotNull,
    );
    expect(
      draft(
        urls: const ['ldap://ldap2.example.invalid'],
        startTls: true,
      ).validateAgainst(inventory),
      isNull,
    );
    expect(
      h.wire.calls.where(
        (call) => call['method'] == 'directoryservices.update',
      ),
      isEmpty,
    );
  });

  test(
    'bind credentials and malformed attribute maps cannot be edited',
    () async {
      final h = await connectedLdap();
      final raw = ldapConfig();
      raw['credential'] = {
        'credential_type': 'LDAP_PLAIN',
        'binddn': 'cn=admin,dc=example,dc=invalid',
        'bindpw': 'secret',
      };
      h.wire.values['directoryservices.config'] = raw;
      await expectLater(
        h.repo.reviewDirectoryLdap(draft()),
        throwsA(isA<DirectoryIdmapException>()),
      );
      expect(
        h.wire.calls.where(
          (call) => call['method'] == 'directoryservices.update',
        ),
        isEmpty,
      );
      final advanced = ldapConfig();
      (advanced['configuration'] as Map<String, Object?>)['attribute_maps'] = {
        'passwd': {'unexpected_field': 'uid'},
      };
      h.wire.values['directoryservices.config'] = advanced;
      await expectLater(
        h.repo.reviewDirectoryLdap(draft()),
        throwsA(isA<DirectoryIdmapException>()),
      );
    },
  );

  test(
    'optional LDAP search bases are projected and saved after owned job',
    () async {
      final h = await connectedLdap();
      final inventory = await h.repo.loadDirectoryIdmap();
      expect(inventory.ldap!.userSearchBase, isNull);
      expect(inventory.ldap!.credentialType, 'LDAP_ANONYMOUS');
      final scoped = DirectoryLdapDraft(
        serverUrls: inventory.ldap!.serverUrls,
        baseDn: inventory.ldap!.baseDn,
        schema: inventory.ldap!.schema,
        startTls: inventory.ldap!.startTls,
        validateCertificates: true,
        userSearchBase: 'ou=users,dc=example,dc=invalid',
        groupSearchBase: 'ou=groups,dc=example,dc=invalid',
        netgroupSearchBase: null,
        attributeMaps: inventory.ldap!.attributeMaps,
      );
      final review = await h.repo.reviewDirectoryLdap(scoped);
      expect(review.changes, hasLength(2));
      final pending = await h.repo.executeDirectoryLdap(
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
      final bases = (payload['configuration'] as Map)['search_bases'] as Map;
      expect(bases, {
        'base_user': 'ou=users,dc=example,dc=invalid',
        'base_group': 'ou=groups,dc=example,dc=invalid',
        'base_netgroup': null,
      });
      h.wire.values['core.get_jobs'] = [
        {
          'id': 91,
          'method': 'directoryservices.update',
          'arguments': [payload],
          'state': 'SUCCESS',
        },
      ];
      final saved = ldapConfig();
      saved['configuration'] = payload['configuration'];
      h.wire.values['directoryservices.config'] = saved;
      expect(
        (await h.repo.pollDirectoryLdap(pending.job!)).outcome,
        DirectoryIdmapOutcome.completed,
      );
      final after = await h.repo.loadDirectoryIdmap();
      expect(after.ldap!.userSearchBase, 'ou=users,dc=example,dc=invalid');
    },
  );

  test(
    'typed attribute mapping preserves other overrides and verifies save',
    () async {
      final h = await connectedLdap();
      final raw = ldapConfig();
      (raw['configuration'] as Map<String, Object?>)['attribute_maps'] = {
        'group': {'group_member': 'memberUid'},
      };
      h.wire.values['directoryservices.config'] = raw;
      final inventory = await h.repo.loadDirectoryIdmap();
      expect(
        inventory.ldap!.attributeMaps!.value('group', 'group_member'),
        'memberUid',
      );
      final maps = DirectoryLdapAttributeMaps.parse({
        'group': {'group_member': 'memberUid'},
        'passwd': {'user_name': 'uid'},
      })!;
      final scoped = DirectoryLdapDraft(
        serverUrls: inventory.ldap!.serverUrls,
        baseDn: inventory.ldap!.baseDn,
        schema: inventory.ldap!.schema,
        startTls: inventory.ldap!.startTls,
        validateCertificates: true,
        userSearchBase: null,
        groupSearchBase: null,
        netgroupSearchBase: null,
        attributeMaps: maps,
      );
      final review = await h.repo.reviewDirectoryLdap(scoped);
      expect(review.changes, ['passwd.user_name: (default) → uid']);
      final pending = await h.repo.executeDirectoryLdap(
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
      final sentMaps =
          (payload['configuration'] as Map)['attribute_maps'] as Map;
      expect((sentMaps['passwd'] as Map)['user_name'], 'uid');
      expect((sentMaps['group'] as Map)['group_member'], 'memberUid');
      h.wire.values['core.get_jobs'] = [
        {
          'id': 91,
          'method': 'directoryservices.update',
          'arguments': [payload],
          'state': 'SUCCESS',
        },
      ];
      final saved = ldapConfig();
      saved['configuration'] = payload['configuration'];
      h.wire.values['directoryservices.config'] = saved;
      expect(
        (await h.repo.pollDirectoryLdap(pending.job!)).outcome,
        DirectoryIdmapOutcome.completed,
      );
    },
  );
  test('unknown LDAP search-base fields fail closed before review', () async {
    final h = await connectedLdap();
    final raw = ldapConfig();
    (raw['configuration'] as Map<String, Object?>)['search_bases'] = {
      'base_user': null,
      'unexpected': 'ou=hidden,dc=example,dc=invalid',
    };
    h.wire.values['directoryservices.config'] = raw;
    await expectLater(
      h.repo.loadDirectoryIdmap(),
      throwsA(isA<DirectoryIdmapException>()),
    );
    await expectLater(
      h.repo.reviewDirectoryLdap(draft()),
      throwsA(isA<DirectoryIdmapException>()),
    );
    expect(
      h.wire.calls.where(
        (call) => call['method'] == 'directoryservices.update',
      ),
      isEmpty,
    );
  });

  test('configuration drift before execution prevents submission', () async {
    final h = await connectedLdap();
    final review = await h.repo.reviewDirectoryLdap(draft());
    final changed = ldapConfig();
    changed['timeout'] = 20;
    h.wire.values['directoryservices.config'] = changed;
    final result = await h.repo.executeDirectoryLdap(
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

  test('foreign job evidence is uncertain without a replay', () async {
    final h = await connectedLdap();
    final review = await h.repo.reviewDirectoryLdap(draft());
    final pending = await h.repo.executeDirectoryLdap(
      review,
      review.confirmation,
    );
    h.wire.values['core.get_jobs'] = [
      {
        'id': 91,
        'method': 'directoryservices.update',
        'arguments': const [],
        'state': 'SUCCESS',
      },
    ];
    expect(
      (await h.repo.pollDirectoryLdap(pending.job!)).outcome,
      DirectoryIdmapOutcome.unknown,
    );
    expect(
      h.wire.calls.where(
        (call) => call['method'] == 'directoryservices.update',
      ),
      hasLength(1),
    );
  });
}
