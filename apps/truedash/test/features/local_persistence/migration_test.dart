import 'package:drift_dev/api/migrations_native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/local_persistence/app_database.dart';

import '../../drift/generated/schema.dart';

void main() {
  test('committed schema v1 opens and migrates to AppDatabase', () async {
    final verifier = SchemaVerifier(GeneratedHelper());
    final connection = await verifier.startAt(1);
    final database = AppDatabase.forTesting(connection);

    await verifier.migrateAndValidate(
      database,
      1,
      options: const ValidationOptions(validateDropped: true),
    );
    await database.close();
  });
}
