import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:truenas_api/truenas_api.dart';
import 'package:trueraid/features/connection/connection_controller.dart';
import 'package:trueraid/features/credentials/secure_credential_vault.dart';
import 'package:trueraid/features/credentials/secure_credential_vault_io.dart';
import 'package:trueraid/features/credentials/secure_credential_vault_web.dart';

const _apiKey = 'TEST_API_KEY_SENTINEL';

void main() {
  const endpoint = 'https://vault-unit.example:8443';
  const apiKey = _apiKey;

  group('NativeSecureCredentialVault', () {
    test('treats a successful vault write as the repository credential commit point', () async {
      final port = _StatefulPort(initialValue: 'prior-key');
      final transport = _RespondingTransport();
      final repository = TrueNasSessionRepository(
        connector: _SingleTransportConnector(transport),
        credentialVault: NativeSecureCredentialVault(storage: port),
      );
      var vaultPostWriteCheckObserved = false;

      final connecting = repository.connect(
        serverInput: 'https://vault-unit.example:8443',
        apiKey: 'replacement-key',
        username: 'test-account',
        rememberApiKey: true,
        isConnectionCurrent: () {
          if (!port.hasWritten) return true;
          if (!vaultPostWriteCheckObserved) {
            vaultPostWriteCheckObserved = true;
            return true;
          }
          return false;
        },
      );
      await _respondHandshake(transport);

      final summary = await connecting;

      expect(summary.identity, 'admin');
      expect(vaultPostWriteCheckObserved, isTrue);
      expect(port.value, 'replacement-key');
      expect(transport.closeCalls, 0);
      await repository.close();
      expect(transport.closeCalls, 1);
    });

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
          matches(RegExp(r'^com\.trueraid\.api-key\.v1\.[a-f0-9]{64}$')),
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
        expect(options.androidNamespace, 'com.trueraid.trueraid.api-key');
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

    test('contains a throwing post-write callback, restores, and releases the lease', () async {
      final port = _BlockingWritePort(initialValue: 'prior-key');
      final vault = NativeSecureCredentialVault(storage: port);

      final stale = vault.writeApiKey(
        endpoint,
        'stale-key',
        isCurrent: () {
          if (port.writeValues.isNotEmpty) {
            throw StateError('callback TEST_API_KEY_SENTINEL');
          }
          return true;
        },
      );
      await port.firstWriteStarted.future;
      final current = vault.writeApiKey(endpoint, 'current-key');
      port.releaseFirstWrite();

      await _expectContainedFailure(stale);
      await current;
      expect(port.value, 'current-key');
      expect(port.writeValues, ['stale-key', 'prior-key', 'current-key']);
    });

    test(
      'contains a throwing pre-write callback without mutating storage',
      () async {
        final port = _BlockingWritePort(initialValue: 'prior-key');
        final vault = NativeSecureCredentialVault(storage: port);

        await expectLater(
          vault.writeApiKey(
            endpoint,
            'stale-key',
            isCurrent: () => throw StateError('callback TEST_API_KEY_SENTINEL'),
          ),
          throwsA(
            isA<CredentialWriteCancelledException>().having(
              (error) => error.toString(),
              'safe text',
              isNot(contains('TEST_API_KEY_SENTINEL')),
            ),
          ),
        );

        expect(port.value, isNull);
        expect(port.writeValues, isEmpty);
        expect(port.deleteCalls, 0);
      },
    );

    test(
      'deletes a newly written key when its post-write callback throws',
      () async {
        final port = _BlockingWritePort();
        final vault = NativeSecureCredentialVault(storage: port);

        final write = vault.writeApiKey(
          endpoint,
          'stale-key',
          isCurrent: () {
            if (port.writeValues.isNotEmpty) {
              throw StateError('callback TEST_API_KEY_SENTINEL');
            }
            return true;
          },
        );
        await port.firstWriteStarted.future;
        port.releaseFirstWrite();

        await _expectContainedFailure(write);
        expect(port.value, isNull);
        expect(port.deleteCalls, 1);
      },
    );

    for (final initialValue in ['prior-key', null]) {
      test(
        'compensates a post-write cancellation with ${initialValue ?? 'no prior key'}',
        () async {
          final port = _StatefulPort(initialValue: initialValue);
          final vault = NativeSecureCredentialVault(storage: port);

          await expectLater(
            vault.writeApiKey(
              endpoint,
              'replacement-key',
              isCurrent: () => !port.hasWritten,
            ),
            throwsA(isA<CredentialWriteCancelledException>()),
          );

          expect(port.value, initialValue);
        },
      );
    }

    test('contains a compensation failure after a throwing callback', () async {
      final port = _FailingRollbackPort();
      final vault = NativeSecureCredentialVault(storage: port);

      await _expectContainedFailure(
        vault.writeApiKey(
          endpoint,
          'stale-key',
          isCurrent: () {
            if (port.hasWritten) {
              throw StateError('callback TEST_API_KEY_SENTINEL');
            }
            return true;
          },
        ),
      );
    });
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
  var deleteCalls = 0;
  final writeValues = <String>[];
  final firstWriteStarted = Completer<void>();
  final _firstWriteGate = Completer<void>();

  void releaseFirstWrite() => _firstWriteGate.complete();

  @override
  Future<void> delete({
    required String key,
    required SecureCredentialStorageOptions options,
  }) async {
    deleteCalls++;
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
    writeValues.add(value);
    if (_writeCount++ == 0) {
      firstWriteStarted.complete();
      await _firstWriteGate.future;
    }
    this.value = value;
  }
}

final class _FailingRollbackPort implements SecureCredentialStoragePort {
  var _writes = 0;
  var hasWritten = false;

  @override
  Future<void> delete({
    required String key,
    required SecureCredentialStorageOptions options,
  }) async => throw StateError('rollback TEST_API_KEY_SENTINEL');

  @override
  Future<String?> read({
    required String key,
    required SecureCredentialStorageOptions options,
  }) async => 'prior-key';

  @override
  Future<void> write({
    required String key,
    required String value,
    required SecureCredentialStorageOptions options,
  }) async {
    hasWritten = true;
    if (_writes++ > 0) throw StateError('rollback TEST_API_KEY_SENTINEL');
  }
}

final class _StatefulPort implements SecureCredentialStoragePort {
  _StatefulPort({String? initialValue}) : value = initialValue;

  String? value;
  var hasWritten = false;

  @override
  Future<void> delete({
    required String key,
    required SecureCredentialStorageOptions options,
  }) async => value = null;

  @override
  Future<String?> read({
    required String key,
    required SecureCredentialStorageOptions options,
  }) async => value;

  @override
  Future<void> write({
    required String key,
    required String value,
    required SecureCredentialStorageOptions options,
  }) async {
    this.value = value;
    hasWritten = true;
  }
}

final class _SingleTransportConnector implements RpcConnector {
  const _SingleTransportConnector(this.transport);

  final RpcTransport transport;

  @override
  Future<RpcTransport> connect(Uri endpoint) async => transport;
}

final class _RespondingTransport implements RpcTransport {
  final _inbound = StreamController<String>();
  final sentFrames = <String>[];
  var closeCalls = 0;

  @override
  Stream<String> get inboundFrames => _inbound.stream;

  @override
  Future<void> send(String frame) async => sentFrames.add(frame);

  void add(String frame) => _inbound.add(frame);

  @override
  Future<void> close() async {
    closeCalls++;
    await _inbound.close();
  }
}

Future<void> _respondHandshake(_RespondingTransport transport) async {
  for (final result in [
    {'state': 'SUCCESS'},
    {'username': 'admin'},
    {'version': '25.10'},
    {'a': {}},
  ]) {
    while (transport.sentFrames.isEmpty) {
      await Future<void>.delayed(Duration.zero);
    }
    final id = jsonDecode(transport.sentFrames.removeAt(0))['id'];
    transport.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  }
}

Future<void> _expectContainedFailure(Future<Object?> operation) async {
  try {
    await operation;
    fail('Expected a credential-free storage failure.');
  } on Object catch (error) {
    expect(
      error,
      anyOf(
        isA<CredentialVaultFailure>(),
        isA<CredentialWriteCancelledException>(),
      ),
    );
    expect(error.toString(), isNot(contains(_apiKey)));
    expect(error.toString(), isNot(contains('private/path')));
  }
}
