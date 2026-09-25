import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

import 'session_cron_tasks_test.dart' as fake;

Map<String, Object?> adConfig({
  int builtinLow = 90000001,
  int builtinHigh = 100000000,
  int domainLow = 100000001,
  int domainHigh = 200000000,
}) => {
  'enable': false,
  'service_type': 'ACTIVEDIRECTORY',
  'credential': {
    'credential_type': 'KERBEROS_PRINCIPAL',
    'principal': 'PRIVATE_KERBEROS_PRINCIPAL',
  },
  'configuration': {
    'hostname': 'nas',
    'domain': 'example.invalid',
    'idmap': {
      'builtin': {'range_low': builtinLow, 'range_high': builtinHigh},
      'idmap_domain': {
        'name': 'EXAMPLE',
        'idmap_backend': 'RID',
        'range_low': domainLow,
        'range_high': domainHigh,
      },
    },
    'trusted_domains': [
      {
        'name': 'TRUSTED',
        'idmap_backend': 'RID',
        'range_low': 200000001,
        'range_high': 300000000,
      },
    ],
    'private': 'PRIVATE_CONFIGURATION_VALUE',
  },
};

Map<String, Object?> editableAdConfig({String backend = 'RID'}) => {
  'id': 1,
  'enable': false,
  'service_type': 'ACTIVEDIRECTORY',
  'credential': {
    'credential_type': 'KERBEROS_PRINCIPAL',
    'principal': r'nas$@EXAMPLE.INVALID',
  },
  'configuration': {
    'hostname': 'nas',
    'domain': 'example.invalid',
    'idmap': {
      'builtin': {'range_low': 90000001, 'range_high': 100000000},
      'idmap_domain': {
        'name': 'EXAMPLE',
        'idmap_backend': backend,
        'range_low': 100000001,
        'range_high': 200000000,
        if (backend == 'RID') 'sssd_compat': false,
        if (backend == 'AD') 'schema_mode': 'RFC2307',
        if (backend == 'AD') 'unix_primary_group': true,
        if (backend == 'AD') 'unix_nss_info': false,
      },
    },
    'site': null,
    'computer_account_ou': null,
    'use_default_domain': false,
    'enable_trusted_domains': false,
    'trusted_domains': <Object?>[],
  },
  'kerberos_realm': 'EXAMPLE.INVALID',
  'enable_account_cache': true,
  'enable_dns_updates': true,
  'timeout': 10,
};

final editDraft = DirectoryIdmapRangeDraft(
  builtin: DirectoryIdmapRange(low: 90000001, high: 100000000),
  primary: DirectoryIdmapRange(low: 110000001, high: 200000000),
);

Map<String, Object?> editableTrustedConfig() {
  final config = editableAdConfig();
  final configuration = config['configuration'] as Map<String, Object?>;
  configuration['enable_trusted_domains'] = true;
  configuration['trusted_domains'] = [
    {
      'name': 'TRUST_A',
      'idmap_backend': 'RID',
      'range_low': 200000001,
      'range_high': 300000000,
      'sssd_compat': false,
    },
    {
      'name': 'TRUST_B',
      'idmap_backend': 'AD',
      'range_low': 300000001,
      'range_high': 400000000,
      'schema_mode': 'SFU',
      'unix_primary_group': false,
      'unix_nss_info': true,
    },
  ];
  return config;
}

