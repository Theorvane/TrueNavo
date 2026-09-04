import 'dart:convert';

import 'package:test/test.dart';
import 'package:truenas_api/truenas_api.dart';

import '../support/in_memory_transport.dart';

void main() {
  test('sends caller ID and completes matching result', () async {
    final transport = InMemoryTransport();
    final client = JsonRpcClient(transport);
    final result = client.call('system.info', id: 'one');
    expect(jsonDecode(transport.sentFrames.single)['id'], 'one');
    transport.add('{"jsonrpc":"2.0","id":"one","result":{"version":"x"}}');
    expect(await result, {'version': 'x'});
    await client.close();
  });

  test(
    'correlates out-of-order responses and ignores notification completion',
    () async {
      final transport = InMemoryTransport();
      final client = JsonRpcClient(transport);
      final first = client.call('a', id: 1);
      final second = client.call('b', id: 2);
      transport.add(
        '{"jsonrpc":"2.0","method":"collection_update","params":{}}',
      );
      transport.add('{"jsonrpc":"2.0","id":2,"result":"second"}');
      transport.add('{"jsonrpc":"2.0","id":1,"result":"first"}');
      expect(await first, 'first');
      expect(await second, 'second');
      await client.close();
    },
  );

  test('preserves remote errors', () async {
    final transport = InMemoryTransport();
    final client = JsonRpcClient(transport);
    final result = client.call('a', id: 'x');
    transport.add(
      '{"jsonrpc":"2.0","id":"x","error":{"code":-32000,"message":"denied","data":{"a":1}}}',
    );
    await expectLater(
      result,
      throwsA(
        isA<JsonRpcRemoteException>().having((e) => e.code, 'code', -32000),
      ),
    );
    await client.close();
  });

  test('protocol violations are observable and settle pending calls', () async {
    final transport = InMemoryTransport();
    final client = JsonRpcClient(transport);
    final errors = <JsonRpcProtocolException>[];
    final subscription = client.protocolErrors.listen(errors.add);
    final result = client.call('a', id: 'x');
    transport.add('{bad');
    await expectLater(result, throwsA(isA<JsonRpcProtocolException>()));
    await Future<void>.delayed(Duration.zero);
    expect(errors, isNotEmpty);
    await subscription.cancel();
    await client.close();
  });

  test('an invalid error object settles its matching pending call', () async {
    final transport = InMemoryTransport();
    final client = JsonRpcClient(transport);
    final result = client.call('a', id: 'x');
    transport.add('{"jsonrpc":"2.0","id":"x","error":{"code":"bad"}}');
    await expectLater(
      result.timeout(const Duration(milliseconds: 100)),
      throwsA(isA<JsonRpcProtocolException>()),
    );
    await client.close();
  });

  test(
    'an invalid response ID settles pending calls with a protocol error',
    () async {
      final transport = InMemoryTransport();
      final client = JsonRpcClient(transport);
      final result = client.call('a', id: 'x');
      transport.add('{"jsonrpc":"2.0","id":null,"result":true}');
      await expectLater(result, throwsA(isA<JsonRpcProtocolException>()));
      await client.close();
    },
  );

  test('unknown or duplicate IDs are protocol errors', () async {
    final transport = InMemoryTransport();
    final client = JsonRpcClient(transport);
    final result = client.call('a', id: 'x');
    transport.add('{"jsonrpc":"2.0","id":"x","result":true}');
    await result;
    final error = client.protocolErrors.first;
    transport.add('{"jsonrpc":"2.0","id":"x","result":true}');
    await expectLater(error, completes);
    await client.close();
  });

  for (final response in [
    '{"jsonrpc":"1.0","id":"x","result":true}',
    '{"jsonrpc":"2.0","id":"x","result":true,"error":{}}',
    '{"jsonrpc":"2.0","id":"x"}',
    '{"jsonrpc":"2.0","id":"unknown","result":true}',
  ]) {
    test('settles pending calls for a protocol violation', () async {
      final transport = InMemoryTransport();
      final client = JsonRpcClient(transport);
      final result = client.call('a', id: 'x');
      transport.add(response);
      await expectLater(result, throwsA(isA<JsonRpcProtocolException>()));
      await client.close();
    });
  }

  test('closing fails pending operations and is idempotent', () async {
    final transport = InMemoryTransport();
    final client = JsonRpcClient(transport);
    final result = client.call('a', id: 'x');
    final settled = expectLater(
      result,
      throwsA(isA<RpcTransportClosedException>()),
    );
    await client.close();
    await settled;
    await client.close();
    expect(transport.closeCalls, 1);
  });

  test('a socket close fails every pending operation', () async {
    final transport = InMemoryTransport();
    final client = JsonRpcClient(transport);
    final first = expectLater(
      client.call('a', id: 'first'),
      throwsA(isA<RpcTransportClosedException>()),
    );
    final second = expectLater(
      client.call('b', id: 'second'),
      throwsA(isA<RpcTransportClosedException>()),
    );
    await transport.finish();
    await Future.wait([first, second]);
    await client.close();
  });
}
