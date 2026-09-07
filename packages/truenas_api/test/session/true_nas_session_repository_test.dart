import 'dart:async';
import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

import '../support/in_memory_transport.dart';

const sentinel = 'test-api-key';

void main() {
  test('handshakes with API_KEY_PLAIN and safely maps a summary', () async {
    final transport = InMemoryTransport();
    final repository = TrueNasSessionRepository(
      connector: FakeConnector(transport),
    );
    final future = repository.connect(
      serverInput: ' https://nas.example ',
      apiKey: sentinel,
    );
    await _respondHandshake(transport);
    final summary = await future;
    expect(summary.originalHostInput, ' https://nas.example ');
    expect(summary.endpointUri.toString(), 'wss://nas.example/api/current');
    expect(summary.identity, 'admin');
    expect(summary.version, '25.10');
    expect(summary.availableMethodNames, {'a', 'b'});
    expect(transport.sentFrames.first, contains('API_KEY_PLAIN'));
    expect(jsonDecode(transport.sentFrames.first)['params'], [
      {'mechanism': 'API_KEY_PLAIN', 'api_key': sentinel},
    ]);
    expect(summary.toString(), isNot(contains(sentinel)));
    await repository.close();
    expect(transport.closeCalls, 1);
  });

  for (final state in ['OTP_REQUIRED', 'AUTH_ERR', 'EXPIRED', 'REDIRECT']) {
    test('$state stops without follow-up calls or secret leakage', () async {
      final transport = InMemoryTransport();
      final repository = TrueNasSessionRepository(
        connector: FakeConnector(transport),
      );
      final future = repository.connect(
        serverInput: 'wss://nas.example',
        apiKey: sentinel,
      );
      await _waitForSend(transport, 1);
      final id = jsonDecode(transport.sentFrames.single)['id'];
      transport.add(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': id,
          'result': {'state': state},
        }),
      );
      await expectLater(future, throwsA(isA<AuthenticationStateException>()));
      expect(transport.sentFrames, hasLength(1));
    });
  }

  test('maps a TLS validation failure without bypassing it', () async {
    final repository = TrueNasSessionRepository(
      connector: FakeConnector(
        InMemoryTransport(),
        error: const TlsHandshakeException(),
      ),
    );
    await expectLater(
      repository.connect(serverInput: 'wss://nas.example', apiKey: sentinel),
      throwsA(isA<TlsCertificateException>()),
    );
  });

  test(
    'authentication failure closes the failed session and clears it',
    () async {
      final transport = InMemoryTransport();
      final repository = TrueNasSessionRepository(
        connector: FakeConnector(transport),
      );
      final future = repository.connect(
        serverInput: 'wss://nas.example',
        apiKey: sentinel,
      );
      await _respondWith(transport, {'state': 'AUTH_ERR'});
      await expectLater(future, throwsA(isA<AuthenticationStateException>()));
      expect(transport.closeCalls, 1);
      await repository.close();
      expect(transport.closeCalls, 1);
    },
  );

  test(
    'protocol failure closes the failed session and preserves the error',
    () async {
      final transport = InMemoryTransport();
      final repository = TrueNasSessionRepository(
        connector: FakeConnector(transport),
      );
      final future = repository.connect(
        serverInput: 'wss://nas.example',
        apiKey: sentinel,
      );
      await _waitForSend(transport, 1);
      transport.add('{"jsonrpc":"2.0","id":null,"result":true}');
      await expectLater(future, throwsA(isA<JsonRpcProtocolException>()));
      expect(transport.closeCalls, 1);
      await repository.close();
      expect(transport.closeCalls, 1);
    },
  );

  test(
    'TLS failure from a created transport closes the failed session',
    () async {
      final transport = InMemoryTransport();
      final repository = TrueNasSessionRepository(
        connector: FakeConnector(transport),
      );
      final future = repository.connect(
        serverInput: 'wss://nas.example',
        apiKey: sentinel,
      );
      await _waitForSend(transport, 1);
      await transport.fail(const TlsHandshakeException());
      await expectLater(future, throwsA(isA<TlsCertificateException>()));
      expect(transport.closeCalls, 1);
      await repository.close();
      expect(transport.closeCalls, 1);
    },
  );

  test('missing optional summary fields remain safe', () async {
    final transport = InMemoryTransport();
    final repository = TrueNasSessionRepository(
      connector: FakeConnector(transport),
    );
    final future = repository.connect(
      serverInput: 'wss://nas.example',
      apiKey: sentinel,
    );
    await _respondWith(transport, {'state': 'SUCCESS'});
    await _respondWith(transport, {});
    await _respondWith(transport, {});
    await _respondWith(transport, {});
    final summary = await future;
    expect(summary.identity, 'unknown');
    expect(summary.version, 'unknown');
    expect(summary.availableMethodNames, isEmpty);
  });

  test(
    'reads a remembered key only after the validated connector succeeds',
    () async {
      final events = <String>[];
      final transport = InMemoryTransport();
      final vault = _RecordingVault(
        events,
        rememberedKey: 'remembered-test-key',
      );
      final repository = TrueNasSessionRepository(
        connector: _RecordingConnector(transport, events),
        credentialVault: vault,
      );

      final future = repository.connect(
        serverInput: ' https://NAS.example/ ',
        apiKey: null,
        rememberApiKey: false,
      );
      await _respondHandshake(transport);
      await future;

      expect(events, ['connector', 'read:wss://nas.example/api/current']);
      expect(transport.sentFrames.first, contains('auth.login_ex'));
      expect(vault.writes, isEmpty);
    },
  );

  test(
    'explicit key wins, writes after summary completion, and never leaks',
    () async {
      final events = <String>[];
      final transport = InMemoryTransport();
      final vault = _RecordingVault(
        events,
        rememberedKey: 'remembered-test-key',
      );
      final repository = TrueNasSessionRepository(
        connector: _RecordingConnector(transport, events),
        credentialVault: vault,
      );

      final future = repository.connect(
        serverInput: 'https://nas.example',
        apiKey: 'explicit-test-key',
        rememberApiKey: true,
      );
      await _respondHandshake(transport);
      final summary = await future;

      expect(events, ['connector', 'write:wss://nas.example/api/current']);
      expect(vault.writes, [
        ('wss://nas.example/api/current', 'explicit-test-key'),
      ]);
      expect(summary.toString(), isNot(contains('explicit-test-key')));
    },
  );

  test(
    'missing or unreadable remembered credentials fail safely before auth',
    () async {
      final missingTransport = InMemoryTransport();
      final missing = TrueNasSessionRepository(
        connector: FakeConnector(missingTransport),
        credentialVault: const NoopCredentialVault(),
      );
      await expectLater(
        missing.connect(
          serverInput: 'https://nas.example',
          apiKey: '',
          rememberApiKey: false,
        ),
        throwsA(isA<CredentialUnavailableException>()),
      );
      expect(missingTransport.sentFrames, isEmpty);
      expect(missingTransport.closeCalls, 1);

      final unreadableTransport = InMemoryTransport();
      final unreadable = TrueNasSessionRepository(
        connector: FakeConnector(unreadableTransport),
        credentialVault: _RecordingVault(<String>[], failRead: true),
      );
      await expectLater(
        unreadable.connect(
          serverInput: 'https://nas.example',
          apiKey: null,
          rememberApiKey: false,
        ),
        throwsA(isA<CredentialUnavailableException>()),
      );
      expect(unreadableTransport.sentFrames, isEmpty);
      expect(unreadableTransport.closeCalls, 1);
    },
  );

  test('never touches the vault when connector verification fails', () async {
    final events = <String>[];
    final repository = TrueNasSessionRepository(
      connector: FakeConnector(
        InMemoryTransport(),
        error: const TlsHandshakeException(),
      ),
      credentialVault: _RecordingVault(
        events,
        rememberedKey: 'remembered-test-key',
      ),
    );

    await expectLater(
      repository.connect(
        serverInput: 'https://nas.example',
        apiKey: null,
        rememberApiKey: true,
      ),
      throwsA(isA<TlsCertificateException>()),
    );
    expect(events, isEmpty);
  });

  test(
    'client factory failure closes the verified transport before vault access',
    () async {
      final events = <String>[];
      final transport = InMemoryTransport();
      final subscription = transport.inboundFrames.listen((_) {});
      addTearDown(subscription.cancel);
      final repository = TrueNasSessionRepository(
        connector: FakeConnector(transport),
        credentialVault: _RecordingVault(
          events,
          rememberedKey: 'remembered-test-key',
        ),
        clientFactory: (_) => throw StateError('client factory detail'),
      );

      await expectLater(
        repository.connect(
          serverInput: 'https://nas.example',
          apiKey: null,
          rememberApiKey: true,
        ),
        throwsA(isA<StateError>()),
      );

      expect(events, isEmpty);
      expect(transport.closeCalls, 1);
    },
  );

  test(
    'never writes after authentication, RPC, or cancellation failure',
    () async {
      for (final failure in ['auth', 'rpc', 'cancelled']) {
        final transport = InMemoryTransport();
        final vault = _RecordingVault(<String>[]);
        final current = failure != 'cancelled';
        final repository = TrueNasSessionRepository(
          connector: FakeConnector(transport),
          credentialVault: vault,
        );
        final future = repository.connect(
          serverInput: 'https://nas.example',
          apiKey: 'explicit-test-key',
          rememberApiKey: true,
          isConnectionCurrent: () => current,
        );
        if (failure == 'cancelled') {
          await expectLater(
            future,
            throwsA(
              isA<CredentialUnavailableException>().having(
                (error) => error.reason,
                'reason',
                CredentialUnavailableReason.cancelled,
              ),
            ),
          );
        } else {
          if (failure == 'auth') {
            await _respondWith(transport, {'state': 'AUTH_ERR'});
          } else {
            await _respondWith(transport, {'state': 'SUCCESS'});
            await _waitForSend(transport, 2);
            transport.add('{invalid');
          }
          await expectLater(future, throwsA(anything));
        }
        expect(vault.writes, isEmpty, reason: failure);
        expect(transport.closeCalls, 1, reason: failure);
      }
    },
  );

  test(
    'maps a write failure to a fixed safe typed error and closes once',
    () async {
      final transport = InMemoryTransport();
      final repository = TrueNasSessionRepository(
        connector: FakeConnector(transport),
        credentialVault: _RecordingVault(<String>[], failWrite: true),
      );
      final future = repository.connect(
        serverInput: 'https://nas.example',
        apiKey: 'explicit-test-key',
        rememberApiKey: true,
      );
      await _respondHandshake(transport);
      await expectLater(
        future,
        throwsA(
          isA<CredentialUnavailableException>().having(
            (error) => error.reason,
            'reason',
            CredentialUnavailableReason.unavailable,
          ),
        ),
      );
      expect(transport.closeCalls, 1);
    },
  );

  test('invalidating during a remembered-key write restores the prior key and closes once', () async {
    final transport = InMemoryTransport();
    final vault = _RaceVault('prior-remembered-key');
    var current = true;
    final repository = TrueNasSessionRepository(
      connector: FakeConnector(transport),
      credentialVault: vault,
    );

    final connecting = repository.connect(
      serverInput: 'https://nas.example',
      apiKey: 'stale-explicit-key',
      rememberApiKey: true,
      isConnectionCurrent: () => current,
    );
    await _respondHandshake(transport);
    await vault.writeStarted.future;
    current = false;
    vault.releaseWrite();

    await expectLater(
      connecting,
      throwsA(
        isA<CredentialUnavailableException>().having(
          (error) => error.reason,
          'reason',
          CredentialUnavailableReason.cancelled,
        ),
      ),
    );
    expect(vault.value, 'prior-remembered-key');
    expect(vault.successes, 0);
    expect(transport.closeCalls, 1);
  });

  for (final scenario in <_HostileCallbackScenario>[
    const _HostileCallbackScenario('before vault read', 1, null, 0),
    const _HostileCallbackScenario('after vault read', 3, null, 0),
    const _HostileCallbackScenario('after auth', 3, 'explicit-test-key', 1),
    const _HostileCallbackScenario('after summary', 6, 'explicit-test-key', 4),
    const _HostileCallbackScenario(
      'during vault write',
      8,
      'explicit-test-key',
      4,
    ),
    const _HostileCallbackScenario(
      'after vault write',
      9,
      'explicit-test-key',
      4,
    ),
    const _HostileCallbackScenario(
      'final pre-return',
      10,
      'explicit-test-key',
      4,
    ),
  ]) {
    test('contains hostile callback ${scenario.name}', () async {
      final transport = InMemoryTransport();
      final vault = _CallbackRecordingVault('remembered-test-key');
      var calls = 0;
      final repository = TrueNasSessionRepository(
        connector: FakeConnector(transport),
        credentialVault: vault,
      );
      final connecting = repository.connect(
        serverInput: 'https://nas.example',
        apiKey: scenario.apiKey,
        rememberApiKey: scenario.apiKey != null,
        isConnectionCurrent: () {
          if (++calls == scenario.throwOnCall) {
            throw StateError('hostile callback TEST_API_KEY_SENTINEL');
          }
          return true;
        },
      );

      for (var index = 0; index < scenario.responses; index++) {
        await _respondWith(transport, switch (index) {
          0 => {'state': 'SUCCESS'},
          1 => {'username': 'admin'},
          2 => {'version': '25.10'},
          _ => {'a': {}},
        });
      }

      await expectLater(
        connecting,
        throwsA(
          isA<CredentialUnavailableException>().having(
            (error) => error.reason,
            'reason',
            anyOf(
              CredentialUnavailableReason.cancelled,
              CredentialUnavailableReason.unavailable,
            ),
          ),
        ),
      );
      try {
        await connecting;
      } on CredentialUnavailableException catch (error) {
        expect(error.toString(), isNot(contains('TEST_API_KEY_SENTINEL')));
        expect(error.userMessage, isNot(contains('TEST_API_KEY_SENTINEL')));
      }
      expect(vault.writes, scenario.throwOnCall < 8 ? isEmpty : hasLength(1));
      expect(transport.closeCalls, 1);
      await repository.close();
      expect(transport.closeCalls, 1);
    });
  }

  test(
    'maps a cancelled vault write without probing a hostile callback again',
    () async {
      final transport = InMemoryTransport();
      final repository = TrueNasSessionRepository(
        connector: FakeConnector(transport),
        credentialVault: const _CancelledWriteVault(),
      );
      var calls = 0;
      final connecting = repository.connect(
        serverInput: 'https://nas.example',
        apiKey: 'explicit-test-key',
        rememberApiKey: true,
        isConnectionCurrent: () {
          if (++calls == 8) {
            throw StateError('hostile callback TEST_API_KEY_SENTINEL');
          }
          return true;
        },
      );
      await _respondHandshake(transport);

      await expectLater(
        connecting,
        throwsA(
          isA<CredentialUnavailableException>().having(
            (error) => error.reason,
            'reason',
            CredentialUnavailableReason.cancelled,
          ),
        ),
      );
      expect(transport.closeCalls, 1);
    },
  );

  test(
    'in-memory vault restores a prior key when currentness throws',
    () async {
      final vault = InMemoryCredentialVault();
      const endpoint = 'wss://nas.example/api/current';
      await vault.writeApiKey(endpoint, 'prior-key');
      var calls = 0;

      await expectLater(
        vault.writeApiKey(
          endpoint,
          'stale-key',
          isCurrent: () {
            if (++calls == 3) {
              throw StateError('hostile callback TEST_API_KEY_SENTINEL');
            }
            return true;
          },
        ),
        throwsA(
          isA<CredentialWriteCancelledException>().having(
            (error) => error.toString(),
            'safe text',
            isNot(contains('TEST_API_KEY_SENTINEL')),
          ),
        ),
      );

      expect(await vault.readApiKey(endpoint), 'prior-key');
    },
  );
}

