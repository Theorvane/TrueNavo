import 'package:drift/drift.dart';

part 'app_database.g.dart';

@DataClassName('StoredServerProfile')
class ServerProfiles extends Table {
  @override
  String get tableName => 'server_profiles';

  TextColumn get id => text().customConstraint(
    'NOT NULL CHECK (length(id) BETWEEN 1 AND 128)',
  )();
  TextColumn get displayName => text()
      .named('display_name')
      .customConstraint(
        'NOT NULL CHECK (length(display_name) BETWEEN 1 AND 256)',
      )();
  TextColumn get originalHostInput => text()
      .named('original_host_input')
      .customConstraint(
        'NOT NULL CHECK (length(original_host_input) BETWEEN 1 AND 2048)',
      )();
  TextColumn get normalizedEndpoint => text()
      .named('normalized_endpoint')
      .customConstraint(
        'NOT NULL UNIQUE CHECK (length(normalized_endpoint) BETWEEN 1 AND 2048)',
      )();
  TextColumn get lastKnownVersion => text()
      .named('last_known_version')
      .customConstraint(
        'NOT NULL CHECK (length(last_known_version) BETWEEN 1 AND 128)',
      )();
  IntColumn get createdAtMs => integer().named('created_at_ms')();
  IntColumn get updatedAtMs => integer().named('updated_at_ms')();
  IntColumn get sortOrder => integer()
      .named('sort_order')
      .customConstraint('NOT NULL UNIQUE CHECK (sort_order >= 0)')();

  @override
  Set<Column<Object>> get primaryKey => {id};
}

class AppSelection extends Table {
  @override
  String get tableName => 'app_selection';

  IntColumn get singletonId => integer()
      .named('singleton_id')
      .customConstraint('NOT NULL CHECK (singleton_id = 1)')();
  TextColumn get selectedProfileId => text()
      .named('selected_profile_id')
      .nullable()
      .references(ServerProfiles, #id, onDelete: KeyAction.setNull)();

  @override
  Set<Column<Object>> get primaryKey => {singletonId};
}

@TableIndex(
  name: 'profile_capabilities_expiry_idx',
  columns: {#profileId, #expiresAtMs},
)
class ProfileCapabilities extends Table {
  @override
  String get tableName => 'profile_capabilities';

  TextColumn get profileId => text()
      .named('profile_id')
      .references(ServerProfiles, #id, onDelete: KeyAction.cascade)();
  TextColumn get methodName => text()
      .named('method_name')
      .customConstraint(
        "NOT NULL CHECK (length(method_name) BETWEEN 1 AND 255 AND method_name NOT GLOB '*[^A-Za-z0-9_.]*' AND method_name NOT GLOB '.*' AND method_name NOT GLOB '*.' AND method_name NOT GLOB '*..*')",
      )();
  IntColumn get observedAtMs => integer().named('observed_at_ms')();
  IntColumn get expiresAtMs => integer()
      .named('expires_at_ms')
      .customConstraint('NOT NULL CHECK (expires_at_ms > observed_at_ms)')();

  @override
  Set<Column<Object>> get primaryKey => {profileId, methodName};
}

@DriftDatabase(tables: [ServerProfiles, AppSelection, ProfileCapabilities])
class AppDatabase extends _$AppDatabase {
  AppDatabase(super.executor);

  AppDatabase.forTesting(super.executor);

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await migrator.createAll();
    },
    beforeOpen: (details) async {
      await customStatement('PRAGMA foreign_keys = ON');
    },
  );
}
