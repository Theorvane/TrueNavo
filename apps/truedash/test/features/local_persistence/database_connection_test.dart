import 'package:flutter_test/flutter_test.dart';
import 'package:truedash/features/local_persistence/database_connection.dart';

void main() {
  test('uses fixed, non-user-derived database asset names', () {
    expect(localDatabaseName, 'truedash_local_state');
    expect(localDatabaseFileName, 'truedash_local_state.sqlite');
    expect(localDatabaseWasmAsset, 'sqlite3.wasm');
    expect(localDatabaseWorkerAsset, 'drift_worker.js');
  });
}