final class _HostileCallbackScenario {
  const _HostileCallbackScenario(
    this.name,
    this.throwOnCall,
    this.apiKey,
    this.responses,
  );

  final String name;
  final int throwOnCall;
  final String? apiKey;
  final int responses;
}

final class _RecordingConnector implements RpcConnector {
  _RecordingConnector(this.transport, this.events);
  final RpcTransport transport;
  final List<String> events;

  @override
  Future<RpcTransport> connect(Uri endpoint) async {
    events.add('connector');
    return transport;
  }
}

final class _RecordingVault implements CredentialVault {
  _RecordingVault(
    this.events, {
    this.rememberedKey,
    this.failRead = false,
    this.failWrite = false,
  });
  final List<String> events;
  final String? rememberedKey;
  final bool failRead;
  final bool failWrite;
  final writes = <(String, String)>[];

  @override
  Future<String?> readApiKey(String endpointIdentifier) async {
    events.add('read:$endpointIdentifier');
    if (failRead) throw StateError('native credential detail');
    return rememberedKey;
  }

  @override
  Future<void> writeApiKey(
    String endpointIdentifier,
    String apiKey, {
    bool Function()? isCurrent,
  }) async {
    events.add('write:$endpointIdentifier');
    if (failWrite) throw StateError('native credential detail');
    writes.add((endpointIdentifier, apiKey));
  }

