import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:truenas_api/truenas_api.dart';

import '../../tool/readonly_live_probe.dart';
import '../../tool/readonly_probe_policy.dart';

void main() {
  late Directory temporary;
  late SecurityContext serverContext;
  late SecurityContext trustedContext;
  late String matchingPin;
  final wrongPin = List.filled(64, '0').join();

  setUpAll(() async {
    // Only ephemeral test credentials are generated; no appliance is contacted.
    temporary = await Directory.systemTemp.createTemp('readonly-probe-tls-');
    final certificate = '${temporary.path}/localhost.pem';
    final privateKey = '${temporary.path}/localhost-key.pem';
    final generated = await Process.run('openssl', [
      'req',
      '-x509',
      '-newkey',
      'rsa:2048',
      '-nodes',
      '-days',
      '1',
      '-subj',
      '/CN=127.0.0.1',
      '-addext',
      'subjectAltName=IP:127.0.0.1',
      '-keyout',
      privateKey,
      '-out',
      certificate,
    ]);
    expect(generated.exitCode, 0, reason: 'Local TLS fixture generation');
    final pem = await File(certificate).readAsString();
    final der = base64Decode(
      pem.split('\n').where((line) => !line.startsWith('-----')).join(),
    );
    matchingPin = sha256.convert(der).toString();
    serverContext = SecurityContext()
      ..useCertificateChain(certificate)
      ..usePrivateKey(privateKey);
    trustedContext = SecurityContext(withTrustedRoots: false)
      ..setTrustedCertificates(certificate);
  });

  tearDownAll(() async {
    if (await temporary.exists()) await temporary.delete(recursive: true);
  });

  Future<_LocalServer> server({
    bool redirect = false,
    bool badAccept = false,
  }) => _LocalServer.start(
    serverContext,
    redirect: redirect,
    badAccept: badAccept,
  );

  test('matching pin authenticates only after a valid upgrade', () async {
    final local = await server();
    final connector = PinnedProbeConnector(local.endpoint, matchingPin);
    final repository = TrueNasSessionRepository(
      connector: connector,
      credentialVault: const NoopCredentialVault(),
    );
    addTearDown(() async {
      connector.dispose();
      await repository.close();
      await local.close();
    });

    final summary = await repository
        .connect(
          serverInput: local.endpoint.replace(scheme: 'https').toString(),
          username: 'local-test-account',
          apiKey: 'synthetic-test-api-key',
          rememberApiKey: false,
        )
        .timeout(const Duration(seconds: 5));

    expect(summary.version, '25.10.0');
    expect(local.requestCount, 1);
    expect(local.authorizationHeaders, everyElement(isNull));
    expect(local.frames.map((frame) => frame['method']), [
      'auth.login_ex',
      'auth.me',
      'system.info',
      'core.get_methods',
    ]);
    expect(local.frames.first['params'], [
      {
        'mechanism': 'API_KEY_PLAIN',
        'username': 'local-test-account',
        'api_key': 'synthetic-test-api-key',
      },
    ]);
  });

  test('wrong untrusted pin prevents even an HTTP upgrade request', () async {
    final local = await server();
    final connector = PinnedProbeConnector(local.endpoint, wrongPin);
    addTearDown(() async {
      connector.dispose();
      await local.close();
    });
    await expectLater(
      connector.connect(local.endpoint),
      throwsA(isA<HandshakeException>()),
    );
    expect(local.requestCount, 0);
    expect(local.frames, isEmpty);
  });

  test(
    'wrong pin rejects an otherwise trusted TLS certificate before RPC',
    () async {
      final local = await server();
      final connector = PinnedProbeConnector(local.endpoint, wrongPin);
      addTearDown(() async {
        connector.dispose();
        await local.close();
      });
      await HttpOverrides.runWithHttpOverrides(
        () => expectLater(
          connector.connect(local.endpoint),
          throwsA(isA<HandshakeException>()),
        ),
        _TrustedFixtureHttpOverrides(trustedContext),
      );
      expect(local.requestCount, 1);
      expect(local.frames, isEmpty);
    },
  );

  test('redirects are rejected without following or authenticating', () async {
    final local = await server(redirect: true);
    final connector = PinnedProbeConnector(local.endpoint, matchingPin);
    addTearDown(() async {
      connector.dispose();
      await local.close();
    });
    await expectLater(
      connector.connect(local.endpoint),
      throwsA(isA<HandshakeException>()),
    );
    expect(local.requestCount, 1);
    expect(local.frames, isEmpty);
    expect(local.authorizationHeaders, everyElement(isNull));
  });

  test(
    'matching certificate does not bypass invalid upgrade acceptance',
    () async {
      final local = await server(badAccept: true);
      final connector = PinnedProbeConnector(local.endpoint, matchingPin);
      addTearDown(() async {
        connector.dispose();
        await local.close();
      });
      await expectLater(
        connector.connect(local.endpoint),
        throwsA(isA<HandshakeException>()),
      );
      expect(local.requestCount, 1);
      expect(local.frames, isEmpty);
    },
  );

  test('forbidden writes never reach a successfully pinned socket', () async {
    final local = await server();
    final connector = PinnedProbeConnector(local.endpoint, matchingPin);
    addTearDown(() async {
      connector.dispose();
      await local.close();
    });
    final transport = await connector.connect(local.endpoint);
    await expectLater(
      transport.send(
        jsonEncode({
          'jsonrpc': '2.0',
          'id': 1,
          'method': 'system.reboot',
          'params': [],
        }),
      ),
      throwsA(isA<ReadOnlyProbePolicyException>()),
    );
    await transport.send(
      jsonEncode({'jsonrpc': '2.0', 'id': 2, 'method': 'system.info'}),
    );
    final response = await transport.inboundFrames.first.timeout(
      const Duration(seconds: 3),
    );
    expect((jsonDecode(response) as Map)['id'], 2);
    expect(local.frames.map((frame) => frame['method']), ['system.info']);
    expect(connector.policy.callCounts, {'system.info': 1});
  });

  test(
    'a different endpoint and plaintext are rejected before connection',
    () async {
      final local = await server();
      final connector = PinnedProbeConnector(local.endpoint, matchingPin);
      addTearDown(() async {
        connector.dispose();
        await local.close();
      });
      for (final target in [
        local.endpoint.replace(path: '/other'),
        local.endpoint.replace(scheme: 'ws'),
      ]) {
        await expectLater(
          connector.connect(target),
          throwsA(isA<HandshakeException>()),
        );
      }
      expect(local.requestCount, 0);
      connector.dispose();
      await expectLater(
        connector.connect(local.endpoint),
        throwsA(isA<HandshakeException>()),
      );
    },
  );
}

