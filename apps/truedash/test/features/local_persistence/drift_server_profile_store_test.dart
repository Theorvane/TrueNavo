import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/local_persistence/app_database.dart';
import 'package:truedash/features/local_persistence/drift_server_profile_store.dart';
import 'package:truedash/features/local_persistence/persistence_failure.dart';
import 'package:truedash/features/server_profiles/server_profile.dart';

void main() {
  late AppDatabase database;
  late DriftServerProfileStore store;
  late DateTime currentTime;

  ServerProfile profile(String id, String host) => ServerProfile(
    id: id,
    displayName: host,
    originalHostInput: 'https://$host',
    normalizedEndpoint: 'wss://$host/api/current',
    lastKnownVersion: '25.10',
  );

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    currentTime = DateTime.utc(2026);
    store = DriftServerProfileStore(database, clock: () => currentTime);
  });
  tearDown(() => store.close());

  test(
    'registers in stable order and refreshes endpoint-collision metadata',
    () async {
      await store.registerAndSelect(profile('one', 'one.example'));
      await store.registerAndSelect(profile('two', 'two.example'));
      final original = await (database.select(
        database.serverProfiles,
      )..where((row) => row.id.equals('one'))).getSingle();
      currentTime = currentTime.add(const Duration(minutes: 1));
      final refreshed = await store.registerAndSelect(
        ServerProfile(
          id: 'different',
          displayName: 'One refreshed',
          originalHostInput: 'https://one.example',
          normalizedEndpoint: 'wss://one.example/api/current',
          lastKnownVersion: '26.04',
        ),
      );

      expect(refreshed.profiles.map((item) => item.id), ['one', 'two']);
      expect(refreshed.profiles.first.displayName, 'One refreshed');
      expect(refreshed.profiles.first.lastKnownVersion, '26.04');
      expect(refreshed.selectedProfileId, 'one');
      final retained = await (database.select(
        database.serverProfiles,
      )..where((row) => row.id.equals('one'))).getSingle();
      expect(retained.createdAtMs, original.createdAtMs);
      expect(retained.sortOrder, original.sortOrder);
      expect(retained.updatedAtMs, currentTime.millisecondsSinceEpoch);
    },
  );

  test(
    'refreshes an id collision in place and rejects invalid endpoints',
    () async {
      await store.registerAndSelect(profile('one', 'one.example'));
      final refreshed = await store.registerAndSelect(
        profile('one', 'two.example'),
      );
      expect(refreshed.profiles.map((item) => item.id), ['one']);
      expect(
        refreshed.profiles.single.normalizedEndpoint,
        'wss://two.example/api/current',
      );
      expect(refreshed.selectedProfileId, 'one');
      await expectLater(
        store.registerAndSelect(profile('bad', 'http://bad.example')),
        throwsA(isA<PersistenceFailure>()),
      );
    },
  );

  test('merges an id and endpoint collision into the id entry', () async {
    await store.registerAndSelect(profile('one', 'one.example'));
    await store.registerAndSelect(profile('two', 'two.example'));
    await store.registerAndSelect(profile('three', 'three.example'));
    final observed = DateTime.utc(2026, 1, 1);
    await store.replaceCapabilities(
      profileId: 'two',
      methodNames: const {'system.info'},
      observedAt: observed,
      expiresAt: observed.add(const Duration(hours: 1)),
    );

    final merged = await store.registerAndSelect(
      ServerProfile(
        id: 'one',
        displayName: 'Merged',
        originalHostInput: 'https://two.example',
        normalizedEndpoint: 'wss://two.example/api/current',
        lastKnownVersion: '26.04',
      ),
    );

    expect(merged.profiles.map((item) => item.id), ['one', 'three']);
    expect(merged.profiles.first.displayName, 'Merged');
    expect(
      merged.profiles.first.normalizedEndpoint,
      'wss://two.example/api/current',
    );
    expect(merged.selectedProfileId, 'one');
    expect(await store.readCapabilities('two', observed), isEmpty);
  });

  test(
    'selects, rejects unknown selection, and falls back after removal',
    () async {
      await store.registerAndSelect(profile('one', 'one.example'));
      await store.registerAndSelect(profile('two', 'two.example'));
      expect((await store.select('one')).selectedProfileId, 'one');
      await expectLater(
        store.select('missing'),
        throwsA(isA<PersistenceFailure>()),
      );
      expect((await store.remove('one')).selectedProfileId, 'two');
    },
  );

  test(
    'replaces capability snapshots atomically and reads only unexpired values',
    () async {
      await store.registerAndSelect(profile('one', 'one.example'));
      final observed = DateTime.utc(2026, 1, 1);
      await store.replaceCapabilities(
        profileId: 'one',
        methodNames: const {'core.get_methods', 'system.info'},
        observedAt: observed,
        expiresAt: observed.add(const Duration(hours: 1)),
      );
      expect(await store.readCapabilities('one', observed), {
        'core.get_methods',
        'system.info',
      });
      await expectLater(
        store.replaceCapabilities(
          profileId: 'one',
          methodNames: const {'valid.method', 'bad..method'},
          observedAt: observed,
          expiresAt: observed.add(const Duration(hours: 2)),
        ),
        throwsA(isA<PersistenceFailure>()),
      );
      expect(await store.readCapabilities('one', observed), {
        'core.get_methods',
        'system.info',
      });
      expect(
        await store.readCapabilities(
          'one',
          observed.add(const Duration(hours: 2)),
        ),
        isEmpty,
      );
    },
  );

  test('enforces capability cap and removal cascades capabilities', () async {
    await store.registerAndSelect(profile('one', 'one.example'));
    final methods = <String>{for (var i = 0; i < 4097; i++) 'core.method_$i'};
    await expectLater(
      store.replaceCapabilities(
        profileId: 'one',
        methodNames: methods,
        observedAt: DateTime.utc(2026),
        expiresAt: DateTime.utc(2026, 1, 2),
      ),
      throwsA(isA<PersistenceFailure>()),
    );
    await store.remove('one');
    expect(await store.readCapabilities('one', DateTime.utc(2026)), isEmpty);
  });

  test(
    'fails closed when persisted capabilities exceed the snapshot cap',
    () async {
      await store.registerAndSelect(profile('one', 'one.example'));
      const observedMs = 1767225600000;
      const expiresMs = 1767312000000;
      await database.batch((batch) {
        for (var index = 0; index < 4097; index++) {
          batch.customStatement(
            "INSERT INTO profile_capabilities "
            "(profile_id, method_name, observed_at_ms, expires_at_ms) "
            "VALUES ('one', 'core.method_$index', $observedMs, $expiresMs)",
          );
        }
      });

      await expectLater(
        store.readCapabilities('one', DateTime.utc(2026, 1, 1)),
        throwsA(isA<PersistenceFailure>()),
      );
    },
  );

  test(
    'fails closed instead of silently dropping a corrupt stored profile',
    () async {
      await database.customStatement('PRAGMA ignore_check_constraints = ON');
      await database.customStatement(
        "INSERT INTO server_profiles "
        "(id, display_name, original_host_input, normalized_endpoint, "
        "last_known_version, created_at_ms, updated_at_ms, sort_order) "
        "VALUES ('corrupt', 'Corrupt', 'http://unsafe.example', "
        "'ws://unsafe.example/api/current', '25.10', 1, 1, 0)",
      );

      await expectLater(store.load(), throwsA(isA<PersistenceFailure>()));
    },
  );

  test(
    'reports capability database failures instead of treating them as expiry',
    () async {
      await store.registerAndSelect(profile('one', 'one.example'));
      await database.close();

      await expectLater(
        store.readCapabilities('one', DateTime.utc(2026)),
        throwsA(isA<PersistenceFailure>()),
      );
    },
  );

  test('rolls back replacement when a capability insert fails mid-transaction', () async {
    await store.registerAndSelect(profile('one', 'one.example'));
    final observed = DateTime.utc(2026, 1, 1);
    final expires = observed.add(const Duration(hours: 1));
    await store.replaceCapabilities(
      profileId: 'one',
      methodNames: const {'core.get_methods'},
      observedAt: observed,
      expiresAt: expires,
    );
    await database.customStatement(
      "CREATE TRIGGER reject_system_info BEFORE INSERT ON profile_capabilities "
      "WHEN NEW.method_name = 'system.info' BEGIN SELECT RAISE(ABORT, 'rejected'); END",
    );

    await expectLater(
      store.replaceCapabilities(
        profileId: 'one',
        methodNames: const {'system.info'},
        observedAt: observed,
        expiresAt: expires,
      ),
      throwsA(isA<PersistenceFailure>()),
    );
    expect(await store.readCapabilities('one', observed), {'core.get_methods'});
  });
}