  @override
  Future<void> deleteApiKey(String endpointIdentifier) async {}
}

final class _RaceVault implements CredentialVault {
  _RaceVault(this.value);

  String? value;
  var successes = 0;
  final writeStarted = Completer<void>();
  final _writeGate = Completer<void>();

  void releaseWrite() => _writeGate.complete();

  @override
  Future<void> deleteApiKey(String endpointIdentifier) async => value = null;

  @override
  Future<String?> readApiKey(String endpointIdentifier) async => value;

  @override
  Future<void> writeApiKey(
    String endpointIdentifier,
    String apiKey, {
    bool Function()? isCurrent,
  }) async {
    final previous = value;
    writeStarted.complete();
    await _writeGate.future;
    value = apiKey;
    if (!(isCurrent?.call() ?? true)) {
      value = previous;
      throw const CredentialWriteCancelledException();
    }
    successes++;
  }
}

final class _CallbackRecordingVault implements CredentialVault {
  _CallbackRecordingVault(this.value);

  String? value;
  final writes = <(String, String)>[];

  @override
  Future<void> deleteApiKey(String endpointIdentifier) async => value = null;

  @override
  Future<String?> readApiKey(String endpointIdentifier) async => value;

  @override
  Future<void> writeApiKey(
    String endpointIdentifier,
    String apiKey, {
    bool Function()? isCurrent,
  }) async {
    writes.add((endpointIdentifier, apiKey));
    value = apiKey;
    isCurrent?.call();
  }
}