final class _TrustedFixtureHttpOverrides extends HttpOverrides {
  _TrustedFixtureHttpOverrides(this.context);
  final SecurityContext context;
  @override
  HttpClient createHttpClient(SecurityContext? _) =>
      super.createHttpClient(context);
}

final class _LocalServer {
  _LocalServer(this.server);
  final HttpServer server;
  final frames = <Map<String, dynamic>>[];
  final authorizationHeaders = <String?>[];
  final sockets = <WebSocket>[];
  int requestCount = 0;
  Uri get endpoint => Uri(
    scheme: 'wss',
    host: '127.0.0.1',
    port: server.port,
    path: '/api/current',
  );

  static Future<_LocalServer> start(
    SecurityContext context, {
    required bool redirect,
    required bool badAccept,
  }) async {
    final local = _LocalServer(
      await HttpServer.bindSecure(InternetAddress.loopbackIPv4, 0, context),
    );
    local.server.listen((request) async {
      local.requestCount++;
      local.authorizationHeaders.add(
        request.headers.value(HttpHeaders.authorizationHeader),
      );
      if (redirect) {
        request.response.statusCode = HttpStatus.temporaryRedirect;
        request.response.headers.set(
          HttpHeaders.locationHeader,
          local.endpoint
              .replace(scheme: 'https', path: '/redirected')
              .toString(),
        );
        await request.response.close();
        return;
      }
      if (badAccept) {
        request.response.statusCode = HttpStatus.switchingProtocols;
        request.response.headers
          ..set(HttpHeaders.upgradeHeader, 'websocket')
          ..set(HttpHeaders.connectionHeader, 'Upgrade')
          ..set('Sec-WebSocket-Accept', 'incorrect-accept-value');
        await request.response.close();
        return;
      }
      final socket = await WebSocketTransformer.upgrade(
        request,
        compression: CompressionOptions.compressionOff,
      );
      local.sockets.add(socket);
      socket.listen((event) {
        final frame = jsonDecode(event as String) as Map<String, dynamic>;
        local.frames.add(frame);
        final Object? result = switch (frame['method']) {
          'auth.login_ex' => {'response_type': 'SUCCESS'},
          'auth.me' => {'username': 'local-test-account'},
          'system.info' => {'version': '25.10.0'},
          'core.get_methods' => <String, Object?>{},
          _ => null,
        };
        socket.add(
          jsonEncode({'jsonrpc': '2.0', 'id': frame['id'], 'result': result}),
        );
      }, onError: (Object _) {});
    }, onError: (Object _) {});
    return local;
  }

  Future<void> close() async {
    for (final socket in sockets) {
      unawaited(socket.close());
    }
    await server.close(force: true);
  }
}
