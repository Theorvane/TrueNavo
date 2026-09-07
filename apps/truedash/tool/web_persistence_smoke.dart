import 'package:truedash/features/local_persistence/app_database.dart';
import 'package:truedash/features/local_persistence/database_connection.dart';
import 'package:web/web.dart' as web;

const _successMarker = 'TRUEDASH_WEB_PERSISTENCE_OK';
const _failureMarker = 'TRUEDASH_WEB_PERSISTENCE_FAILED';

Future<void> main() async {
  web.document.title = 'TRUEDASH_WEB_PERSISTENCE_START';
  var marker = _failureMarker;
  final database = AppDatabase(openLocalDatabase());
  try {
    final probe = await database.customSelect('SELECT 1 AS value').getSingle();
    await database.customStatement(
      "INSERT OR REPLACE INTO server_profiles "
      "(id, display_name, original_host_input, normalized_endpoint, "
      "last_known_version, created_at_ms, updated_at_ms, sort_order) "
      "VALUES ('web-smoke-id', 'web.smoke.example', "
      "'https://web.smoke.example', "
      "'wss://web.smoke.example/api/current', '25.10', 1, 1, 0)",
    );
    final row = await database
        .customSelect(
          "SELECT normalized_endpoint FROM server_profiles "
          "WHERE id = 'web-smoke-id'",
        )
        .getSingle();
    if (probe.read<int>('value') == 1 &&
        row.read<String>('normalized_endpoint') ==
            'wss://web.smoke.example/api/current') {
      marker = _successMarker;
    }
  } on Object {
    marker = _failureMarker;
  } finally {
    try {
      await database.close();
    } on Object {
      marker = _failureMarker;
    }
  }
  web.document.title = marker;
  web.document.body?.textContent = marker;
}