final class _CancelledWriteVault implements CredentialVault {
  const _CancelledWriteVault();

  @override
  Future<void> deleteApiKey(String endpointIdentifier) async {}

  @override
  Future<String?> readApiKey(String endpointIdentifier) async => null;

  @override
  Future<void> writeApiKey(
    String endpointIdentifier,
    String apiKey, {
    bool Function()? isCurrent,
  }) async => throw const CredentialWriteCancelledException();
}

Future<void> _respondHandshake(InMemoryTransport transport) async {
  for (final result in [
    {'state': 'SUCCESS'},
    {'username': 'admin'},
    {'version': '25.10'},
    {'a': {}, 'b': {}},
  ]) {
    await _waitForSend(transport, transport.sentFrames.length + 1);
    final id = jsonDecode(transport.sentFrames.last)['id'];
    transport.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
  }
}

Future<void> _respondWith(InMemoryTransport transport, Object result) async {
  await _waitForSend(transport, transport.sentFrames.length + 1);
  final id = jsonDecode(transport.sentFrames.last)['id'];
  transport.add(jsonEncode({'jsonrpc': '2.0', 'id': id, 'result': result}));
}

Future<void> _waitForSend(InMemoryTransport transport, int count) async {
  while (transport.sentFrames.length < count) {
    await Future<void>.delayed(Duration.zero);
  }
}
