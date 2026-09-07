import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/local_persistence/app_database.dart';

void main() {
  test(
    'version one creation migration creates all local-state tables',
    () async {
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(database.close);

      final tables = await database
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name",
          )
          .get();

      expect(
        tables.map((row) => row.read<String>('name')),
        containsAll(<String>[
          'app_selection',
          'profile_capabilities',
          'server_profiles',
        ]),
      );
    },
  );
}
