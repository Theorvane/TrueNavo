import 'package:flutter_test/flutter_test.dart';
import 'package:truenavo/features/local_persistence/database_connection.dart';

void main() {
  test('uses fixed, non-user-derived database asset names', () {
    expect(localDatabaseName, 'truenavo_local_state');
    expect(localDatabaseFileName, 'truenavo_local_state.sqlite');
    expect(localDatabaseWasmAsset, 'sqlite3.wasm');
    expect(localDatabaseWorkerAsset, 'drift_worker.js');
  });
}
