import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/local_persistence/app_database.dart';

void main() {
  late AppDatabase database;

  setUp(() => database = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => database.close());

  test('creates version-one tables and endpoint/sort constraints', () async {
    expect(database.schemaVersion, 1);
    await database
        .into(database.serverProfiles)
        .insert(
          ServerProfilesCompanion.insert(
            id: 'profile-1',
            displayName: 'NAS',
            originalHostInput: 'https://nas.example',
            normalizedEndpoint: 'wss://nas.example/api/current',
            lastKnownVersion: '25.10',
            createdAtMs: 1,
            updatedAtMs: 1,
            sortOrder: 0,
          ),
        );

    await expectLater(
      database
          .into(database.serverProfiles)
          .insert(
            ServerProfilesCompanion.insert(
              id: 'profile-2',
              displayName: 'Other',
              originalHostInput: 'https://other.example',
              normalizedEndpoint: 'wss://nas.example/api/current',
              lastKnownVersion: '25.10',
              createdAtMs: 2,
              updatedAtMs: 2,
              sortOrder: 1,
            ),
          ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      database.customStatement(
        "INSERT INTO server_profiles VALUES ('bad', 'Bad', 'https://bad.example', 'wss://bad.example/api/current', '1', 1, 1, -1)",
      ),
      throwsA(isA<Exception>()),
    );
  });

  test('enforces singleton selection and foreign-key actions', () async {
    await database
        .into(database.serverProfiles)
        .insert(
          ServerProfilesCompanion.insert(
            id: 'profile-1',
            displayName: 'NAS',
            originalHostInput: 'https://nas.example',
            normalizedEndpoint: 'wss://nas.example/api/current',
            lastKnownVersion: '25.10',
            createdAtMs: 1,
            updatedAtMs: 1,
            sortOrder: 0,
          ),
        );
    await database
        .into(database.appSelection)
        .insert(
          AppSelectionCompanion.insert(
            singletonId: const Value(1),
            selectedProfileId: const Value('profile-1'),
          ),
        );
    await expectLater(
      database
          .into(database.appSelection)
          .insert(AppSelectionCompanion.insert(singletonId: const Value(2))),
      throwsA(isA<Exception>()),
    );
    await database
        .into(database.profileCapabilities)
        .insert(
          ProfileCapabilitiesCompanion.insert(
            profileId: 'profile-1',
            methodName: 'core.get_methods',
            observedAtMs: 10,
            expiresAtMs: 11,
          ),
        );
    await (database.delete(
      database.serverProfiles,
    )..where((row) => row.id.equals('profile-1'))).go();

    expect(
      (await database.select(database.appSelection).getSingle())
          .selectedProfileId,
      isNull,
    );
    expect(await database.select(database.profileCapabilities).get(), isEmpty);
  });

  test('enforces method grammar, expiry ordering, and expiry index', () async {
    final indexes = await database
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'profile_capabilities'",
        )
        .get();
    expect(
      indexes.map((row) => row.read<String>('name')),
      contains('profile_capabilities_expiry_idx'),
    );
    await database
        .into(database.serverProfiles)
        .insert(
          ServerProfilesCompanion.insert(
            id: 'profile-1',
            displayName: 'NAS',
            originalHostInput: 'https://nas.example',
            normalizedEndpoint: 'wss://nas.example/api/current',
            lastKnownVersion: '25.10',
            createdAtMs: 1,
            updatedAtMs: 1,
            sortOrder: 0,
          ),
        );
    await expectLater(
      database.customStatement(
        "INSERT INTO profile_capabilities VALUES ('profile-1', 'bad..name', 1, 2)",
      ),
      throwsA(isA<Exception>()),
    );
    await expectLater(
      database.customStatement(
        "INSERT INTO profile_capabilities VALUES ('profile-1', 'valid.name', 2, 2)",
      ),
      throwsA(isA<Exception>()),
    );
  });
}
