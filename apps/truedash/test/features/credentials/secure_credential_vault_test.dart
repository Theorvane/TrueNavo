import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:truedash/features/connection/connection_controller.dart';
import 'package:truedash/features/credentials/secure_credential_vault.dart';
import 'package:truedash/features/credentials/secure_credential_vault_io.dart';
import 'package:truedash/features/credentials/secure_credential_vault_web.dart';

const _apiKey = 'TEST_API_KEY_SENTINEL';

void main() {
  const endpoint = 'https://vault-unit.example:8443';
  const apiKey = _apiKey;

  group('NativeSecureCredentialVault', () {
    test('delegates read, write, and delete using only hashed keys', () async {
      final port = _Port();
      final vault = NativeSecureCredentialVault(storage: port);

      expect(await vault.readApiKey(endpoint), apiKey);
      await vault.writeApiKey(endpoint, apiKey);
      await vault.deleteApiKey(endpoint);

      expect(port.operations, hasLength(4));
      for (final operation in port.operations) {
        expect(
          operation.key,
          matches(RegExp(r'^com\.truedash\.api-key\.v1\.[a-f0-9]{64}$')),
        );
        expect(operation.key, isNot(contains('vault-unit.example')));
      }
      expect(
        port.operations
            .singleWhere((operation) => operation.value != null)
            .value,
        apiKey,
      );
      for (final options in port.options) {
        expect(options.androidResetOnError, isFalse);
        expect(options.androidNamespace, 'com.truedash.truedash.api-key');
        expect(options.appleSynchronizable, isFalse);
        expect(options.appleThisDeviceUnlocked, isTrue);
        expect(options.macOsDataProtectionKeychain, isTrue);
      }
    });

    test(
      'maps storage failures without exposing raw detail or key material',
      () async {
        final vault = NativeSecureCredentialVault(storage: _Port(fail: true));

        await _expectContainedFailure(vault.readApiKey(endpoint));
        await _expectContainedFailure(vault.writeApiKey(endpoint, apiKey));
        await _expectContainedFailure(vault.deleteApiKey(endpoint));
      },
    );

    test(
      'fails closed for malformed values returned by secure storage',
      () async {
        for (final storedValue in ['', 'x' * 16385]) {
          final vault = NativeSecureCredentialVault(
            storage: _Port(readValue: storedValue),
          );
          await expectLater(
            vault.readApiKey(endpoint),
            throwsA(
              isA<CredentialVaultFailure>().having(
                (failure) => failure.kind,
                'kind',
                CredentialVaultFailureKind.unavailable,
              ),
            ),
          );
        }
      },
    );

    test(
      'rejects empty or oversized API keys before calling storage',
      () async {
        final port = _Port();
        final vault = NativeSecureCredentialVault(storage: port);

        await expectLater(
          vault.writeApiKey(endpoint, ''),
          throwsA(isA<CredentialVaultFailure>()),
        );
        await expectLater(
          vault.writeApiKey(endpoint, 'x' * 16385),
          throwsA(isA<CredentialVaultFailure>()),
        );
        expect(port.operations, isEmpty);
      },
    );

    test(
      'restores a stale write and serializes a later current write',
      () async {
        final port = _BlockingWritePort(initialValue: 'prior-key');
        final vault = NativeSecureCredentialVault(storage: port);
        var staleCurrent = true;

        final stale = vault.writeApiKey(
          endpoint,
          'stale-key',
          isCurrent: () => staleCurrent,
        );
        await port.firstWriteStarted.future;
        staleCurrent = false;
        final current = vault.writeApiKey(
          endpoint,
          'current-key',
          isCurrent: () => true,
        );
        port.releaseFirstWrite();

        await expectLater(
          stale,
          throwsA(isA<CredentialWriteCancelledException>()),
        );
        await current;
        expect(port.value, 'current-key');
      },
    );
  });

  test('WebSecureCredentialVault never persists API keys', () async {
    const vault = WebSecureCredentialVault();

    expect(await vault.readApiKey(endpoint), isNull);
    await expectLater(
      vault.writeApiKey(endpoint, apiKey),
      throwsA(isA<CredentialVaultFailure>()),
    );
    await vault.deleteApiKey(endpoint);
  });

  test('production provider selects the conditional platform vault', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    final vault = container.read(credentialVaultProvider);
    expect(vault, isNot(isA<NoopCredentialVault>()));
    expect(
      vault,
      kIsWeb
          ? isA<WebSecureCredentialVault>()
          : isA<NativeSecureCredentialVault>(),
    );
  });
}

final class _Port implements SecureCredentialStoragePort {
  _Port({this.fail = false, this.readValue = _apiKey});
  final bool fail;
  final String? readValue;
  final options = <SecureCredentialStorageOptions>[];
  final operations = <_Operation>[];

  @override
  Future<void> delete({
    required String key,
    required SecureCredentialStorageOptions options,
  }) async {
    this.options.add(options);
    if (fail) throw StateError('private/path and TEST_API_KEY_SENTINEL');
    operations.add(_Operation(key));
  }

  @override
  Future<String?> read({
    required String key,
    required SecureCredentialStorageOptions options,
  }) async {
    this.options.add(options);
    if (fail) throw StateError('private/path and TEST_API_KEY_SENTINEL');
    operations.add(_Operation(key));
    return readValue;
  }

  @override
  Future<void> write({
    required String key,
    required String value,
    required SecureCredentialStorageOptions options,
  }) async {
    this.options.add(options);
    if (fail) throw StateError('private/path and TEST_API_KEY_SENTINEL');
    operations.add(_Operation(key, value));
  }
}

final class _Operation {
  const _Operation(this.key, [this.value]);
  final String key;
  final String? value;
}

final class _BlockingWritePort implements SecureCredentialStoragePort {
  _BlockingWritePort({this.initialValue});

  final String? initialValue;
  String? value;
  var _writeCount = 0;
  final firstWriteStarted = Completer<void>();
  final _firstWriteGate = Completer<void>();

  void releaseFirstWrite() => _firstWriteGate.complete();

  @override
  Future<void> delete({
    required String key,
    required SecureCredentialStorageOptions options,
  }) async {
    value = null;
  }

  @override
  Future<String?> read({
    required String key,
    required SecureCredentialStorageOptions options,
  }) async => value ?? initialValue;

  @override
  Future<void> write({
    required String key,
    required String value,
    required SecureCredentialStorageOptions options,
  }) async {
    if (_writeCount++ == 0) {
      firstWriteStarted.complete();
      await _firstWriteGate.future;
    }
    this.value = value;
  }
}

Future<void> _expectContainedFailure(Future<Object?> operation) async {
  try {
    await operation;
    fail('Expected a credential-free storage failure.');
  } on CredentialVaultFailure catch (error) {
    expect(error.toString(), isNot(contains(_apiKey)));
    expect(error.toString(), isNot(contains('private/path')));
  }
}
