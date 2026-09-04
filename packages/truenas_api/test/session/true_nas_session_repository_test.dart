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
