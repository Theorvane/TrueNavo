import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/local_persistence/app_database.dart';
import 'package:truedash/features/local_persistence/drift_server_profile_store.dart';
import 'package:truedash/features/local_persistence/persistence_failure.dart';
import 'package:truedash/features/server_profiles/server_profile.dart';

void main() {
  late AppDatabase database;
  late DriftServerProfileStore store;

  ServerProfile profile(String id, String host) => ServerProfile(
    id: id,
    displayName: host,
    originalHostInput: 'https://$host',
    normalizedEndpoint: 'wss://$host/api/current',
    lastKnownVersion: '25.10',
  );

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    store = DriftServerProfileStore(database, clock: () => DateTime.utc(2026));
  });
  tearDown(() => store.close());

  test(
    'registers in stable order, restores, and resolves endpoint collisions',
    () async {
      await store.registerAndSelect(profile('one', 'one.example'));
      await store.registerAndSelect(profile('two', 'two.example'));
      final duplicate = await store.registerAndSelect(
        profile('different', 'one.example'),
      );

      expect(duplicate.profiles.map((item) => item.id), ['one', 'two']);
      expect(duplicate.selectedProfileId, 'one');
    },
  );

  test('rejects id collisions and invalid profile endpoints without unsafe details', () async {
    await store.registerAndSelect(profile('one', 'one.example'));
    await expectLater(
      store.registerAndSelect(profile('one', 'two.example')),
      throwsA(isA<PersistenceFailure>()),
    );
    await expectLater(
      store.registerAndSelect(profile('bad', 'http://bad.example')),
      throwsA(isA<PersistenceFailure>()),
    );
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
