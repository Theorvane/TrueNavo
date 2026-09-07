// @TestOn('vm')
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/local_persistence/app_database.dart';
import 'package:truedash/features/local_persistence/drift_server_profile_store.dart';
import 'package:truedash/features/local_persistence/persistence_failure.dart';
import 'package:truedash/features/server_profiles/server_profile.dart';

void main() {
  ServerProfile safeProfile({String id = 'safe-id'}) => ServerProfile(
    id: id,
    displayName: 'safe.example',
    originalHostInput: 'https://safe.example',
    normalizedEndpoint: 'wss://safe.example/api/current',
    lastKnownVersion: '25.10',
  );

  test('schema is limited to approved credential-free data', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final rows = await database
        .customSelect(
          "SELECT name, sql FROM sqlite_master WHERE type = 'table' "
          "AND name IN ('server_profiles', 'app_selection', "
          "'profile_capabilities') ORDER BY name",
        )
        .get();
    expect(rows.map((row) => row.read<String>('name')), [
      'app_selection',
      'profile_capabilities',
      'server_profiles',
    ]);
    final schema = rows.map((row) => row.read<String>('sql')).join('\n');
    final columns = <String>[];
    final types = <String>[];
    for (final table in const [
      'server_profiles',
      'app_selection',
      'profile_capabilities',
    ]) {
      final info = await database
          .customSelect('PRAGMA table_info($table)')
          .get();
      columns.addAll(info.map((row) => row.read<String>('name').toLowerCase()));
      types.addAll(info.map((row) => row.read<String>('type').toLowerCase()));
    }
    for (final forbidden in const [
      'api_key',
      'credential',
      'password',
      'token',
      'pin',
      'fingerprint',
      'certificate',
      'secret',
      'auth_header',
    ]) {
      expect(columns, everyElement(isNot(contains(forbidden))));
    }
    expect(types, everyElement(isNot(anyOf('blob', 'json'))));
    expect(
      RegExp(r'\b(?:blob|json)\b', caseSensitive: false).hasMatch(schema),
      isFalse,
    );
  });

  test(
    'secret-shaped and JSON public inputs fail before durable write',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final store = DriftServerProfileStore(database);
      addTearDown(store.close);
      const secret = 'td8_api_key=AIzaSyDURABLE_SENTINEL';
      const json = '{"td8":"DURABLE_SENTINEL"}';
      final rejected = <ServerProfile>[
        safeProfile(id: secret),
        ServerProfile(
          id: 'display',
          displayName: secret,
          originalHostInput: 'https://safe.example',
          normalizedEndpoint: 'wss://safe.example/api/current',
          lastKnownVersion: '25.10',
        ),
        ServerProfile(
          id: 'original',
          displayName: 'safe.example',
          originalHostInput: 'https://$secret.example',
          normalizedEndpoint: 'wss://$secret.example/api/current',
          lastKnownVersion: '25.10',
        ),
        ServerProfile(
          id: 'endpoint',
          displayName: 'safe.example',
          originalHostInput: 'https://safe.example',
          normalizedEndpoint: 'wss://safe.example/api/$secret',
          lastKnownVersion: '25.10',
        ),
        ServerProfile(
          id: 'version',
          displayName: 'safe.example',
          originalHostInput: 'https://safe.example',
          normalizedEndpoint: 'wss://safe.example/api/current',
          lastKnownVersion: json,
        ),
      ];
      for (final profile in rejected) {
        await expectLater(
          store.registerAndSelect(profile),
          throwsA(isA<PersistenceFailure>()),
        );
      }
      await store.registerAndSelect(safeProfile());
      await expectLater(
        store.replaceCapabilities(
          profileId: 'safe-id',
          methodNames: const {'td8_api_key_DURABLE_SENTINEL'},
          observedAt: DateTime.utc(2026),
          expiresAt: DateTime.utc(2026, 1, 2),
        ),
        throwsA(isA<PersistenceFailure>()),
      );
      final durableRows = await database
          .customSelect('SELECT * FROM server_profiles')
          .get();
      expect(
        durableRows.single.data.values.join(),
        isNot(contains('DURABLE_SENTINEL')),
      );
      expect(
        await store.readCapabilities('safe-id', DateTime.utc(2026)),
        isEmpty,
      );
    },
  );

  test('valid host version and method names remain persistable', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final store = DriftServerProfileStore(database);
    addTearDown(store.close);
    await store.registerAndSelect(safeProfile());
    await store.replaceCapabilities(
      profileId: 'safe-id',
      methodNames: const {'core.get_methods', 'system.info'},
      observedAt: DateTime.utc(2026),
      expiresAt: DateTime.utc(2026, 1, 2),
    );
    expect(await store.readCapabilities('safe-id', DateTime.utc(2026)), {
      'core.get_methods',
      'system.info',
    });
  });

  test('secret-shaped corrupt capability rows fail closed on read', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final store = DriftServerProfileStore(database);
    addTearDown(store.close);
    await store.registerAndSelect(safeProfile());
    await database.customStatement(
      'INSERT INTO profile_capabilities '
      '(profile_id, method_name, observed_at_ms, expires_at_ms) '
      'VALUES (?, ?, ?, ?)',
      ['safe-id', 'api_key_DURABLE_SENTINEL', 1, 4102444800000],
    );

    await expectLater(
      store.readCapabilities('safe-id', DateTime.utc(2026)),
      throwsA(
        isA<PersistenceFailure>().having(
          (failure) => failure.kind,
          'kind',
          PersistenceFailureKind.unavailable,
        ),
      ),
    );
  });

  test('native reopen retains safe state, expires stale data, and has no credential bytes', () async {
    final directory = await Directory.systemTemp.createTemp(
      'truedash-task8-reopen-',
    );
    final file = File('${directory.path}/state.sqlite');
    if (await Link(file.path).exists()) {
      fail('test database path must not be a link');
    }
    addTearDown(() async {
      if (await directory.exists()) await directory.delete(recursive: true);
    });
    final observed = DateTime.utc(2026, 1, 1);
    final first = AppDatabase.forTesting(NativeDatabase(file));
    final writer = DriftServerProfileStore(first);
    await writer.registerAndSelect(safeProfile());
    await writer.replaceCapabilities(
      profileId: 'safe-id',
      methodNames: const {'system.info'},
      observedAt: observed,
      expiresAt: observed.add(const Duration(hours: 1)),
    );
    await writer.replaceCapabilities(
      profileId: 'safe-id',
      methodNames: const {'system.info'},
      observedAt: observed,
      expiresAt: observed.add(const Duration(hours: 1)),
    );
    await writer.close();

    final second = AppDatabase.forTesting(NativeDatabase(file));
    final reader = DriftServerProfileStore(second);
    addTearDown(reader.close);
    expect((await reader.load()).profiles, [safeProfile()]);
    expect((await reader.load()).selectedProfileId, 'safe-id');
    expect(await reader.readCapabilities('safe-id', observed), {'system.info'});
    expect(
      await reader.readCapabilities(
        'safe-id',
        observed.add(const Duration(days: 1)),
      ),
      isEmpty,
    );
    await reader.close();
    expect(
      latin1.decode(await file.readAsBytes()),
      isNot(contains('DURABLE_SENTINEL')),
    );
  });

  test('store close is idempotent and later operations fail closed', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final store = DriftServerProfileStore(database);
    await Future.wait([store.close(), store.close()]);
    await expectLater(store.load(), throwsA(isA<PersistenceFailure>()));
  });

  test(
    'corrupt native database reports a credential-free persistence failure',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'truedash-task8-corrupt-',
      );
      final file = File('${directory.path}/state.sqlite');
      if (await Link(file.path).exists()) {
        fail('test database path must not be a link');
      }
      await file.writeAsBytes(const [0, 1, 2, 3, 4, 5]);
      addTearDown(() async {
        if (await directory.exists()) await directory.delete(recursive: true);
      });
      final store = DriftServerProfileStore(
        AppDatabase.forTesting(NativeDatabase(file)),
      );
      addTearDown(store.close);
      try {
        await store.load();
        fail('corrupt data must not be treated as an empty database');
      } on PersistenceFailure catch (error) {
        expect(error.kind, PersistenceFailureKind.unavailable);
        expect(error.toString(), isNot(contains(file.path)));
        expect(error.toString().toLowerCase(), isNot(contains('sqlite')));
      }
    },
  );

  test(
    'production persistence and web route contain no secret or TLS bypass path',
    () {
      final production = [
        'lib/features/local_persistence/app_database.dart',
        'lib/features/local_persistence/app_database.g.dart',
        'lib/features/local_persistence/drift_server_profile_store.dart',
        'lib/features/local_persistence/database_connection_web.dart',
        'lib/features/credentials/secure_credential_vault_web.dart',
      ].map((path) => File(path).readAsStringSync()).join('\n');
      for (final forbidden in const [
        'badCertificateCallback',
        'allowBadCertificates',
        'trustAll',
        'debugPrint(',
        'print(',
      ]) {
        expect(production, isNot(contains(forbidden)));
      }
      final generated = File(
        'lib/features/local_persistence/app_database.g.dart',
      ).readAsStringSync();
      for (final forbiddenField in const [
        'apiKey',
        'credential',
        'password',
        'authHeader',
        'certificate',
        'fingerprint',
      ]) {
        expect(generated, isNot(contains(forbiddenField)));
      }
      final webConnection = File(
        'lib/features/local_persistence/database_connection_web.dart',
      ).readAsStringSync();
      final webVault = File(
        'lib/features/credentials/secure_credential_vault_web.dart',
      ).readAsStringSync();
      expect(webConnection, contains('DriftWebOptions'));
      expect(webConnection, contains('sqlite3Wasm'));
      expect(webConnection, contains('driftWorker'));
      expect(webConnection, isNot(contains('dart:io')));
      expect(webVault, contains('WebSecureCredentialVault'));
      expect(webVault, isNot(contains('flutter_secure_storage')));
      expect(webVault, isNot(contains('tls_trust')));
    },
  );
}
