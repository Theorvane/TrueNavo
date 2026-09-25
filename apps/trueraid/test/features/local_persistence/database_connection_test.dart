import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/local_persistence/database_connection.dart';

void main() {
  test('uses fixed, non-user-derived database asset names', () {
    expect(localDatabaseName, 'trueraid_local_state');
    expect(localDatabaseFileName, 'trueraid_local_state.sqlite');
    expect(localDatabaseWasmAsset, 'sqlite3.wasm');
    expect(localDatabaseWorkerAsset, 'drift_worker.js');
  });
}
