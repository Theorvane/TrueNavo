// @TestOn('browser')
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:trueraid/features/credentials/secure_credential_vault.dart';
import 'package:trueraid/features/credentials/secure_credential_vault_web.dart'
    as web;
import 'package:trueraid/features/local_persistence/database_connection.dart';

void main() {
  test('web route uses browser-managed storage boundaries', () async {
    expect(kIsWeb, isTrue);
    expect(createSecureCredentialVault(), isA<web.WebSecureCredentialVault>());
    const vault = web.WebSecureCredentialVault();
    expect(await vault.readApiKey('wss://safe.example/api/current'), isNull);
    await expectLater(
      vault.writeApiKey('wss://safe.example/api/current', 'td8-sentinel'),
      throwsA(
        isA<CredentialVaultFailure>().having(
          (failure) => failure.kind,
          'kind',
          CredentialVaultFailureKind.unsupported,
        ),
      ),
    );
    expect(localDatabaseWasmAsset, 'sqlite3.wasm');
    expect(localDatabaseWorkerAsset, 'drift_worker.js');
  }, skip: !kIsWeb);
}