final trustedEditDraft = DirectoryIdmapRangeDraft(
  builtin: DirectoryIdmapRange(low: 90000001, high: 100000000),
  primary: DirectoryIdmapRange(low: 100000001, high: 200000000),
  trusted: [
    DirectoryIdmapRange(low: 210000001, high: 300000000),
    DirectoryIdmapRange(low: 300000001, high: 400000000),
  ],
);
void main() {
  test('disabled AD may report null status and null type', () async {
    final h = await fake.connected(
      configure: (wire) {
        wire.methods.add('directoryservices.status');
        wire.values['directoryservices.config'] = editableAdConfig();
        wire.values['directoryservices.status'] = {
          'type': null,
          'status': null,
        };
      },
    );
    final inventory = await h.repo.loadDirectoryIdmap();
    expect(inventory.status, isNull);
    expect(editDraft.validateAgainst(inventory), isNull);
  });

  test(
    'reviewed RID update submits once and verifies owned job and readback',
    () async {
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.addAll([
            'directoryservices.status',
            'directoryservices.update',
          ]);
          wire.metadata['directoryservices.update'] = {'job': true};
          wire.values['directoryservices.config'] = editableAdConfig();
          wire.values['directoryservices.status'] = {
            'type': null,
            'status': null,
          };
          wire.values['directoryservices.update'] = 7;
        },
      );
      expect(h.repo.directoryIdmapCapabilities.canEdit, isTrue);
      final review = await h.repo.reviewDirectoryIdmap(editDraft);
      expect(review.changes, hasLength(1));
      expect(review.confirmation, 'IDMAP ${fake.host.substring(0, 8)}');
      final result = await h.repo.executeDirectoryIdmap(
        review,
        review.confirmation,
      );
      expect(result.outcome, DirectoryIdmapOutcome.pending);
      final writes = h.wire.calls
          .where((c) => c['method'] == 'directoryservices.update')
          .toList();
      expect(writes, hasLength(1));
      final payload = ((writes.single['params'] as List).single as Map);
      expect(payload['enable'], false);
      expect(payload['service_type'], 'ACTIVEDIRECTORY');
      expect(payload['force'], false);
      expect(payload['credential'], {
        'credential_type': 'KERBEROS_PRINCIPAL',
        'principal': 'nas\$@EXAMPLE.INVALID',
      });
      expect((payload['configuration'] as Map)['trusted_domains'], isEmpty);
      expect((payload['configuration'] as Map)['idmap'], isA<Map>());
      expect(payload.toString(), isNot(contains('password')));
      h.wire.values['core.get_jobs'] = [
        {
          'id': 7,
          'method': 'directoryservices.update',
          'arguments': [payload],
          'state': 'SUCCESS',
        },
      ];
      final saved = editableAdConfig();
      saved['configuration'] = payload['configuration'];
      h.wire.values['directoryservices.config'] = saved;
      final completed = await h.repo.pollDirectoryIdmap(result.job!);
      expect(completed.outcome, DirectoryIdmapOutcome.completed);
    },
  );
  test(
    'AD backend range edit preserves schema options and verifies readback',
    () async {
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.addAll([
            'directoryservices.status',
            'directoryservices.update',
          ]);
          wire.metadata['directoryservices.update'] = {'job': true};
          wire.values['directoryservices.config'] = editableAdConfig(
            backend: 'AD',
          );
          wire.values['directoryservices.status'] = {
            'type': null,
            'status': null,
          };
          wire.values['directoryservices.update'] = 8;
        },
      );
      final inventory = await h.repo.loadDirectoryIdmap();
      expect(inventory.primary?.backend, 'AD');
      expect(editDraft.validateAgainst(inventory), isNull);
      final review = await h.repo.reviewDirectoryIdmap(editDraft);
      final submitted = await h.repo.executeDirectoryIdmap(
        review,
        review.confirmation,
      );
      expect(submitted.outcome, DirectoryIdmapOutcome.pending);
      final payload =
          ((h.wire.calls.lastWhere(
                        (call) => call['method'] == 'directoryservices.update',
                      )['params']
                      as List)
                  .single
              as Map);
      final idmap = (payload['configuration'] as Map)['idmap'] as Map;
      final primary = idmap['idmap_domain'] as Map;
      expect(primary['idmap_backend'], 'AD');
      expect(primary['schema_mode'], 'RFC2307');
      expect(primary['unix_primary_group'], true);
      expect(primary['unix_nss_info'], false);
      expect(primary['range_low'], 110000001);
      expect(primary.containsKey('sssd_compat'), isFalse);
      h.wire.values['core.get_jobs'] = [
        {
          'id': 8,
          'method': 'directoryservices.update',
          'arguments': [payload],
          'state': 'SUCCESS',
        },
      ];
      final saved = editableAdConfig(backend: 'AD');
      saved['configuration'] = payload['configuration'];
      h.wire.values['directoryservices.config'] = saved;
      expect(
        (await h.repo.pollDirectoryIdmap(submitted.job!)).outcome,
        DirectoryIdmapOutcome.completed,
      );
    },
  );

  test(
    'existing trusted RID and AD range update preserves domain settings',
    () async {
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.addAll([
            'directoryservices.status',
            'directoryservices.update',
          ]);
          wire.metadata['directoryservices.update'] = {'job': true};
          wire.values['directoryservices.config'] = editableTrustedConfig();
          wire.values['directoryservices.status'] = {
            'type': null,
            'status': null,
          };
          wire.values['directoryservices.update'] = 9;
        },
      );
      final inventory = await h.repo.loadDirectoryIdmap();
      expect(trustedEditDraft.validateAgainst(inventory), isNull);
      final review = await h.repo.reviewDirectoryIdmap(trustedEditDraft);
      expect(review.changes, [
        'TRUST_A: 200000001–300000000 → 210000001–300000000',
      ]);
      final submitted = await h.repo.executeDirectoryIdmap(
        review,
        review.confirmation,
      );
      expect(submitted.outcome, DirectoryIdmapOutcome.pending);
      final writes = h.wire.calls
          .where((c) => c['method'] == 'directoryservices.update')
          .toList();
      expect(writes, hasLength(1));
      final payload = (writes.single['params'] as List).single as Map;
      final trusted =
          (payload['configuration'] as Map)['trusted_domains'] as List;
      expect(trusted, [
        {
          'name': 'TRUST_A',
          'idmap_backend': 'RID',
          'range_low': 210000001,
          'range_high': 300000000,
          'sssd_compat': false,
        },
        {
          'name': 'TRUST_B',
          'idmap_backend': 'AD',
          'range_low': 300000001,
          'range_high': 400000000,
          'schema_mode': 'SFU',
          'unix_primary_group': false,
          'unix_nss_info': true,
        },
      ]);
      h.wire.values['core.get_jobs'] = [
        {
          'id': 9,
          'method': 'directoryservices.update',
          'arguments': [payload],
          'state': 'SUCCESS',
        },
      ];
      final saved = editableTrustedConfig();
      saved['configuration'] = payload['configuration'];
      h.wire.values['directoryservices.config'] = saved;
      expect(
        (await h.repo.pollDirectoryIdmap(submitted.job!)).outcome,
        DirectoryIdmapOutcome.completed,
      );
    },
  );

  test(
    'trusted range editor rejects missing overlap and unsafe domain rows',
    () async {
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.addAll([
            'directoryservices.status',
            'directoryservices.update',
          ]);
          wire.metadata['directoryservices.update'] = {'job': true};
          wire.values['directoryservices.config'] = editableTrustedConfig();
          wire.values['directoryservices.status'] = {
            'type': null,
            'status': null,
          };
        },
      );
      final inventory = await h.repo.loadDirectoryIdmap();
      expect(editDraft.validateAgainst(inventory), contains('trusted'));
      final overlap = DirectoryIdmapRangeDraft(
        builtin: trustedEditDraft.builtin,
        primary: trustedEditDraft.primary,
        trusted: [
          DirectoryIdmapRange(low: 190000000, high: 300000000),
          trustedEditDraft.trusted[1],
        ],
      );
      expect(overlap.validateAgainst(inventory), contains('overlap'));
      final invalid = editableTrustedConfig();
      final rows = (invalid['configuration'] as Map)['trusted_domains'] as List;
      (rows[0] as Map)['ldap_user_dn_password'] = 'SYNTHETIC_SECRET';
      h.wire.values['directoryservices.config'] = invalid;
      await expectLater(
        h.repo.reviewDirectoryIdmap(trustedEditDraft),
        throwsA(isA<DirectoryIdmapException>()),
      );
      final duplicate = editableTrustedConfig();
      final duplicateRows =
          (duplicate['configuration'] as Map)['trusted_domains'] as List;
      (duplicateRows[1] as Map)['name'] = 'TRUST_A';
      h.wire.values['directoryservices.config'] = duplicate;
      await expectLater(
        h.repo.reviewDirectoryIdmap(trustedEditDraft),
        throwsA(isA<DirectoryIdmapException>()),
      );
      expect(
        h.wire.calls.where((c) => c['method'] == 'directoryservices.update'),
        isEmpty,
      );
    },
  );
  test(
    'option-only RID/AD edit preserves ranges and verifies readback',
    () async {
      final configured = editableTrustedConfig();
      final primary =
          ((configured['configuration'] as Map)['idmap'] as Map)['idmap_domain']
              as Map;
      primary['idmap_backend'] = 'AD';
      primary.remove('sssd_compat');
      primary['schema_mode'] = 'RFC2307';
      primary['unix_primary_group'] = true;
      primary['unix_nss_info'] = false;
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.addAll([
            'directoryservices.status',
            'directoryservices.update',
          ]);
          wire.metadata['directoryservices.update'] = {'job': true};
          wire.values['directoryservices.config'] = configured;
          wire.values['directoryservices.status'] = {
            'type': null,
            'status': null,
          };
          wire.values['directoryservices.update'] = 10;
        },
      );
      final inventory = await h.repo.loadDirectoryIdmap();
      expect(inventory.primary?.options?.schemaMode, 'RFC2307');
      expect(inventory.trusted[1].options?.unixNssInfo, true);
      final draft = DirectoryIdmapRangeDraft(
        builtin: inventory.builtin!.range,
        primary: inventory.primary!.range,
        trusted: inventory.trusted.map((d) => d.range).toList(),
        options: const [
          DirectoryIdmapBackendOptions.ad(
            schemaMode: 'SFU20',
            unixPrimaryGroup: true,
            unixNssInfo: false,
          ),
          DirectoryIdmapBackendOptions.rid(sssdCompat: true),
          DirectoryIdmapBackendOptions.ad(
            schemaMode: 'SFU',
            unixPrimaryGroup: false,
            unixNssInfo: false,
          ),
        ],
      );
      expect(draft.validateAgainst(inventory), isNull);
      final review = await h.repo.reviewDirectoryIdmap(draft);
      expect(review.changes, [
        'Primary domain schema mode: RFC2307 → SFU20',
        'TRUST_A SSSD compatibility: false → true',
        'TRUST_B Unix NSS info: true → false',
      ]);
      final submitted = await h.repo.executeDirectoryIdmap(
        review,
        review.confirmation,
      );
      expect(submitted.outcome, DirectoryIdmapOutcome.pending);
      final writes = h.wire.calls
          .where((c) => c['method'] == 'directoryservices.update')
          .toList();
      expect(writes, hasLength(1));
      final payload = (writes.single['params'] as List).single as Map;
      final settings = payload['configuration'] as Map;
      final savedPrimary = (settings['idmap'] as Map)['idmap_domain'] as Map;
      final savedTrusted = settings['trusted_domains'] as List;
      expect(savedPrimary['schema_mode'], 'SFU20');
      expect(savedPrimary['range_low'], 100000001);
      expect((savedTrusted[0] as Map)['sssd_compat'], true);
      expect((savedTrusted[1] as Map)['unix_nss_info'], false);
      expect((savedTrusted[1] as Map)['range_low'], 300000001);
      h.wire.values['core.get_jobs'] = [
        {
          'id': 10,
          'method': 'directoryservices.update',
          'arguments': [payload],
          'state': 'SUCCESS',
        },
      ];
      final saved = editableTrustedConfig();
      saved['configuration'] = settings;
      h.wire.values['directoryservices.config'] = saved;
      expect(
        (await h.repo.pollDirectoryIdmap(submitted.job!)).outcome,
        DirectoryIdmapOutcome.completed,
      );
    },
  );

  test(
    'invalid option shapes and changed saved options reject writes',
    () async {
      final configured = editableTrustedConfig();
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.addAll([
            'directoryservices.status',
            'directoryservices.update',
          ]);
          wire.metadata['directoryservices.update'] = {'job': true};
          wire.values['directoryservices.config'] = configured;
          wire.values['directoryservices.status'] = {
            'type': null,
            'status': null,
          };
        },
      );
      final inventory = await h.repo.loadDirectoryIdmap();
      final bad = DirectoryIdmapRangeDraft(
        builtin: inventory.builtin!.range,
        primary: inventory.primary!.range,
        trusted: inventory.trusted.map((d) => d.range).toList(),
        options: const [
          DirectoryIdmapBackendOptions.ad(
            schemaMode: 'RFC2307',
            unixPrimaryGroup: true,
            unixNssInfo: false,
          ),
        ],
      );
      expect(bad.validateAgainst(inventory), contains('count'));
      await expectLater(
        h.repo.reviewDirectoryIdmap(bad),
        throwsA(isA<DirectoryIdmapException>()),
      );
      final valid = DirectoryIdmapRangeDraft(
        builtin: inventory.builtin!.range,
        primary: inventory.primary!.range,
        trusted: inventory.trusted.map((d) => d.range).toList(),
        options: const [
          DirectoryIdmapBackendOptions.rid(sssdCompat: true),
          null,
          null,
        ],
      );
      final review = await h.repo.reviewDirectoryIdmap(valid);
      final drifted = editableTrustedConfig();
      final rows = (drifted['configuration'] as Map)['trusted_domains'] as List;
      (rows[1] as Map)['unix_nss_info'] = false;
      h.wire.values['directoryservices.config'] = drifted;
      final rejected = await h.repo.executeDirectoryIdmap(
        review,
        review.confirmation,
      );
      expect(rejected.outcome, DirectoryIdmapOutcome.rejected);
      expect(
        h.wire.calls.where((c) => c['method'] == 'directoryservices.update'),
        isEmpty,
      );
    },
  );
  test(
    'new RID trusted domain is reviewed and verified after owned job',
    () async {
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.addAll([
            'directoryservices.status',
            'directoryservices.update',
          ]);
          wire.metadata['directoryservices.update'] = {'job': true};
          wire.values['directoryservices.config'] = editableAdConfig();
          wire.values['directoryservices.status'] = {
            'type': null,
            'status': null,
          };
          wire.values['directoryservices.update'] = 11;
        },
      );
      final inventory = await h.repo.loadDirectoryIdmap();
      final draft = DirectoryIdmapRangeDraft(
        builtin: inventory.builtin!.range,
        primary: inventory.primary!.range,
        addition: const DirectoryIdmapTrustedAddition(
          name: 'TRUST_NEW',
          range: DirectoryIdmapRange(low: 200000001, high: 300000000),
          options: DirectoryIdmapBackendOptions.rid(sssdCompat: false),
        ),
      );
      expect(draft.validateAgainst(inventory), isNull);
      final review = await h.repo.reviewDirectoryIdmap(draft);
      expect(review.changes, [
        'Add trusted domain TRUST_NEW (RID): 200000001–300000000',
      ]);
      final submitted = await h.repo.executeDirectoryIdmap(
        review,
        review.confirmation,
      );
      expect(submitted.outcome, DirectoryIdmapOutcome.pending);
      final writes = h.wire.calls
          .where((c) => c['method'] == 'directoryservices.update')
          .toList();
      expect(writes, hasLength(1));
      final payload = (writes.single['params'] as List).single as Map;
      final configuration = payload['configuration'] as Map;
      expect(configuration['enable_trusted_domains'], true);
      expect(configuration['trusted_domains'], [
        {
          'name': 'TRUST_NEW',
          'idmap_backend': 'RID',
          'range_low': 200000001,
          'range_high': 300000000,
          'sssd_compat': false,
        },
      ]);
      h.wire.values['core.get_jobs'] = [
        {
          'id': 11,
          'method': 'directoryservices.update',
          'arguments': [payload],
          'state': 'SUCCESS',
        },
      ];
      final saved = editableAdConfig();
      saved['configuration'] = configuration;
      h.wire.values['directoryservices.config'] = saved;
      expect(
        (await h.repo.pollDirectoryIdmap(submitted.job!)).outcome,
        DirectoryIdmapOutcome.completed,
      );
    },
  );

  test('new AD trusted domain uses explicit schema options', () async {
    final h = await fake.connected(
      configure: (wire) {
        wire.methods.addAll([
          'directoryservices.status',
          'directoryservices.update',
        ]);
        wire.metadata['directoryservices.update'] = {'job': true};
        wire.values['directoryservices.config'] = editableTrustedConfig();
        wire.values['directoryservices.status'] = {
          'type': null,
          'status': null,
        };
        wire.values['directoryservices.update'] = 12;
      },
    );
    final inventory = await h.repo.loadDirectoryIdmap();
    final draft = DirectoryIdmapRangeDraft(
      builtin: inventory.builtin!.range,
      primary: inventory.primary!.range,
      trusted: inventory.trusted.map((domain) => domain.range).toList(),
      addition: const DirectoryIdmapTrustedAddition(
        name: 'TRUST_C',
        range: DirectoryIdmapRange(low: 400000001, high: 500000000),
        options: DirectoryIdmapBackendOptions.ad(
          schemaMode: 'RFC2307',
          unixPrimaryGroup: true,
          unixNssInfo: false,
        ),
      ),
    );
    final review = await h.repo.reviewDirectoryIdmap(draft);
    final submitted = await h.repo.executeDirectoryIdmap(
      review,
      review.confirmation,
    );
    expect(submitted.outcome, DirectoryIdmapOutcome.pending);
    final payload =
        (h.wire.calls.lastWhere(
                      (c) => c['method'] == 'directoryservices.update',
                    )['params']
                    as List)
                .single
            as Map;
    final configuration = payload['configuration'] as Map;
    final rows = configuration['trusted_domains'] as List;
    expect(rows, hasLength(3));
    expect(rows.last, {
      'name': 'TRUST_C',
      'idmap_backend': 'AD',
      'range_low': 400000001,
      'range_high': 500000000,
      'schema_mode': 'RFC2307',
      'unix_primary_group': true,
      'unix_nss_info': false,
    });
    h.wire.values['core.get_jobs'] = [
      {
        'id': 12,
        'method': 'directoryservices.update',
        'arguments': [payload],
        'state': 'SUCCESS',
      },
    ];
    final saved = editableTrustedConfig();
    saved['configuration'] = configuration;
    h.wire.values['directoryservices.config'] = saved;
    expect(
      (await h.repo.pollDirectoryIdmap(submitted.job!)).outcome,
      DirectoryIdmapOutcome.completed,
    );
  });

  test(
    'trusted addition rejects duplicate, overlap and primary-domain name',
    () async {
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.addAll([
            'directoryservices.status',
            'directoryservices.update',
          ]);
          wire.metadata['directoryservices.update'] = {'job': true};
          wire.values['directoryservices.config'] = editableTrustedConfig();
          wire.values['directoryservices.status'] = {
            'type': null,
            'status': null,
          };
        },
      );
      final inventory = await h.repo.loadDirectoryIdmap();
      DirectoryIdmapRangeDraft draft(String name, DirectoryIdmapRange range) =>
          DirectoryIdmapRangeDraft(
            builtin: inventory.builtin!.range,
            primary: inventory.primary!.range,
            trusted: inventory.trusted.map((domain) => domain.range).toList(),
            addition: DirectoryIdmapTrustedAddition(
              name: name,
              range: range,
              options: const DirectoryIdmapBackendOptions.rid(
                sssdCompat: false,
              ),
            ),
          );
      expect(
        draft(
          'TRUST_A',
          const DirectoryIdmapRange(low: 400000001, high: 500000000),
        ).validateAgainst(inventory),
        contains('unique'),
      );
      expect(
        draft(
          'TRUST_C',
          const DirectoryIdmapRange(low: 299999999, high: 400000000),
        ).validateAgainst(inventory),
        contains('overlap'),
      );
      expect(
        draft(
          'trust_c',
          const DirectoryIdmapRange(low: 400000001, high: 500000000),
        ).validateAgainst(inventory),
        contains('uppercase'),
      );
      final newConfig = editableAdConfig();
      h.wire.values['directoryservices.config'] = newConfig;
      final fresh = await h.repo.loadDirectoryIdmap();
      final collision = DirectoryIdmapRangeDraft(
        builtin: fresh.builtin!.range,
        primary: fresh.primary!.range,
        addition: const DirectoryIdmapTrustedAddition(
          name: 'EXAMPLE',
          range: DirectoryIdmapRange(low: 200000001, high: 300000000),
          options: DirectoryIdmapBackendOptions.rid(sssdCompat: false),
        ),
      );
      expect(collision.validateAgainst(fresh), isNull);
      await expectLater(
        h.repo.reviewDirectoryIdmap(collision),
        throwsA(isA<DirectoryIdmapException>()),
      );
      expect(
        h.wire.calls.where((c) => c['method'] == 'directoryservices.update'),
        isEmpty,
      );
    },
  );
  test(
    'removing one trusted domain preserves other settings and verifies job',
    () async {
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.addAll([
            'directoryservices.status',
            'directoryservices.update',
          ]);
          wire.metadata['directoryservices.update'] = {'job': true};
          wire.values['directoryservices.config'] = editableTrustedConfig();
          wire.values['directoryservices.status'] = {
            'type': null,
            'status': null,
          };
          wire.values['directoryservices.update'] = 13;
        },
      );
      final inventory = await h.repo.loadDirectoryIdmap();
      final draft = DirectoryIdmapRangeDraft(
        builtin: inventory.builtin!.range,
        primary: inventory.primary!.range,
        trusted: inventory.trusted.map((domain) => domain.range).toList(),
        removal: 'TRUST_A',
      );
      expect(draft.validateAgainst(inventory), isNull);
      final review = await h.repo.reviewDirectoryIdmap(draft);
      expect(review.changes, ['Remove trusted domain TRUST_A']);
      expect(
        review.confirmation,
        'REMOVE TRUST_A IDMAP ${fake.host.substring(0, 8)}',
      );
      await expectLater(
        h.repo.executeDirectoryIdmap(
          review,
          'IDMAP ${fake.host.substring(0, 8)}',
        ),
        throwsA(isA<DirectoryIdmapException>()),
      );
      final submitted = await h.repo.executeDirectoryIdmap(
        review,
        review.confirmation,
      );
      expect(submitted.outcome, DirectoryIdmapOutcome.pending);
      final writes = h.wire.calls
          .where((c) => c['method'] == 'directoryservices.update')
          .toList();
      expect(writes, hasLength(1));
      final payload = (writes.single['params'] as List).single as Map;
      final configuration = payload['configuration'] as Map;
      expect(configuration['enable_trusted_domains'], true);
      final rows = configuration['trusted_domains'] as List;
      expect(rows, hasLength(1));
      expect((rows.single as Map)['name'], 'TRUST_B');
      expect((rows.single as Map)['schema_mode'], 'SFU');
      h.wire.values['core.get_jobs'] = [
        {
          'id': 13,
          'method': 'directoryservices.update',
          'arguments': [payload],
          'state': 'SUCCESS',
        },
      ];
      final saved = editableTrustedConfig();
      saved['configuration'] = configuration;
      h.wire.values['directoryservices.config'] = saved;
      expect(
        (await h.repo.pollDirectoryIdmap(submitted.job!)).outcome,
        DirectoryIdmapOutcome.completed,
      );
    },
  );

  test('removing last trusted domain disables trusted support', () async {
    final configured = editableTrustedConfig();
    final initial = configured['configuration'] as Map;
    initial['trusted_domains'] = [(initial['trusted_domains'] as List).first];
    final h = await fake.connected(
      configure: (wire) {
        wire.methods.addAll([
          'directoryservices.status',
          'directoryservices.update',
        ]);
        wire.metadata['directoryservices.update'] = {'job': true};
        wire.values['directoryservices.config'] = configured;
        wire.values['directoryservices.status'] = {
          'type': null,
          'status': null,
        };
        wire.values['directoryservices.update'] = 14;
      },
    );
    final inventory = await h.repo.loadDirectoryIdmap();
    final draft = DirectoryIdmapRangeDraft(
      builtin: inventory.builtin!.range,
      primary: inventory.primary!.range,
      trusted: [inventory.trusted.single.range],
      removal: 'TRUST_A',
    );
    final review = await h.repo.reviewDirectoryIdmap(draft);
    final submitted = await h.repo.executeDirectoryIdmap(
      review,
      review.confirmation,
    );
    expect(submitted.outcome, DirectoryIdmapOutcome.pending);
    final payload =
        (h.wire.calls.lastWhere(
                      (c) => c['method'] == 'directoryservices.update',
                    )['params']
                    as List)
                .single
            as Map;
    final configuration = payload['configuration'] as Map;
    expect(configuration['enable_trusted_domains'], false);
    expect(configuration['trusted_domains'], isEmpty);
    h.wire.values['core.get_jobs'] = [
      {
        'id': 14,
        'method': 'directoryservices.update',
        'arguments': [payload],
        'state': 'SUCCESS',
      },
    ];
    final saved = editableTrustedConfig();
    saved['configuration'] = configuration;
    h.wire.values['directoryservices.config'] = saved;
    expect(
      (await h.repo.pollDirectoryIdmap(submitted.job!)).outcome,
      DirectoryIdmapOutcome.completed,
    );
  });

  test('trusted removal rejects unknown target and mixed changes', () async {
    final h = await fake.connected(
      configure: (wire) {
        wire.methods.addAll([
          'directoryservices.status',
          'directoryservices.update',
        ]);
        wire.metadata['directoryservices.update'] = {'job': true};
        wire.values['directoryservices.config'] = editableTrustedConfig();
        wire.values['directoryservices.status'] = {
          'type': null,
          'status': null,
        };
      },
    );
    final inventory = await h.repo.loadDirectoryIdmap();
    DirectoryIdmapRangeDraft draft({
      String? removal,
      DirectoryIdmapRange? primary,
      DirectoryIdmapTrustedAddition? addition,
    }) => DirectoryIdmapRangeDraft(
      builtin: inventory.builtin!.range,
      primary: primary ?? inventory.primary!.range,
      trusted: inventory.trusted.map((domain) => domain.range).toList(),
      removal: removal,
      addition: addition,
    );
    expect(
      draft(removal: 'MISSING').validateAgainst(inventory),
      contains('existing'),
    );
    expect(
      draft(
        removal: 'TRUST_A',
        primary: const DirectoryIdmapRange(low: 110000001, high: 200000000),
      ).validateAgainst(inventory),
      contains('separately'),
    );
    expect(
      draft(
        removal: 'TRUST_A',
        addition: const DirectoryIdmapTrustedAddition(
          name: 'TRUST_C',
          range: DirectoryIdmapRange(low: 400000001, high: 500000000),
          options: DirectoryIdmapBackendOptions.rid(sssdCompat: false),
        ),
      ).validateAgainst(inventory),
      contains('without adding'),
    );
    expect(
      h.wire.calls.where((c) => c['method'] == 'directoryservices.update'),
      isEmpty,
    );
  });
  test(
    'removal with stale saved mapping stays unknown without replay',
    () async {
      final configured = editableTrustedConfig();
      final configuration = configured['configuration'] as Map;
      configuration['trusted_domains'] = [
        (configuration['trusted_domains'] as List).first,
      ];
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.addAll([
            'directoryservices.status',
            'directoryservices.update',
          ]);
          wire.metadata['directoryservices.update'] = {'job': true};
          wire.values['directoryservices.config'] = configured;
          wire.values['directoryservices.status'] = {
            'type': null,
            'status': null,
          };
          wire.values['directoryservices.update'] = 15;
        },
      );
      final inventory = await h.repo.loadDirectoryIdmap();
      final draft = DirectoryIdmapRangeDraft(
        builtin: inventory.builtin!.range,
        primary: inventory.primary!.range,
        trusted: [inventory.trusted.single.range],
        removal: 'TRUST_A',
      );
      final review = await h.repo.reviewDirectoryIdmap(draft);
      final submitted = await h.repo.executeDirectoryIdmap(
        review,
        review.confirmation,
      );
      final writes = h.wire.calls
          .where((c) => c['method'] == 'directoryservices.update')
          .toList();
      final payload = (writes.single['params'] as List).single as Map;
      h.wire.values['core.get_jobs'] = [
        {
          'id': 15,
          'method': 'directoryservices.update',
          'arguments': [payload],
          'state': 'SUCCESS',
        },
      ];
      expect(
        (await h.repo.pollDirectoryIdmap(submitted.job!)).outcome,
        DirectoryIdmapOutcome.unknown,
      );
      await expectLater(
        h.repo.reviewDirectoryIdmap(draft),
        throwsA(isA<DirectoryIdmapException>()),
      );
      expect(
        h.wire.calls.where((c) => c['method'] == 'directoryservices.update'),
        hasLength(1),
      );
    },
  );
  test(
    'AD backend invalid schema and unexpected fields block submission',
    () async {
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.addAll([
            'directoryservices.status',
            'directoryservices.update',
          ]);
          wire.metadata['directoryservices.update'] = {'job': true};
          wire.values['directoryservices.status'] = {
            'type': null,
            'status': null,
          };
          wire.values['directoryservices.update'] = 8;
        },
      );
      final invalid = editableAdConfig(backend: 'AD');
      final configuration = invalid['configuration'] as Map;
      final idmap = configuration['idmap'] as Map;
      (idmap['idmap_domain'] as Map)['schema_mode'] = 'INVALID';
      h.wire.values['directoryservices.config'] = invalid;
      await expectLater(
        h.repo.reviewDirectoryIdmap(editDraft),
        throwsA(isA<DirectoryIdmapException>()),
      );
      final unexpected = editableAdConfig(backend: 'AD');
      final nextIdmap = (unexpected['configuration'] as Map)['idmap'] as Map;
      (nextIdmap['idmap_domain'] as Map)['ldap_user_dn_password'] =
          'SYNTHETIC_SECRET';
      h.wire.values['directoryservices.config'] = unexpected;
      await expectLater(
        h.repo.reviewDirectoryIdmap(editDraft),
        throwsA(isA<DirectoryIdmapException>()),
      );
      expect(
        h.wire.calls.where(
          (call) => call['method'] == 'directoryservices.update',
        ),
        isEmpty,
      );
    },
  );

  test(
    'changed configuration and secret-bearing credentials block submission',
    () async {
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.addAll([
            'directoryservices.status',
            'directoryservices.update',
          ]);
          wire.metadata['directoryservices.update'] = {'job': true};
          wire.values['directoryservices.config'] = editableAdConfig();
          wire.values['directoryservices.status'] = {
            'type': null,
            'status': null,
          };
          wire.values['directoryservices.update'] = 7;
        },
      );
      final review = await h.repo.reviewDirectoryIdmap(editDraft);
      final changed = editableAdConfig();
      changed['timeout'] = 12;
      h.wire.values['directoryservices.config'] = changed;
      final rejected = await h.repo.executeDirectoryIdmap(
        review,
        review.confirmation,
      );
      expect(rejected.outcome, DirectoryIdmapOutcome.rejected);
      expect(
        h.wire.calls.where((c) => c['method'] == 'directoryservices.update'),
        isEmpty,
      );
      final secretBearing = editableAdConfig();
      secretBearing['credential'] = {
        'credential_type': 'KERBEROS_USER',
        'username': 'administrator',
        'password': 'SYNTHETIC_SECRET',
      };
      h.wire.values['directoryservices.config'] = secretBearing;
      await expectLater(
        h.repo.reviewDirectoryIdmap(editDraft),
        throwsA(isA<DirectoryIdmapException>()),
      );
    },
  );
  test('RID range draft validates boundaries, overlap, and changed values', () {
    final inventory = DirectoryIdmapInventory(
      endpoint: 'wss://nas.example.invalid/api/current',
      hostId: fake.host,
      serviceType: 'ACTIVEDIRECTORY',
      enabled: false,
      status: 'DISABLED',
      builtin: const DirectoryIdmapDomain(
        label: 'BUILTIN',
        backend: 'TDB',
        range: DirectoryIdmapRange(low: 90000001, high: 100000000),
      ),
      primary: const DirectoryIdmapDomain(
        label: 'Primary domain',
        backend: 'RID',
        range: DirectoryIdmapRange(low: 100000001, high: 200000000),
      ),
      trusted: const [],
    );
    final unchanged = DirectoryIdmapRangeDraft(
      builtin: DirectoryIdmapRange(low: 90000001, high: 100000000),
      primary: DirectoryIdmapRange(low: 100000001, high: 200000000),
    );
    expect(unchanged.validateAgainst(inventory), contains('Change'));
    final overlap = DirectoryIdmapRangeDraft(
      builtin: DirectoryIdmapRange(low: 90000001, high: 100000001),
      primary: DirectoryIdmapRange(low: 100000001, high: 200000000),
    );
    expect(overlap.validateAgainst(inventory), contains('overlap'));
    final short = DirectoryIdmapRangeDraft(
      builtin: DirectoryIdmapRange(low: 90000001, high: 90001000),
      primary: DirectoryIdmapRange(low: 100000001, high: 200000000),
    );
    expect(short.validateAgainst(inventory), contains('10000'));
    final valid = DirectoryIdmapRangeDraft(
      builtin: DirectoryIdmapRange(low: 90000001, high: 100000000),
      primary: DirectoryIdmapRange(low: 110000001, high: 200000000),
    );
    expect(valid.validateAgainst(inventory), isNull);
    expect(valid.changesFrom(inventory), [
      'Primary domain: 100000001–200000000 → 110000001–200000000',
    ]);
    final active = DirectoryIdmapInventory(
      endpoint: inventory.endpoint,
      hostId: inventory.hostId,
      serviceType: inventory.serviceType,
      enabled: true,
      status: 'HEALTHY',
      builtin: inventory.builtin,
      primary: inventory.primary,
      trusted: const [],
    );
    expect(valid.validateAgainst(active), contains('Disable'));
  });

  test(
    'projects only IDMAP backend and ranges from secret-bearing AD response',
    () async {
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.add('directoryservices.status');
          wire.values['directoryservices.config'] = adConfig();
          wire.values['directoryservices.status'] = {
            'type': 'ACTIVEDIRECTORY',
            'status': 'DISABLED',
            'status_msg': 'PRIVATE_STATUS_MESSAGE',
          };
        },
      );
      expect(h.repo.directoryIdmapCapabilities.canRead, isTrue);
      final view = await h.repo.loadDirectoryIdmap();
      expect(view.isActiveDirectory, isTrue);
      expect(view.enabled, isFalse);
      expect(view.domains.map((d) => d.backend), ['TDB', 'RID', 'RID']);
      expect(view.domains.map((d) => [d.range.low, d.range.high]), [
        [90000001, 100000000],
        [100000001, 200000000],
        [200000001, 300000000],
      ]);
      expect(view.warnings, isEmpty);
      expect(view.domains.toString(), isNot(contains('PRIVATE_')));
      expect(
        h.wire.calls.map((c) => c['method']),
        isNot(contains('directoryservices.update')),
      );
    },
  );

  test('flags inclusive overlap and insufficient ID span', () async {
    final h = await fake.connected(
      configure: (wire) {
        wire.methods.add('directoryservices.status');
        wire.values['directoryservices.config'] = adConfig(
          builtinHigh: 100000010,
          domainLow: 100000000,
          domainHigh: 100000500,
        );
        wire.values['directoryservices.status'] = {
          'type': 'ACTIVEDIRECTORY',
          'status': 'DISABLED',
        };
      },
    );
    final view = await h.repo.loadDirectoryIdmap();
    expect(view.warnings.join(' '), contains('overlaps'));
    expect(view.warnings.join(' '), contains('fewer than 10,000'));
  });

  test('missing status method and malformed AD mapping fail closed', () async {
    final unsupported = await fake.connected();
    expect(unsupported.repo.directoryIdmapCapabilities.canRead, isFalse);
    await expectLater(
      unsupported.repo.loadDirectoryIdmap(),
      throwsA(isA<DirectoryIdmapException>()),
    );
    final malformed = await fake.connected(
      configure: (wire) {
        wire.methods.add('directoryservices.status');
        wire.values['directoryservices.config'] = adConfig();
        wire.values['directoryservices.status'] = {
          'type': 'LDAP',
          'status': 'HEALTHY',
        };
      },
    );
    await expectLater(
      malformed.repo.loadDirectoryIdmap(),
      throwsA(isA<DirectoryIdmapException>()),
    );
  });
  test('failed owned job with unchanged configuration is rejected', () async {
    final h = await fake.connected(
      configure: (wire) {
        wire.methods.addAll([
          'directoryservices.status',
          'directoryservices.update',
        ]);
        wire.metadata['directoryservices.update'] = {'job': true};
        wire.values['directoryservices.config'] = editableAdConfig();
        wire.values['directoryservices.status'] = {
          'type': null,
          'status': null,
        };
        wire.values['directoryservices.update'] = 7;
      },
    );
    final review = await h.repo.reviewDirectoryIdmap(editDraft);
    final submitted = await h.repo.executeDirectoryIdmap(
      review,
      review.confirmation,
    );
    final payload =
        ((h.wire.calls.lastWhere(
                      (call) => call['method'] == 'directoryservices.update',
                    )['params']
                    as List)
                .single
            as Map);
    h.wire.values['core.get_jobs'] = [
      {
        'id': 7,
        'method': 'directoryservices.update',
        'arguments': [payload],
        'state': 'FAILED',
      },
    ];
    final result = await h.repo.pollDirectoryIdmap(submitted.job!);
    expect(result.outcome, DirectoryIdmapOutcome.rejected);
    expect(
      h.wire.calls.where(
        (call) => call['method'] == 'directoryservices.update',
      ),
      hasLength(1),
    );
  });

  test('malformed receipt fences IDMAP writes without replay', () async {
    final h = await fake.connected(
      configure: (wire) {
        wire.methods.addAll([
          'directoryservices.status',
          'directoryservices.update',
        ]);
        wire.metadata['directoryservices.update'] = {'job': true};
        wire.values['directoryservices.config'] = editableAdConfig();
        wire.values['directoryservices.status'] = {
          'type': null,
          'status': null,
        };
        wire.values['directoryservices.update'] = {'unexpected': true};
      },
    );
    final review = await h.repo.reviewDirectoryIdmap(editDraft);
    final result = await h.repo.executeDirectoryIdmap(
      review,
      review.confirmation,
    );
    expect(result.outcome, DirectoryIdmapOutcome.unknown);
    expect(result.job, isNull);
    await expectLater(
      h.repo.reviewDirectoryIdmap(editDraft),
      throwsA(isA<DirectoryIdmapException>()),
    );
    expect(
      h.wire.calls.where(
        (call) => call['method'] == 'directoryservices.update',
      ),
      hasLength(1),
    );
  });
  test(
    'isolated primary RID to AD migration strips RID options and verifies save',
    () async {
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.addAll([
            'directoryservices.status',
            'directoryservices.update',
          ]);
          wire.metadata['directoryservices.update'] = {'job': true};
          wire.values['directoryservices.config'] = editableAdConfig();
          wire.values['directoryservices.status'] = {
            'type': null,
            'status': null,
          };
          wire.values['directoryservices.update'] = 16;
        },
      );
      final draft = DirectoryIdmapRangeDraft(
        builtin: const DirectoryIdmapRange(low: 90000001, high: 100000000),
        primary: const DirectoryIdmapRange(low: 100000001, high: 200000000),
        transition: const DirectoryIdmapBackendTransition.primary(
          DirectoryIdmapBackendOptions.ad(
            schemaMode: 'RFC2307',
            unixPrimaryGroup: true,
            unixNssInfo: false,
          ),
        ),
      );
      final inventory = await h.repo.loadDirectoryIdmap();
      expect(draft.validateAgainst(inventory), isNull);
      final review = await h.repo.reviewDirectoryIdmap(draft);
      expect(
        review.confirmation,
        'MIGRATE PRIMARY IDMAP ${fake.host.substring(0, 8)}',
      );
      final submitted = await h.repo.executeDirectoryIdmap(
        review,
        review.confirmation,
      );
      expect(submitted.outcome, DirectoryIdmapOutcome.pending);
      final payload =
          ((h.wire.calls.lastWhere(
                        (call) => call['method'] == 'directoryservices.update',
                      )['params']
                      as List)
                  .single
              as Map);
      final config = payload['configuration'] as Map;
      final primary = (config['idmap'] as Map)['idmap_domain'] as Map;
      expect(primary['idmap_backend'], 'AD');
      expect(primary.containsKey('sssd_compat'), isFalse);
      expect(primary['schema_mode'], 'RFC2307');
      expect(primary['name'], 'EXAMPLE');
      h.wire.values['core.get_jobs'] = [
        {
          'id': 16,
          'method': 'directoryservices.update',
          'arguments': [payload],
          'state': 'SUCCESS',
        },
      ];
      final saved = editableAdConfig();
      saved['configuration'] = config;
      h.wire.values['directoryservices.config'] = saved;
      expect(
        (await h.repo.pollDirectoryIdmap(submitted.job!)).outcome,
        DirectoryIdmapOutcome.completed,
      );
    },
  );

  test(
    'trusted AD to RID migration is isolated and strips AD options',
    () async {
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.addAll([
            'directoryservices.status',
            'directoryservices.update',
          ]);
          wire.metadata['directoryservices.update'] = {'job': true};
          wire.values['directoryservices.config'] = editableTrustedConfig();
          wire.values['directoryservices.status'] = {
            'type': null,
            'status': null,
          };
          wire.values['directoryservices.update'] = 17;
        },
      );
      DirectoryIdmapRangeDraft draft({int primaryLow = 100000001}) =>
          DirectoryIdmapRangeDraft(
            builtin: const DirectoryIdmapRange(low: 90000001, high: 100000000),
            primary: DirectoryIdmapRange(low: primaryLow, high: 200000000),
            trusted: const [
              DirectoryIdmapRange(low: 200000001, high: 300000000),
              DirectoryIdmapRange(low: 300000001, high: 400000000),
            ],
            transition: const DirectoryIdmapBackendTransition.trusted(
              'TRUST_B',
              DirectoryIdmapBackendOptions.rid(sssdCompat: true),
            ),
          );
      final inventory = await h.repo.loadDirectoryIdmap();
      expect(draft().validateAgainst(inventory), isNull);
      expect(
        draft(primaryLow: 110000001).validateAgainst(inventory),
        contains('separately'),
      );
      final review = await h.repo.reviewDirectoryIdmap(draft());
      expect(
        review.confirmation,
        'MIGRATE TRUST_B IDMAP ${fake.host.substring(0, 8)}',
      );
      final submitted = await h.repo.executeDirectoryIdmap(
        review,
        review.confirmation,
      );
      expect(submitted.outcome, DirectoryIdmapOutcome.pending);
      final payload =
          ((h.wire.calls.lastWhere(
                        (call) => call['method'] == 'directoryservices.update',
                      )['params']
                      as List)
                  .single
              as Map);
      final config = payload['configuration'] as Map;
      final trusted = config['trusted_domains'] as List;
      final migrated = trusted[1] as Map;
      expect(migrated['idmap_backend'], 'RID');
      expect(migrated['sssd_compat'], true);
      expect(migrated.containsKey('schema_mode'), isFalse);
      expect(migrated.containsKey('unix_primary_group'), isFalse);
      expect(migrated.containsKey('unix_nss_info'), isFalse);
      expect((trusted[0] as Map)['name'], 'TRUST_A');
      h.wire.values['core.get_jobs'] = [
        {
          'id': 17,
          'method': 'directoryservices.update',
          'arguments': [payload],
          'state': 'SUCCESS',
        },
      ];
      final saved = editableTrustedConfig();
      saved['configuration'] = config;
      h.wire.values['directoryservices.config'] = saved;
      expect(
        (await h.repo.pollDirectoryIdmap(submitted.job!)).outcome,
        DirectoryIdmapOutcome.completed,
      );
    },
  );
  test(
    'migration rejects missing target and fences mismatched saved backend',
    () async {
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.addAll([
            'directoryservices.status',
            'directoryservices.update',
          ]);
          wire.metadata['directoryservices.update'] = {'job': true};
          wire.values['directoryservices.config'] = editableTrustedConfig();
          wire.values['directoryservices.status'] = {
            'type': null,
            'status': null,
          };
          wire.values['directoryservices.update'] = 18;
        },
      );
      DirectoryIdmapRangeDraft draft(String target) => DirectoryIdmapRangeDraft(
        builtin: const DirectoryIdmapRange(low: 90000001, high: 100000000),
        primary: const DirectoryIdmapRange(low: 100000001, high: 200000000),
        trusted: const [
          DirectoryIdmapRange(low: 200000001, high: 300000000),
          DirectoryIdmapRange(low: 300000001, high: 400000000),
        ],
        transition: DirectoryIdmapBackendTransition.trusted(
          target,
          const DirectoryIdmapBackendOptions.rid(sssdCompat: true),
        ),
      );
      final inventory = await h.repo.loadDirectoryIdmap();
      expect(draft('MISSING').validateAgainst(inventory), isNotNull);
      expect(draft('TRUST_B').validateAgainst(inventory), isNull);
      final review = await h.repo.reviewDirectoryIdmap(draft('TRUST_B'));
      final submitted = await h.repo.executeDirectoryIdmap(
        review,
        review.confirmation,
      );
      final payload =
          ((h.wire.calls.lastWhere(
                        (call) => call['method'] == 'directoryservices.update',
                      )['params']
                      as List)
                  .single
              as Map);
      h.wire.values['core.get_jobs'] = [
        {
          'id': 18,
          'method': 'directoryservices.update',
          'arguments': [payload],
          'state': 'SUCCESS',
        },
      ];
      // A success receipt with the old persisted backend is not success.
      expect(
        (await h.repo.pollDirectoryIdmap(submitted.job!)).outcome,
        DirectoryIdmapOutcome.unknown,
      );
      expect(
        h.wire.calls.where(
          (call) => call['method'] == 'directoryservices.update',
        ),
        hasLength(1),
      );
    },
  );
  test(
    'LDAP overview projects only nonsecret transport and schema fields',
    () async {
      Map<String, Object?> ldapConfig(String url) => {
        'enable': false,
        'service_type': 'LDAP',
        'credential': {
          'credential_type': 'LDAP_PLAIN',
          'binddn': 'cn=private,dc=example,dc=invalid',
          'bindpw': 'DO_NOT_EXPOSE_SECRET',
        },
        'configuration': {
          'server_urls': [url],
          'basedn': 'dc=example,dc=invalid',
          'schema': 'RFC2307BIS',
          'starttls': true,
          'validate_certificates': true,
          'auxiliary_parameters': 'DO_NOT_EXPOSE_AUXILIARY',
        },
      };
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.add('directoryservices.status');
          wire.values['directoryservices.config'] = ldapConfig(
            'ldap://ldap.example.invalid:389',
          );
          wire.values['directoryservices.status'] = {
            'type': null,
            'status': 'DISABLED',
          };
        },
      );
      final overview = (await h.repo.loadDirectoryIdmap()).ldap!;
      expect(overview.serverUrls, ['ldap://ldap.example.invalid:389']);
      expect(overview.baseDn, 'dc=example,dc=invalid');
      expect(overview.schema, 'RFC2307BIS');
      expect(overview.credentialType, 'LDAP_PLAIN');
      expect(overview.hasAuxiliaryParameters, isTrue);
      expect(overview.startTls, isTrue);
      expect(overview.encryptedTransport, isTrue);
      expect(overview.validateCertificates, isTrue);
      expect(overview.toString(), isNot(contains('DO_NOT_EXPOSE')));
      expect((await h.repo.loadDirectoryIdmap()).isActiveDirectory, isFalse);
      h.wire.values['directoryservices.config'] = ldapConfig(
        'ldap://user:password@ldap.example.invalid',
      );
      await expectLater(
        h.repo.loadDirectoryIdmap(),
        throwsA(isA<DirectoryIdmapException>()),
      );
    },
  );
  test('directory cache refresh submits once and verifies owned job', () async {
    final h = await fake.connected(
      configure: (wire) {
        wire.methods.addAll([
          'directoryservices.status',
          'directoryservices.cache_refresh',
        ]);
        wire.metadata['directoryservices.cache_refresh'] = {'job': true};
        final config = editableAdConfig();
        config['enable'] = true;
        wire.values['directoryservices.config'] = config;
        wire.values['directoryservices.status'] = {
          'type': 'ACTIVEDIRECTORY',
          'status': 'HEALTHY',
        };
        wire.values['directoryservices.cache_refresh'] = 19;
      },
    );
    expect(h.repo.directoryIdmapCapabilities.canRefreshCache, isTrue);
    final review = await h.repo.reviewDirectoryCacheRefresh();
    expect(
      review.confirmation,
      'REFRESH ACTIVEDIRECTORY CACHE ${fake.host.substring(0, 8)}',
    );
    final pending = await h.repo.executeDirectoryCacheRefresh(
      review,
      review.confirmation,
    );
    expect(pending.outcome, DirectoryIdmapOutcome.pending);
    final writes = h.wire.calls
        .where((call) => call['method'] == 'directoryservices.cache_refresh')
        .toList();
    expect(writes, hasLength(1));
    expect(writes.single['params'], isEmpty);
    h.wire.values['core.get_jobs'] = [
      {
        'id': 19,
        'method': 'directoryservices.cache_refresh',
        'arguments': [],
        'state': 'SUCCESS',
      },
    ];
    final completed = await h.repo.pollDirectoryCacheRefresh(pending.job!);
    expect(completed.outcome, DirectoryIdmapOutcome.completed);
  });

  test('cache refresh preflight drift prevents submission', () async {
    final h = await fake.connected(
      configure: (wire) {
        wire.methods.addAll([
          'directoryservices.status',
          'directoryservices.cache_refresh',
        ]);
        wire.metadata['directoryservices.cache_refresh'] = {'job': true};
        final config = editableAdConfig();
        config['enable'] = true;
        wire.values['directoryservices.config'] = config;
        wire.values['directoryservices.status'] = {
          'type': 'ACTIVEDIRECTORY',
          'status': 'HEALTHY',
        };
        wire.values['directoryservices.cache_refresh'] = 20;
      },
    );
    final review = await h.repo.reviewDirectoryCacheRefresh();
    final changed = editableAdConfig();
    changed['enable'] = true;
    changed['timeout'] = 15;
    h.wire.values['directoryservices.config'] = changed;
    final rejected = await h.repo.executeDirectoryCacheRefresh(
      review,
      review.confirmation,
    );
    expect(rejected.outcome, DirectoryIdmapOutcome.rejected);
    expect(
      h.wire.calls.where(
        (call) => call['method'] == 'directoryservices.cache_refresh',
      ),
      isEmpty,
    );
  });

  test('ambiguous cache refresh receipt fences replay', () async {
    final h = await fake.connected(
      configure: (wire) {
        wire.methods.addAll([
          'directoryservices.status',
          'directoryservices.cache_refresh',
        ]);
        wire.metadata['directoryservices.cache_refresh'] = {'job': true};
        final config = editableAdConfig();
        config['enable'] = true;
        wire.values['directoryservices.config'] = config;
        wire.values['directoryservices.status'] = {
          'type': 'ACTIVEDIRECTORY',
          'status': 'HEALTHY',
        };
        wire.values['directoryservices.cache_refresh'] = {'unexpected': true};
      },
    );
    final review = await h.repo.reviewDirectoryCacheRefresh();
    final uncertain = await h.repo.executeDirectoryCacheRefresh(
      review,
      review.confirmation,
    );
    expect(uncertain.outcome, DirectoryIdmapOutcome.unknown);
    await expectLater(
      h.repo.reviewDirectoryCacheRefresh(),
      throwsA(isA<DirectoryIdmapException>()),
    );
    expect(
      h.wire.calls.where(
        (call) => call['method'] == 'directoryservices.cache_refresh',
      ),
      hasLength(1),
    );
  });
  test(
    'cache refresh refuses unhealthy service and foreign job result',
    () async {
      final h = await fake.connected(
        configure: (wire) {
          wire.methods.addAll([
            'directoryservices.status',
            'directoryservices.cache_refresh',
          ]);
          wire.metadata['directoryservices.cache_refresh'] = {'job': true};
          final config = editableAdConfig();
          config['enable'] = true;
          wire.values['directoryservices.config'] = config;
          wire.values['directoryservices.status'] = {
            'type': 'ACTIVEDIRECTORY',
            'status': 'FAULTED',
          };
          wire.values['directoryservices.cache_refresh'] = 21;
        },
      );
      await expectLater(
        h.repo.reviewDirectoryCacheRefresh(),
        throwsA(isA<DirectoryIdmapException>()),
      );
      h.wire.values['directoryservices.status'] = {
        'type': 'ACTIVEDIRECTORY',
        'status': 'HEALTHY',
      };
      final review = await h.repo.reviewDirectoryCacheRefresh();
      final pending = await h.repo.executeDirectoryCacheRefresh(
        review,
        review.confirmation,
      );
      h.wire.values['core.get_jobs'] = [
        {
          'id': 21,
          'method': 'directoryservices.update',
          'arguments': [],
          'state': 'SUCCESS',
        },
      ];
      expect(
        (await h.repo.pollDirectoryCacheRefresh(pending.job!)).outcome,
        DirectoryIdmapOutcome.unknown,
      );
      expect(
        h.wire.calls.where(
          (call) => call['method'] == 'directoryservices.cache_refresh',
        ),
        hasLength(1),
      );
    },
  );
  test('AD keytab sync submits once and verifies the owned job', () async {
    final h = await fake.connected(
      configure: (wire) {
        wire.methods.addAll([
          'directoryservices.status',
          'directoryservices.sync_keytab',
        ]);
        wire.metadata['directoryservices.sync_keytab'] = {'job': true};
        final config = editableAdConfig();
        config['enable'] = true;
        wire.values['directoryservices.config'] = config;
        wire.values['directoryservices.status'] = {
          'type': 'ACTIVEDIRECTORY',
          'status': 'HEALTHY',
        };
        wire.values['directoryservices.sync_keytab'] = 22;
      },
    );
    expect(h.repo.directoryIdmapCapabilities.canSyncKeytab, isTrue);
    expect(h.repo.directoryIdmapCapabilities.canRefreshCache, isFalse);
    final review = await h.repo.reviewDirectoryKeytabSync();
    expect(review.action, DirectoryMaintenanceAction.syncKeytab);
    expect(review.confirmation, 'SYNC AD KEYTAB ${fake.host.substring(0, 8)}');
    final pending = await h.repo.executeDirectoryKeytabSync(
      review,
      review.confirmation,
    );
    expect(pending.outcome, DirectoryIdmapOutcome.pending);
    final writes = h.wire.calls
        .where((call) => call['method'] == 'directoryservices.sync_keytab')
        .toList();
    expect(writes, hasLength(1));
    expect(writes.single['params'], isEmpty);
    h.wire.values['core.get_jobs'] = [
      {
        'id': 22,
        'method': 'directoryservices.sync_keytab',
        'arguments': [],
        'state': 'SUCCESS',
      },
    ];
    expect(
      (await h.repo.pollDirectoryKeytabSync(pending.job!)).outcome,
      DirectoryIdmapOutcome.completed,
    );
  });

  test('keytab sync refuses LDAP and foreign job receipts', () async {
    final h = await fake.connected(
      configure: (wire) {
        wire.methods.addAll([
          'directoryservices.status',
          'directoryservices.sync_keytab',
        ]);
        wire.metadata['directoryservices.sync_keytab'] = {'job': true};
        wire.values['directoryservices.config'] = {
          'enable': true,
          'service_type': 'LDAP',
          'configuration': {
            'server_urls': ['ldaps://ldap.example.invalid'],
            'basedn': 'dc=example,dc=invalid',
          },
          'credential': {'credential_type': 'LDAP_ANONYMOUS'},
        };
        wire.values['directoryservices.status'] = {
          'type': 'LDAP',
          'status': 'HEALTHY',
        };
        wire.values['directoryservices.sync_keytab'] = 23;
      },
    );
    await expectLater(
      h.repo.reviewDirectoryKeytabSync(),
      throwsA(isA<DirectoryIdmapException>()),
    );
    expect(
      h.wire.calls.where(
        (call) => call['method'] == 'directoryservices.sync_keytab',
      ),
      isEmpty,
    );
    final ad = editableAdConfig();
    ad['enable'] = true;
    h.wire.values['directoryservices.config'] = ad;
    h.wire.values['directoryservices.status'] = {
      'type': 'ACTIVEDIRECTORY',
      'status': 'HEALTHY',
    };
    final review = await h.repo.reviewDirectoryKeytabSync();
    final pending = await h.repo.executeDirectoryKeytabSync(
      review,
      review.confirmation,
    );
    h.wire.values['core.get_jobs'] = [
      {
        'id': 23,
        'method': 'directoryservices.cache_refresh',
        'arguments': [],
        'state': 'SUCCESS',
      },
    ];
    expect(
      (await h.repo.pollDirectoryKeytabSync(pending.job!)).outcome,
      DirectoryIdmapOutcome.unknown,
    );
    expect(
      h.wire.calls.where(
        (call) => call['method'] == 'directoryservices.sync_keytab',
      ),
      hasLength(1),
    );
  });
}
