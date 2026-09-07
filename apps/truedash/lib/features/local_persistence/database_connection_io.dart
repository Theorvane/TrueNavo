import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';

import 'database_connection_constants.dart';

DatabaseConnection openLocalDatabase() => driftDatabase(name: localDatabaseName);
