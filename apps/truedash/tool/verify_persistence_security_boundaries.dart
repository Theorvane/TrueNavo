import 'dart:io';

final _productionSources = <String>[
  'lib/features/local_persistence/app_database.dart',
  'lib/features/local_persistence/app_database.g.dart',
  'lib/features/local_persistence/database_connection_web.dart',
  'lib/features/local_persistence/drift_server_profile_store.dart',
  'lib/features/credentials/secure_credential_vault_web.dart',
];

final _forbiddenRuntimePatterns = <RegExp>[
  RegExp(r'\bbadCertificateCallback\b'),
  RegExp(r'\ballowBadCertificates\b'),
  RegExp(r'\btrustAll\b'),
  RegExp(r'\bdebugPrint\s*\('),
  RegExp(r'\bprint\s*\('),
];

final _forbiddenGeneratedFields = <RegExp>[
  RegExp(r'\bapiKey\b'),
  RegExp(r'\bcredential\b', caseSensitive: false),
  RegExp(r'\bpassword\b', caseSensitive: false),
  RegExp(r'\bauthHeader\b'),
  RegExp(r'\bcertificate\b', caseSensitive: false),
  RegExp(r'\bfingerprint\b', caseSensitive: false),
];

void _verifyNoMatches(String path, String source, Iterable<RegExp> patterns) {
  for (final pattern in patterns) {
    if (pattern.hasMatch(source)) {
      throw StateError('Persistence security boundary violation in $path.');
    }
  }
}

Future<void> main() async {
  for (final path in _productionSources) {
    final source = await File(path).readAsString();
    _verifyNoMatches(path, source, _forbiddenRuntimePatterns);
  }

  final generated = await File(
    'lib/features/local_persistence/app_database.g.dart',
  ).readAsString();
  _verifyNoMatches(
    'lib/features/local_persistence/app_database.g.dart',
    generated,
    _forbiddenGeneratedFields,
  );

  final webConnection = await File(
    'lib/features/local_persistence/database_connection_web.dart',
  ).readAsString();
  for (final required in const [
    'DriftWebOptions',
    'sqlite3Wasm',
    'driftWorker',
  ]) {
    if (!webConnection.contains(required)) {
      throw StateError('Drift Web connection is not configured.');
    }
  }
  if (webConnection.contains('dart:io')) {
    throw StateError('Drift Web connection imports an IO-only library.');
  }

  final webVault = await File(
    'lib/features/credentials/secure_credential_vault_web.dart',
  ).readAsString();
  for (final forbidden in const ['flutter_secure_storage', 'tls_trust']) {
    if (webVault.contains(forbidden)) {
      throw StateError('Web credential vault boundary violation.');
    }
  }
}
